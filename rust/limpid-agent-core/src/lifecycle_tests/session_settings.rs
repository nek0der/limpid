//! The session's model and permission mode: taken from any call that says
//! them, kept through the calls that do not, and written even by a call whose
//! events change nothing else.

use super::*;
use limpid_agent_model::PermissionMode;

fn saying(model: Option<&str>, mode: Option<PermissionMode>) -> ApplyContext {
    ApplyContext {
        settings: SessionSettings {
            model: model.map(str::to_owned),
            permission_mode: mode,
        },
        ..context()
    }
}

fn model_switch() -> AgentEvent {
    AgentEvent::Extension {
        name: "PostModelSwitch".into(),
        payload: serde_json::Value::Null,
    }
}

#[test]
fn a_setting_is_kept_until_a_call_says_another() {
    let said = saying(Some("Opus 5.5"), Some(PermissionMode::Auto));
    let session = apply(None, &started(None), &said, &claude(), NOW)
        .run
        .expect("record");
    assert_eq!(session.model.as_deref(), Some("Opus 5.5"));
    assert_eq!(session.permission_mode, Some(PermissionMode::Auto));

    // A prompt that says only the mode keeps the model.
    let asked = apply(
        Some(&session),
        &prompt("go"),
        &saying(None, Some(PermissionMode::Plan)),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(asked.model.as_deref(), Some("Opus 5.5"));
    assert_eq!(asked.permission_mode, Some(PermissionMode::Plan));

    // A start of a new conversation in the same process keeps both: the
    // process still runs them, and the start says them again when it can.
    let cleared = apply(Some(&asked), &started(None), &context(), &claude(), LATER)
        .run
        .expect("record");
    assert_eq!(cleared.model.as_deref(), Some("Opus 5.5"));
    assert_eq!(cleared.permission_mode, Some(PermissionMode::Plan));
}

#[test]
fn a_call_that_changes_nothing_else_still_writes_the_model_it_says() {
    let (session, _, _) = run(&claude(), &[started(None), prompt("go")]);
    let switched = apply(
        Some(&session),
        &model_switch(),
        &saying(Some("Fable 5.1 1M"), None),
        &claude(),
        LATER,
    )
    .run
    .expect("the switch writes the model");
    assert_eq!(switched.model.as_deref(), Some("Fable 5.1 1M"));
    assert_eq!(switched.revision, Some(session.revision.unwrap_or(0) + 1));
    // Nothing else moves: the run's state, its episode, its last event, and
    // when it last changed are the ones the prompt left.
    assert_eq!(
        RunRecord {
            model: session.model.clone(),
            revision: session.revision,
            ..switched
        },
        session
    );
}

#[test]
fn a_call_that_says_nothing_new_writes_nothing() {
    let said = saying(Some("Opus 5.5"), Some(PermissionMode::Default));
    let session = apply(None, &started(None), &said, &claude(), NOW)
        .run
        .expect("record");
    assert_eq!(
        apply(Some(&session), &model_switch(), &said, &claude(), LATER).run,
        None
    );
    assert_eq!(
        apply(
            Some(&session),
            &model_switch(),
            &context(),
            &claude(),
            LATER
        )
        .run,
        None
    );
    // With no record yet there is no run for the setting to describe.
    assert_eq!(
        apply(None, &model_switch(), &said, &claude(), LATER).run,
        None
    );
}

#[test]
fn an_ended_session_still_takes_a_setting_without_coming_back() {
    let (session, _, _) = run(&claude(), &[started(None)]);
    let ended = apply(
        Some(&session),
        &AgentEvent::SessionEnded {
            reason: Some("other".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    let switched = apply(
        Some(&ended),
        &model_switch(),
        &saying(Some("Haiku 5.5"), None),
        &claude(),
        LATER,
    )
    .run
    .expect("the switch writes the model");
    assert_eq!(switched.state, ended.state);
    assert_eq!(switched.state_episode_token, ended.state_episode_token);
    assert_eq!(switched.model.as_deref(), Some("Haiku 5.5"));
}
