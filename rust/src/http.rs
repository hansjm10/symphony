use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::Utc;
use serde_json::json;
use tokio::sync::{RwLock, mpsc};

use crate::domain::RuntimeSnapshot;
use crate::orchestrator::{ControlMessage, Orchestrator};

#[derive(Clone)]
struct HttpState {
    snapshot: Arc<RwLock<RuntimeSnapshot>>,
    orchestrator: Orchestrator,
    control_tx: mpsc::Sender<ControlMessage>,
}

pub async fn serve(
    bind_host: String,
    port: u16,
    snapshot: Arc<RwLock<RuntimeSnapshot>>,
    orchestrator: Orchestrator,
    control_tx: mpsc::Sender<ControlMessage>,
) -> crate::Result<()> {
    let app = Router::new()
        .route("/", get(dashboard))
        .route("/api/v1/state", get(state))
        .route("/api/v1/:issue_identifier", get(issue))
        .route("/api/v1/refresh", post(refresh))
        .with_state(HttpState {
            snapshot,
            orchestrator,
            control_tx,
        });
    let listener = tokio::net::TcpListener::bind((bind_host.as_str(), port))
        .await
        .map_err(|error| crate::SymphonyError::Io(error.to_string()))?;
    axum::serve(listener, app)
        .await
        .map_err(|error| crate::SymphonyError::Io(error.to_string()))
}

async fn dashboard(State(state): State<HttpState>) -> Html<String> {
    let snapshot = state.snapshot.read().await.clone();
    Html(format!(
        "<html><body><h1>Symphony Rust</h1><pre>{}</pre></body></html>",
        serde_json::to_string_pretty(&snapshot).unwrap_or_else(|_| "{}".to_string())
    ))
}

async fn state(State(state): State<HttpState>) -> Json<RuntimeSnapshot> {
    Json(state.snapshot.read().await.clone())
}

async fn issue(
    Path(issue_identifier): Path<String>,
    State(state): State<HttpState>,
) -> impl IntoResponse {
    match state.orchestrator.issue_snapshot(&issue_identifier).await {
        Some(snapshot) => (StatusCode::OK, Json(json!(snapshot))).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(json!({
                "error": {
                    "code": "issue_not_found",
                    "message": format!("unknown issue: {issue_identifier}")
                }
            })),
        )
            .into_response(),
    }
}

async fn refresh(State(state): State<HttpState>) -> impl IntoResponse {
    let _ = state.control_tx.send(ControlMessage::Refresh).await;
    (
        StatusCode::ACCEPTED,
        Json(json!({
            "queued": true,
            "coalesced": false,
            "requested_at": Utc::now(),
            "operations": ["poll", "reconcile"]
        })),
    )
}
