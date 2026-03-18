use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use chrono::Utc;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, mpsc};
use tokio::time::{Duration, Instant, timeout};
use tokio_util::sync::CancellationToken;
use tracing::debug;

use crate::config::EffectiveConfig;
use crate::domain::{Issue, RuntimeEvent, TokenUsage};
use crate::error::{Result, SymphonyError};

const INITIALIZE_ID: i64 = 1;
const THREAD_START_ID: i64 = 2;
const TURN_START_ID: i64 = 3;

#[derive(Debug)]
enum StreamMessage {
    StdoutLine(String),
    StderrLine(String),
}

#[derive(Clone)]
pub struct SessionEventSender(Arc<dyn Fn(RuntimeEvent) + Send + Sync>);

impl SessionEventSender {
    pub fn new<F>(callback: F) -> Self
    where
        F: Fn(RuntimeEvent) + Send + Sync + 'static,
    {
        Self(Arc::new(callback))
    }

    pub fn emit(&self, event: RuntimeEvent) {
        (self.0)(event);
    }
}

pub struct AppServerClient {
    config: EffectiveConfig,
    logs_root: Option<PathBuf>,
}

pub struct AppServerSession {
    config: EffectiveConfig,
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    stream_rx: mpsc::Receiver<StreamMessage>,
    workspace: PathBuf,
    thread_id: String,
    logs_root: Option<PathBuf>,
}

pub struct TurnOutcome {
    pub session_id: String,
    pub turn_id: String,
    pub usage: Option<TokenUsage>,
    pub rate_limits: Option<Value>,
    pub events: VecDeque<RuntimeEvent>,
}

impl AppServerClient {
    pub fn new(config: EffectiveConfig, logs_root: Option<PathBuf>) -> Self {
        Self { config, logs_root }
    }

    pub async fn start_session(&self, workspace: &Path) -> Result<AppServerSession> {
        let mut child = Command::new("bash");
        child
            .arg("-lc")
            .arg(&self.config.codex.command)
            .current_dir(workspace)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = child.spawn().map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                SymphonyError::CodexNotFound
            } else {
                SymphonyError::Io(error.to_string())
            }
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| SymphonyError::Io("missing codex stdin".to_string()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| SymphonyError::Io("missing codex stdout".to_string()))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| SymphonyError::Io("missing codex stderr".to_string()))?;
        let (tx, rx) = mpsc::channel(256);
        spawn_stdout_reader(stdout, tx.clone());
        spawn_stderr_reader(stderr, tx.clone());
        let mut session = AppServerSession {
            config: self.config.clone(),
            child,
            stdin: Arc::new(Mutex::new(stdin)),
            stream_rx: rx,
            workspace: workspace.to_path_buf(),
            thread_id: String::new(),
            logs_root: self.logs_root.clone(),
        };
        session
            .send_json(&json!({
                "id": INITIALIZE_ID,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "symphony-rust",
                        "version": env!("CARGO_PKG_VERSION")
                    },
                    "capabilities": {
                        "experimentalApi": true
                    }
                }
            }))
            .await?;
        session.await_response(INITIALIZE_ID).await?;
        session
            .send_json(&json!({
                "method": "initialized",
                "params": {}
            }))
            .await?;
        session
            .send_json(&json!({
                "id": THREAD_START_ID,
                "method": "thread/start",
                "params": {
                    "approvalPolicy": self.config.codex.approval_policy,
                    "sandbox": self.config.codex.thread_sandbox,
                    "cwd": workspace.to_string_lossy().to_string(),
                    "dynamicTools": [linear_graphql_tool_spec()]
                }
            }))
            .await?;
        let response = session.await_response(THREAD_START_ID).await?;
        let thread_id = response
            .get("thread")
            .and_then(|thread| thread.get("id"))
            .and_then(Value::as_str)
            .ok_or_else(|| SymphonyError::ResponseError("missing thread id".to_string()))?;
        session.thread_id = thread_id.to_string();
        Ok(session)
    }
}

impl AppServerSession {
    pub async fn run_turn(
        &mut self,
        issue: &Issue,
        prompt: &str,
        cancel: &CancellationToken,
        on_event: SessionEventSender,
        linear_graphql: Option<Arc<dyn Fn(Value) -> Value + Send + Sync>>,
    ) -> Result<TurnOutcome> {
        let sandbox_policy = self.config.default_turn_sandbox_policy(&self.workspace);
        self.send_json(&json!({
            "id": TURN_START_ID,
            "method": "turn/start",
            "params": {
                "threadId": self.thread_id,
                "input": [{"type": "text", "text": prompt}],
                "cwd": self.workspace.to_string_lossy().to_string(),
                "title": format!("{}: {}", issue.identifier, issue.title),
                "approvalPolicy": self.config.codex.approval_policy,
                "sandboxPolicy": sandbox_policy
            }
        }))
        .await?;
        let response = self.await_response(TURN_START_ID).await?;
        let turn_id = response
            .get("turn")
            .and_then(|turn| turn.get("id"))
            .and_then(Value::as_str)
            .ok_or_else(|| SymphonyError::ResponseError("missing turn id".to_string()))?
            .to_string();
        let session_id = format!("{}-{}", self.thread_id, turn_id);
        on_event.emit(RuntimeEvent {
            event: "session_started".to_string(),
            timestamp: Utc::now(),
            session_id: Some(session_id.clone()),
            codex_app_server_pid: self.child.id().map(|pid| pid.to_string()),
            message: None,
            usage: None,
            payload: None,
        });
        let deadline = Instant::now() + Duration::from_millis(self.config.codex.turn_timeout_ms);
        let mut usage = None;
        let mut rate_limits = None;
        let mut events = VecDeque::new();
        loop {
            let timeout_duration = deadline.saturating_duration_since(Instant::now());
            let next_message = tokio::select! {
                _ = cancel.cancelled() => {
                    self.stop().await;
                    return Err(SymphonyError::TurnCancelled("canceled_by_reconciliation".to_string()));
                }
                result = timeout(timeout_duration, self.stream_rx.recv()) => result,
            };
            let Some(message) = next_message.map_err(|_| SymphonyError::TurnTimeout)? else {
                let status = self
                    .child
                    .wait()
                    .await
                    .map_err(|error| SymphonyError::Io(error.to_string()))?;
                return Err(SymphonyError::PortExit(status.code().unwrap_or(-1)));
            };
            match message {
                StreamMessage::StdoutLine(line) => {
                    if let Some(path) = self.session_log_path(issue) {
                        append_log_line(path, &line).await;
                    }
                    let payload = match serde_json::from_str::<Value>(&line) {
                        Ok(payload) => payload,
                        Err(_) => {
                            if line.trim_start().starts_with('{') {
                                let event = RuntimeEvent {
                                    event: "malformed".to_string(),
                                    timestamp: Utc::now(),
                                    session_id: Some(session_id.clone()),
                                    codex_app_server_pid: self
                                        .child
                                        .id()
                                        .map(|pid| pid.to_string()),
                                    message: Some("malformed protocol line".to_string()),
                                    usage: None,
                                    payload: Some(Value::String(line.clone())),
                                };
                                on_event.emit(event.clone());
                                push_recent(&mut events, event);
                            }
                            continue;
                        }
                    };
                    if let Some((found_usage, found_rate_limits)) =
                        extract_usage_and_limits(&payload)
                    {
                        usage = found_usage.or(usage);
                        rate_limits = found_rate_limits.or(rate_limits);
                    }
                    if let Some(method) = payload.get("method").and_then(Value::as_str) {
                        match method {
                            "turn/completed" => {
                                let event = RuntimeEvent {
                                    event: "turn_completed".to_string(),
                                    timestamp: Utc::now(),
                                    session_id: Some(session_id.clone()),
                                    codex_app_server_pid: self
                                        .child
                                        .id()
                                        .map(|pid| pid.to_string()),
                                    message: None,
                                    usage: usage.clone(),
                                    payload: Some(payload),
                                };
                                on_event.emit(event.clone());
                                push_recent(&mut events, event);
                                return Ok(TurnOutcome {
                                    session_id,
                                    turn_id,
                                    usage,
                                    rate_limits,
                                    events,
                                });
                            }
                            "turn/failed" => {
                                return Err(SymphonyError::TurnFailed(payload.to_string()));
                            }
                            "turn/cancelled" => {
                                return Err(SymphonyError::TurnCancelled(payload.to_string()));
                            }
                            "item/commandExecution/requestApproval"
                            | "item/fileChange/requestApproval"
                            | "execCommandApproval"
                            | "applyPatchApproval" => {
                                if let Some(id) = payload.get("id").and_then(Value::as_str) {
                                    self.send_json(&json!({
                                        "id": id,
                                        "result": { "decision": "acceptForSession" }
                                    }))
                                    .await?;
                                    let event = RuntimeEvent {
                                        event: "approval_auto_approved".to_string(),
                                        timestamp: Utc::now(),
                                        session_id: Some(session_id.clone()),
                                        codex_app_server_pid: self
                                            .child
                                            .id()
                                            .map(|pid| pid.to_string()),
                                        message: Some(method.to_string()),
                                        usage: None,
                                        payload: Some(payload),
                                    };
                                    on_event.emit(event.clone());
                                    push_recent(&mut events, event);
                                }
                            }
                            "item/tool/call" => {
                                let call_id =
                                    payload.get("id").and_then(Value::as_str).ok_or_else(|| {
                                        SymphonyError::ResponseError(
                                            "tool call missing id".to_string(),
                                        )
                                    })?;
                                let params = payload.get("params").cloned().unwrap_or(Value::Null);
                                let tool_name = params
                                    .get("tool")
                                    .and_then(Value::as_str)
                                    .or_else(|| params.get("name").and_then(Value::as_str));
                                let result = match (tool_name, &linear_graphql) {
                                    (Some("linear_graphql"), Some(handler)) => handler(
                                        params.get("arguments").cloned().unwrap_or(Value::Null),
                                    ),
                                    _ => json!({
                                        "success": false,
                                        "output": "{\"error\":\"unsupported_tool_call\"}",
                                        "contentItems": [{"type":"inputText","text":"{\"error\":\"unsupported_tool_call\"}"}]
                                    }),
                                };
                                self.send_json(&json!({
                                    "id": call_id,
                                    "result": result
                                }))
                                .await?;
                                let event = RuntimeEvent {
                                    event: if tool_name == Some("linear_graphql") {
                                        "tool_call_completed".to_string()
                                    } else {
                                        "unsupported_tool_call".to_string()
                                    },
                                    timestamp: Utc::now(),
                                    session_id: Some(session_id.clone()),
                                    codex_app_server_pid: self
                                        .child
                                        .id()
                                        .map(|pid| pid.to_string()),
                                    message: tool_name.map(|value| value.to_string()),
                                    usage: None,
                                    payload: Some(payload),
                                };
                                on_event.emit(event.clone());
                                push_recent(&mut events, event);
                            }
                            "item/tool/requestUserInput"
                            | "turn/input_required"
                            | "turn/needs_input"
                            | "turn/request_input"
                            | "turn/approval_required" => {
                                self.stop().await;
                                return Err(SymphonyError::TurnInputRequired);
                            }
                            _ => {
                                let event = RuntimeEvent {
                                    event: "notification".to_string(),
                                    timestamp: Utc::now(),
                                    session_id: Some(session_id.clone()),
                                    codex_app_server_pid: self
                                        .child
                                        .id()
                                        .map(|pid| pid.to_string()),
                                    message: payload
                                        .get("params")
                                        .and_then(|params| params.get("message"))
                                        .and_then(Value::as_str)
                                        .map(|text| text.to_string())
                                        .or_else(|| Some(method.to_string())),
                                    usage: usage.clone(),
                                    payload: Some(payload),
                                };
                                on_event.emit(event.clone());
                                push_recent(&mut events, event);
                            }
                        }
                    }
                }
                StreamMessage::StderrLine(line) => {
                    debug!("codex stderr: {}", line.trim());
                    if let Some(path) = self.session_log_path(issue) {
                        append_log_line(path, &format!("stderr: {line}")).await;
                    }
                }
            }
        }
    }

    pub async fn stop(&mut self) {
        let _ = self.child.kill().await;
    }

    async fn send_json(&self, payload: &Value) -> Result<()> {
        let mut stdin = self.stdin.lock().await;
        let line = serde_json::to_vec(payload)
            .map_err(|error| SymphonyError::ResponseError(error.to_string()))?;
        stdin.write_all(&line).await?;
        stdin.write_all(b"\n").await?;
        stdin.flush().await?;
        Ok(())
    }

    async fn await_response(&mut self, request_id: i64) -> Result<Value> {
        loop {
            let Some(message) = timeout(
                Duration::from_millis(self.config.codex.read_timeout_ms),
                self.stream_rx.recv(),
            )
            .await
            .map_err(|_| SymphonyError::ResponseTimeout)?
            else {
                let status = self
                    .child
                    .wait()
                    .await
                    .map_err(|error| SymphonyError::Io(error.to_string()))?;
                return Err(SymphonyError::PortExit(status.code().unwrap_or(-1)));
            };
            match message {
                StreamMessage::StdoutLine(line) => {
                    let payload = match serde_json::from_str::<Value>(&line) {
                        Ok(payload) => payload,
                        Err(_) => continue,
                    };
                    if payload.get("id").and_then(Value::as_i64) == Some(request_id) {
                        if let Some(error) = payload.get("error") {
                            return Err(SymphonyError::ResponseError(error.to_string()));
                        }
                        return payload.get("result").cloned().ok_or_else(|| {
                            SymphonyError::ResponseError("missing response result".to_string())
                        });
                    }
                }
                StreamMessage::StderrLine(line) => debug!("codex stderr: {}", line.trim()),
            }
        }
    }

    fn session_log_path(&self, issue: &Issue) -> Option<PathBuf> {
        let root = self.logs_root.as_ref()?;
        Some(
            root.join("codex")
                .join(&issue.identifier)
                .join("latest.log"),
        )
    }
}

fn spawn_stdout_reader(stdout: tokio::process::ChildStdout, tx: mpsc::Sender<StreamMessage>) {
    tokio::spawn(async move {
        let mut reader = BufReader::new(stdout).lines();
        loop {
            match reader.next_line().await {
                Ok(Some(line)) => {
                    if tx.send(StreamMessage::StdoutLine(line)).await.is_err() {
                        return;
                    }
                }
                Ok(None) => return,
                Err(_) => return,
            }
        }
    });
}

fn spawn_stderr_reader(stderr: tokio::process::ChildStderr, tx: mpsc::Sender<StreamMessage>) {
    tokio::spawn(async move {
        let mut reader = BufReader::new(stderr).lines();
        loop {
            match reader.next_line().await {
                Ok(Some(line)) => {
                    if tx.send(StreamMessage::StderrLine(line)).await.is_err() {
                        return;
                    }
                }
                Ok(None) => return,
                Err(_) => return,
            }
        }
    });
}

async fn append_log_line(path: PathBuf, line: &str) {
    if let Some(parent) = path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let mut options = tokio::fs::OpenOptions::new();
    options.create(true).append(true);
    if let Ok(mut file) = options.open(path).await {
        let _ = file.write_all(line.as_bytes()).await;
        let _ = file.write_all(b"\n").await;
    }
}

fn linear_graphql_tool_spec() -> Value {
    json!({
        "name": "linear_graphql",
        "description": "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "variables": {"type": ["object", "null"], "additionalProperties": true}
            }
        }
    })
}

fn extract_usage_and_limits(payload: &Value) -> Option<(Option<TokenUsage>, Option<Value>)> {
    let usage_payload = payload
        .pointer("/params/total_token_usage")
        .or_else(|| payload.pointer("/params/usage"))
        .or_else(|| payload.get("usage"))
        .or_else(|| payload.pointer("/params/tokenUsage"))
        .or_else(|| payload.pointer("/params/totalTokenUsage"));
    let usage = usage_payload.and_then(parse_usage);
    let rate_limits = payload
        .pointer("/params/rate_limits")
        .or_else(|| payload.pointer("/params/rateLimits"))
        .cloned();
    if usage.is_none() && rate_limits.is_none() {
        None
    } else {
        Some((usage, rate_limits))
    }
}

fn parse_usage(value: &Value) -> Option<TokenUsage> {
    let input_tokens = value
        .get("input_tokens")
        .or_else(|| value.get("inputTokens"))
        .or_else(|| value.get("prompt_tokens"))
        .and_then(Value::as_u64)?;
    let output_tokens = value
        .get("output_tokens")
        .or_else(|| value.get("outputTokens"))
        .or_else(|| value.get("completion_tokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let total_tokens = value
        .get("total_tokens")
        .or_else(|| value.get("totalTokens"))
        .and_then(Value::as_u64)
        .unwrap_or(input_tokens + output_tokens);
    Some(TokenUsage {
        input_tokens,
        output_tokens,
        total_tokens,
    })
}

fn push_recent(events: &mut VecDeque<RuntimeEvent>, event: RuntimeEvent) {
    if events.len() >= 20 {
        events.pop_front();
    }
    events.push_back(event);
}
