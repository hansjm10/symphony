---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "symphony-054d78cce109"
  active_states:
    - Todo
    - In Progress
    - In Review
    - Rework
    - Merging
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/hansjm10/symphony .
    mkdir -p "$HOME/.local/bin"
    cp context-pruner "$HOME/.local/bin/context-pruner"
    chmod 755 "$HOME/.local/bin/context-pruner"
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: PATH="$HOME/.local/bin:$PATH" codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions, auth, tools, or secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Repository sources of truth:

- `/work/symphony/SPEC.md`
- `/work/symphony/elixir/AGENTS.md`
- `/work/symphony/elixir/README.md`

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth, permissions, tools, or secrets).
3. Final message must report completed actions and blockers only. Do not include "next steps for user".
4. Work only in the provided repository copy.
5. Keep scope tight to the current Linear ticket. If you discover follow-up work, create a separate `Backlog` issue in the same project.
6. Keep one persistent Linear progress comment headed `## Codex Workpad`. Reuse it instead of creating multiple progress comments.
7. Keep the Linear state accurate as work moves through `Todo`, `In Progress`, `In Review`, `Rework`, `Merging`, and `Done`.
8. Commit and push code changes when the task is complete, and create or update the corresponding PR.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

- Use a configured Linear MCP server when available.
- Otherwise use Symphony's injected `linear_graphql` tool.
- If neither is present, stop and report the missing integration as the blocker.
- If `linear_graphql` is available, open `.codex/skills/linear/SKILL.md` and follow it for raw Linear GraphQL operations.

## Context discovery and reads

- `context-pruner` is the local CLI for bounded file reads, targeted grep, and optional prune-focused shell capture. Prefer it before broad `cat`, `sed`, `rg`, or ad hoc shell output when you need repository context.
- The CLI shape was adapted from prior Jeeves work. For reuse-first background, see `/work/jeeves/docs/mcp-pruner-cli-report.md` and `/work/jeeves/packages/mcp-pruner/`.
- Open `.codex/skills/context-pruner/SKILL.md` before discovery work when the skill is available, and follow its command surface and fallback guidance.
- Start with the narrowest command that can answer the question:
  - `context-pruner read --file-path <path> --start-line <n> --end-line <n>` or `--around-line <n> --radius <n>` for known files.
  - `context-pruner grep --pattern <regex> --path <path> --context-lines <n> --max-matches <n>` for bounded search.
  - `context-pruner bash --command "<command>"` only when the answer must come from shell output rather than directly from files.
- Add `--focus` only after the file window, search path, and match counts are already narrow enough that pruning has a clear target.
- Phrase `--focus` as the specific retention goal for the remote pruner:
  - broader mixed file window -> `Keep exactly the statements that define ...`
  - grep-style clustered output -> `Which lines are relevant to ...?`
  - ultra-narrow fact lookup -> `Extract only the minimum text needed to answer ...`
  - avoid negative-only phrasing like `Drop examples, framing, and unrelated lines.`
  - avoid line-number-only phrasing like `Return only lines 49, 54, 67, and 68.`
- Keep Symphony env-driven: prefer `PRUNER_URL`; use `JEEVES_PRUNER_URL` only as a compatibility alias when `PRUNER_URL` is unset. The current remote verification target referenced in `/work/jeeves/.env` is `http://192.168.1.15:8000/prune`, but do not hardcode it or assume it must be configured.
- Fall back to bounded raw reads only when `context-pruner` is unavailable, cannot express the query, or you need exact raw bytes or interactive output. Use tight fallbacks such as `sed -n '120,160p' path`, `rg -n "pattern" path`, or a small shell command. Avoid full-file reads or unbounded repo sweeps unless no narrower option exists.

## Default posture

- Start by determining the ticket's current state, then follow the matching flow for that state.
- Start every task by opening the `## Codex Workpad` comment and bringing it up to date before doing new work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior or issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current: state, checklist, acceptance criteria, and PR linkage.
- Treat one persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done" comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as mandatory acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution, create a separate Linear issue instead of expanding scope. Put it in `Backlog`, assign it to the same project, link it to the current ticket as `related`, and add `blockedBy` when appropriate.
- Move state only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, tools, or permissions.
- Use the blocked-access escape hatch only for true external blockers after documented fallbacks are exhausted.

## Related skills

- `context-pruner`: use `.codex/skills/context-pruner/SKILL.md` for bounded discovery and focused raw-read fallbacks.
- `linear`: interact with Linear.
- `pull`: keep the branch updated with latest `origin/main` before handoff-sensitive work.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep the remote branch current and publish updates.
- `land`: when the ticket reaches `Merging`, open and follow `.codex/skills/land/SKILL.md`.

## Status map

- `Backlog` -> out of scope for active execution. Do not modify unless the run is explicitly about triage or follow-up creation.
- `Todo` -> queued. Immediately transition to `In Progress` before active implementation.
  - Special case: if a PR is already attached, treat the ticket as a feedback/rework loop. Run the full PR feedback sweep, address or explicitly push back on comments, revalidate, and return to `In Review`.
- `In Progress` -> implementation actively underway.
- `In Review` -> PR exists and is in review. Perform Codex self-review plus external feedback sweep, then wait, rework, or advance.
- `Rework` -> changes are required before the PR can advance.
- `Merging` -> PR is approved by humans or marked clean by Codex self-review and ready to land.
- `Done` -> terminal state. No further work required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content or state; stop and wait unless the run is explicitly about issue curation.
   - `Todo` -> immediately move to `In Progress`, ensure the bootstrap workpad comment exists, then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from the existing workpad.
   - `In Review` -> run the review flow and wait or poll when no action is needed.
   - `Rework` -> run the rework flow.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt when required.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - move ticket to `In Progress`
   - find or create `## Codex Workpad`
   - only then begin analysis, planning, and implementation
6. Add a short workpad note if ticket state and ticket content are inconsistent, then proceed with the safest flow.

## Step 1: Start or continue execution (`Todo` or `In Progress`)

1. Find or create a single persistent workpad comment:
   - Search existing comments for the marker header `## Codex Workpad`.
   - Reuse it if found. Do not create a second live workpad.
   - If not found, create one workpad comment and use it for all updates.
2. If arriving from `Todo`, do not delay on additional state transitions: the ticket should already be `In Progress`.
3. Immediately reconcile the workpad before new edits:
   - check off items already done
   - expand or fix the plan so it matches current scope
   - ensure `Acceptance Criteria`, `Validation`, and `Review` sections are current
4. Start work by writing or updating a hierarchical plan in the workpad.
5. Include a compact environment stamp near the top of the workpad as a code fence line:
   - format: `<host>:<abs-workdir>@<short-sha>`
6. Add explicit acceptance criteria and TODOs in checklist form.
   - If changes are user-facing, include a UI walkthrough acceptance criterion for the end-to-end user path.
   - If changes touch app behavior, add explicit launch path, changed interaction path, and expected result path checks.
   - If the ticket description or comments include `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad as required checkboxes.
7. Run a principal-style self-review of the plan and refine it in the workpad.
8. Before implementing, capture a concrete reproduction signal and record it in the `Notes` section.
9. Run the `pull` skill or equivalent sync flow to bring the branch up to date with `origin/main` before handoff-sensitive work, then record the result in `Notes`:
   - merge source
   - result (`clean` or `conflicts resolved`)
   - resulting `HEAD` short SHA
10. Compact context and proceed to execution.

## PR feedback sweep protocol

When a ticket has an attached PR, run this protocol before moving to `In Review` and while handling `In Review`:

1. Identify the PR number from issue links or attachments.
2. Gather feedback from all channels:
   - top-level PR comments
   - inline review comments
   - review summaries and states
   - CI and check failures
3. Treat every actionable reviewer comment, bot comment, or failing validation signal as blocking until one of these is true:
   - code, tests, or docs changed to address it
   - explicit, justified pushback was posted on that thread
   - the signal is proven stale or unrelated and documented in the workpad
4. Update the workpad plan and checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until no outstanding actionable comments remain.

## Blocked-access escape hatch

Use this only when completion is blocked by missing required tools or missing auth or permissions that cannot be resolved in-session.

- GitHub is not a valid blocker by default. Try fallback strategies first.
- Do not move to `In Review` or `Merging` on the basis of missing GitHub access alone unless all fallback strategies have been attempted and documented in the workpad.
- If a required non-GitHub tool is missing, or required non-GitHub auth is unavailable, record a short blocker brief in the workpad that includes:
  - what is missing
  - why it blocks required acceptance or validation
  - exact human action needed to unblock
- Keep the brief concise and action-oriented.

## Step 2: Execution phase (`Todo` -> `In Progress`)

1. Determine current repo state: branch, `git status`, and `HEAD`. Verify the sync result is recorded in the workpad before implementation continues.
2. Load the existing workpad comment and treat it as the active execution checklist.
3. Implement against the hierarchical TODOs and keep the workpad current:
   - check off completed items
   - add newly discovered items in the appropriate section
   - update the workpad immediately after each meaningful milestone
   - never leave completed work unchecked
   - for tickets that started as `Todo` with an attached PR, run the full PR feedback sweep immediately after kickoff and before new feature work
4. Run validation required for the scope.
   - Mandatory gate: execute all ticket-provided `Validation`, `Test Plan`, or `Testing` requirements when present.
   - Prefer targeted proof that directly demonstrates the behavior changed.
   - Temporary local proof edits are allowed when they increase confidence, but revert them before commit or push.
   - Document temporary proof steps and outcomes in the workpad.
   - If app-touching, run `launch-app` validation and capture or upload media via `github-pr-media` before handoff.
5. Re-check all acceptance criteria and close any gaps.
6. Before every `git push` attempt, run the required validation for the scope and confirm it passes. If it fails, address issues and rerun until green.
7. Attach the PR URL to the ticket when available, preferably as an attachment rather than only in comments.
   - Ensure the GitHub PR has label `symphony`.
8. Merge latest `origin/main` into the branch, resolve conflicts, and rerun checks.
9. Update the workpad with final checklist status and validation notes.
   - Mark completed plan, acceptance, and validation items as checked.
   - Add final handoff notes in the same workpad comment.
   - Do not include PR URL in the workpad comment; keep PR linkage on the ticket via attachments or links.
   - Add a short `### Confusions` section at the bottom when any part of execution was unclear.
10. Only then move the ticket to `In Review`.

## Step 3: Review and merge handling (`In Review` and `Merging`)

1. When the ticket is in `In Review`, do not start unrelated coding.
2. Perform a Codex self-review before waiting:
   - inspect the PR diff, linked ticket requirements, current checks, and reviewer feedback
   - record a concise self-review result in the workpad
3. Run the full PR feedback sweep protocol.
4. If the self-review or external review finds actionable issues, move the ticket to `Rework` and follow the rework flow.
5. If the PR is green and either:
   - externally approved, or
   - marked clean by Codex self-review in the workpad
   move the ticket to `Merging`.
6. Do not rely on a formal GitHub self-approval unless repository policy explicitly requires it and the actor is allowed to submit it.
7. Otherwise wait and poll.
8. When the ticket is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the land flow until the PR is merged.
9. After merge succeeds, move the ticket to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a focused feedback-response loop, not a passive waiting state.
2. Re-read the full ticket body, PR, review comments, and CI signals. Explicitly identify what must change this attempt.
3. Update the workpad with the requested changes, revised plan, and validation approach.
4. Implement the required changes, rerun validation, and push updates.
5. Re-run the PR feedback sweep protocol.
6. Move back to `In Review` only when the PR is ready for another review pass.

## Completion bar before `In Review`

- Step 1 and Step 2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation and tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the ticket.
- Required PR metadata is present, including label `symphony`.
- If app-touching, runtime validation and media requirements are complete.

## Guardrails

- If the branch PR is already closed or merged, do not reuse that branch or prior implementation state for continuation.
- For closed or merged branch PRs, create a new branch from `origin/main` and restart from reproduction and planning as if starting fresh.
- If ticket state is `Backlog`, do not modify it; wait for a later run that explicitly handles backlog work.
- Do not edit the ticket body or description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per ticket.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate `Backlog` issue rather than expanding current scope, and include a clear title, description, acceptance criteria, same-project assignment, a `related` link to the current ticket, and `blockedBy` when the follow-up depends on the current ticket.
- Do not move to `In Review` unless the `Completion bar before In Review` is satisfied.
- In `In Review`, do not make unrelated changes; only respond to review and validation signals.
- If state is terminal (`Done`), do nothing and shut down.
- Keep ticket text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and exact unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Review

- self-review status and key findings

### Notes

- <short timestamped progress note>

### Confusions

- <only include when something was confusing during execution>
````
