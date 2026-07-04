#!/usr/bin/env bash
# lib/run-task.sh — run ONE task end-to-end in its own worktree.
#
# Invoked by mypod.sh as a background job. Never touches CLAUDE_TASKS.md
# directly — reports outcome via a result file so mypod.sh remains the
# single writer of the task queue (avoids concurrent-write races).
#
# Usage: run-task.sh <repo_path> <task_text> <worktree_path> <branch>
#                     <base_branch> <prompt_file> <result_file> <timeout_seconds>
set -uo pipefail  # no -e: every failure path below must still report a result

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/worktree.sh"

# run_with_timeout <seconds> <cmd...>
# Portable substitute for GNU `timeout`/`gtimeout` (neither ships with stock
# macOS). Runs the command in its own process group (`set -m` in a subshell)
# so a negative-PID kill reaches any children it spawns too, not just the
# top-level process.
run_with_timeout() {
  local timeout_seconds="$1"; shift
  ( set -m; "$@" ) &
  local cmd_pid=$!
  ( sleep "$timeout_seconds"; kill -TERM -"$cmd_pid" 2>/dev/null ) &
  local watchdog_pid=$!
  local exit_code=0
  wait "$cmd_pid" 2>/dev/null || exit_code=$?
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  return "$exit_code"
}

run_task() {
  local repo_path="$1" task_text="$2" worktree_path="$3" branch="$4"
  local base_branch="$5" prompt_file="$6" result_file="$7" timeout_seconds="$8"
  local log_file="${worktree_path}.mypod.log"

  if ! safe_add_worktree "$repo_path" "$worktree_path" "$branch" "$base_branch"; then
    printf 'status=skipped\nreason=worktree_create_failed\n' > "$result_file"
    return 0
  fi

  local prompt
  prompt="$(cat "$prompt_file")
## Task
${task_text}"

  ( cd "$worktree_path" && run_with_timeout "$timeout_seconds" claude --print "$prompt" ) \
    > "$log_file" 2>&1
  local claude_exit=$?

  if [ "$claude_exit" -ne 0 ]; then
    printf 'status=skipped\nreason=agent_exit_%s\nlog=%s\n' "$claude_exit" "$log_file" > "$result_file"
    safe_remove_worktree "$repo_path" "$worktree_path" "$branch"
    return 0
  fi

  # Not `git log ... | grep -q .` — under `set -o pipefail` (this script sets
  # it), grep -q can close the pipe after its first match while git log still
  # has more to write, and the resulting SIGPIPE makes pipefail report the
  # whole pipeline as failed even when commits genuinely exist. rev-list
  # --count has no such pipe to race.
  local commit_count
  commit_count="$(git -C "$worktree_path" rev-list --count "${base_branch}..HEAD" 2>/dev/null || echo 0)"
  if [ "${commit_count:-0}" -eq 0 ] 2>/dev/null; then
    printf 'status=skipped\nreason=no_commits\nlog=%s\n' "$log_file" > "$result_file"
    safe_remove_worktree "$repo_path" "$worktree_path" "$branch"
    return 0
  fi

  if ! git -C "$worktree_path" push -u origin "$branch" >>"$log_file" 2>&1; then
    printf 'status=skipped\nreason=push_failed\nlog=%s\n' "$log_file" > "$result_file"
    safe_remove_worktree "$repo_path" "$worktree_path" "$branch"
    return 0
  fi

  local pr_url
  pr_url="$(gh pr create --title "auto: ${task_text}" \
    --body "Automated by MyPod. Task: ${task_text}" \
    --base "$base_branch" --head "$branch" 2>>"$log_file")"

  if [ -z "$pr_url" ]; then
    printf 'status=skipped\nreason=pr_create_failed\nlog=%s\n' "$log_file" > "$result_file"
    safe_remove_worktree "$repo_path" "$worktree_path" "$branch"
    return 0
  fi

  printf 'status=done\npr_url=%s\n' "$pr_url" > "$result_file"
  safe_remove_worktree "$repo_path" "$worktree_path" "$branch"
}

run_task "$@"
