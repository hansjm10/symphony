use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum SymphonyError {
    #[error("missing_workflow_file: {path}")]
    MissingWorkflowFile { path: PathBuf },
    #[error("workflow_parse_error: {0}")]
    WorkflowParse(String),
    #[error("workflow_front_matter_not_a_map")]
    WorkflowFrontMatterNotAMap,
    #[error("template_parse_error: {0}")]
    TemplateParse(String),
    #[error("template_render_error: {0}")]
    TemplateRender(String),
    #[error("invalid_workflow_config: {0}")]
    InvalidConfig(String),
    #[error("unsupported_tracker_kind: {0}")]
    UnsupportedTrackerKind(String),
    #[error("missing_tracker_api_key")]
    MissingTrackerApiKey,
    #[error("missing_tracker_project_slug")]
    MissingTrackerProjectSlug,
    #[error("linear_api_request: {0}")]
    LinearApiRequest(String),
    #[error("linear_api_status: {0}")]
    LinearApiStatus(u16),
    #[error("linear_graphql_errors: {0}")]
    LinearGraphqlErrors(String),
    #[error("linear_unknown_payload: {0}")]
    LinearUnknownPayload(String),
    #[error("linear_missing_end_cursor")]
    LinearMissingEndCursor,
    #[error("workspace_error: {0}")]
    Workspace(String),
    #[error("hook_failed: {hook}: {reason}")]
    HookFailed { hook: &'static str, reason: String },
    #[error("hook_timed_out: {hook}")]
    HookTimedOut { hook: &'static str },
    #[error("invalid_workspace_cwd: {0}")]
    InvalidWorkspaceCwd(String),
    #[error("response_timeout")]
    ResponseTimeout,
    #[error("turn_timeout")]
    TurnTimeout,
    #[error("port_exit: {0}")]
    PortExit(i32),
    #[error("response_error: {0}")]
    ResponseError(String),
    #[error("turn_failed: {0}")]
    TurnFailed(String),
    #[error("turn_cancelled: {0}")]
    TurnCancelled(String),
    #[error("turn_input_required")]
    TurnInputRequired,
    #[error("codex_not_found")]
    CodexNotFound,
    #[error("io: {0}")]
    Io(String),
}

impl From<std::io::Error> for SymphonyError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

pub type Result<T> = std::result::Result<T, SymphonyError>;
