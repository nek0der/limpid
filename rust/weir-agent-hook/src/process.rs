//! Process inspection through `ps`, which every supported Unix ships. The
//! functions degrade to `None` on any failure; a missing pid only means the
//! host cannot sweep this run.

#[cfg(unix)]
use std::process::Command;

/// Walks up from the current process looking for an ancestor whose `comm`
/// is one of `names`, at most ten hops. Agents spawn hooks through
/// intermediate shells, so the parent is rarely the agent itself.
#[cfg(unix)]
#[must_use]
pub fn find_ancestor_named(names: &[String]) -> Option<u32> {
    find_ancestor_in(std::process::id(), names, parent_and_comm)
}

#[cfg(not(unix))]
#[must_use]
pub fn find_ancestor_named(_names: &[String]) -> Option<u32> {
    None
}

/// The walk itself over a process table given as a lookup function, so the
/// rule can be tested without spawning anything. Returns the pid whose
/// `comm` matched, never its parent. The parsers below are compiled off
/// Unix only for their tests, so a non-Unix build stays warning-free.
#[cfg(any(unix, test))]
fn find_ancestor_in(
    start: u32,
    names: &[String],
    lookup: impl Fn(u32) -> Option<(u32, String)>,
) -> Option<u32> {
    let mut pid = start;
    for _ in 0..10 {
        let (parent, comm) = lookup(pid)?;
        if names.iter().any(|name| comm_matches(&comm, name)) {
            return Some(pid);
        }
        if parent <= 1 {
            return None;
        }
        pid = parent;
    }
    None
}

/// `ps` reports either the bare name or a full path; both count.
#[cfg(any(unix, test))]
fn comm_matches(comm: &str, name: &str) -> bool {
    comm == name || comm.rsplit('/').next() == Some(name)
}

#[cfg(unix)]
fn parent_and_comm(pid: u32) -> Option<(u32, String)> {
    let output = Command::new("/bin/ps")
        .args(["-o", "ppid=,comm=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    parse_parent_and_comm(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(any(unix, test))]
fn parse_parent_and_comm(line: &str) -> Option<(u32, String)> {
    let line = line.trim();
    let (parent, comm) = line.split_once(char::is_whitespace)?;
    Some((parent.parse().ok()?, comm.trim().to_owned()))
}

/// The Unix epoch second a process started, from `ps -o lstart=` rendered in
/// UTC and the C locale.
#[cfg(unix)]
#[must_use]
pub fn start_epoch(pid: u32) -> Option<u64> {
    let output = Command::new("/bin/ps")
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .output()
        .ok()?;
    parse_lstart(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(not(unix))]
#[must_use]
pub fn start_epoch(_pid: u32) -> Option<u64> {
    None
}

/// Parses `Mon Sep 14 01:02:03 2026` as UTC.
#[cfg(any(unix, test))]
fn parse_lstart(value: &str) -> Option<u64> {
    let mut parts = value.split_whitespace();
    let _weekday = parts.next()?;
    let month = match parts.next()? {
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12,
        _ => return None,
    };
    let day: u32 = parts.next()?.parse().ok()?;
    let mut clock = parts.next()?.split(':');
    let hour: u32 = clock.next()?.parse().ok()?;
    let minute: u32 = clock.next()?.parse().ok()?;
    let second: u32 = clock.next()?.parse().ok()?;
    let year: i64 = parts.next()?.parse().ok()?;
    let days = weir_agent_model::days_from_civil(year, month, day)?;
    let seconds = i64::from(hour) * 3600 + i64::from(minute) * 60 + i64::from(second);
    u64::try_from(days * 86_400 + seconds).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ps_output_shapes() {
        assert_eq!(
            parse_parent_and_comm("  4242 /opt/homebrew/bin/claude\n"),
            Some((4242, "/opt/homebrew/bin/claude".into()))
        );
        assert_eq!(parse_parent_and_comm(""), None);
        assert!(comm_matches("/opt/homebrew/bin/claude", "claude"));
        assert!(!comm_matches("claude.sh", "claude"));
    }

    #[test]
    fn the_walk_returns_the_matching_process_not_its_parent() {
        // Each entry is `pid => (parent, comm)`:
        // 100 (the hook) -> 90 (sh) -> 80 (claude) -> 1 (launchd).
        let table = |pid: u32| match pid {
            100 => Some((90, "AgentIntegrationHookHelper".to_owned())),
            90 => Some((80, "sh".to_owned())),
            80 => Some((1, "/opt/homebrew/bin/claude".to_owned())),
            _ => None,
        };
        assert_eq!(
            find_ancestor_in(100, &["claude".to_owned()], table),
            Some(80),
            "the agent's own pid, not the shell that spawned the hook"
        );
        assert_eq!(find_ancestor_in(100, &["codex".to_owned()], table), None);
        // A start that matches is itself the answer.
        assert_eq!(
            find_ancestor_in(80, &["claude".to_owned()], table),
            Some(80)
        );
    }

    /// The host matches a record's tmux server on the kernel's start second
    /// of the server process (`TmuxClientProbe.processStartSecond`), not on
    /// tmux's `#{start_time}`, which tmux sets a moment later and so can be a
    /// second ahead. Both sides read one value only if `ps` reports exactly
    /// the kernel's second, which this pins.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_start_recorded_is_the_kernels_start_second() {
        let pid = std::process::id();
        // SAFETY: `proc_bsdinfo` is plain integers and byte arrays, for
        // which all zeroes is a valid value.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = i32::try_from(std::mem::size_of::<libc::proc_bsdinfo>()).expect("size");
        // SAFETY: `info` is a writable `proc_bsdinfo` of exactly `size` bytes,
        // which is what this flavor fills.
        let written = unsafe {
            libc::proc_pidinfo(
                i32::try_from(pid).expect("pid"),
                libc::PROC_PIDTBSDINFO,
                0,
                std::ptr::addr_of_mut!(info).cast(),
                size,
            )
        };
        assert_eq!(written, size);
        assert_eq!(start_epoch(pid), Some(info.pbi_start_tvsec));
    }

    #[test]
    fn lstart_is_read_as_utc() {
        assert_eq!(parse_lstart("Thu Jan  1 00:00:00 1970\n"), Some(0));
        assert_eq!(
            parse_lstart("Sun Sep 13 16:00:00 2026"),
            Some(1_789_315_200)
        );
        assert_eq!(parse_lstart("garbage"), None);
    }
}
