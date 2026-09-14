//! ISO-8601 UTC timestamps with second precision, the format every record
//! field has always used, without a calendar dependency.
//!
//! Both the hook runtime and the projection need these: the hook runtime stamps records,
//! and the projection compares them against retention windows. Keeping one
//! implementation is what stops a record written in one format from being read
//! as another.

use std::time::{SystemTime, UNIX_EPOCH};

/// `2026-09-14T00:00:00Z` for `time`.
#[must_use]
pub fn format_utc_seconds(time: SystemTime) -> String {
    let seconds = unix_seconds(time);
    let days = i64::try_from(seconds / 86_400).unwrap_or(0);
    let remainder = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        remainder / 3600,
        (remainder % 3600) / 60,
        remainder % 60
    )
}

/// Whole seconds since the Unix epoch, zero for times before it.
#[must_use]
pub fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs())
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`).
#[must_use]
pub fn days_from_civil(year: i64, month: u32, day: u32) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_index = i64::from(if month > 2 { month - 3 } else { month + 9 });
    let day_of_year = (153 * month_index + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

/// The inverse of `days_from_civil`.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = if shifted >= 0 {
        shifted
    } else {
        shifted - 146_096
    } / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = u32::try_from(day_of_year - (153 * month_index + 2) / 5 + 1).unwrap_or(1);
    let month = u32::try_from(if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    })
    .unwrap_or(1);
    (if month <= 2 { year + 1 } else { year }, month, day)
}

/// Whole seconds since the Unix epoch for an ISO-8601 UTC timestamp with
/// second precision, as records carry them. Returns `None` for anything else,
/// including the empty string a version 2 record used for "not started".
///
/// Deliberately narrow: this reads back what `format_utc_seconds` wrote, not
/// arbitrary ISO-8601. A record with an offset or a fractional second did not
/// come from this code, and guessing at it would be worse than ignoring it.
#[must_use]
pub fn parse_utc_seconds(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    if bytes[10] != b'T' || bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'Z' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| value.get(range)?.parse::<i64>().ok();
    let year = number(0..4)?;
    let month = u32::try_from(number(5..7)?).ok()?;
    let day = u32::try_from(number(8..10)?).ok()?;
    let hour = number(11..13)?;
    let minute = number(14..16)?;
    let second = number(17..19)?;
    if !(0..24).contains(&hour) || !(0..60).contains(&minute) || !(0..60).contains(&second) {
        return None;
    }
    let days = days_from_civil(year, month, day)?;
    let total = days.checked_mul(86_400)? + hour * 3600 + minute * 60 + second;
    u64::try_from(total).ok()
}

/// Seconds between two record timestamps, or `None` when either is unreadable.
/// Negative differences clamp to zero: a record stamped in the future is a
/// clock that moved, not an event that has not happened yet.
#[must_use]
pub fn seconds_between(earlier: &str, later: &str) -> Option<u64> {
    let earlier = parse_utc_seconds(earlier)?;
    let later = parse_utc_seconds(later)?;
    Some(later.saturating_sub(earlier))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn formats_known_instants() {
        assert_eq!(format_utc_seconds(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        let time = UNIX_EPOCH + Duration::from_secs(1_789_315_201);
        assert_eq!(format_utc_seconds(time), "2026-09-13T16:00:01Z");
        let leap = UNIX_EPOCH + Duration::from_secs(951_782_401);
        assert_eq!(format_utc_seconds(leap), "2000-02-29T00:00:01Z");
    }

    #[test]
    fn civil_conversions_round_trip() {
        for days in [-719_468, -1, 0, 1, 10_957, 20_000, 30_000, 100_000] {
            let (year, month, day) = civil_from_days(days);
            assert_eq!(days_from_civil(year, month, day), Some(days));
        }
        assert_eq!(days_from_civil(2026, 13, 1), None);
    }
}
