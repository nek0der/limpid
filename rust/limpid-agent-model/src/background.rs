//! Work an agent left running when its turn ended.
//!
//! Claude Code's `Stop` lists the background tasks still running
//! (`background_tasks`): shells started with `run_in_background` and
//! subagents launched to run on their own. When one ends on its own, Claude
//! begins a turn of its own from a `<task-notification>` prompt, and that
//! turn's `Stop` lists what is left, so the latest stop's list stands with no
//! end event of its own. One the person stops from Claude's task list starts
//! no turn: Claude queues its end for the next prompt, so the list keeps it
//! until then. Codex keeps its background terminals running after a turn
//! too, but its `Stop` does not list them and no hook reports their end, so
//! it reports none.

use crate::serde_helpers::is_zero;
use serde::{Deserialize, Serialize};

/// How many tasks of each kind were still running when the turn ended.
///
/// Counts rather than the tasks themselves: the interface says how much is
/// left, and a task's own words (its command, its description) are already
/// in the agent's terminal. Serialized in camel case like the record and the
/// projection badge that carry it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackgroundWork {
    #[serde(default, skip_serializing_if = "is_zero")]
    pub shells: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub subagents: u32,
    /// Tasks of a kind the interface does not name, such as Claude's
    /// monitors and remote agents.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub others: u32,
}

impl BackgroundWork {
    /// Whether any task is counted.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.shells == 0 && self.subagents == 0 && self.others == 0
    }
}
