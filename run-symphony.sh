#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

SYMPHONY_DIR="${SYMPHONY_DIR:-$ROOT_DIR/elixir}"
MISE_BIN="${MISE_BIN:-$(command -v mise || true)}"
PORT="${SYMPHONY_PORT:-8080}"
HOST="${SYMPHONY_HOST:-0.0.0.0}"
WORKFLOW_FILE="${WORKFLOW_FILE:-$SYMPHONY_DIR/WORKFLOW.md}"
SYMPHONY_BIN="${SYMPHONY_BIN:-$SYMPHONY_DIR/bin/symphony}"

if [[ ! -d "$SYMPHONY_DIR" ]]; then
  echo "Symphony directory not found: $SYMPHONY_DIR" >&2
  exit 1
fi

if [[ -z "$MISE_BIN" || ! -x "$MISE_BIN" ]]; then
  echo "mise binary not found or not executable: ${MISE_BIN:-<unset>}" >&2
  exit 1
fi

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "Workflow file not found: $WORKFLOW_FILE" >&2
  exit 1
fi

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

cd "$SYMPHONY_DIR"

if [[ ! -x "$SYMPHONY_BIN" ]] ||
  [[ "$SYMPHONY_DIR/mix.exs" -nt "$SYMPHONY_BIN" ]] ||
  [[ "$SYMPHONY_DIR/mix.lock" -nt "$SYMPHONY_BIN" ]] ||
  [[ -n "$(find "$SYMPHONY_DIR/lib" "$SYMPHONY_DIR/config" -type f -newer "$SYMPHONY_BIN" -print -quit)" ]]; then
  "$MISE_BIN" exec -- mix build
fi

exec "$MISE_BIN" exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port "$PORT" \
  --host "$HOST" \
  "$WORKFLOW_FILE"
