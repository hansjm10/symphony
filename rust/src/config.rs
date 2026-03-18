use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::error::{Result, SymphonyError};

#[derive(Debug, Clone)]
pub struct EffectiveConfig {
    pub tracker: TrackerConfig,
    pub polling: PollingConfig,
    pub workspace: WorkspaceConfig,
    pub hooks: HooksConfig,
    pub agent: AgentConfig,
    pub codex: CodexConfig,
    pub server: ServerConfig,
}

#[derive(Debug, Clone)]
pub struct TrackerConfig {
    pub kind: String,
    pub endpoint: String,
    pub api_key: Option<String>,
    pub project_slug: Option<String>,
    pub active_states: Vec<String>,
    pub terminal_states: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct PollingConfig {
    pub interval_ms: u64,
}

#[derive(Debug, Clone)]
pub struct WorkspaceConfig {
    pub root: PathBuf,
}

#[derive(Debug, Clone, Default)]
pub struct HooksConfig {
    pub after_create: Option<String>,
    pub before_run: Option<String>,
    pub after_run: Option<String>,
    pub before_remove: Option<String>,
    pub timeout_ms: u64,
}

#[derive(Debug, Clone)]
pub struct AgentConfig {
    pub max_concurrent_agents: usize,
    pub max_turns: u32,
    pub max_retry_backoff_ms: u64,
    pub max_concurrent_agents_by_state: BTreeMap<String, usize>,
}

#[derive(Debug, Clone)]
pub struct CodexConfig {
    pub command: String,
    pub approval_policy: Value,
    pub thread_sandbox: String,
    pub turn_sandbox_policy: Option<Value>,
    pub turn_timeout_ms: u64,
    pub read_timeout_ms: u64,
    pub stall_timeout_ms: i64,
}

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub port: Option<u16>,
    pub host: String,
}

impl EffectiveConfig {
    pub fn from_front_matter(value: &Value) -> Result<Self> {
        let root = value
            .as_object()
            .ok_or(SymphonyError::WorkflowFrontMatterNotAMap)?;

        let workspace_root_default = env::temp_dir().join("symphony_workspaces");
        let tracker = tracker_config(root)?;
        let polling = PollingConfig {
            interval_ms: int_like(root_obj(root, "polling"), "interval_ms").unwrap_or(30_000),
        };

        let hooks_timeout = int_like(root_obj(root, "hooks"), "timeout_ms")
            .filter(|value| *value > 0)
            .unwrap_or(60_000);
        let hooks_obj = root_obj(root, "hooks");
        let hooks = HooksConfig {
            after_create: string_value(hooks_obj, "after_create"),
            before_run: string_value(hooks_obj, "before_run"),
            after_run: string_value(hooks_obj, "after_run"),
            before_remove: string_value(hooks_obj, "before_remove"),
            timeout_ms: hooks_timeout,
        };

        let workspace = WorkspaceConfig {
            root: resolve_path_value(
                string_value(root_obj(root, "workspace"), "root"),
                &workspace_root_default,
            )?,
        };

        let agent_obj = root_obj(root, "agent");
        let agent = AgentConfig {
            max_concurrent_agents: int_like(agent_obj, "max_concurrent_agents")
                .unwrap_or(10)
                .max(1) as usize,
            max_turns: int_like(agent_obj, "max_turns").unwrap_or(20).max(1) as u32,
            max_retry_backoff_ms: int_like(agent_obj, "max_retry_backoff_ms")
                .unwrap_or(300_000)
                .max(1),
            max_concurrent_agents_by_state: state_limit_map(
                agent_obj,
                "max_concurrent_agents_by_state",
            ),
        };

        let codex_obj = root_obj(root, "codex");
        let codex = CodexConfig {
            command: string_value(codex_obj, "command")
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "codex app-server".to_string()),
            approval_policy: value_or_default(
                codex_obj,
                "approval_policy",
                serde_json::json!({
                    "reject": {
                        "sandbox_approval": true,
                        "rules": true,
                        "mcp_elicitations": true
                    }
                }),
            ),
            thread_sandbox: string_value(codex_obj, "thread_sandbox")
                .unwrap_or_else(|| "workspace-write".to_string()),
            turn_sandbox_policy: codex_obj
                .and_then(|obj| obj.get("turn_sandbox_policy"))
                .cloned(),
            turn_timeout_ms: int_like(codex_obj, "turn_timeout_ms")
                .unwrap_or(3_600_000)
                .max(1),
            read_timeout_ms: int_like(codex_obj, "read_timeout_ms")
                .unwrap_or(5_000)
                .max(1),
            stall_timeout_ms: int_like(codex_obj, "stall_timeout_ms")
                .map(|value| value as i64)
                .unwrap_or(300_000),
        };

        let server_obj = root_obj(root, "server");
        let server = ServerConfig {
            port: int_like(server_obj, "port").map(|port| port as u16),
            host: string_value(server_obj, "host").unwrap_or_else(|| "127.0.0.1".to_string()),
        };

        let config = Self {
            tracker,
            polling,
            workspace,
            hooks,
            agent,
            codex,
            server,
        };
        config.validate_dispatch_preflight()?;
        Ok(config)
    }

    pub fn validate_dispatch_preflight(&self) -> Result<()> {
        if self.tracker.kind.trim().is_empty() {
            return Err(SymphonyError::InvalidConfig(
                "tracker.kind must be present".to_string(),
            ));
        }
        if self.tracker.kind != "linear" {
            return Err(SymphonyError::UnsupportedTrackerKind(
                self.tracker.kind.clone(),
            ));
        }
        if self.tracker.api_key.is_none() {
            return Err(SymphonyError::MissingTrackerApiKey);
        }
        if self.tracker.project_slug.is_none() {
            return Err(SymphonyError::MissingTrackerProjectSlug);
        }
        if self.codex.command.trim().is_empty() {
            return Err(SymphonyError::InvalidConfig(
                "codex.command must be present".to_string(),
            ));
        }
        Ok(())
    }

    pub fn default_turn_sandbox_policy(&self, workspace: &Path) -> Value {
        self.codex.turn_sandbox_policy.clone().unwrap_or_else(|| {
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": [workspace.to_string_lossy().to_string()],
                "readOnlyAccess": {"type": "fullAccess"},
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            })
        })
    }

    pub fn is_active_state(&self, state: &str) -> bool {
        self.tracker
            .active_states
            .iter()
            .any(|candidate| candidate.eq_ignore_ascii_case(state))
    }

    pub fn is_terminal_state(&self, state: &str) -> bool {
        self.tracker
            .terminal_states
            .iter()
            .any(|candidate| candidate.eq_ignore_ascii_case(state))
    }

    pub fn max_concurrent_agents_for_state(&self, state: &str) -> usize {
        self.agent
            .max_concurrent_agents_by_state
            .get(&state.trim().to_ascii_lowercase())
            .copied()
            .unwrap_or(self.agent.max_concurrent_agents)
    }
}

fn tracker_config(root: &Map<String, Value>) -> Result<TrackerConfig> {
    let tracker = root_obj(root, "tracker");
    let kind = string_value(tracker, "kind").unwrap_or_default();
    let endpoint = string_value(tracker, "endpoint")
        .unwrap_or_else(|| "https://api.linear.app/graphql".to_string());
    let api_key = resolve_secret_value(string_value(tracker, "api_key"), "LINEAR_API_KEY");
    let project_slug = string_value(tracker, "project_slug");
    Ok(TrackerConfig {
        kind,
        endpoint,
        api_key,
        project_slug,
        active_states: string_list(tracker, "active_states")
            .unwrap_or_else(|| vec!["Todo".to_string(), "In Progress".to_string()]),
        terminal_states: string_list(tracker, "terminal_states").unwrap_or_else(|| {
            vec![
                "Closed".to_string(),
                "Cancelled".to_string(),
                "Canceled".to_string(),
                "Duplicate".to_string(),
                "Done".to_string(),
            ]
        }),
    })
}

fn root_obj<'a>(root: &'a Map<String, Value>, key: &str) -> Option<&'a Map<String, Value>> {
    root.get(key)?.as_object()
}

fn string_value(root: Option<&Map<String, Value>>, key: &str) -> Option<String> {
    root?
        .get(key)
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
}

fn string_list(root: Option<&Map<String, Value>>, key: &str) -> Option<Vec<String>> {
    let values = root?.get(key)?.as_array()?;
    Some(
        values
            .iter()
            .filter_map(|value| value.as_str().map(|item| item.to_string()))
            .collect(),
    )
}

fn int_like(root: Option<&Map<String, Value>>, key: &str) -> Option<u64> {
    let value = root?.get(key)?;
    match value {
        Value::Number(number) => number.as_u64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn value_or_default(root: Option<&Map<String, Value>>, key: &str, default: Value) -> Value {
    root.and_then(|obj| obj.get(key))
        .cloned()
        .unwrap_or(default)
}

fn resolve_secret_value(value: Option<String>, env_name: &str) -> Option<String> {
    match value {
        Some(text) if text.trim().is_empty() => None,
        Some(text) if text == format!("${env_name}") => env::var(env_name).ok(),
        Some(text) if text.starts_with('$') => env::var(text.trim_start_matches('$')).ok(),
        Some(text) => Some(text),
        None => env::var(env_name).ok(),
    }
}

fn resolve_path_value(value: Option<String>, default: &Path) -> Result<PathBuf> {
    let resolved = match value {
        Some(text) if text.starts_with('$') => env::var(text.trim_start_matches('$'))
            .map(PathBuf::from)
            .map_err(|_| SymphonyError::InvalidConfig(format!("missing env path for {text}")))?,
        Some(text) if text.starts_with("~/") => {
            let home = dirs::home_dir().ok_or_else(|| {
                SymphonyError::InvalidConfig("home directory unavailable".to_string())
            })?;
            home.join(text.trim_start_matches("~/"))
        }
        Some(text) if text == "~" => dirs::home_dir().ok_or_else(|| {
            SymphonyError::InvalidConfig("home directory unavailable".to_string())
        })?,
        Some(text) => PathBuf::from(text),
        None => default.to_path_buf(),
    };
    Ok(resolved)
}

fn state_limit_map(root: Option<&Map<String, Value>>, key: &str) -> BTreeMap<String, usize> {
    root.and_then(|obj| obj.get(key))
        .and_then(|value| value.as_object())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|(state, raw_value)| {
                    let limit = match raw_value {
                        Value::Number(number) => number.as_u64(),
                        Value::String(text) => text.parse().ok(),
                        _ => None,
                    }?;
                    if limit == 0 {
                        return None;
                    }
                    Some((state.trim().to_ascii_lowercase(), limit as usize))
                })
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_string_integers_and_defaults() {
        let value = serde_json::json!({
            "tracker": {
                "kind": "linear",
                "api_key": "secret",
                "project_slug": "proj"
            },
            "polling": { "interval_ms": "1500" },
            "agent": {
                "max_concurrent_agents": "3",
                "max_concurrent_agents_by_state": {
                    "Todo": "2",
                    "Bad": 0
                }
            }
        });
        let config = EffectiveConfig::from_front_matter(&value).expect("config");
        assert_eq!(config.polling.interval_ms, 1500);
        assert_eq!(config.agent.max_concurrent_agents, 3);
        assert_eq!(
            config.agent.max_concurrent_agents_by_state.get("todo"),
            Some(&2)
        );
        assert!(
            !config
                .agent
                .max_concurrent_agents_by_state
                .contains_key("bad")
        );
    }
}
