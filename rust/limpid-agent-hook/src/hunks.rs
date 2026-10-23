//! Taking hunks of a file's diff back out of what the file holds now: the
//! discard of a review hunk.
//!
//! A hunk is read from git's own unified diff, as bytes, so what is taken
//! back is exactly what the review showed. Its new side is looked for in the
//! file as it is now, and replaced by its old side only where it is found
//! whole and only once: where the diff put it (moved by what the hunks
//! before it changed), else at the one place in the file it is. A hunk
//! whose lines changed since, are gone, or are in more than one place
//! elsewhere is reported and left alone. There is no fuzz: context that
//! differs means the person did not see what would be written over.

/// One hunk of a unified diff.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    /// The `@@ -a,b +c,d @@` part of the hunk's line: the review names a
    /// hunk by it (`ranges`), and a discard checks it is the hunk the review
    /// showed. The function name git may add after it is left out: it may
    /// be any bytes, and the review draws it with some of them replaced.
    pub header: String,
    new_start: usize,
    old: Vec<Vec<u8>>,
    new: Vec<Vec<u8>>,
    /// Whether the old side's last line, or the new side's, ends the file
    /// without a newline (`\ No newline at end of file`).
    old_lacks_newline: bool,
    new_lacks_newline: bool,
}

/// A file's lines, and whether its last one ends with a newline.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Text {
    lines: Vec<Vec<u8>>,
    ends_with_newline: bool,
}

impl Text {
    #[must_use]
    pub fn from_bytes(bytes: &[u8]) -> Self {
        if bytes.is_empty() {
            return Self {
                lines: Vec::new(),
                ends_with_newline: true,
            };
        }
        let ends_with_newline = bytes.last() == Some(&b'\n');
        let body = if ends_with_newline {
            &bytes[..bytes.len() - 1]
        } else {
            bytes
        };
        Self {
            lines: body
                .split(|byte| *byte == b'\n')
                .map(<[u8]>::to_vec)
                .collect(),
            ends_with_newline,
        }
    }

    #[must_use]
    pub fn into_bytes(self) -> Vec<u8> {
        let mut bytes = self.lines.join(&b'\n');
        if self.ends_with_newline && !self.lines.is_empty() {
            bytes.push(b'\n');
        }
        bytes
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }
}

/// Every hunk of one file's patch, in order. `None` when the patch is not
/// one git writes.
#[must_use]
pub fn parse(patch: &[u8]) -> Option<Vec<Hunk>> {
    let mut hunks: Vec<Hunk> = Vec::new();
    // What the current hunk still expects, old side then new side.
    let mut remaining = (0_usize, 0_usize);
    // Which sides the last line belonged to, for a marker after it.
    let mut last = (false, false);
    let mut lines = patch.split(|byte| *byte == b'\n').peekable();
    while let Some(line) = lines.next() {
        if line.is_empty() && lines.peek().is_none() {
            break;
        }
        if line.starts_with(b"@@ ") {
            if remaining != (0, 0) {
                return None;
            }
            let (hunk, counts) = header(line)?;
            hunks.push(hunk);
            remaining = counts;
            last = (false, false);
            continue;
        }
        let Some(hunk) = hunks.last_mut() else {
            // The file's headers, before its first hunk.
            continue;
        };
        let (tag, text) = match line.split_first() {
            Some((tag, text)) => (*tag, text.to_vec()),
            // An empty context line, as some tools write it.
            None => (b' ', Vec::new()),
        };
        match tag {
            b' ' if remaining.0 > 0 && remaining.1 > 0 => {
                hunk.old.push(text.clone());
                hunk.new.push(text);
                remaining = (remaining.0 - 1, remaining.1 - 1);
                last = (true, true);
            }
            b'-' if remaining.0 > 0 => {
                hunk.old.push(text);
                remaining.0 -= 1;
                last = (true, false);
            }
            b'+' if remaining.1 > 0 => {
                hunk.new.push(text);
                remaining.1 -= 1;
                last = (false, true);
            }
            b'\\' => {
                hunk.old_lacks_newline |= last.0;
                hunk.new_lacks_newline |= last.1;
            }
            // Past the hunk's counts: the next file's headers, or a line
            // the patch does not account for.
            _ if remaining == (0, 0) => {}
            _ => return None,
        }
    }
    (remaining == (0, 0)).then_some(hunks)
}

/// The ranges part of a hunk's `@@` line, as `Hunk::header` keeps it:
/// what names the hunk.
#[must_use]
pub fn ranges(header: &str) -> &str {
    header
        .get(3..)
        .and_then(|rest| rest.find(" @@"))
        .map_or(header, |end| &header[..end + 6])
}

/// The header's hunk, empty, and the line counts it announces.
fn header(line: &[u8]) -> Option<(Hunk, (usize, usize))> {
    // Only the ranges, which git writes in ASCII; what follows is the
    // function the hunk is in, in the file's own bytes.
    let close = line
        .get(3..)?
        .windows(3)
        .position(|window| window == b" @@")?
        + 3;
    let text = std::str::from_utf8(&line[..close + 3]).ok()?;
    let (old, rest) = text.strip_prefix("@@ -")?.split_once(" +")?;
    let new = rest.strip_suffix(" @@")?;
    let range = |range: &str| -> Option<(usize, usize)> {
        match range.split_once(',') {
            Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
            None => Some((range.parse().ok()?, 1)),
        }
    };
    let (_, old_count) = range(old)?;
    let (new_start, new_count) = range(new)?;
    let header = text.to_owned();
    Some((
        Hunk {
            header,
            new_start,
            old: Vec::with_capacity(old_count),
            new: Vec::with_capacity(new_count),
            old_lacks_newline: false,
            new_lacks_newline: false,
        },
        (old_count, new_count),
    ))
}

/// Why a hunk was not taken back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mismatch {
    /// Its lines are not in the file as the review showed them.
    NotFound,
}

/// Takes `chosen` (indices into `hunks`, the file's whole patch) back out
/// of `text`. Each is looked for nearest where the diff put it, shifted by
/// what the hunks before it in the file changed; the hunks not chosen were
/// left in the file and shift nothing. Returns the text and, per chosen
/// hunk in order, whether it was taken back.
#[must_use]
pub fn reverse(text: Text, hunks: &[Hunk], chosen: &[usize]) -> (Text, Vec<Result<(), Mismatch>>) {
    let mut text = text;
    let mut order: Vec<usize> = chosen.to_vec();
    order.sort_by_key(|index| hunks.get(*index).map_or(usize::MAX, |hunk| hunk.new_start));
    let mut results: Vec<(usize, Result<(), Mismatch>)> = Vec::new();
    // How far lines below the hunks taken back so far have moved.
    let mut shift: isize = 0;
    for index in order {
        let Some(hunk) = hunks.get(index) else {
            results.push((index, Err(Mismatch::NotFound)));
            continue;
        };
        let expected = if hunk.new.is_empty() {
            hunk.new_start
        } else {
            hunk.new_start.saturating_sub(1)
        };
        let expected = expected.saturating_add_signed(shift);
        match find(&text, hunk, expected) {
            Some(at) => {
                replace(&mut text, hunk, at);
                shift += isize::try_from(hunk.old.len()).unwrap_or(0)
                    - isize::try_from(hunk.new.len()).unwrap_or(0);
                results.push((index, Ok(())));
            }
            None => results.push((index, Err(Mismatch::NotFound))),
        }
    }
    let ordered = chosen
        .iter()
        .map(|index| {
            results
                .iter()
                .find(|(done, _)| done == index)
                .map_or(Err(Mismatch::NotFound), |(_, result)| *result)
        })
        .collect();
    (text, ordered)
}

/// Where the hunk's new side is in `text`: at `expected`, else at the one
/// place it is. A side with no lines (the range emptied or deleted the
/// file) is a file with none, never a place inside one.
fn find(text: &Text, hunk: &Hunk, expected: usize) -> Option<usize> {
    if hunk.new.is_empty() {
        return text.lines.is_empty().then_some(0);
    }
    let fits = |at: usize| -> bool {
        let end = at + hunk.new.len();
        if end > text.lines.len() || text.lines[at..end] != hunk.new[..] {
            return false;
        }
        // A side that ends without a newline is the file's end.
        let is_at_end = end == text.lines.len();
        if hunk.new_lacks_newline {
            is_at_end && !text.ends_with_newline
        } else {
            !(is_at_end && !hunk.new.is_empty() && !text.ends_with_newline)
        }
    };
    let last = text.lines.len().checked_sub(hunk.new.len())?;
    if expected <= last && fits(expected) {
        return Some(expected);
    }
    // Moved by an edit above it: found only where it is unmistakable.
    let mut places = (0..=last).filter(|at| fits(*at));
    let place = places.next()?;
    places.next().is_none().then_some(place)
}

fn replace(text: &mut Text, hunk: &Hunk, at: usize) {
    let end = at + hunk.new.len();
    let is_at_end = end == text.lines.len();
    text.lines.splice(at..end, hunk.old.iter().cloned());
    if is_at_end && !hunk.old.is_empty() {
        text.ends_with_newline = !hunk.old_lacks_newline;
    } else if is_at_end && hunk.new_lacks_newline {
        // The side that lacked the newline is gone; the line now last ended
        // with one.
        text.ends_with_newline = true;
    }
}

#[cfg(test)]
#[path = "hunks_tests.rs"]
mod tests;
