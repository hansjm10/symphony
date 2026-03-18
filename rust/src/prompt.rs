use tera::{Context, Tera};

use crate::domain::Issue;
use crate::error::{Result, SymphonyError};

const DEFAULT_PROMPT: &str = r#"You are working on an issue from Linear.

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
"#;

pub fn validate_template(template: &str) -> Result<()> {
    let text = if template.trim().is_empty() {
        DEFAULT_PROMPT
    } else {
        template
    };
    let mut tera = Tera::default();
    tera.add_raw_template("workflow", text)
        .map_err(|error| SymphonyError::TemplateParse(error.to_string()))?;
    Ok(())
}

pub fn render_prompt(template: &str, issue: &Issue, attempt: Option<u32>) -> Result<String> {
    let text = if template.trim().is_empty() {
        DEFAULT_PROMPT
    } else {
        template
    };
    let mut tera = Tera::default();
    tera.add_raw_template("workflow", text)
        .map_err(|error| SymphonyError::TemplateParse(error.to_string()))?;
    let mut context = Context::new();
    context.insert("issue", issue);
    context.insert("attempt", &attempt);
    tera.render("workflow", &context)
        .map_err(|error| SymphonyError::TemplateRender(error.to_string()))
}

pub fn continuation_prompt(issue: &Issue, turn_number: u32, max_turns: u32) -> String {
    format!(
        "Continue working on Linear issue {}: {}.\n\nThe issue is still in an active tracker state. Continue from the existing thread and existing workspace without repeating the original task prompt. This is continuation turn {} of {} for the current worker session.",
        issue.identifier, issue.title, turn_number, max_turns
    )
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use super::*;
    use crate::domain::Issue;

    fn issue() -> Issue {
        Issue {
            id: "1".to_string(),
            identifier: "ABC-1".to_string(),
            title: "Title".to_string(),
            description: Some("Body".to_string()),
            state: "Todo".to_string(),
            labels: vec![],
            blocked_by: vec![],
            priority: Some(1),
            branch_name: None,
            url: None,
            assignee_id: None,
            created_at: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            updated_at: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
        }
    }

    #[test]
    fn render_fails_on_unknown_variable() {
        let error = render_prompt("{{ unknown }}", &issue(), None).expect_err("unknown variable");
        assert!(matches!(error, SymphonyError::TemplateRender(_)));
    }
}
