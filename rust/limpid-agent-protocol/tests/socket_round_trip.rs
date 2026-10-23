#![cfg(unix)]

use limpid_agent_core::ProviderId;
use limpid_agent_core::{Principal, RunId};
use limpid_agent_protocol::{
    ApprovalDecisionWire, ApprovalKeyWire, ApprovalRequestWire, ApprovalService, ApprovalStateWire,
    ErrorCode, MAXIMUM_DECISION_BYTES, MAXIMUM_RECORDS, MAXIMUM_REQUEST_BYTES,
    MAXIMUM_RESPONSE_BYTES, PROTOCOL_VERSION, RequestBody, ResponseBody, WireRequest, WireResponse,
    read_frame, write_frame,
};
use serde_json::json;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

fn start_connection(
    service: Arc<ApprovalService>,
    principal: Principal,
) -> (UnixStream, thread::JoinHandle<()>) {
    let (client, mut server) = UnixStream::pair().unwrap();
    let task = thread::spawn(move || {
        service.serve_connection(&mut server, &principal).unwrap();
    });
    (client, task)
}

fn exchange(stream: &mut UnixStream, request: &WireRequest) -> WireResponse {
    write_frame(stream, request, MAXIMUM_REQUEST_BYTES).unwrap();
    read_frame(stream, MAXIMUM_RESPONSE_BYTES).unwrap().unwrap()
}

fn hello(stream: &mut UnixStream) -> Uuid {
    let response = exchange(
        stream,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: None,
            body: RequestBody::Hello {
                client_version: "test".into(),
            },
        },
    );
    assert!(matches!(response.body, ResponseBody::HelloResult { .. }));
    response.service_epoch
}

fn approval(run_id: Uuid, request_id: Uuid) -> ApprovalRequestWire {
    ApprovalRequestWire {
        run_id,
        request_id,
        provider: ProviderId::new("claude").expect("provider id"),
        session_id: Some("session".into()),
        operation_id: None,
        tool_name: "Bash".into(),
        summary: Some("Run tests".into()),
        input: json!({"command": "make test"}),
        timeout_ms: 5_000,
        questions: Vec::new(),
        agent_run_id: None,
    }
}

#[test]
fn requester_waits_for_controller_decision_over_real_streams() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let requester_epoch = hello(&mut requester);
    let controller_epoch = hello(&mut controller);
    assert_eq!(requester_epoch, controller_epoch);

    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let resolver = thread::spawn(move || {
        let response = exchange(
            &mut controller,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(controller_epoch),
                body: RequestBody::ApprovalResolve {
                    key: ApprovalKeyWire { run_id, request_id },
                    decision: ApprovalDecisionWire::AllowOnce,
                },
            },
        );
        assert!(matches!(response.body, ResponseBody::ApprovalResult(_)));
        drop(controller);
    });

    let response = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalWait {
                key: ApprovalKeyWire { run_id, request_id },
                maximum_wait_ms: 5_000,
            },
        },
    );
    let ResponseBody::ApprovalResult(snapshot) = response.body else {
        panic!("expected approval result");
    };
    assert!(matches!(snapshot.state, ApprovalStateWire::Resolved { .. }));

    drop(requester);
    resolver.join().unwrap();
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn requester_receives_controller_answer_over_real_streams() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let requester_epoch = hello(&mut requester);
    let controller_epoch = hello(&mut controller);

    let mut request = approval(run_id, request_id);
    request.tool_name = "AskUserQuestion".into();
    request.input = json!({});
    request.questions = serde_json::from_value(json!([{
        "prompt": "Which color?",
        "options": [{"label": "Red"}],
        "multi_select": false
    }]))
    .unwrap();
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalSubmit(request),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let get = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(controller_epoch),
            body: RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        },
    );
    let ResponseBody::ApprovalResult(pending) = get.body else {
        panic!("expected approval result");
    };
    let pending = serde_json::to_value(&pending).unwrap();
    assert_eq!(pending["request"]["questions"][0]["prompt"], "Which color?");

    let decision = json!({"decision": "answer", "answers": {"Which color?": "Red"}});
    let resolve_decision: ApprovalDecisionWire = serde_json::from_value(decision.clone()).unwrap();
    let resolver = thread::spawn(move || {
        let response = exchange(
            &mut controller,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(controller_epoch),
                body: RequestBody::ApprovalResolve {
                    key: ApprovalKeyWire { run_id, request_id },
                    decision: resolve_decision,
                },
            },
        );
        assert!(matches!(response.body, ResponseBody::ApprovalResult(_)));
        drop(controller);
    });

    let response = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalWait {
                key: ApprovalKeyWire { run_id, request_id },
                maximum_wait_ms: 5_000,
            },
        },
    );
    let ResponseBody::ApprovalResult(snapshot) = response.body else {
        panic!("expected approval result");
    };
    let snapshot = serde_json::to_value(&snapshot).unwrap();
    assert_eq!(snapshot["state"]["status"], "resolved");
    assert_eq!(snapshot["state"]["result"], decision);

    drop(requester);
    resolver.join().unwrap();
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn controller_subscription_wakes_when_requester_submits() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let requester_epoch = hello(&mut requester);
    let controller_epoch = hello(&mut controller);
    assert_eq!(requester_epoch, controller_epoch);

    // The subscription is on the wire before the submit goes out. Whether
    // the service is already waiting on it by then is not something it
    // shows, so the assertions hold either way: a subscription that starts
    // after the submit reads the same snapshot at once.
    let (sent, subscription_sent) = mpsc::channel();
    let subscriber = thread::spawn(move || {
        write_frame(
            &mut controller,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(controller_epoch),
                body: RequestBody::ApprovalSubscribe {
                    after_sequence: 0,
                    maximum_wait_ms: 5_000,
                },
            },
            MAXIMUM_REQUEST_BYTES,
        )
        .unwrap();
        sent.send(()).unwrap();
        let response: WireResponse = read_frame(&mut controller, MAXIMUM_RESPONSE_BYTES)
            .unwrap()
            .unwrap();
        let ResponseBody::ApprovalSnapshotResult {
            sequence, requests, ..
        } = response.body
        else {
            panic!("expected approval snapshot result");
        };
        assert_eq!(sequence, 1);
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].request_id, request_id);
        drop(controller);
    });

    subscription_sent
        .recv_timeout(Duration::from_secs(5))
        .expect("the subscription is sent");
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    drop(requester);
    subscriber.join().unwrap();
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn stream_session_rejects_self_approval_and_stale_epoch() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        service,
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let epoch = hello(&mut requester);
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let self_approval = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::AllowOnce,
            },
        },
    );
    assert!(matches!(
        self_approval.body,
        ResponseBody::Error {
            code: ErrorCode::Unauthorized,
            ..
        }
    ));

    let stale = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(Uuid::new_v4()),
            body: RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        },
    );
    assert!(matches!(
        stale.body,
        ResponseBody::Error {
            code: ErrorCode::EpochMismatch,
            ..
        }
    ));

    drop(requester);
    requester_task.join().unwrap();
}

#[test]
fn wait_returns_at_the_callers_deadline_and_releases_the_broker() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);

    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let started = Instant::now();
    let wait = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalWait {
                key: ApprovalKeyWire { run_id, request_id },
                maximum_wait_ms: 20,
            },
        },
    );
    assert!(started.elapsed() < Duration::from_millis(500));
    let ResponseBody::ApprovalResult(snapshot) = wait.body else {
        panic!("expected approval result");
    };
    assert!(matches!(snapshot.state, ApprovalStateWire::Pending));

    let resolved = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::AllowOnce,
            },
        },
    );
    assert!(matches!(resolved.body, ResponseBody::ApprovalResult(_)));

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn oversized_denial_is_rejected_without_resolving_the_request() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let denied = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::Deny {
                    message: Some("x".repeat(MAXIMUM_DECISION_BYTES)),
                },
            },
        },
    );
    assert!(matches!(
        denied.body,
        ResponseBody::Error {
            code: ErrorCode::InvalidRequest,
            ..
        }
    ));

    let current = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        },
    );
    let ResponseBody::ApprovalResult(snapshot) = current.body else {
        panic!("expected approval result");
    };
    assert!(matches!(snapshot.state, ApprovalStateWire::Pending));

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn bounded_snapshot_remains_response_safe_at_capacity() {
    let service = Arc::new(ApprovalService::new(usize::MAX));
    let run_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);

    for _ in 0..MAXIMUM_RECORDS {
        let request_id = Uuid::new_v4();
        let mut request = approval(run_id, request_id);
        request.input = json!({"command": "x".repeat(40 * 1024)});
        let response = exchange(
            &mut requester,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(epoch),
                body: RequestBody::ApprovalSubmit(request),
            },
        );
        assert!(matches!(response.body, ResponseBody::ApprovalResult(_)));
    }

    let snapshot = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSnapshot,
        },
    );
    let encoded = serde_json::to_vec(&snapshot).unwrap();
    assert!(encoded.len() <= MAXIMUM_RESPONSE_BYTES);
    let ResponseBody::ApprovalSnapshotResult { requests, .. } = snapshot.body else {
        panic!("expected approval snapshot");
    };
    assert_eq!(requests.len(), MAXIMUM_RECORDS);

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

fn request(epoch: Uuid, body: RequestBody) -> WireRequest {
    WireRequest {
        version: PROTOCOL_VERSION,
        message_id: Uuid::new_v4(),
        service_epoch: Some(epoch),
        body,
    }
}

#[test]
fn only_controller_responses_carry_the_service_clock() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let key = ApprovalKeyWire { run_id, request_id };
    let submitted = exchange(
        &mut requester,
        &request(
            epoch,
            RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        ),
    );
    let ResponseBody::ApprovalResult(submitted) = submitted.body else {
        panic!("expected approval result");
    };
    assert_eq!(submitted.now_ms, None);

    let snapshot = exchange(
        &mut controller,
        &request(epoch, RequestBody::ApprovalSnapshot),
    );
    let ResponseBody::ApprovalSnapshotResult {
        requests, now_ms, ..
    } = snapshot.body
    else {
        panic!("expected approval snapshot");
    };
    let now_ms = now_ms.expect("a controller snapshot carries the service clock");
    assert!(requests[0].deadline_ms > now_ms);

    let controller_get = exchange(
        &mut controller,
        &request(epoch, RequestBody::ApprovalGet(key.clone())),
    );
    let ResponseBody::ApprovalResult(controller_get) = controller_get.body else {
        panic!("expected approval result");
    };
    assert!(controller_get.now_ms.is_some());

    // A requester's response keeps its current shape: the key is absent,
    // not null.
    let requester_get = exchange(
        &mut requester,
        &request(epoch, RequestBody::ApprovalGet(key)),
    );
    let encoded = serde_json::to_value(&requester_get).unwrap();
    assert!(encoded["body"].get("now_ms").is_none());

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn responses_from_an_older_service_still_decode() {
    let epoch = Uuid::new_v4();
    let snapshot = json!({
        "version": PROTOCOL_VERSION,
        "message_id": Uuid::new_v4(),
        "in_reply_to": Uuid::new_v4(),
        "service_epoch": epoch,
        "type": "approval.snapshot.result",
        "body": {"sequence": 3, "requests": []}
    });
    let decoded: WireResponse = serde_json::from_value(snapshot).unwrap();
    let ResponseBody::ApprovalSnapshotResult {
        sequence, now_ms, ..
    } = decoded.body
    else {
        panic!("expected approval snapshot");
    };
    assert_eq!(sequence, 3);
    assert_eq!(now_ms, None);

    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let get = json!({
        "version": PROTOCOL_VERSION,
        "message_id": Uuid::new_v4(),
        "in_reply_to": Uuid::new_v4(),
        "service_epoch": epoch,
        "type": "approval.result",
        "body": {
            "request": serde_json::to_value(approval(run_id, request_id)).unwrap(),
            "state": {"status": "pending"},
            "created_at_ms": 10,
            "deadline_ms": 5_010,
            "sequence": 1
        }
    });
    let decoded: WireResponse = serde_json::from_value(get).unwrap();
    let ResponseBody::ApprovalResult(snapshot) = decoded.body else {
        panic!("expected approval result");
    };
    assert_eq!(snapshot.now_ms, None);
}

#[test]
fn a_requesters_wait_consumes_its_result_and_a_controller_get_does_not() {
    let service = Arc::new(ApprovalService::new(2));
    let run_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let answered = Uuid::new_v4();
    for request_id in [answered, Uuid::new_v4()] {
        let submitted = exchange(
            &mut requester,
            &request(
                epoch,
                RequestBody::ApprovalSubmit(approval(run_id, request_id)),
            ),
        );
        assert!(matches!(submitted.body, ResponseBody::ApprovalResult(_)));
    }
    let key = ApprovalKeyWire {
        run_id,
        request_id: answered,
    };
    let resolved = exchange(
        &mut controller,
        &request(
            epoch,
            RequestBody::ApprovalResolve {
                key: key.clone(),
                decision: ApprovalDecisionWire::AllowOnce,
            },
        ),
    );
    assert!(matches!(resolved.body, ResponseBody::ApprovalResult(_)));

    // The app looking up how it ended keeps the result for the hook.
    exchange(
        &mut controller,
        &request(epoch, RequestBody::ApprovalGet(key.clone())),
    );
    let third = exchange(
        &mut requester,
        &request(
            epoch,
            RequestBody::ApprovalSubmit(approval(run_id, Uuid::new_v4())),
        ),
    );
    assert!(matches!(
        third.body,
        ResponseBody::Error {
            code: ErrorCode::CapacityExceeded,
            ..
        }
    ));
    let snapshot = exchange(
        &mut controller,
        &request(epoch, RequestBody::ApprovalSnapshot),
    );
    let ResponseBody::ApprovalSnapshotResult {
        unevictable_records,
        ..
    } = snapshot.body
    else {
        panic!("expected approval snapshot");
    };
    assert_eq!(unevictable_records, Some(2));

    // The hook's wait returns the result and frees its slot.
    let waited = exchange(
        &mut requester,
        &request(
            epoch,
            RequestBody::ApprovalWait {
                key,
                maximum_wait_ms: 1_000,
            },
        ),
    );
    assert!(matches!(waited.body, ResponseBody::ApprovalResult(_)));
    let fourth = exchange(
        &mut requester,
        &request(
            epoch,
            RequestBody::ApprovalSubmit(approval(run_id, Uuid::new_v4())),
        ),
    );
    assert!(matches!(fourth.body, ResponseBody::ApprovalResult(_)));

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}
