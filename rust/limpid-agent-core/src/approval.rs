use std::collections::BTreeMap;
use uuid::Uuid;

macro_rules! identifier {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
        pub struct $name(Uuid);

        impl $name {
            #[must_use]
            pub const fn new(value: Uuid) -> Self {
                Self(value)
            }

            #[must_use]
            pub const fn value(self) -> Uuid {
                self.0
            }
        }
    };
}

identifier!(RunId);
identifier!(RequestId);
identifier!(ServiceEpoch);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentProvider {
    Claude,
    Codex,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Principal {
    Requester { run_id: RunId },
    Controller,
    Diagnostic,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ApprovalKey {
    pub run_id: RunId,
    pub request_id: RequestId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalRequest {
    pub key: ApprovalKey,
    pub provider: AgentProvider,
    pub session_id: Option<String>,
    pub operation_id: Option<String>,
    pub tool_name: String,
    pub summary: Option<String>,
    /// Canonical JSON owned by the protocol adapter.
    pub input_json: String,
    pub timeout_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalDecision {
    AllowOnce,
    Deny { message: Option<String> },
    Delegate,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalState {
    Pending,
    Resolved(ApprovalDecision),
    Canceled,
    Expired,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalSnapshot {
    pub request: ApprovalRequest,
    pub state: ApprovalState,
    pub created_at_ms: u64,
    pub deadline_ms: u64,
    pub sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BrokerError {
    Unauthorized,
    InvalidTimeout,
    CapacityExceeded,
    NotFound,
    RequestConflict,
    AlreadyTerminal,
    ClockOverflow,
    SequenceOverflow,
}

pub struct ApprovalBroker {
    epoch: ServiceEpoch,
    maximum_records: usize,
    sequence: u64,
    records: BTreeMap<ApprovalKey, ApprovalSnapshot>,
}

impl ApprovalBroker {
    #[must_use]
    pub fn new(epoch: ServiceEpoch, maximum_records: usize) -> Self {
        Self {
            epoch,
            maximum_records,
            sequence: 0,
            records: BTreeMap::new(),
        }
    }

    #[must_use]
    pub const fn epoch(&self) -> ServiceEpoch {
        self.epoch
    }

    #[must_use]
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Registers a request for the authenticated run.
    ///
    /// # Errors
    ///
    /// Returns an authorization, validation, capacity, conflict, or counter
    /// error without changing an existing request.
    pub fn submit(
        &mut self,
        principal: &Principal,
        request: ApprovalRequest,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Requester { run_id } if *run_id == request.key.run_id) {
            return Err(BrokerError::Unauthorized);
        }
        if request.timeout_ms == 0 {
            return Err(BrokerError::InvalidTimeout);
        }
        if let Some(existing) = self.records.get(&request.key) {
            return if existing.request == request {
                Ok(existing.clone())
            } else {
                Err(BrokerError::RequestConflict)
            };
        }
        if self.records.len() >= self.maximum_records {
            return Err(BrokerError::CapacityExceeded);
        }
        let deadline_ms = now_ms
            .checked_add(request.timeout_ms)
            .ok_or(BrokerError::ClockOverflow)?;
        let sequence = self.next_sequence()?;
        let snapshot = ApprovalSnapshot {
            request,
            state: ApprovalState::Pending,
            created_at_ms: now_ms,
            deadline_ms,
            sequence,
        };
        self.records.insert(snapshot.request.key, snapshot.clone());
        Ok(snapshot)
    }

    /// Returns one request visible to the principal, expiring it first when due.
    ///
    /// # Errors
    ///
    /// Returns an authorization, missing-request, or counter error.
    pub fn get(
        &mut self,
        principal: &Principal,
        key: ApprovalKey,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        Self::authorize_read(principal, key)?;
        self.records.get(&key).cloned().ok_or(BrokerError::NotFound)
    }

    /// Applies the first controller decision to a pending request.
    ///
    /// # Errors
    ///
    /// Returns an authorization, missing-request, terminal-state, or counter
    /// error. Repeating the same accepted decision is idempotent.
    pub fn resolve(
        &mut self,
        principal: &Principal,
        key: ApprovalKey,
        decision: ApprovalDecision,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Controller) {
            return Err(BrokerError::Unauthorized);
        }
        if let Some(existing) = self.records.get(&key) {
            if existing.state == ApprovalState::Resolved(decision.clone()) {
                return Ok(existing.clone());
            }
            if existing.state != ApprovalState::Pending {
                return Err(BrokerError::AlreadyTerminal);
            }
        } else {
            return Err(BrokerError::NotFound);
        }
        let sequence = self.next_sequence()?;
        let record = self.records.get_mut(&key).ok_or(BrokerError::NotFound)?;
        record.state = ApprovalState::Resolved(decision);
        record.sequence = sequence;
        Ok(record.clone())
    }

    /// Cancels a pending request owned by the requester.
    ///
    /// # Errors
    ///
    /// Returns an authorization, missing-request, terminal-state, or counter
    /// error.
    pub fn cancel(
        &mut self,
        principal: &Principal,
        key: ApprovalKey,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Requester { run_id } if *run_id == key.run_id) {
            return Err(BrokerError::Unauthorized);
        }
        let state = self
            .records
            .get(&key)
            .map(|record| record.state.clone())
            .ok_or(BrokerError::NotFound)?;
        if state == ApprovalState::Canceled {
            return self.records.get(&key).cloned().ok_or(BrokerError::NotFound);
        }
        if state != ApprovalState::Pending {
            return Err(BrokerError::AlreadyTerminal);
        }
        let sequence = self.next_sequence()?;
        let record = self.records.get_mut(&key).ok_or(BrokerError::NotFound)?;
        record.state = ApprovalState::Canceled;
        record.sequence = sequence;
        Ok(record.clone())
    }

    /// Returns a controller-only consistent snapshot after applying expiry.
    ///
    /// # Errors
    ///
    /// Returns an authorization or counter error.
    pub fn snapshot(
        &mut self,
        principal: &Principal,
        now_ms: u64,
    ) -> Result<Vec<ApprovalSnapshot>, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Controller) {
            return Err(BrokerError::Unauthorized);
        }
        Ok(self.records.values().cloned().collect())
    }

    /// Expires every pending request whose deadline has passed.
    ///
    /// # Errors
    ///
    /// Returns a counter error if the projection sequence is exhausted.
    pub fn expire(&mut self, now_ms: u64) -> Result<Vec<ApprovalSnapshot>, BrokerError> {
        let keys = self
            .records
            .iter()
            .filter(|(_, record)| {
                record.state == ApprovalState::Pending && now_ms >= record.deadline_ms
            })
            .map(|(key, _)| *key)
            .collect::<Vec<_>>();
        let expired_count = u64::try_from(keys.len()).map_err(|_| BrokerError::SequenceOverflow)?;
        self.sequence
            .checked_add(expired_count)
            .ok_or(BrokerError::SequenceOverflow)?;
        let mut expired = Vec::with_capacity(keys.len());
        for key in keys {
            // The aggregate check above proves every increment in this loop is
            // safe, so expiry cannot leave a partially updated batch.
            self.sequence += 1;
            if let Some(record) = self.records.get_mut(&key) {
                record.state = ApprovalState::Expired;
                record.sequence = self.sequence;
                expired.push(record.clone());
            }
        }
        Ok(expired)
    }

    fn authorize_read(principal: &Principal, key: ApprovalKey) -> Result<(), BrokerError> {
        match principal {
            Principal::Requester { run_id } if *run_id == key.run_id => Ok(()),
            Principal::Controller => Ok(()),
            Principal::Requester { .. } | Principal::Diagnostic => Err(BrokerError::Unauthorized),
        }
    }

    fn next_sequence(&mut self) -> Result<u64, BrokerError> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(BrokerError::SequenceOverflow)?;
        Ok(self.sequence)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(value: u128) -> Uuid {
        Uuid::from_u128(value)
    }

    fn request(run: u128, request: u128) -> ApprovalRequest {
        ApprovalRequest {
            key: ApprovalKey {
                run_id: RunId::new(id(run)),
                request_id: RequestId::new(id(request)),
            },
            provider: AgentProvider::Claude,
            session_id: Some("session".into()),
            operation_id: None,
            tool_name: "Bash".into(),
            summary: Some("Run tests".into()),
            input_json: r#"{"command":"make test"}"#.into(),
            timeout_ms: 1_000,
        }
    }

    fn broker() -> ApprovalBroker {
        ApprovalBroker::new(ServiceEpoch::new(id(99)), 8)
    }

    #[test]
    fn requester_cannot_resolve_its_own_request() {
        let mut broker = broker();
        let request = request(1, 2);
        let principal = Principal::Requester {
            run_id: request.key.run_id,
        };
        broker.submit(&principal, request.clone(), 0).unwrap();

        assert_eq!(
            broker.resolve(&principal, request.key, ApprovalDecision::AllowOnce, 1),
            Err(BrokerError::Unauthorized)
        );
    }

    #[test]
    fn requester_cannot_read_or_cancel_another_run() {
        let mut broker = broker();
        let request = request(1, 2);
        broker
            .submit(
                &Principal::Requester {
                    run_id: request.key.run_id,
                },
                request.clone(),
                0,
            )
            .unwrap();
        let other = Principal::Requester {
            run_id: RunId::new(id(3)),
        };

        assert_eq!(
            broker.get(&other, request.key, 1),
            Err(BrokerError::Unauthorized)
        );
        assert_eq!(
            broker.cancel(&other, request.key, 1),
            Err(BrokerError::Unauthorized)
        );
    }

    #[test]
    fn identical_submit_and_resolution_are_idempotent() {
        let mut broker = broker();
        let request = request(1, 2);
        let requester = Principal::Requester {
            run_id: request.key.run_id,
        };
        let first = broker.submit(&requester, request.clone(), 0).unwrap();
        let second = broker.submit(&requester, request.clone(), 10).unwrap();
        assert_eq!(first, second);

        let first = broker
            .resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                20,
            )
            .unwrap();
        let second = broker
            .resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                30,
            )
            .unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn changed_submit_conflicts_and_late_allow_is_rejected() {
        let mut broker = broker();
        let request = request(1, 2);
        let requester = Principal::Requester {
            run_id: request.key.run_id,
        };
        broker.submit(&requester, request.clone(), 0).unwrap();
        let mut changed = request.clone();
        changed.tool_name = "Write".into();
        assert_eq!(
            broker.submit(&requester, changed, 1),
            Err(BrokerError::RequestConflict)
        );
        assert_eq!(
            broker.resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                1_000
            ),
            Err(BrokerError::AlreadyTerminal)
        );
        assert_eq!(
            broker.get(&requester, request.key, 1_000).unwrap().state,
            ApprovalState::Expired
        );
    }

    #[test]
    fn cancellation_wins_over_delayed_resolution() {
        let mut broker = broker();
        let request = request(1, 2);
        let requester = Principal::Requester {
            run_id: request.key.run_id,
        };
        broker.submit(&requester, request.clone(), 0).unwrap();
        broker.cancel(&requester, request.key, 10).unwrap();

        assert_eq!(
            broker.resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                11
            ),
            Err(BrokerError::AlreadyTerminal)
        );
    }
}
