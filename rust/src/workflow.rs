use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::SystemTime;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::Value;
use tracing::{error, warn};

use crate::config::EffectiveConfig;
use crate::error::{Result, SymphonyError};

#[derive(Debug, Clone)]
pub struct WorkflowBundle {
    pub path: PathBuf,
    pub config: EffectiveConfig,
    pub prompt_template: String,
    pub front_matter: Value,
}

#[derive(Debug)]
struct StoreState {
    bundle: WorkflowBundle,
    modified_at: Option<SystemTime>,
    last_reload_error: Option<String>,
}

#[derive(Clone)]
pub struct WorkflowStore {
    path: PathBuf,
    state: Arc<RwLock<StoreState>>,
}

impl WorkflowStore {
    pub fn load(path: PathBuf) -> Result<Self> {
        let bundle = load_bundle(&path)?;
        let modified_at = fs::metadata(&path)
            .ok()
            .and_then(|meta| meta.modified().ok());
        Ok(Self {
            path,
            state: Arc::new(RwLock::new(StoreState {
                bundle,
                modified_at,
                last_reload_error: None,
            })),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn current(&self) -> WorkflowBundle {
        self.state.read().expect("workflow state").bundle.clone()
    }

    pub fn last_reload_error(&self) -> Option<String> {
        self.state
            .read()
            .expect("workflow state")
            .last_reload_error
            .clone()
    }

    pub fn reload(&self) -> Result<()> {
        let bundle = load_bundle(&self.path)?;
        let modified_at = fs::metadata(&self.path)
            .ok()
            .and_then(|meta| meta.modified().ok());
        let mut state = self.state.write().expect("workflow state");
        state.bundle = bundle;
        state.modified_at = modified_at;
        state.last_reload_error = None;
        Ok(())
    }

    pub fn reload_if_changed(&self) {
        let current_modified = fs::metadata(&self.path)
            .ok()
            .and_then(|meta| meta.modified().ok());
        let needs_reload = {
            let state = self.state.read().expect("workflow state");
            current_modified.is_some() && current_modified != state.modified_at
        };
        if needs_reload {
            if let Err(error) = self.reload() {
                self.set_reload_error(error.to_string());
            }
        }
    }

    pub fn set_reload_error(&self, message: String) {
        let mut state = self.state.write().expect("workflow state");
        state.last_reload_error = Some(message);
    }

    pub fn start_watcher<F>(&self, on_reload: F) -> notify::Result<RecommendedWatcher>
    where
        F: Fn() + Send + Sync + 'static,
    {
        let store = self.clone();
        let callback = Arc::new(on_reload);
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| match event {
                Ok(_) => match store.reload() {
                    Ok(_) => callback(),
                    Err(error) => {
                        let message = error.to_string();
                        warn!("workflow reload failed: {message}");
                        store.set_reload_error(message);
                    }
                },
                Err(error) => error!("workflow watcher error: {error}"),
            })?;
        watcher.watch(&self.path, RecursiveMode::NonRecursive)?;
        Ok(watcher)
    }
}

fn load_bundle(path: &Path) -> Result<WorkflowBundle> {
    let content = fs::read_to_string(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            SymphonyError::MissingWorkflowFile {
                path: path.to_path_buf(),
            }
        } else {
            SymphonyError::Io(error.to_string())
        }
    })?;
    let (front_matter, prompt_template) = split_front_matter(&content)?;
    let config = EffectiveConfig::from_front_matter(&front_matter)?;
    crate::prompt::validate_template(&prompt_template)?;
    Ok(WorkflowBundle {
        path: path.to_path_buf(),
        config,
        prompt_template,
        front_matter,
    })
}

fn split_front_matter(content: &str) -> Result<(Value, String)> {
    let lines: Vec<&str> = content.lines().collect();
    if !matches!(lines.first(), Some(first) if *first == "---") {
        return Ok((
            Value::Object(Default::default()),
            content.trim().to_string(),
        ));
    }
    let end_index = lines[1..]
        .iter()
        .position(|line| *line == "---")
        .ok_or_else(|| {
            SymphonyError::WorkflowParse("unterminated YAML front matter".to_string())
        })?
        + 1;
    let yaml = lines[1..end_index].join("\n");
    let prompt = lines[(end_index + 1)..].join("\n").trim().to_string();
    if yaml.trim().is_empty() {
        return Ok((Value::Object(Default::default()), prompt));
    }
    let yaml_value: serde_yaml::Value = serde_yaml::from_str(&yaml)
        .map_err(|error| SymphonyError::WorkflowParse(error.to_string()))?;
    let json = serde_json::to_value(yaml_value)
        .map_err(|error| SymphonyError::WorkflowParse(error.to_string()))?;
    if !json.is_object() {
        return Err(SymphonyError::WorkflowFrontMatterNotAMap);
    }
    Ok((json, prompt))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_front_matter_and_prompt() {
        let content = r#"---
tracker:
  kind: linear
  api_key: secret
  project_slug: test
---
Hello {{ issue.identifier }}
"#;
        let (_config, prompt) = split_front_matter(content).expect("workflow");
        assert_eq!(prompt, "Hello {{ issue.identifier }}");
    }
}
