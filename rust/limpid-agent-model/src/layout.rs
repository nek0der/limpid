//! The names the hook runtime gives the files it leaves in a provider's
//! directories, other than the run record's own (`RUN_RECORD_FILE_SUFFIX`).
//!
//! Each is declared once because the hook runtime writes the file and the host
//! lists, rewrites, locks, or deletes it by the same name. The host asks the
//! bridge for these values rather than keeping copies, since a copy that
//! drifted would compile, pass its own tests, and leave the file unread. Files
//! already on disk, and the shell receivers kept as the rollback path, use
//! exactly these names, so changing one strands them.

/// What a resume hint's file name ends with in the provider's session
/// directory. The rest of the name is the id of the pane the hint belongs to.
pub const SESSION_HINT_FILE_SUFFIX: &str = ".json";

/// What a working-directory event's file name ends with in the provider's
/// cwd-event directory. The rest of the name is the pane's id.
pub const CWD_EVENT_FILE_SUFFIX: &str = ".cwd.json";

/// The directory inside the provider's state directory that worktree events
/// are written to.
pub const WORKTREE_EVENTS_DIRECTORY: &str = "worktree-events";

/// What a finished worktree event's file name ends with. Anything else in the
/// directory is a write still in progress.
pub const WORKTREE_EVENT_FILE_SUFFIX: &str = ".json";

/// What is appended to a file's name to name the sidecar every writer takes an
/// advisory lock on before replacing or deleting that file.
pub const LOCK_FILE_SUFFIX: &str = ".flock";

/// The file name of the resume hint for `pane_id`.
#[must_use]
pub fn session_hint_file_name(pane_id: &str) -> String {
    format!("{pane_id}{SESSION_HINT_FILE_SUFFIX}")
}

/// The file name of the working-directory event for `pane_id`.
#[must_use]
pub fn cwd_event_file_name(pane_id: &str) -> String {
    format!("{pane_id}{CWD_EVENT_FILE_SUFFIX}")
}

#[cfg(test)]
mod tests {
    use super::*;

    const PANE: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";

    #[test]
    fn the_names_match_what_is_already_on_disk() {
        // Existing files and the shell receivers use these names; a change
        // here must come with a migration, not slip through as a rename.
        assert_eq!(
            session_hint_file_name(PANE),
            "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10.json"
        );
        assert_eq!(
            cwd_event_file_name(PANE),
            "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10.cwd.json"
        );
        assert_eq!(WORKTREE_EVENTS_DIRECTORY, "worktree-events");
        assert_eq!(WORKTREE_EVENT_FILE_SUFFIX, ".json");
        assert_eq!(LOCK_FILE_SUFFIX, ".flock");
    }
}
