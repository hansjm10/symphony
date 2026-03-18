use chrono::{DateTime, Utc};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};

use crate::config::EffectiveConfig;
use crate::domain::{BlockedBy, Issue};
use crate::error::{Result, SymphonyError};

const PAGE_SIZE: u64 = 50;
const NETWORK_TIMEOUT_MS: u64 = 30_000;

const CANDIDATE_QUERY: &str = r#"
query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
  issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
    nodes {
      id
      identifier
      title
      description
      priority
      state { name }
      branchName
      url
      assignee { id }
      labels { nodes { name } }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state { name }
          }
        }
      }
      createdAt
      updatedAt
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
"#;

const BY_IDS_QUERY: &str = r#"
query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
  issues(filter: {id: {in: $ids}}, first: $first) {
    nodes {
      id
      identifier
      title
      description
      priority
      state { name }
      branchName
      url
      assignee { id }
      labels { nodes { name } }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state { name }
          }
        }
      }
      createdAt
      updatedAt
    }
  }
}
"#;

#[derive(Clone)]
pub struct LinearClient {
    client: reqwest::Client,
    config: EffectiveConfig,
}

impl LinearClient {
    pub fn new(config: EffectiveConfig) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(NETWORK_TIMEOUT_MS))
            .build()
            .map_err(|error| SymphonyError::LinearApiRequest(error.to_string()))?;
        Ok(Self { client, config })
    }

    pub async fn fetch_candidate_issues(&self) -> Result<Vec<Issue>> {
        let mut after: Option<String> = None;
        let mut all = Vec::new();
        loop {
            let body = self
                .graphql(
                    CANDIDATE_QUERY,
                    json!({
                        "projectSlug": self.config.tracker.project_slug.clone().ok_or(SymphonyError::MissingTrackerProjectSlug)?,
                        "stateNames": self.config.tracker.active_states,
                        "first": PAGE_SIZE,
                        "relationFirst": PAGE_SIZE,
                        "after": after,
                    }),
                )
                .await?;
            let issues = body
                .get("data")
                .and_then(|data| data.get("issues"))
                .ok_or_else(|| {
                    SymphonyError::LinearUnknownPayload("missing data.issues".to_string())
                })?;
            all.extend(normalize_nodes(
                issues
                    .get("nodes")
                    .and_then(Value::as_array)
                    .ok_or_else(|| {
                        SymphonyError::LinearUnknownPayload("missing issues.nodes".to_string())
                    })?,
            )?);
            let page_info = issues
                .get("pageInfo")
                .and_then(Value::as_object)
                .ok_or_else(|| {
                    SymphonyError::LinearUnknownPayload("missing issues.pageInfo".to_string())
                })?;
            let has_next = page_info
                .get("hasNextPage")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if !has_next {
                return Ok(all);
            }
            after = page_info
                .get("endCursor")
                .and_then(Value::as_str)
                .map(|value| value.to_string());
            if after.is_none() {
                return Err(SymphonyError::LinearMissingEndCursor);
            }
        }
    }

    pub async fn fetch_issues_by_states(&self, states: &[String]) -> Result<Vec<Issue>> {
        if states.is_empty() {
            return Ok(Vec::new());
        }
        let mut override_config = self.config.clone();
        override_config.tracker.active_states = states.to_vec();
        Self::new(override_config)?.fetch_candidate_issues().await
    }

    pub async fn fetch_issue_states_by_ids(&self, ids: &[String]) -> Result<Vec<Issue>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let body = self
            .graphql(
                BY_IDS_QUERY,
                json!({
                    "ids": ids,
                    "first": ids.len(),
                    "relationFirst": PAGE_SIZE,
                }),
            )
            .await?;
        let nodes = body
            .get("data")
            .and_then(|data| data.get("issues"))
            .and_then(|issues| issues.get("nodes"))
            .and_then(Value::as_array)
            .ok_or_else(|| {
                SymphonyError::LinearUnknownPayload("missing issue state nodes".to_string())
            })?;
        let mut issues = normalize_nodes(nodes)?;
        issues.sort_by_key(|issue| {
            ids.iter()
                .position(|id| id == &issue.id)
                .unwrap_or(usize::MAX)
        });
        Ok(issues)
    }

    pub async fn graphql(&self, query: &str, variables: Value) -> Result<Value> {
        let api_key = self
            .config
            .tracker
            .api_key
            .as_ref()
            .ok_or(SymphonyError::MissingTrackerApiKey)?;
        let mut headers = HeaderMap::new();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(api_key)
                .map_err(|error| SymphonyError::LinearApiRequest(error.to_string()))?,
        );
        let response = self
            .client
            .post(&self.config.tracker.endpoint)
            .headers(headers)
            .json(&json!({
                "query": query,
                "variables": variables
            }))
            .send()
            .await
            .map_err(|error| SymphonyError::LinearApiRequest(error.to_string()))?;
        let status = response.status();
        let body: Value = response
            .json()
            .await
            .map_err(|error| SymphonyError::LinearApiRequest(error.to_string()))?;
        if !status.is_success() {
            return Err(SymphonyError::LinearApiStatus(status.as_u16()));
        }
        if let Some(errors) = body.get("errors") {
            return Err(SymphonyError::LinearGraphqlErrors(errors.to_string()));
        }
        Ok(body)
    }
}

fn normalize_nodes(nodes: &[Value]) -> Result<Vec<Issue>> {
    nodes.iter().map(normalize_issue).collect()
}

fn normalize_issue(node: &Value) -> Result<Issue> {
    let created_at = parse_datetime(node, "createdAt")?;
    let updated_at = parse_datetime(node, "updatedAt")?;
    let labels = node
        .get("labels")
        .and_then(|labels| labels.get("nodes"))
        .and_then(Value::as_array)
        .map(|nodes| {
            nodes
                .iter()
                .filter_map(|label| label.get("name").and_then(Value::as_str))
                .map(|label| label.to_ascii_lowercase())
                .collect()
        })
        .unwrap_or_default();
    let blocked_by = node
        .get("inverseRelations")
        .and_then(|relations| relations.get("nodes"))
        .and_then(Value::as_array)
        .map(|relations| {
            relations
                .iter()
                .filter(|relation| relation.get("type").and_then(Value::as_str) == Some("blocks"))
                .filter_map(|relation| relation.get("issue"))
                .filter_map(|issue| {
                    Some(BlockedBy {
                        id: issue.get("id")?.as_str()?.to_string(),
                        identifier: issue.get("identifier")?.as_str()?.to_string(),
                        state: issue.get("state")?.get("name")?.as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Issue {
        id: required_string(node, "id")?,
        identifier: required_string(node, "identifier")?,
        title: required_string(node, "title")?,
        description: node
            .get("description")
            .and_then(Value::as_str)
            .map(|value| value.to_string()),
        state: node
            .get("state")
            .and_then(|state| state.get("name"))
            .and_then(Value::as_str)
            .ok_or_else(|| SymphonyError::LinearUnknownPayload("missing state.name".to_string()))?
            .to_string(),
        labels,
        blocked_by,
        priority: node.get("priority").and_then(Value::as_i64),
        branch_name: node
            .get("branchName")
            .and_then(Value::as_str)
            .map(|value| value.to_string()),
        url: node
            .get("url")
            .and_then(Value::as_str)
            .map(|value| value.to_string()),
        assignee_id: node
            .get("assignee")
            .and_then(|assignee| assignee.get("id"))
            .and_then(Value::as_str)
            .map(|value| value.to_string()),
        created_at,
        updated_at,
    })
}

fn required_string(node: &Value, key: &str) -> Result<String> {
    node.get(key)
        .and_then(Value::as_str)
        .map(|value| value.to_string())
        .ok_or_else(|| SymphonyError::LinearUnknownPayload(format!("missing {key}")))
}

fn parse_datetime(node: &Value, key: &str) -> Result<DateTime<Utc>> {
    let value = required_string(node, key)?;
    DateTime::parse_from_rfc3339(&value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| SymphonyError::LinearUnknownPayload(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_labels_and_blockers() {
        let node = json!({
            "id": "1",
            "identifier": "ABC-1",
            "title": "Title",
            "description": "Body",
            "priority": 2,
            "state": { "name": "Todo" },
            "labels": { "nodes": [{ "name": "Bug" }] },
            "inverseRelations": { "nodes": [{
                "type": "blocks",
                "issue": { "id": "2", "identifier": "ABC-2", "state": { "name": "In Progress" } }
            }]},
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        });
        let issue = normalize_issue(&node).expect("issue");
        assert_eq!(issue.labels, vec!["bug"]);
        assert_eq!(issue.blocked_by.len(), 1);
    }
}
