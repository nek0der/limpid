//! The session's model and permission mode: taken from any call that says
//! them, kept through the calls that do not, and written even by a call whose
//! events change nothing else.

use super::*;
use limpid_agent_model::PermissionMode;

fn saying(model: Option<&str>, mode: Option<PermissionMode>) -> ApplyContext {
    ApplyContext {
        settings: SessionSettings {
            model: model.map(str::to_owned),
            answered_model: None,
            is_awaiting_answer: false,
            effort: None,
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

#[test]
fn launch_order_is_kept_through_session_restarts_and_compaction() {
    let launch = ApplyContext {
        run_launch_order: Some(123),
        ..context()
    };
    let mut record = apply(None, &started(None), &launch, &claude(), NOW)
        .run
        .expect("record");
    assert_eq!(record.run_launch_order, Some(123));
    let changed = ApplyContext {
        run_launch_order: Some(999),
        ..context()
    };
    for event in [
        prompt("go"),
        started(None),
        AgentEvent::SessionStarted {
            compact: true,
            source: Some(SessionSource::Compact),
            session_id: Some("session-1".into()),
            session_title: None,
            cwd: Some("/repo".into()),
        },
    ] {
        record = apply(Some(&record), &event, &changed, &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(record.run_launch_order, Some(123));
    }
    record = apply(
        Some(&record),
        &prompt("again"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(record.run_launch_order, Some(123));
}

#[test]
fn parent_identity_is_immutable_and_own_observations_advance_without_a_state_change() {
    let initial = ApplyContext {
        parent_run_id: Some("parent".into()),
        run_observed_order: Some(100),
        ..saying(Some("Opus 5.5"), Some(PermissionMode::Default))
    };
    let record = apply(None, &started(None), &initial, &claude(), NOW)
        .run
        .expect("record");
    let later = ApplyContext {
        parent_run_id: Some("another-parent".into()),
        run_observed_order: Some(200),
        ..initial
    };
    let next = apply(Some(&record), &model_switch(), &later, &claude(), LATER)
        .run
        .expect("observation write");
    assert_eq!(next.parent_run_id.as_deref(), Some("parent"));
    assert_eq!(next.run_observed_order, Some(200));
    assert_eq!(next.updated_at, record.updated_at);
    assert_eq!(next.state_episode_token, record.state_episode_token);
    assert_eq!(next.revision, Some(record.revision.unwrap_or(0) + 1));
    let delayed = ApplyContext {
        run_observed_order: Some(150),
        ..later
    };
    assert!(
        apply(Some(&next), &model_switch(), &delayed, &claude(), LATER)
            .run
            .is_none()
    );
    let changed = apply(Some(&next), &prompt("go"), &delayed, &claude(), LATER)
        .run
        .expect("state write");
    assert_eq!(changed.parent_run_id.as_deref(), Some("parent"));
    assert_eq!(changed.run_observed_order, Some(200));
}

#[test]
fn a_new_model_drops_the_effort_said_of_the_old_one() {
    let saying_effort = |model: Option<&str>, effort: Option<&str>| ApplyContext {
        settings: SessionSettings {
            model: model.map(str::to_owned),
            answered_model: None,
            is_awaiting_answer: false,
            effort: effort.map(str::to_owned),
            permission_mode: None,
        },
        ..context()
    };
    let (session, _, _) = run(&claude(), &[started(None), prompt("go")]);
    let said = apply(
        Some(&session),
        &model_switch(),
        &saying_effort(Some("Opus 5.5"), Some("high")),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(said.effort.as_deref(), Some("high"));

    let same = apply(
        Some(&said),
        &model_switch(),
        &saying_effort(Some("Opus 5.5"), None),
        &claude(),
        LATER,
    );
    let same = same.run.as_ref().unwrap_or(&said);
    assert_eq!(
        same.effort.as_deref(),
        Some("high"),
        "the same model keeps it"
    );

    let switched = apply(
        Some(&said),
        &model_switch(),
        &saying_effort(Some("Haiku 5.5"), None),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(switched.effort, None);

    let both = apply(
        Some(&said),
        &model_switch(),
        &saying_effort(Some("Haiku 5.5"), Some("low")),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(both.effort.as_deref(), Some("low"));
}

#[test]
fn an_answered_model_fills_only_a_record_without_one() {
    let answering = |model: &str| ApplyContext {
        settings: SessionSettings {
            answered_model: Some(model.to_owned()),
            effort: Some("high".to_owned()),
            ..SessionSettings::default()
        },
        ..context()
    };
    let (session, _, _) = run(&claude(), &[started(None), prompt("go")]);
    assert_eq!(session.model, None);
    let filled = apply(
        Some(&session),
        &model_switch(),
        &answering("Opus 5.5"),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(filled.model.as_deref(), Some("Opus 5.5"));
    assert_eq!(
        filled.effort.as_deref(),
        Some("high"),
        "said in the same call"
    );

    let said = apply(
        Some(&session),
        &model_switch(),
        &saying(Some("Fable 5.1 1M"), None),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    let kept = apply(
        Some(&said),
        &model_switch(),
        &answering("Fable 5.1"),
        &claude(),
        LATER,
    );
    let kept = kept.run.as_ref().unwrap_or(&said);
    assert_eq!(kept.model.as_deref(), Some("Fable 5.1 1M"));
}
