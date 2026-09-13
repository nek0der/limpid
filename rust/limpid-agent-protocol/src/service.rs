use crate::frame::{FrameError, read_frame, write_frame};
use crate::wire::{
    ApprovalIndexWire, ApprovalSnapshotWire, ErrorCode, RequestBody, ResponseBody, WireRequest,
    WireResponse,
};
use crate::{
    MAXIMUM_APPROVAL_BYTES, MAXIMUM_DECISION_BYTES, MAXIMUM_RECORDS, MAXIMUM_REQUEST_BYTES,
    MAXIMUM_RESPONSE_BYTES, MAXIMUM_WAIT_MS, PROTOCOL_VERSION,
};
use limpid_agent_core::{ApprovalBroker, ApprovalState, BrokerError, Principal, ServiceEpoch};
use std::fmt;
use std::io::{Read, Write};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use uuid::Uuid;

#[derive(Debug)]
pub enum ServeError {
    Frame(FrameError),
    Synchronization,
}

impl fmt::Display for ServeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Frame(error) => write!(formatter, "{error}"),
            Self::Synchronization => formatter.write_str("approval service synchronization failed"),
        }
    }
}

impl std::error::Error for ServeError {}

impl From<FrameError> for ServeError {
    fn from(value: FrameError) -> Self {
        Self::Frame(value)
    }
}

/// In-process protocol host. Platform adapters authenticate the peer, choose a
/// principal, and provide the stream and its process lifetime.
pub struct ApprovalService {
    started_at: Instant,
    broker: Mutex<ApprovalBroker>,
    changed: Condvar,
}

/// A platform-authenticated, stateful connection to an [`ApprovalService`].
///
/// The platform adapter supplies the principal when it creates this value. The
/// JSON payload never chooses its authorization level, and each connection
/// tracks its own completed hello exchange.
pub struct ApprovalSession {
    service: Arc<ApprovalService>,
    principal: Principal,
    has_completed_hello: bool,
}

#[derive(Debug)]
pub enum ExchangeError {
    InputTooLarge,
    InvalidUtf8,
    InvalidJson,
    ResponseTooLarge,
    Service(ServeError),
}

impl fmt::Display for ExchangeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge => formatter.write_str("request exceeds the protocol limit"),
            Self::InvalidUtf8 => formatter.write_str("request is not valid UTF-8"),
            Self::InvalidJson => formatter.write_str("request is not valid JSON"),
            Self::ResponseTooLarge => formatter.write_str("response exceeds the protocol limit"),
            Self::Service(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for ExchangeError {}

impl ApprovalService {
    #[must_use]
    pub fn new(maximum_records: usize) -> Self {
        Self {
            started_at: Instant::now(),
            broker: Mutex::new(ApprovalBroker::new(
                ServiceEpoch::new(Uuid::new_v4()),
                maximum_records.min(MAXIMUM_RECORDS),
            )),
            changed: Condvar::new(),
        }
    }

    /// Creates one authenticated discrete-message session.
    #[must_use]
    pub fn session(self: &Arc<Self>, principal: Principal) -> ApprovalSession {
        ApprovalSession {
            service: Arc::clone(self),
            principal,
            has_completed_hello: false,
        }
    }

    /// Serves request-response frames until the peer closes the stream.
    ///
    /// The platform host must authenticate the peer and inject its principal;
    /// no role claimed in JSON can grant controller authority.
    ///
    /// # Errors
    ///
    /// Returns a framing, serialization, I/O, or synchronization error and
    /// never converts that failure into an approval.
    pub fn serve_connection<S: Read + Write>(
        &self,
        stream: &mut S,
        principal: &Principal,
    ) -> Result<(), ServeError> {
        let mut has_completed_hello = false;
        while let Some(request) = read_frame(stream, MAXIMUM_REQUEST_BYTES)? {
            let response = self.handle(principal, &mut has_completed_hello, request)?;
            Self::write_response(stream, &response)?;
        }
        Ok(())
    }

    fn handle(
        &self,
        principal: &Principal,
        has_completed_hello: &mut bool,
        request: WireRequest,
    ) -> Result<WireResponse, ServeError> {
        let epoch = self.lock_broker()?.epoch().value();
        let body = if request.version != PROTOCOL_VERSION {
            error(
                ErrorCode::UnsupportedVersion,
                "unsupported protocol version",
            )
        } else if matches!(request.body, RequestBody::Hello { .. }) {
            if *has_completed_hello {
                error(ErrorCode::AlreadyInitialized, "hello was already accepted")
            } else {
                *has_completed_hello = true;
                ResponseBody::HelloResult {
                    capabilities: vec![
                        "approval.allow_once".into(),
                        "approval.deny".into(),
                        "approval.delegate".into(),
                        "approval.subscribe".into(),
                        "approval.wait".into(),
                    ],
                }
            }
        } else if !*has_completed_hello {
            error(ErrorCode::HelloRequired, "hello must be the first request")
        } else if request.service_epoch != Some(epoch) {
            error(
                ErrorCode::EpochMismatch,
                "service epoch does not match this process",
            )
        } else {
            self.handle_authenticated(principal, request.body)?
        };

        Ok(WireResponse {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            in_reply_to: request.message_id,
            service_epoch: epoch,
            body,
        })
    }

    fn handle_authenticated(
        &self,
        principal: &Principal,
        body: RequestBody,
    ) -> Result<ResponseBody, ServeError> {
        if requested_wait_ms(&body).is_some_and(|wait_ms| wait_ms > MAXIMUM_WAIT_MS) {
            return Ok(error(
                ErrorCode::InvalidTimeout,
                "wait is outside the supported range",
            ));
        }
        let result = match body {
            RequestBody::Hello { .. } => {
                return Ok(error(
                    ErrorCode::AlreadyInitialized,
                    "hello was already accepted",
                ));
            }
            RequestBody::ApprovalSubmit(request) => {
                if request.timeout_ms == 0 {
                    return Ok(error(
                        ErrorCode::InvalidTimeout,
                        "timeout is outside the supported range",
                    ));
                }
                let encoded_length = serde_json::to_vec(&request)
                    .map_err(|_| ServeError::Synchronization)?
                    .len();
                if encoded_length > MAXIMUM_APPROVAL_BYTES {
                    return Ok(error(
                        ErrorCode::InvalidRequest,
                        "approval request exceeds the response-safe limit",
                    ));
                }
                let Ok(request) = request.into_domain() else {
                    return Ok(error(ErrorCode::InvalidRequest, "input is not valid JSON"));
                };
                let result = self
                    .lock_broker()?
                    .submit(principal, request, self.now_ms());
                if result.is_ok() {
                    self.changed.notify_all();
                }
                result
            }
            RequestBody::ApprovalGet(key) => {
                self.lock_broker()?
                    .get(principal, key.into_domain(), self.now_ms())
            }
            RequestBody::ApprovalWait {
                key,
                maximum_wait_ms,
            } => {
                return self.wait(principal, key.into_domain(), maximum_wait_ms);
            }
            RequestBody::ApprovalCancel(key) => {
                let result =
                    self.lock_broker()?
                        .cancel(principal, key.into_domain(), self.now_ms());
                if result.is_ok() {
                    self.changed.notify_all();
                }
                result
            }
            RequestBody::ApprovalResolve { key, decision } => {
                let decision_length = serde_json::to_vec(&decision)
                    .map_err(|_| ServeError::Synchronization)?
                    .len();
                if decision_length > MAXIMUM_DECISION_BYTES {
                    return Ok(error(
                        ErrorCode::InvalidRequest,
                        "approval decision exceeds the supported limit",
                    ));
                }
                let result = self.lock_broker()?.resolve(
                    principal,
                    key.into_domain(),
                    decision.into(),
                    self.now_ms(),
                );
                if result.is_ok() {
                    self.changed.notify_all();
                }
                result
            }
            RequestBody::ApprovalSnapshot => {
                return self.snapshot(principal);
            }
            RequestBody::ApprovalSubscribe {
                after_sequence,
                maximum_wait_ms,
            } => {
                return self.subscribe(principal, after_sequence, maximum_wait_ms);
            }
        };
        match result {
            Ok(snapshot) => ApprovalSnapshotWire::from_domain(snapshot)
                .map(ResponseBody::ApprovalResult)
                .map_err(|_| ServeError::Synchronization),
            Err(error) => Ok(broker_error(&error)),
        }
    }

    fn wait(
        &self,
        principal: &Principal,
        key: limpid_agent_core::ApprovalKey,
        maximum_wait_ms: u64,
    ) -> Result<ResponseBody, ServeError> {
        let wait_started = Instant::now();
        let mut broker = self.lock_broker()?;
        loop {
            let now_ms = self.now_ms();
            let snapshot = match broker.get(principal, key, now_ms) {
                Ok(snapshot) => snapshot,
                Err(error) => return Ok(broker_error(&error)),
            };
            let caller_remaining_ms = maximum_wait_ms.saturating_sub(
                u64::try_from(wait_started.elapsed().as_millis()).unwrap_or(u64::MAX),
            );
            if snapshot.state != ApprovalState::Pending || caller_remaining_ms == 0 {
                return ApprovalSnapshotWire::from_domain(snapshot)
                    .map(ResponseBody::ApprovalResult)
                    .map_err(|_| ServeError::Synchronization);
            }
            let request_remaining_ms = snapshot.deadline_ms.saturating_sub(now_ms);
            let remaining_ms = request_remaining_ms.min(caller_remaining_ms);
            if remaining_ms == 0 {
                continue;
            }
            let waited = self
                .changed
                .wait_timeout(broker, Duration::from_millis(remaining_ms))
                .map_err(|_| ServeError::Synchronization)?;
            broker = waited.0;
        }
    }

    fn snapshot(&self, principal: &Principal) -> Result<ResponseBody, ServeError> {
        let mut broker = self.lock_broker()?;
        let snapshots = match broker.snapshot(principal, self.now_ms()) {
            Ok(snapshots) => snapshots,
            Err(error) => return Ok(broker_error(&error)),
        };
        let sequence = broker.sequence();
        let requests = snapshots.into_iter().map(ApprovalIndexWire::from).collect();
        Ok(ResponseBody::ApprovalSnapshotResult { sequence, requests })
    }

    /// Holds a controller request until the projection changes or its bounded
    /// wait ends. Reissuing this cursor-based call is an event subscription,
    /// so the app never needs a timer that polls the broker.
    fn subscribe(
        &self,
        principal: &Principal,
        after_sequence: u64,
        maximum_wait_ms: u64,
    ) -> Result<ResponseBody, ServeError> {
        if !matches!(principal, Principal::Controller) {
            return Ok(broker_error(&BrokerError::Unauthorized));
        }
        let wait_started = Instant::now();
        let mut broker = self.lock_broker()?;
        loop {
            let now_ms = self.now_ms();
            let snapshots = match broker.snapshot(principal, now_ms) {
                Ok(snapshots) => snapshots,
                Err(error) => return Ok(broker_error(&error)),
            };
            let sequence = broker.sequence();
            let caller_remaining_ms = maximum_wait_ms.saturating_sub(
                u64::try_from(wait_started.elapsed().as_millis()).unwrap_or(u64::MAX),
            );
            if sequence != after_sequence || caller_remaining_ms == 0 {
                let requests = snapshots.into_iter().map(ApprovalIndexWire::from).collect();
                return Ok(ResponseBody::ApprovalSnapshotResult { sequence, requests });
            }
            let deadline_remaining_ms = snapshots
                .iter()
                .filter(|snapshot| snapshot.state == ApprovalState::Pending)
                .map(|snapshot| snapshot.deadline_ms.saturating_sub(now_ms))
                .min()
                .unwrap_or(caller_remaining_ms);
            let remaining_ms = caller_remaining_ms.min(deadline_remaining_ms);
            if remaining_ms == 0 {
                continue;
            }
            let waited = self
                .changed
                .wait_timeout(broker, Duration::from_millis(remaining_ms))
                .map_err(|_| ServeError::Synchronization)?;
            broker = waited.0;
        }
    }

    fn lock_broker(&self) -> Result<MutexGuard<'_, ApprovalBroker>, ServeError> {
        self.broker.lock().map_err(|_| ServeError::Synchronization)
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.started_at.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn write_response<S: Write>(stream: &mut S, response: &WireResponse) -> Result<(), ServeError> {
        match write_frame(stream, response, MAXIMUM_RESPONSE_BYTES) {
            Ok(()) => Ok(()),
            Err(FrameError::TooLarge { .. }) => {
                let fallback = WireResponse {
                    version: PROTOCOL_VERSION,
                    message_id: Uuid::new_v4(),
                    in_reply_to: response.in_reply_to,
                    service_epoch: response.service_epoch,
                    body: error(ErrorCode::Internal, "response exceeds the protocol limit"),
                };
                write_frame(stream, &fallback, MAXIMUM_RESPONSE_BYTES).map_err(ServeError::Frame)
            }
            Err(error) => Err(ServeError::Frame(error)),
        }
    }
}

impl ApprovalSession {
    /// Handles exactly one complete JSON request and returns exactly one JSON
    /// response. This intentionally does not use stream framing: XPC carries
    /// one `Data` value for each request and response.
    ///
    /// # Errors
    ///
    /// Returns malformed-input, size, serialization, or service errors. The
    /// caller must treat every error as a rejected operation.
    pub fn exchange_json(&mut self, input: &[u8]) -> Result<Vec<u8>, ExchangeError> {
        if input.len() > MAXIMUM_REQUEST_BYTES {
            return Err(ExchangeError::InputTooLarge);
        }
        let input = std::str::from_utf8(input).map_err(|_| ExchangeError::InvalidUtf8)?;
        let request = serde_json::from_str(input).map_err(|_| ExchangeError::InvalidJson)?;
        let response = self
            .service
            .handle(&self.principal, &mut self.has_completed_hello, request)
            .map_err(ExchangeError::Service)?;
        let encoded = serde_json::to_vec(&response).map_err(|_| ExchangeError::ResponseTooLarge)?;
        if encoded.len() > MAXIMUM_RESPONSE_BYTES {
            return Err(ExchangeError::ResponseTooLarge);
        }
        Ok(encoded)
    }
}

fn error(code: ErrorCode, message: &str) -> ResponseBody {
    ResponseBody::Error {
        code,
        message: message.into(),
    }
}

fn requested_wait_ms(body: &RequestBody) -> Option<u64> {
    match body {
        RequestBody::ApprovalSubmit(request) => Some(request.timeout_ms),
        RequestBody::ApprovalWait {
            maximum_wait_ms, ..
        }
        | RequestBody::ApprovalSubscribe {
            maximum_wait_ms, ..
        } => Some(*maximum_wait_ms),
        _ => None,
    }
}

fn broker_error(error_value: &BrokerError) -> ResponseBody {
    let (code, message) = match error_value {
        BrokerError::Unauthorized => (ErrorCode::Unauthorized, "principal is not authorized"),
        BrokerError::InvalidTimeout => (ErrorCode::InvalidTimeout, "timeout must be positive"),
        BrokerError::CapacityExceeded => {
            (ErrorCode::CapacityExceeded, "approval capacity exceeded")
        }
        BrokerError::NotFound => (ErrorCode::NotFound, "approval request was not found"),
        BrokerError::RequestConflict => (
            ErrorCode::RequestConflict,
            "request ID was reused with different content",
        ),
        BrokerError::AlreadyTerminal => (
            ErrorCode::AlreadyTerminal,
            "approval request is already terminal",
        ),
        BrokerError::ClockOverflow | BrokerError::SequenceOverflow => {
            (ErrorCode::Internal, "approval service counter overflow")
        }
    };
    error(code, message)
}
