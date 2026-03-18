use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{RwLock, mpsc};
use tokio::time::{Duration, interval};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crate::codex::{AppServerClient, SessionEventSender};
use crate::config::EffectiveConfig;
use crate::domain::{
    CodexTotals, Issue, IssueDebugSnapshot, RetryEntry, RunningSessionSnapshot, RuntimeEvent,
    RuntimeSnapshot, SnapshotCounts, TokenUsage,
};
use crate::error::{Result, SymphonyError};
use crate::linear::LinearClient;
use crate::prompt::{continuation_prompt, render_prompt};
use crate::workflow::WorkflowStore;
use crate::workspace::{WorkspaceManager, sanitize_issue_identifier};

#[derive(Debug)]
pub enum ControlMessage {
    Refresh,
}

#[derive(Debug)]
pub enum WorkerMessage {
    Event {
        issue_id: String,
        event: RuntimeEvent,
        rate_limits: Option<Value>,
    },
    Finished {
        issue_id: String,
        result: std::result::Result<(), SymphonyError>,
    },
}

struct RunningEntry {
    issue: Issue,
    workspace: PathBuf,
    started_at: DateTime<Utc>,
    turn_count: u32,
    session_id: Option<String>,
    last_event: Option<String>,
    last_message: Option<String>,
    last_event_at: Option<DateTime<Utc>>,
    last_usage_totals: TokenUsage,
    current_retry_attempt: Option<u32>,
    last_error: Option<String>,
    recent_events: VecDeque<RuntimeEvent>,
    cancel: CancellationToken,
}

#[derive(Default)]
struct State {
    running: BTreeMap<String, RunningEntry>,
    claimed: BTreeSet<String>,
    retry_attempts: BTreeMap<String, RetryEntry>,
    ended_runtime_seconds: f64,
    codex_totals: CodexTotals,
    rate_limits: Option<Value>,
}

#[derive(Clone)]
pub struct Orchestrator {
    workflow: WorkflowStore,
    snapshot: Arc<RwLock<RuntimeSnapshot>>,
    logs_root: Option<PathBuf>,
}

impl Orchestrator {
    pub fn new(workflow: WorkflowStore, logs_root: Option<PathBuf>) -> Self {
        let snapshot = Arc::new(RwLock::new(RuntimeSnapshot {
            generated_at: Utc::now(),
            counts: SnapshotCounts {
                running: 0,
                retrying: 0,
            },
            running: Vec::new(),
            retrying: Vec::new(),
            codex_totals: CodexTotals::zero(),
            rate_limits: None,
            workflow_error: None,
        }));
        Self {
            workflow,
            snapshot,
            logs_root,
        }
    }

    pub fn snapshot_handle(&self) -> Arc<RwLock<RuntimeSnapshot>> {
        self.snapshot.clone()
    }

    pub async fn run(self, mut control_rx: mpsc::Receiver<ControlMessage>) -> Result<()> {
        let (worker_tx, mut worker_rx) = mpsc::channel(512);
        let mut state = State::default();
        let initial_config = self.workflow.current().config.clone();
        startup_terminal_cleanup(&initial_config).await;
        let mut tick = interval(Duration::from_millis(initial_config.polling.interval_ms));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    self.workflow.reload_if_changed();
                    let config = self.workflow.current().config.clone();
                    tick = interval(Duration::from_millis(config.polling.interval_ms));
                    self.reconcile(&config, &mut state).await;
                    if let Err(error) = config.validate_dispatch_preflight() {
                        warn!("dispatch preflight validation failed: {error}");
                        self.publish_snapshot(&state).await;
                        continue;
                    }
                    if let Err(error) = self.dispatch_tick(&config, &mut state, worker_tx.clone()).await {
                        warn!("dispatch tick failed: {error}");
                    }
                    self.process_due_retries(&config, &mut state, worker_tx.clone()).await;
                    self.publish_snapshot(&state).await;
                }
                Some(message) = worker_rx.recv() => {
                    self.handle_worker_message(&mut state, message).await;
                    self.publish_snapshot(&state).await;
                }
                Some(control) = control_rx.recv() => {
                    match control {
                        ControlMessage::Refresh => {
                            let config = self.workflow.current().config.clone();
                            self.reconcile(&config, &mut state).await;
                            if let Err(error) = self.dispatch_tick(&config, &mut state, worker_tx.clone()).await {
                                warn!("refresh dispatch failed: {error}");
                            }
                            self.process_due_retries(&config, &mut state, worker_tx.clone()).await;
                            self.publish_snapshot(&state).await;
                        }
                    }
                }
            }
        }
    }

    async fn dispatch_tick(
        &self,
        config: &EffectiveConfig,
        state: &mut State,
        worker_tx: mpsc::Sender<WorkerMessage>,
    ) -> Result<()> {
        let client = LinearClient::new(config.clone())?;
        let mut issues = client.fetch_candidate_issues().await?;
        issues.sort_by(|left, right| {
            left.priority
                .unwrap_or(i64::MAX)
                .cmp(&right.priority.unwrap_or(i64::MAX))
                .then_with(|| left.created_at.cmp(&right.created_at))
                .then_with(|| left.identifier.cmp(&right.identifier))
        });
        for issue in issues {
            if self.available_slots(config, state) == 0 {
                break;
            }
            if self.should_dispatch(config, state, &issue) {
                self.dispatch_issue(config, state, issue, None, worker_tx.clone())
                    .await;
            }
        }
        Ok(())
    }

    async fn process_due_retries(
        &self,
        config: &EffectiveConfig,
        state: &mut State,
        worker_tx: mpsc::Sender<WorkerMessage>,
    ) {
        let now = Utc::now();
        let due: Vec<String> = state
            .retry_attempts
            .iter()
            .filter(|(_, entry)| entry.due_at <= now)
            .map(|(issue_id, _)| issue_id.clone())
            .collect();
        if due.is_empty() {
            return;
        }
        let client = match LinearClient::new(config.clone()) {
            Ok(client) => client,
            Err(error) => {
                warn!("retry polling failed before client init: {error}");
                return;
            }
        };
        let candidates = match client.fetch_candidate_issues().await {
            Ok(candidates) => candidates,
            Err(error) => {
                warn!("retry candidate fetch failed: {error}");
                return;
            }
        };
        for issue_id in due {
            let Some(entry) = state.retry_attempts.remove(&issue_id) else {
                continue;
            };
            let maybe_issue = candidates
                .iter()
                .find(|issue| issue.id == issue_id)
                .cloned();
            match maybe_issue {
                Some(issue) if self.should_dispatch(config, state, &issue) => {
                    self.dispatch_issue(
                        config,
                        state,
                        issue,
                        Some(entry.attempt),
                        worker_tx.clone(),
                    )
                    .await;
                }
                Some(issue) => {
                    self.schedule_retry(
                        config,
                        state,
                        issue.id.clone(),
                        issue.identifier.clone(),
                        entry.attempt + 1,
                        Some("no available orchestrator slots".to_string()),
                    );
                }
                None => {
                    state.claimed.remove(&issue_id);
                }
            }
        }
    }

    async fn reconcile(&self, config: &EffectiveConfig, state: &mut State) {
        let now = Utc::now();
        let stalled: Vec<String> = state
            .running
            .iter()
            .filter_map(|(issue_id, entry)| {
                let reference = entry.last_event_at.unwrap_or(entry.started_at);
                let elapsed = now.signed_duration_since(reference).num_milliseconds();
                (config.codex.stall_timeout_ms > 0 && elapsed > config.codex.stall_timeout_ms)
                    .then(|| issue_id.clone())
            })
            .collect();
        for issue_id in stalled {
            if let Some(entry) = state.running.remove(&issue_id) {
                entry.cancel.cancel();
                self.add_runtime_seconds(state, &entry);
                self.schedule_retry(
                    config,
                    state,
                    issue_id.clone(),
                    entry.issue.identifier.clone(),
                    entry.current_retry_attempt.unwrap_or(0) + 1,
                    Some("stalled session".to_string()),
                );
            }
        }
        let running_ids: Vec<String> = state.running.keys().cloned().collect();
        if running_ids.is_empty() {
            return;
        }
        let client = match LinearClient::new(config.clone()) {
            Ok(client) => client,
            Err(error) => {
                warn!("running state refresh failed before client init: {error}");
                return;
            }
        };
        let refreshed = match client.fetch_issue_states_by_ids(&running_ids).await {
            Ok(issues) => issues,
            Err(error) => {
                warn!("running state refresh failed: {error}");
                return;
            }
        };
        let by_id: BTreeMap<String, Issue> = refreshed
            .into_iter()
            .map(|issue| (issue.id.clone(), issue))
            .collect();
        for issue_id in running_ids {
            let Some(issue) = by_id.get(&issue_id).cloned() else {
                continue;
            };
            if config.is_terminal_state(&issue.state) {
                self.stop_issue(
                    state,
                    &issue_id,
                    true,
                    Some("tracker entered terminal state".to_string()),
                )
                .await;
            } else if config.is_active_state(&issue.state) {
                if let Some(entry) = state.running.get_mut(&issue_id) {
                    entry.issue = issue;
                }
            } else {
                self.stop_issue(
                    state,
                    &issue_id,
                    false,
                    Some("tracker left active state".to_string()),
                )
                .await;
            }
        }
    }

    async fn stop_issue(
        &self,
        state: &mut State,
        issue_id: &str,
        cleanup_workspace: bool,
        reason: Option<String>,
    ) {
        let Some(entry) = state.running.remove(issue_id) else {
            return;
        };
        entry.cancel.cancel();
        self.add_runtime_seconds(state, &entry);
        if cleanup_workspace {
            let manager = WorkspaceManager::new(self.workflow.current().config.clone());
            if let Err(error) = manager.remove(&entry.workspace).await {
                warn!("workspace cleanup failed: {error}");
            }
        }
        state.claimed.remove(issue_id);
        state.retry_attempts.remove(issue_id);
        if let Some(message) = reason {
            info!(
                issue_id = %entry.issue.id,
                issue_identifier = %entry.issue.identifier,
                reason = %message,
                "running issue stopped"
            );
        }
    }

    async fn dispatch_issue(
        &self,
        config: &EffectiveConfig,
        state: &mut State,
        issue: Issue,
        attempt: Option<u32>,
        worker_tx: mpsc::Sender<WorkerMessage>,
    ) {
        let workspace_path = config
            .workspace
            .root
            .join(sanitize_issue_identifier(&issue.identifier));
        let cancel = CancellationToken::new();
        let issue_id = issue.id.clone();
        let issue_id_for_task = issue_id.clone();
        let issue_identifier = issue.identifier.clone();
        let issue_for_task = issue.clone();
        let workflow = self.workflow.clone();
        let logs_root = self.logs_root.clone();
        let cancel_for_task = cancel.clone();
        let _handle = tokio::spawn(async move {
            let result = run_agent_attempt(
                workflow,
                logs_root,
                issue_for_task,
                attempt,
                cancel_for_task,
                worker_tx.clone(),
            )
            .await;
            let _ = worker_tx
                .send(WorkerMessage::Finished {
                    issue_id: issue_id_for_task,
                    result,
                })
                .await;
        });
        state.retry_attempts.remove(&issue_id);
        state.claimed.insert(issue_id.clone());
        state.running.insert(
            issue_id.clone(),
            RunningEntry {
                issue,
                workspace: workspace_path,
                started_at: Utc::now(),
                turn_count: 0,
                session_id: None,
                last_event: None,
                last_message: None,
                last_event_at: None,
                last_usage_totals: TokenUsage::zero(),
                current_retry_attempt: attempt,
                last_error: None,
                recent_events: VecDeque::new(),
                cancel,
            },
        );
        info!(issue_id = %issue_id, issue_identifier = %issue_identifier, "dispatched issue");
    }

    async fn handle_worker_message(&self, state: &mut State, message: WorkerMessage) {
        match message {
            WorkerMessage::Event {
                issue_id,
                event,
                rate_limits,
            } => {
                if let Some(entry) = state.running.get_mut(&issue_id) {
                    entry.last_event = Some(event.event.clone());
                    entry.last_message = event.message.clone();
                    entry.last_event_at = Some(event.timestamp);
                    if let Some(session_id) = &event.session_id {
                        entry.session_id = Some(session_id.clone());
                    }
                    if let Some(usage) = &event.usage {
                        let delta_input = usage
                            .input_tokens
                            .saturating_sub(entry.last_usage_totals.input_tokens);
                        let delta_output = usage
                            .output_tokens
                            .saturating_sub(entry.last_usage_totals.output_tokens);
                        let delta_total = usage
                            .total_tokens
                            .saturating_sub(entry.last_usage_totals.total_tokens);
                        state.codex_totals.input_tokens += delta_input;
                        state.codex_totals.output_tokens += delta_output;
                        state.codex_totals.total_tokens += delta_total;
                        entry.last_usage_totals = usage.clone();
                    }
                    if event.event == "turn_completed" {
                        entry.turn_count += 1;
                    }
                    if entry.recent_events.len() >= 20 {
                        entry.recent_events.pop_front();
                    }
                    entry.recent_events.push_back(event);
                    if let Some(rate_limits) = rate_limits {
                        state.rate_limits = Some(rate_limits);
                    }
                }
            }
            WorkerMessage::Finished { issue_id, result } => {
                let Some(entry) = state.running.remove(&issue_id) else {
                    return;
                };
                self.add_runtime_seconds(state, &entry);
                match result {
                    Ok(()) => {
                        self.schedule_retry(
                            &self.workflow.current().config,
                            state,
                            issue_id.clone(),
                            entry.issue.identifier.clone(),
                            1,
                            None,
                        );
                    }
                    Err(error) => {
                        let attempt = entry.current_retry_attempt.unwrap_or(0) + 1;
                        self.schedule_retry(
                            &self.workflow.current().config,
                            state,
                            issue_id.clone(),
                            entry.issue.identifier.clone(),
                            attempt,
                            Some(error.to_string()),
                        );
                    }
                }
            }
        }
    }

    fn schedule_retry(
        &self,
        config: &EffectiveConfig,
        state: &mut State,
        issue_id: String,
        identifier: String,
        attempt: u32,
        error: Option<String>,
    ) {
        let delay_ms = if error.is_none() {
            1_000
        } else {
            let exp = 10_000_u64.saturating_mul(2_u64.saturating_pow(attempt.saturating_sub(1)));
            exp.min(config.agent.max_retry_backoff_ms)
        };
        state.retry_attempts.insert(
            issue_id.clone(),
            RetryEntry {
                issue_id,
                identifier,
                attempt,
                due_at: Utc::now() + ChronoDuration::milliseconds(delay_ms as i64),
                error,
            },
        );
    }

    fn should_dispatch(&self, config: &EffectiveConfig, state: &State, issue: &Issue) -> bool {
        if issue.id.is_empty()
            || issue.identifier.is_empty()
            || issue.title.is_empty()
            || issue.state.is_empty()
        {
            return false;
        }
        if !config.is_active_state(&issue.state) || config.is_terminal_state(&issue.state) {
            return false;
        }
        if state.running.contains_key(&issue.id) || state.claimed.contains(&issue.id) {
            return false;
        }
        if issue.state.eq_ignore_ascii_case("Todo")
            && issue
                .blocked_by
                .iter()
                .any(|blocker| !config.is_terminal_state(&blocker.state))
        {
            return false;
        }
        let global_available = self.available_slots(config, state);
        if global_available == 0 {
            return false;
        }
        let running_for_state = state
            .running
            .values()
            .filter(|entry| entry.issue.state.eq_ignore_ascii_case(&issue.state))
            .count();
        running_for_state < config.max_concurrent_agents_for_state(&issue.state)
    }

    fn available_slots(&self, config: &EffectiveConfig, state: &State) -> usize {
        config
            .agent
            .max_concurrent_agents
            .saturating_sub(state.running.len())
    }

    fn add_runtime_seconds(&self, state: &mut State, entry: &RunningEntry) {
        let seconds = (Utc::now() - entry.started_at).num_milliseconds() as f64 / 1000.0;
        state.ended_runtime_seconds += seconds.max(0.0);
        state.codex_totals.seconds_running = state.ended_runtime_seconds;
    }

    async fn publish_snapshot(&self, state: &State) {
        let running: Vec<RunningSessionSnapshot> = state
            .running
            .values()
            .map(|entry| RunningSessionSnapshot {
                issue_id: entry.issue.id.clone(),
                issue_identifier: entry.issue.identifier.clone(),
                state: entry.issue.state.clone(),
                session_id: entry.session_id.clone(),
                turn_count: entry.turn_count,
                last_event: entry.last_event.clone(),
                last_message: entry.last_message.clone(),
                started_at: entry.started_at,
                last_event_at: entry.last_event_at,
                tokens: entry.last_usage_totals.clone(),
                workspace: entry.workspace.clone(),
                current_retry_attempt: entry.current_retry_attempt,
                recent_events: entry.recent_events.clone(),
                last_error: entry.last_error.clone(),
            })
            .collect();
        let retrying: Vec<RetryEntry> = state.retry_attempts.values().cloned().collect();
        let active_seconds: f64 = state
            .running
            .values()
            .map(|entry| (Utc::now() - entry.started_at).num_milliseconds() as f64 / 1000.0)
            .sum();
        let snapshot = RuntimeSnapshot {
            generated_at: Utc::now(),
            counts: SnapshotCounts {
                running: running.len(),
                retrying: retrying.len(),
            },
            running,
            retrying,
            codex_totals: CodexTotals {
                seconds_running: state.ended_runtime_seconds + active_seconds,
                ..state.codex_totals.clone()
            },
            rate_limits: state.rate_limits.clone(),
            workflow_error: self.workflow.last_reload_error(),
        };
        *self.snapshot.write().await = snapshot;
    }

    pub async fn issue_snapshot(&self, issue_identifier: &str) -> Option<IssueDebugSnapshot> {
        let snapshot = self.snapshot.read().await;
        if let Some(running) = snapshot
            .running
            .iter()
            .find(|row| row.issue_identifier == issue_identifier)
        {
            let logs = issue_logs(self.logs_root.as_ref(), issue_identifier);
            let attempts = BTreeMap::from([
                ("restart_count".to_string(), 0),
                (
                    "current_retry_attempt".to_string(),
                    running.current_retry_attempt.unwrap_or(0),
                ),
            ]);
            return Some(IssueDebugSnapshot {
                issue_identifier: running.issue_identifier.clone(),
                issue_id: running.issue_id.clone(),
                status: "running".to_string(),
                workspace: BTreeMap::from([(
                    "path".to_string(),
                    running.workspace.to_string_lossy().to_string(),
                )]),
                attempts,
                running: Some(running.clone()),
                retry: snapshot
                    .retrying
                    .iter()
                    .find(|entry| entry.identifier == issue_identifier)
                    .cloned(),
                logs,
                recent_events: running.recent_events.iter().cloned().collect(),
                last_error: running.last_error.clone(),
                tracked: BTreeMap::new(),
            });
        }
        snapshot
            .retrying
            .iter()
            .find(|entry| entry.identifier == issue_identifier)
            .map(|retry| IssueDebugSnapshot {
                issue_identifier: retry.identifier.clone(),
                issue_id: retry.issue_id.clone(),
                status: "retrying".to_string(),
                workspace: BTreeMap::from([(
                    "path".to_string(),
                    self.workflow
                        .current()
                        .config
                        .workspace
                        .root
                        .join(sanitize_issue_identifier(issue_identifier))
                        .to_string_lossy()
                        .to_string(),
                )]),
                attempts: BTreeMap::from([
                    ("restart_count".to_string(), 0),
                    ("current_retry_attempt".to_string(), retry.attempt),
                ]),
                running: None,
                retry: Some(retry.clone()),
                logs: issue_logs(self.logs_root.as_ref(), issue_identifier),
                recent_events: Vec::new(),
                last_error: retry.error.clone(),
                tracked: BTreeMap::new(),
            })
    }
}

async fn run_agent_attempt(
    workflow: WorkflowStore,
    logs_root: Option<PathBuf>,
    mut issue: Issue,
    attempt: Option<u32>,
    cancel: CancellationToken,
    worker_tx: mpsc::Sender<WorkerMessage>,
) -> Result<()> {
    let bundle = workflow.current();
    let config = bundle.config.clone();
    let workspace_manager = WorkspaceManager::new(config.clone());
    let workspace = workspace_manager.prepare(&issue.identifier).await?;
    workspace_manager.before_run(&workspace.path).await?;
    let app_server = AppServerClient::new(config.clone(), logs_root);
    let mut session = match app_server.start_session(&workspace.path).await {
        Ok(session) => session,
        Err(error) => {
            workspace_manager.after_run(&workspace.path).await;
            return Err(error);
        }
    };
    let linear = LinearClient::new(config.clone())?;

    let max_turns = config.agent.max_turns.max(1);
    let mut turn_number = 1;
    loop {
        let prompt = if turn_number == 1 {
            render_prompt(&bundle.prompt_template, &issue, attempt)?
        } else {
            continuation_prompt(&issue, turn_number, max_turns)
        };
        let issue_id = issue.id.clone();
        let tx = worker_tx.clone();
        let sender = SessionEventSender::new(move |event| {
            let _ = tx.blocking_send(WorkerMessage::Event {
                issue_id: issue_id.clone(),
                rate_limits: event
                    .payload
                    .as_ref()
                    .and_then(|payload| payload.pointer("/params/rate_limits").cloned()),
                event,
            });
        });
        let _turn = session
            .run_turn(&issue, &prompt, &cancel, sender, None)
            .await?;
        let refreshed = linear
            .fetch_issue_states_by_ids(&[issue.id.clone()])
            .await?;
        if let Some(updated_issue) = refreshed.into_iter().next() {
            issue = updated_issue;
        }
        if !config.is_active_state(&issue.state) || turn_number >= max_turns {
            break;
        }
        turn_number += 1;
    }
    session.stop().await;
    workspace_manager.after_run(&workspace.path).await;
    Ok(())
}

async fn startup_terminal_cleanup(config: &EffectiveConfig) {
    let client = match LinearClient::new(config.clone()) {
        Ok(client) => client,
        Err(error) => {
            warn!("startup cleanup skipped: {error}");
            return;
        }
    };
    let terminal = match client
        .fetch_issues_by_states(&config.tracker.terminal_states)
        .await
    {
        Ok(issues) => issues,
        Err(error) => {
            warn!("startup cleanup query failed: {error}");
            return;
        }
    };
    let manager = WorkspaceManager::new(config.clone());
    for issue in terminal {
        let workspace = config
            .workspace
            .root
            .join(sanitize_issue_identifier(&issue.identifier));
        if let Err(error) = manager.remove(&workspace).await {
            warn!("startup workspace cleanup failed: {error}");
        }
    }
}

fn issue_logs(
    logs_root: Option<&PathBuf>,
    issue_identifier: &str,
) -> BTreeMap<String, Vec<BTreeMap<String, String>>> {
    let mut logs = BTreeMap::new();
    if let Some(root) = logs_root {
        let latest = root.join("codex").join(issue_identifier).join("latest.log");
        if latest.exists() {
            logs.insert(
                "codex_session_logs".to_string(),
                vec![BTreeMap::from([
                    ("label".to_string(), "latest".to_string()),
                    ("path".to_string(), latest.to_string_lossy().to_string()),
                    ("url".to_string(), "null".to_string()),
                ])],
            );
        }
    }
    logs
}

#[cfg(test)]
mod tests {
    use std::fs;

    use chrono::TimeZone;
    use serde_json::json;
    use tempfile::tempdir;

    use super::*;
    use crate::domain::BlockedBy;

    fn base_config() -> EffectiveConfig {
        crate::config::EffectiveConfig::from_front_matter(&json!({
            "tracker": {
                "kind": "linear",
                "api_key": "secret",
                "project_slug": "proj"
            }
        }))
        .expect("config")
    }

    fn issue(state: &str, priority: Option<i64>, blocked: bool) -> Issue {
        Issue {
            id: format!("{state}-id"),
            identifier: format!("{state}-1"),
            title: "Task".to_string(),
            description: None,
            state: state.to_string(),
            labels: vec![],
            blocked_by: if blocked {
                vec![BlockedBy {
                    id: "x".to_string(),
                    identifier: "X-1".to_string(),
                    state: "In Progress".to_string(),
                }]
            } else {
                vec![]
            },
            priority,
            branch_name: None,
            url: None,
            assignee_id: None,
            created_at: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            updated_at: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
        }
    }

    #[test]
    fn blocks_todo_issue_with_non_terminal_blocker() {
        let dir = tempdir().expect("tmpdir");
        let workflow_path = dir.path().join("WORKFLOW.md");
        fs::write(
            &workflow_path,
            r#"---
tracker:
  kind: linear
  api_key: secret
  project_slug: proj
---
Hello {{ issue.identifier }}
"#,
        )
        .expect("workflow");
        let orchestrator =
            Orchestrator::new(WorkflowStore::load(workflow_path).expect("store"), None);
        let state = State::default();
        let config = base_config();
        assert!(!orchestrator.should_dispatch(&config, &state, &issue("Todo", Some(1), true)));
    }
}
