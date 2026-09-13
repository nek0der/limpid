#![cfg(unix)]

use limpid_agent_core::{Principal, RunId};
use limpid_agent_protocol::{
    AgentProviderWire, ApprovalDecisionWire, ApprovalKeyWire, ApprovalRequestWire, ApprovalService,
    ApprovalStateWire, ErrorCode, MAXIMUM_DECISION_BYTES, MAXIMUM_RECORDS, MAXIMUM_REQUEST_BYTES,
    MAXIMUM_RESPONSE_BYTES, PROTOCOL_VERSION, RequestBody, ResponseBody, WireRequest, WireResponse,
    read_frame, write_frame,
};
use serde_json::json;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
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
        provider: AgentProviderWire::Claude,
        session_id: Some("session".into()),
        operation_id: None,
        tool_name: "Bash".into(),
        summary: Some("Run tests".into()),
        input: json!({"command": "make test"}),
        timeout_ms: 5_000,
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
