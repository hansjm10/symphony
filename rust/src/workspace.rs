use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::process::Command;
use tokio::time::{Duration, timeout};
use tracing::{info, warn};

use crate::config::EffectiveConfig;
use crate::domain::WorkspaceInfo;
use crate::error::{Result, SymphonyError};

#[derive(Clone)]
pub struct WorkspaceManager {
    config: EffectiveConfig,
}

impl WorkspaceManager {
    pub fn new(config: EffectiveConfig) -> Self {
        Self { config }
    }

    pub async fn prepare(&self, issue_identifier: &str) -> Result<WorkspaceInfo> {
        let root = &self.config.workspace.root;
        tokio::fs::create_dir_all(root).await?;
        let workspace_key = sanitize_issue_identifier(issue_identifier);
        let workspace_path = root.join(workspace_key);
        ensure_within_root(root, &workspace_path)?;
        let created_now = match tokio::fs::metadata(&workspace_path).await {
            Ok(metadata) => {
                if !metadata.is_dir() {
                    return Err(SymphonyError::Workspace(format!(
                        "workspace path exists but is not a directory: {}",
                        workspace_path.display()
                    )));
                }
                false
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                tokio::fs::create_dir_all(&workspace_path).await?;
                true
            }
            Err(error) => return Err(error.into()),
        };
        if created_now {
            self.run_optional_hook(
                "after_create",
                self.config.hooks.after_create.as_deref(),
                &workspace_path,
            )
            .await?;
        }
        Ok(WorkspaceInfo {
            path: workspace_path,
            created_now,
        })
    }

    pub async fn before_run(&self, workspace: &Path) -> Result<()> {
        self.run_optional_hook(
            "before_run",
            self.config.hooks.before_run.as_deref(),
            workspace,
        )
        .await
    }

    pub async fn after_run(&self, workspace: &Path) {
        if let Err(error) = self
            .run_optional_hook(
                "after_run",
                self.config.hooks.after_run.as_deref(),
                workspace,
            )
            .await
        {
            warn!("after_run hook failed: {error}");
        }
    }

    pub async fn remove(&self, workspace: &Path) -> Result<()> {
        ensure_within_root(&self.config.workspace.root, workspace)?;
        if tokio::fs::metadata(workspace).await.is_err() {
            return Ok(());
        }
        if let Err(error) = self
            .run_optional_hook(
                "before_remove",
                self.config.hooks.before_remove.as_deref(),
                workspace,
            )
            .await
        {
            warn!("before_remove hook failed: {error}");
        }
        tokio::fs::remove_dir_all(workspace).await?;
        Ok(())
    }

    async fn run_optional_hook(
        &self,
        hook_name: &'static str,
        script: Option<&str>,
        workspace: &Path,
    ) -> Result<()> {
        ensure_within_root(&self.config.workspace.root, workspace)?;
        let Some(script) = script.filter(|script| !script.trim().is_empty()) else {
            return Ok(());
        };
        info!(hook = hook_name, workspace = %workspace.display(), "running workspace hook");
        let mut child = Command::new("bash");
        child
            .arg("-lc")
            .arg(script)
            .current_dir(workspace)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let future = child.output();
        let output = timeout(Duration::from_millis(self.config.hooks.timeout_ms), future)
            .await
            .map_err(|_| SymphonyError::HookTimedOut { hook: hook_name })??;
        if output.status.success() {
            return Ok(());
        }
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(SymphonyError::HookFailed {
            hook: hook_name,
            reason: if stderr.is_empty() {
                format!("exit status {}", output.status)
            } else {
                stderr
            },
        })
    }
}

pub fn sanitize_issue_identifier(identifier: &str) -> String {
    identifier
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

pub fn ensure_within_root(root: &Path, workspace: &Path) -> Result<()> {
    let root_abs = absolute_path(root)?;
    let workspace_abs = absolute_path(workspace)?;
    if workspace_abs == root_abs {
        return Err(SymphonyError::InvalidWorkspaceCwd(format!(
            "workspace path resolved to workspace root: {}",
            workspace_abs.display()
        )));
    }
    if !workspace_abs.starts_with(&root_abs) {
        return Err(SymphonyError::InvalidWorkspaceCwd(format!(
            "workspace path {} is outside root {}",
            workspace_abs.display(),
            root_abs.display()
        )));
    }
    Ok(())
}

fn absolute_path(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        std::fs::canonicalize(path)
            .map_err(|error| SymphonyError::InvalidWorkspaceCwd(error.to_string()))
    } else if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_workspace_keys() {
        assert_eq!(sanitize_issue_identifier("ABC-1"), "ABC-1");
        assert_eq!(sanitize_issue_identifier("A/B:C"), "A_B_C");
    }
}
