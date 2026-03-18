use std::path::PathBuf;

use clap::Parser;
use tokio::sync::mpsc;
use tracing_subscriber::EnvFilter;

use symphony_rust::http;
use symphony_rust::orchestrator::{ControlMessage, Orchestrator};
use symphony_rust::workflow::WorkflowStore;
use symphony_rust::{Result, SymphonyError};

#[derive(Debug, Parser)]
struct Cli {
    workflow: Option<PathBuf>,
    #[arg(long)]
    logs_root: Option<PathBuf>,
    #[arg(long)]
    port: Option<u16>,
    #[arg(long)]
    host: Option<String>,
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .compact()
        .init();

    let cli = Cli::parse();
    let workflow_path = cli
        .workflow
        .unwrap_or_else(|| std::env::current_dir().expect("cwd").join("WORKFLOW.md"));
    if !workflow_path.exists() {
        return Err(SymphonyError::MissingWorkflowFile {
            path: workflow_path,
        });
    }
    let workflow = WorkflowStore::load(workflow_path)?;
    let orchestrator = Orchestrator::new(workflow.clone(), cli.logs_root.clone());
    let snapshot = orchestrator.snapshot_handle();
    let (control_tx, control_rx) = mpsc::channel::<ControlMessage>(32);
    let watcher_control = control_tx.clone();
    let _watcher = workflow
        .start_watcher(move || {
            let _ = watcher_control.blocking_send(ControlMessage::Refresh);
        })
        .map_err(|error| SymphonyError::Io(error.to_string()))?;

    let runtime = {
        let orchestrator = orchestrator.clone();
        tokio::spawn(async move { orchestrator.run(control_rx).await })
    };

    if let Some(port) = cli.port.or(workflow.current().config.server.port) {
        let host = cli
            .host
            .or_else(|| Some(workflow.current().config.server.host.clone()))
            .unwrap_or_else(|| "127.0.0.1".to_string());
        let http_orchestrator = orchestrator.clone();
        let http_control = control_tx.clone();
        tokio::spawn(async move {
            if let Err(error) =
                http::serve(host, port, snapshot, http_orchestrator, http_control).await
            {
                tracing::error!("http server failed: {error}");
            }
        });
    }

    tokio::select! {
        result = runtime => {
            result.map_err(|error| SymphonyError::Io(error.to_string()))??;
        }
        signal = tokio::signal::ctrl_c() => {
            signal.map_err(|error| SymphonyError::Io(error.to_string()))?;
        }
    }
    Ok(())
}
