//! Turn records in the hook runtime: the snapshots at each end of a turn,
//! the conversation's counter, and the record files under `turns/` in the
//! provider's state directory. What an event does to a turn is decided in
//! `limpid_agent_core` (`turn_step`, `begin_record`, `end_record`); this
//! module runs git and writes.
//!
//! One event is handled in three steps. Before the run record's lock, the
//! snapshot is taken, because `git add -A` can take long in a large
//! repository. Under the lock the record is written, and only then does the
//! run record name it. After the lock, the snapshot's tree is pinned by a
//! ref; until then it is an unreferenced object, which `git gc` keeps for
//! weeks. A begin is taken under the worktree lock (`worktree_lock`), held
//! from the snapshot until the run record names it.

use crate::git::{SnapshotRunner, TurnSide};
use crate::records::{HookLog, atomic_write, ensure_user_only_directory, with_record_lock};
use limpid_agent_core::{
    SnapshotTaken, TurnEnd, TurnStart, TurnStep, begin_record, conversation_of, end_only_record,
    end_record, turn_snapshot_cwd,
};
use limpid_agent_model::{
    AgentEvent, CheckResult, ConversationKey, DiffStat, EventApplication, EventId,
    ProviderDescriptor, RunRecord, SnapshotStatus, TurnCounter, TurnPhase, TurnRecord, TurnUsage,
    turn_record_file_name,
};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// What was prepared for one event before the run record's lock.
pub(crate) enum Prepared {
    /// A prompt begins a turn. `event` is `None` when the call carried no id:
    /// the snapshot is still taken for the run record's own fields, but no
    /// turn is recorded, since a retry could not be told apart.
    Begin {
        turn_id: String,
        event: Option<EventId>,
        taken: SnapshotTaken,
        /// The provider's own id for the turn (`TurnTranscript::marker`).
        provider_turn_id: Option<String>,
    },
    /// A turn ends. `turn_id` is the run's current turn, which an end may
    /// close again when the provider says the turn went on after another
    /// stop hook held it (`continues_ended_turn`): the later end is the one
    /// that holds the whole turn. `None` when the run has no turn to end, or
    /// only one that already ended; an end-only record is written, which
    /// reads as incomplete, since a stop with no prompt of its own (an agent
    /// answering a background task) is not the earlier turn's.
    End {
        turn_id: Option<String>,
        event: EventId,
        phase: TurnPhase,
        continues_ended_turn: bool,
        /// Set for a `TurnStep::Retake`: the turn keeps the phase it ended
        /// in, and only its end snapshot and difference are new.
        keeps_phase: bool,
        taken: SnapshotTaken,
        diff: Option<DiffStat>,
        /// What the transcript says the turn used and ran, and what the
        /// agent said as it ended.
        reading: EndReading,
    },
    /// Nothing to write, for the reason given (an event already applied or
    /// without an id, a current turn unreadable or written by a newer build,
    /// a retake with no ended turn); the reason goes to the hook log.
    Skip(&'static str),
}

/// What a turn's end read from the provider's transcript. Each part is
/// `None` when the transcript did not say, which keeps what the turn had.
#[derive(Debug, Default)]
pub(crate) struct EndReading {
    /// The provider's own id for the turn the reading counted from
    /// (`TurnReading::marker`).
    pub marker: Option<String>,
    pub usage: Option<TurnUsage>,
    pub checks: Option<Vec<CheckResult>>,
    /// Whether `checks` may leave out the turn's first runs.
    pub are_checks_partial: bool,
    /// What the agent said as the turn ended, read from the stop's own
    /// payload rather than the transcript (`with_reply`), as `TurnEnd::reply`
    /// takes it.
    pub reply: Option<String>,
}

impl EndReading {
    /// The reading with the reply the event ended the turn with: a stop's,
    /// whole, or empty for a stop that sent none. Any other end has none,
    /// which keeps what the record held.
    fn with_reply(self, event: &AgentEvent) -> Self {
        let reply = match event {
            AgentEvent::TurnFinished { reply, .. } => Some(reply.clone().unwrap_or_default()),
            _ => None,
        };
        Self { reply, ..self }
    }
}

/// What the provider's transcript says of the turn a hook call begins or
/// ends: read with the snapshot, before the lock, since a turn's
/// transcript and its subagents' are files of their own.
pub(crate) trait TurnTranscript {
    /// The provider's own id for the turn a prompt begins
    /// (`TurnRecord::provider_turn_id`).
    fn marker(&self) -> Option<String>;

    /// What the turn that began with `marker` used and ran, as it ends.
    fn read_end(&self, marker: Option<&str>) -> EndReading;
}

impl Prepared {
    /// The begin snapshot this event took, or `None` when it took none (an
    /// end, or a retried prompt), so the run record's own fields keep what
    /// they had.
    pub(crate) fn begin_snapshot(&self) -> Option<&SnapshotTaken> {
        match self {
            Self::Begin { taken, .. } => Some(taken),
            Self::End { .. } | Self::Skip(_) => None,
        }
    }
}

/// What to pin once the lock is released.
pub(crate) struct Pin {
    root: PathBuf,
    turn_id: String,
    side: TurnSide,
    tree: String,
}

/// Where turns live for one hook call.
pub(crate) struct Turns<'a> {
    pub directory: PathBuf,
    pub descriptor: &'a ProviderDescriptor,
    pub run_id: &'a str,
    pub pane_id: &'a str,
    pub now: &'a str,
    pub log: &'a HookLog,
    /// The call's transcript, for a call that may begin or end a turn;
    /// `None` reads nothing.
    pub transcript: Option<&'a dyn TurnTranscript>,
}

impl<'a> Turns<'a> {
    /// The same turns, written at `now`: a prompt in a worktree is stamped
    /// once the wait for the worktree lock is over (`begin_time`).
    pub(crate) fn at<'b>(&self, now: &'b str) -> Turns<'b>
    where
        'a: 'b,
    {
        Turns {
            directory: self.directory.clone(),
            descriptor: self.descriptor,
            run_id: self.run_id,
            pane_id: self.pane_id,
            now,
            log: self.log,
            transcript: self.transcript,
        }
    }
}

/// What the run record says its current turn is.
enum Current {
    /// It names none, or the turn's file is gone (deleted with its turn).
    None,
    /// It names one this build cannot read, or one whose file names another
    /// turn. Left as it is, and nothing is written in its place: a newer
    /// build's turn is not ours to end or to replace.
    Unreadable,
    Turn(Box<TurnRecord>),
}

impl Current {
    fn turn(&self) -> Option<&TurnRecord> {
        match self {
            Self::Turn(turn) => Some(turn),
            Self::None | Self::Unreadable => None,
        }
    }
}

/// Whether `value` is a turn id as the writer spells it: an upper-case
/// hyphenated UUID. Other spellings `Uuid::parse_str` accepts (`urn:uuid:`,
/// braces) would not make a valid ref name.
pub(crate) fn is_turn_id(value: &str) -> bool {
    uuid::Uuid::parse_str(value)
        .is_ok_and(|uuid| uuid.hyphenated().to_string().to_uppercase() == value)
}

fn not_taken(reason: &str) -> SnapshotTaken {
    SnapshotTaken {
        status: SnapshotStatus::Skipped {
            reason: reason.to_owned(),
        },
        skipped: Vec::new(),
        git_context: None,
    }
}

impl Turns<'_> {
    fn read_end(&self, marker: Option<&str>) -> EndReading {
        self.transcript
            .map(|transcript| transcript.read_end(marker))
            .unwrap_or_default()
    }

    fn record_path(&self, turn_id: &str) -> PathBuf {
        self.directory.join(turn_record_file_name(turn_id))
    }

    /// The run's current turn. Both ids come from files, so the one in the
    /// run record is checked to be a turn id before it becomes part of a
    /// path, and the record found there must carry the same id, since every
    /// later path and ref name is built from the record's own.
    fn current(&self, record: Option<&RunRecord>) -> Current {
        let Some(turn_id) = record.and_then(|record| record.current_turn_id.as_deref()) else {
            return Current::None;
        };
        if !is_turn_id(turn_id) {
            self.log.line("read turn: the run names no turn id");
            return Current::Unreadable;
        }
        let bytes = match std::fs::read(self.record_path(turn_id)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Current::None,
            Err(error) => {
                self.log.line(&format!("read turn {turn_id}: {error}"));
                return Current::Unreadable;
            }
        };
        match TurnRecord::decode(&bytes) {
            Ok(turn) if turn.turn_id == turn_id => Current::Turn(Box::new(turn)),
            Ok(_) => {
                self.log
                    .line(&format!("read turn {turn_id}: names another turn"));
                Current::Unreadable
            }
            Err(error) => {
                self.log.line(&format!("read turn {turn_id}: {error}"));
                Current::Unreadable
            }
        }
    }

    /// Where a begin is captured: the directory the event names, else the
    /// hook's own.
    pub(crate) fn begin_directory(&self, event: &AgentEvent) -> PathBuf {
        turn_snapshot_cwd(event, self.descriptor)
            .flatten()
            .map_or_else(current_directory, PathBuf::from)
    }

    /// Takes the snapshot `step` needs, before the lock. `record` is the run
    /// record as it stood before the lock, which is enough to skip a retried
    /// event; the decision is made again under the lock. A begin is not
    /// captured when `begin_skip` gives a reason: a restore kept the
    /// worktree past the hook's limit.
    pub(crate) fn prepare(
        &self,
        step: TurnStep,
        event: &AgentEvent,
        event_id: Option<EventId>,
        record: Option<&RunRecord>,
        snapshots: &dyn SnapshotRunner,
        begin_skip: Option<&str>,
    ) -> Prepared {
        let current = self.current(record);
        if let (Some(turn), Some(event_id)) = (current.turn(), &event_id)
            && turn
                .applied_events
                .iter()
                .any(|applied| applied == event_id.as_str())
        {
            return Prepared::Skip("event already applied");
        }
        match step {
            TurnStep::Begin => Prepared::Begin {
                turn_id: uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase(),
                event: event_id,
                provider_turn_id: self.transcript.and_then(TurnTranscript::marker),
                taken: match begin_skip {
                    Some(reason) => not_taken(reason),
                    None => snapshots.capture(
                        &self.begin_directory(event),
                        self.pane_id,
                        TurnSide::Begin,
                    ),
                },
            },
            TurnStep::End { .. } | TurnStep::Retake => {
                let (phase, continues_ended_turn, keeps_phase) = match step {
                    TurnStep::End {
                        phase,
                        continues_ended_turn,
                    } => (phase, continues_ended_turn, false),
                    // The phase is read from the turn when it is written.
                    _ => (TurnPhase::Finished, true, true),
                };
                let Some(event_id) = event_id else {
                    return Prepared::Skip("turn event without an id");
                };
                // An end nobody prompted reads from the last prompt; when
                // that prompt is the ended turn's own, what it reads is that
                // turn's, already recorded, and is not counted again.
                let end_only = |id, ended: Option<&str>| {
                    let reading = self.read_end(None);
                    Prepared::End {
                        turn_id: None,
                        event: id,
                        phase,
                        continues_ended_turn,
                        keeps_phase: false,
                        taken: not_taken("beginMissing"),
                        diff: None,
                        reading: if ended.is_some() && reading.marker.as_deref() == ended {
                            EndReading::default()
                        } else {
                            reading
                        }
                        .with_reply(event),
                    }
                };
                let turn = match current {
                    Current::Unreadable => return Prepared::Skip("current turn unreadable"),
                    // A newer build's turn is not ours to end, nor to put an
                    // end-only record in place of.
                    Current::Turn(turn) if !turn.is_writable() => {
                        return Prepared::Skip("a newer build wrote the current turn");
                    }
                    // A retake has no turn of its own to stand for.
                    Current::None if keeps_phase => {
                        return Prepared::Skip("no ended turn to take again");
                    }
                    Current::None => return end_only(event_id, None),
                    Current::Turn(turn)
                        if turn.phase != TurnPhase::Started && !continues_ended_turn =>
                    {
                        return end_only(event_id, turn.provider_turn_id.as_deref());
                    }
                    Current::Turn(turn) => turn,
                };
                let (taken, diff) = self.take_end(&turn, snapshots);
                Prepared::End {
                    turn_id: Some(turn.turn_id.clone()),
                    event: event_id,
                    phase,
                    continues_ended_turn,
                    keeps_phase,
                    taken,
                    diff,
                    // An end-only record read its turn when it was written;
                    // read again with no prompt of its own, the transcript's
                    // last prompt could be the turn before it.
                    reading: if turn.has_prompt() {
                        self.read_end(turn.provider_turn_id.as_deref())
                    } else {
                        EndReading::default()
                    }
                    .with_reply(event),
                }
            }
        }
    }

    /// The end snapshot of `turn`, and its difference from the begin. The
    /// end is taken where the turn began, so the two trees are of one
    /// repository even if the agent changed directory. A turn whose begin
    /// was not captured has nothing to compare an end with, and the
    /// directory the hook runs in may be another repository entirely, so
    /// none is taken; the begin's reason is the one the turn reports.
    fn take_end(
        &self,
        turn: &TurnRecord,
        snapshots: &dyn SnapshotRunner,
    ) -> (SnapshotTaken, Option<DiffStat>) {
        let taken = match &turn.begin {
            SnapshotStatus::Captured { root, .. } => {
                snapshots.capture(Path::new(root), self.pane_id, TurnSide::End)
            }
            _ => not_taken("beginNotCaptured"),
        };
        let diff = match (&turn.begin, &taken.status) {
            (
                SnapshotStatus::Captured { tree: begin, root },
                SnapshotStatus::Captured {
                    tree: end,
                    root: end_root,
                },
            ) if root == end_root => snapshots.diff(Path::new(root), begin, end),
            _ => None,
        };
        (taken, diff)
    }

    /// Writes the turn record under the run record's lock, and names it on
    /// `run`, the record about to be written. `previous` is the run record
    /// read under the lock.
    pub(crate) fn commit(
        &self,
        prepared: Prepared,
        previous: Option<&RunRecord>,
        run: Option<&mut RunRecord>,
    ) -> Option<Pin> {
        match prepared {
            Prepared::Skip(reason) => {
                self.log.line(&format!("turn not written: {reason}"));
                None
            }
            Prepared::Begin {
                turn_id,
                event,
                taken,
                provider_turn_id,
            } => self.begin(turn_id, event, taken, provider_turn_id, previous, run?),
            Prepared::End {
                turn_id: Some(turn_id),
                event,
                phase,
                continues_ended_turn,
                keeps_phase,
                taken,
                diff,
                reading,
                ..
            } => self.end(
                &turn_id,
                &event,
                TurnEnd {
                    phase,
                    now: self.now,
                    end: taken,
                    diff,
                    usage: reading.usage,
                    checks: reading.checks,
                    are_checks_partial: reading.are_checks_partial,
                    reply: reading.reply.as_deref(),
                },
                continues_ended_turn,
                keeps_phase,
                previous,
            ),
            Prepared::End {
                turn_id: None,
                event,
                phase,
                taken,
                reading,
                ..
            } => {
                self.end_only(&event, phase, taken, reading, previous, run?);
                None
            }
        }
    }

    fn begin(
        &self,
        turn_id: String,
        event: Option<EventId>,
        taken: SnapshotTaken,
        provider_turn_id: Option<String>,
        previous: Option<&RunRecord>,
        run: &mut RunRecord,
    ) -> Option<Pin> {
        if let Some(event) = &event
            && self
                .current(previous)
                .turn()
                .is_some_and(|turn| turn.applied_events.iter().any(|id| id == event.as_str()))
        {
            self.log.line("turn not written: event already applied");
            return None;
        }
        // From here on a new turn has begun, recorded or not. Until its
        // record is written the run names no turn, so an end that follows a
        // failed begin is not taken for the end of the turn before it.
        run.current_turn_id = None;
        let Some(event) = event else {
            self.log.line("turn not written: prompt without an id");
            return None;
        };
        let conversation = conversation_of(&self.descriptor.id, Some(run), self.run_id);
        let display_number = self.number(&conversation)?;
        let pin = pin_for(&taken.status, &turn_id, TurnSide::Begin);
        let prompt = run.last_prompt.clone().unwrap_or_default();
        let record = begin_record(TurnStart {
            turn_id: turn_id.clone(),
            conversation,
            run_id: self.run_id,
            pane_id: self.pane_id,
            display_number,
            prompt: &prompt,
            now: self.now,
            begin: taken,
            event: &event,
            provider_turn_id,
        });
        if !self.write(&record) {
            return None;
        }
        // Named only once the record is on disk, so a reader that follows
        // the run record always finds the turn.
        run.current_turn_id = Some(turn_id);
        pin
    }

    fn end(
        &self,
        turn_id: &str,
        event: &EventId,
        ending: TurnEnd<'_>,
        continues_ended_turn: bool,
        keeps_phase: bool,
        previous: Option<&RunRecord>,
    ) -> Option<Pin> {
        // Read again under the lock: a prompt may have begun another turn
        // since the snapshot was taken, and this end is not that turn's; nor
        // is it an ended turn's, unless it continues that turn.
        let Current::Turn(mut turn) = self.current(previous) else {
            self.log.line("turn not written: the turn was overtaken");
            return None;
        };
        if turn.turn_id != turn_id || (turn.phase != TurnPhase::Started && !continues_ended_turn) {
            self.log.line("turn not written: the turn was overtaken");
            return None;
        }
        // A record a newer build wrote, or one this build could only read in
        // part, is left as it is rather than cut down.
        if !turn.is_writable() {
            self.log.line("turn not written: a newer build wrote it");
            return None;
        }
        if turn.apply_event(Some(event)) != EventApplication::Applied {
            self.log.line("turn not written: event already applied");
            return None;
        }
        let pin = pin_for(&ending.end.status, turn_id, TurnSide::End);
        // A retake keeps how the turn ended; a turn whose end was never
        // written ends as finished.
        let ending = if keeps_phase && turn.phase != TurnPhase::Started {
            TurnEnd {
                phase: turn.phase,
                ..ending
            }
        } else {
            ending
        };
        let ended = end_record(&turn, ending);
        self.write(&ended).then_some(pin).flatten()
    }

    /// Records an end the run has no open turn for (the hook missed the
    /// prompt, the run began before this build, or the agent stopped again
    /// with no prompt of its own), so the turn shows as incomplete rather
    /// than not at all, and an ended turn keeps the end it had.
    fn end_only(
        &self,
        event: &EventId,
        phase: TurnPhase,
        taken: SnapshotTaken,
        reading: EndReading,
        previous: Option<&RunRecord>,
        run: &mut RunRecord,
    ) {
        match self.current(previous) {
            Current::None => {}
            Current::Turn(turn) if turn.is_writable() && turn.phase != TurnPhase::Started => {}
            Current::Turn(turn) if !turn.is_writable() => {
                self.log
                    .line("turn not written: a newer build wrote the current turn");
                return;
            }
            Current::Turn(_) => {
                self.log
                    .line("turn not written: a turn began while this end was prepared");
                return;
            }
            Current::Unreadable => {
                self.log.line("turn not written: current turn unreadable");
                return;
            }
        }
        let conversation = conversation_of(&self.descriptor.id, Some(run), self.run_id);
        let Some(display_number) = self.number(&conversation) else {
            return;
        };
        let turn_id = uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase();
        let record = end_only_record(
            TurnStart {
                turn_id: turn_id.clone(),
                conversation,
                run_id: self.run_id,
                pane_id: self.pane_id,
                display_number,
                prompt: "",
                now: self.now,
                begin: SnapshotTaken {
                    status: SnapshotStatus::Pending,
                    skipped: Vec::new(),
                    git_context: None,
                },
                event,
                provider_turn_id: None,
            },
            TurnEnd {
                phase,
                now: self.now,
                end: taken,
                diff: None,
                usage: reading.usage,
                checks: reading.checks,
                are_checks_partial: reading.are_checks_partial,
                reply: reading.reply.as_deref(),
            },
        );
        if self.write(&record) {
            run.current_turn_id = Some(turn_id);
        }
    }

    /// Records `check` as the last one the run's current turn ran, under the
    /// run record's lock. A check is part of a turn under way; one that
    /// arrives with no turn running (a background command finishing after
    /// the stop) is not the earlier turn's, and is left out.
    pub(crate) fn record_check(
        &self,
        record: Option<&RunRecord>,
        event: Option<&EventId>,
        check: CheckResult,
    ) {
        let Some(event) = event else {
            self.log.line("check not written: a call without an id");
            return;
        };
        let Current::Turn(mut turn) = self.current(record) else {
            return;
        };
        if !turn.is_writable() || turn.phase != TurnPhase::Started {
            return;
        }
        if turn.apply_event(Some(event)) != EventApplication::Applied {
            return;
        }
        turn.push_check(check);
        self.write(&turn);
    }

    /// The conversation's next display number, or `None` after logging why
    /// there is none.
    fn number(&self, conversation: &ConversationKey) -> Option<u32> {
        ensure_user_only_directory(&self.directory);
        self.next_display_number(conversation)
            .map_err(|error| self.log.line(&format!("turn not written: {error}")))
            .ok()
    }

    fn write(&self, record: &TurnRecord) -> bool {
        let path = self.record_path(&record.turn_id);
        let written = record
            .encode()
            .map_err(|error| error.to_string())
            .and_then(|bytes| atomic_write(&path, &bytes).map_err(|error| error.to_string()));
        if let Err(error) = &written {
            self.log.line(&format!("write {}: {error}", path.display()));
        }
        written.is_ok()
    }

    /// The next display number of `conversation`, taken under the counter's
    /// own lock: two runs of one conversation (a resumed session in another
    /// pane) number their turns from one sequence. The counter only grows,
    /// so a deleted turn's number is never given again.
    fn next_display_number(&self, conversation: &ConversationKey) -> Result<u32, String> {
        let path = self.directory.join(conversation.counter_file_name());
        with_record_lock(&path, || {
            let (last, extra) = match std::fs::read(&path) {
                Ok(bytes) => {
                    let counter: TurnCounter = serde_json::from_slice(&bytes)
                        .map_err(|error| format!("read counter: {error}"))?;
                    // The file name is a hash of the key; a different key
                    // inside is a collision, and sharing its numbers would
                    // give two conversations the same "T7".
                    if counter.conversation != *conversation {
                        return Err("counter belongs to another conversation".to_owned());
                    }
                    (counter.last_display_number, counter.extra)
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (0, BTreeMap::new()),
                Err(error) => return Err(format!("read counter: {error}")),
            };
            let next = last
                .checked_add(1)
                .ok_or_else(|| "counter is exhausted".to_owned())?;
            let counter = TurnCounter {
                conversation: conversation.clone(),
                last_display_number: next,
                extra,
            };
            let bytes = serde_json::to_vec(&counter).map_err(|error| error.to_string())?;
            atomic_write(&path, &bytes).map_err(|error| format!("write counter: {error}"))?;
            Ok(next)
        })
        .unwrap_or_else(|| Err("counter lock busy".to_owned()))
    }

    /// Pins a snapshot's tree; a failure costs the tree's protection from
    /// `git gc`, not the record.
    pub(crate) fn pin(&self, pin: &Pin, snapshots: &dyn SnapshotRunner) {
        if let Err(error) = snapshots.pin(&pin.root, &pin.turn_id, pin.side, &pin.tree) {
            self.log.line(&format!("pin turn {}: {error}", pin.turn_id));
        }
    }
}

fn pin_for(status: &SnapshotStatus, turn_id: &str, side: TurnSide) -> Option<Pin> {
    match status {
        SnapshotStatus::Captured { tree, root } => Some(Pin {
            root: PathBuf::from(root),
            turn_id: turn_id.to_owned(),
            side,
            tree: tree.clone(),
        }),
        _ => None,
    }
}

/// The hook's working directory, which is where an event without a
/// directory of its own happened.
pub(crate) fn current_directory() -> PathBuf {
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}
