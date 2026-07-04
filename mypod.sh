#!/usr/bin/env bash
# mypod.sh — run pending CLAUDE_TASKS.md tasks in parallel, each in its own
# isolated git worktree. Portable to the stock Bash (3.2) and coreutils
# shipped with macOS — no Homebrew bash, no GNU `timeout` required.
#
# Usage: bash mypod.sh [max-parallel] [timeout-seconds]
# Run from inside the project directory (same convention as autonomous.sh).
set -uo pipefail  # no -e: a single task's failure must not abort the batch

MYPOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MYPOD_ROOT/lib/worktree.sh"
source "$MYPOD_ROOT/lib/tasks.sh"

MAX_PARALLEL="${1:-3}"
TIMEOUT_SECONDS="${2:-1800}"

REPO_PATH="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT="$(basename "$REPO_PATH")"
TASKS_FILE="$REPO_PATH/CLAUDE_TASKS.md"
BASE_BRANCH="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)"
WORKTREES_DIR="$(dirname "$REPO_PATH")/mypod-worktrees/$PROJECT"
RESULTS_DIR="$(mktemp -d)"

echo "======================================="
echo "  MyPod — $PROJECT"
echo "  Max parallel: $MAX_PARALLEL   Timeout/task: ${TIMEOUT_SECONDS}s"
echo "======================================="

# Drain inbox into CLAUDE_TASKS.md before reading the queue (reuse existing logic).
if [ -f "$HOME/.claude/inbox/inbox.jsonl" ]; then
  bash "$HOME/.claude/inbox/inbox-to-tasks.sh" "$TASKS_FILE" 2>/dev/null || true
fi

if [ ! -f "$TASKS_FILE" ]; then
  echo "No CLAUDE_TASKS.md found in $REPO_PATH — nothing to do."
  exit 0
fi

mkdir -p "$WORKTREES_DIR"
cd "$REPO_PATH"

# --- Claim phase: single writer, lock held only for read + claim ---
if ! acquire_queue_lock; then
  exit 1
fi

claimed_tasks=()
claimed_labels=()
claimed_branches=()
claimed_worktrees=()

task_index=0
while IFS= read -r task_text; do
  [ -z "$task_text" ] && continue
  if [ "$task_index" -ge "$MAX_PARALLEL" ]; then
    break
  fi

  slug="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)"
  [ -z "$slug" ] && slug="task"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$-${task_index}"
  label="${slug}-${stamp}"

  if claim_task "$TASKS_FILE" "$task_text" "$label"; then
    claimed_tasks+=("$task_text")
    claimed_labels+=("$label")
    claimed_branches+=("mypod/${label}")
    claimed_worktrees+=("${WORKTREES_DIR}/${label}")
    task_index=$((task_index + 1))
  fi
done < <(parse_pending_tasks "$TASKS_FILE")

release_queue_lock

if [ "${#claimed_tasks[@]}" -eq 0 ]; then
  echo "No pending tasks to run."
  rm -rf "$RESULTS_DIR"
  exit 0
fi

echo "Claimed ${#claimed_tasks[@]} task(s):"
i=0
while [ "$i" -lt "${#claimed_tasks[@]}" ]; do
  echo "  - ${claimed_tasks[$i]}"
  i=$((i + 1))
done
echo ""

# --- Dispatch phase: one run-task.sh per claimed task, in parallel ---
running_pids=()
i=0
while [ "$i" -lt "${#claimed_tasks[@]}" ]; do
  result_file="${RESULTS_DIR}/${claimed_labels[$i]}.result"
  bash "$MYPOD_ROOT/lib/run-task.sh" \
    "$REPO_PATH" "${claimed_tasks[$i]}" "${claimed_worktrees[$i]}" \
    "${claimed_branches[$i]}" "$BASE_BRANCH" \
    "$MYPOD_ROOT/MYPOD_TASK_PROMPT.md" "$result_file" "$TIMEOUT_SECONDS" &
  running_pids+=("$!")
  i=$((i + 1))
done

# Bash 3.2 (stock on macOS) has no `wait -n`; a flat `wait` over the explicit
# pid list is portable and sufficient since MAX_PARALLEL already caps how
# many run-task.sh jobs this invocation ever launches at once.
for pid in "${running_pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

echo "All tasks finished. Resolving $TASKS_FILE ..."
echo ""

# --- Resolve phase: single writer, update CLAUDE_TASKS.md from result files ---
done_count=0
skipped_count=0
i=0
while [ "$i" -lt "${#claimed_tasks[@]}" ]; do
  task_text="${claimed_tasks[$i]}"
  label="${claimed_labels[$i]}"
  result_file="${RESULTS_DIR}/${label}.result"

  status="skipped"
  detail="no_result_reported"
  if [ -f "$result_file" ]; then
    status="$(grep '^status=' "$result_file" | head -1 | cut -d= -f2-)"
    if [ "$status" = "done" ]; then
      detail="$(grep '^pr_url=' "$result_file" | head -1 | cut -d= -f2-)"
    else
      detail="$(grep '^reason=' "$result_file" | head -1 | cut -d= -f2-)"
    fi
  fi

  if [ "$status" = "done" ]; then
    resolve_task "$TASKS_FILE" "$task_text" "$label" "done" "$detail"
    done_count=$((done_count + 1))
    echo "  done:    $task_text -> $detail"
  else
    resolve_task "$TASKS_FILE" "$task_text" "$label" "skipped" "$detail"
    skipped_count=$((skipped_count + 1))
    echo "  skipped: $task_text ($detail)"
  fi
  i=$((i + 1))
done

rm -rf "$RESULTS_DIR"

echo ""
echo "======================================="
echo "  Done: $done_count   Skipped: $skipped_count"
echo "======================================="
