//! Provider-neutral automatic title selection.

/// Maximum number of UTF-8 bytes accepted for one title candidate.
pub const MAX_TITLE_BYTES: usize = 4_096;
/// Maximum prompt bytes inspected while deriving the fallback title.
pub const MAX_FIRST_PROMPT_BYTES: usize = 65_536;

/// Inputs ordered by semantic provenance rather than arrival time.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TitleCandidates<'a> {
    pub provider_session: Option<&'a str>,
    pub provider_generated: Option<&'a str>,
    pub first_prompt: Option<&'a str>,
}

/// Validation failures at the provider-neutral title boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TitleError {
    TooLong,
}

/// Selects and normalizes the best available automatic title.
///
/// A provider session title includes both Claude's documented
/// `SessionStart.session_title` and a later explicit provider rename. The
/// caller collapses observations from the same conversation to their latest
/// value before invoking this reducer.
pub fn resolve_title(candidates: TitleCandidates<'_>) -> Result<Option<String>, TitleError> {
    for candidate in [candidates.provider_session, candidates.provider_generated] {
        let Some(candidate) = candidate else { continue };
        if candidate.len() > MAX_TITLE_BYTES {
            return Err(TitleError::TooLong);
        }
        let normalized = sanitize_title(candidate);
        if !normalized.is_empty() {
            return Ok(Some(normalized));
        }
    }

    if let Some(first_prompt) = candidates.first_prompt {
        if first_prompt.len() > MAX_FIRST_PROMPT_BYTES {
            return Err(TitleError::TooLong);
        }
        let mut normalized = sanitize_title(first_prompt);
        truncate_utf8(&mut normalized, MAX_TITLE_BYTES);
        if !normalized.is_empty() {
            return Ok(Some(normalized));
        }
    }
    Ok(None)
}

fn truncate_utf8(value: &mut String, maximum_bytes: usize) {
    if value.len() <= maximum_bytes {
        return;
    }
    let mut boundary = maximum_bytes;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
}

/// Matches the existing native title boundary while keeping the policy in the
/// portable core. The result is always suitable for Limpid's single-line UI.
fn sanitize_title(value: &str) -> String {
    let mut visible = String::with_capacity(value.len());
    for character in value.chars() {
        let scalar = character as u32;
        if matches!(character, '\n' | '\t' | '\r') {
            visible.push(' ');
        } else if scalar < 0x20
            || (0x7f..=0x9f).contains(&scalar)
            || (0x202a..=0x202e).contains(&scalar)
            || (0x2066..=0x2069).contains(&scalar)
            || matches!(scalar, 0x200b..=0x200f | 0xfeff)
        {
            // Drop terminal controls and invisible direction modifiers.
        } else {
            visible.push(character);
        }
    }
    visible
        .split(' ')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_session_title_has_highest_precedence() {
        let resolved = resolve_title(TitleCandidates {
            provider_session: Some("  Explicit title  "),
            provider_generated: Some("Generated title"),
            first_prompt: Some("Opening prompt"),
        })
        .unwrap();

        assert_eq!(resolved.as_deref(), Some("Explicit title"));
    }

    #[test]
    fn blank_candidates_fall_through() {
        let resolved = resolve_title(TitleCandidates {
            provider_session: Some(" \n "),
            provider_generated: Some("Generated title"),
            first_prompt: Some("Opening prompt"),
        })
        .unwrap();

        assert_eq!(resolved.as_deref(), Some("Generated title"));
    }

    #[test]
    fn oversized_candidate_is_rejected_instead_of_falling_through() {
        let oversized = "x".repeat(MAX_TITLE_BYTES + 1);
        let result = resolve_title(TitleCandidates {
            provider_session: Some(&oversized),
            provider_generated: Some("Generated title"),
            first_prompt: None,
        });

        assert_eq!(result, Err(TitleError::TooLong));
    }

    #[test]
    fn unsafe_and_multiline_characters_are_normalized_before_selection() {
        let resolved = resolve_title(TitleCandidates {
            provider_session: Some("  Safe\u{202e}\n\t title\u{200b}  "),
            provider_generated: None,
            first_prompt: None,
        })
        .unwrap();

        assert_eq!(resolved.as_deref(), Some("Safe title"));
    }

    #[test]
    fn candidate_that_is_empty_after_sanitizing_falls_through() {
        let resolved = resolve_title(TitleCandidates {
            provider_session: Some("\u{202e}\u{200b}"),
            provider_generated: Some("Generated"),
            first_prompt: None,
        })
        .unwrap();

        assert_eq!(resolved.as_deref(), Some("Generated"));
    }

    #[test]
    fn long_first_prompt_is_truncated_at_a_utf8_boundary() {
        let prompt = format!("{}あ", "x".repeat(MAX_TITLE_BYTES - 1));
        let resolved = resolve_title(TitleCandidates {
            provider_session: None,
            provider_generated: None,
            first_prompt: Some(&prompt),
        })
        .unwrap()
        .unwrap();

        assert_eq!(resolved.len(), MAX_TITLE_BYTES - 1);
        assert_eq!(resolved, "x".repeat(MAX_TITLE_BYTES - 1));
    }
}
