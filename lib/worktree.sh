# lib/worktree.sh — safe git worktree create/remove.
#
# Pattern adapted from stablyai/orca (MIT) src/main/git/worktree.ts: create
# with --no-track + push.autoSetupRemote so an agent's first `git push` just
# works, and never destroy a worktree/branch that might hold real agent work.
#
# Meant to be `source`d, not executed — no `set` calls here so the caller's
# shell options (e.g. mypod.sh deliberately runs without -e) aren't clobbered.

# safe_add_worktree <repo_path> <worktree_path> <branch> <base_branch>
# Creates a linked worktree on a new branch off base_branch. Uses --no-track
# so the new branch doesn't inherit base_branch's upstream — otherwise
# `git status` inside the worktree would misreport "behind" against a branch
# the agent hasn't published yet. Then enables push.autoSetupRemote (only if
# unset at every scope) so a plain `git push` from the worktree auto-creates
# origin/<branch> instead of erroring for lack of upstream.
safe_add_worktree() {
  local repo_path="$1" worktree_path="$2" branch="$3" base_branch="$4"

  if ! git -C "$repo_path" worktree add --no-track -b "$branch" "$worktree_path" "$base_branch"; then
    return 1
  fi

  if ! git -C "$worktree_path" config --get push.autoSetupRemote >/dev/null 2>&1; then
    git -C "$worktree_path" config --local push.autoSetupRemote true || true
  fi
  return 0
}

# safe_remove_worktree <repo_path> <worktree_path> <branch>
#
# Refuses to remove a worktree that has uncommitted/untracked changes — leaves
# it on disk and reports why, rather than silently discarding in-progress
# work. Deletes the local branch only with `-d` (git refuses if it has commits
# not merged/pushed), so a branch with real, unpublished work is preserved
# instead of destroyed. `git worktree add` itself is atomic — if creation
# fails, nothing is left to clean up — so there is no "rollback a failed
# create" case that needs a force option here.
safe_remove_worktree() {
  local repo_path="$1" worktree_path="$2" branch="$3"

  if [ ! -d "$worktree_path" ]; then
    return 0
  fi

  if [ -n "$(git -C "$worktree_path" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
    echo "mypod: left worktree in place (uncommitted changes) — needs manual review: $worktree_path" >&2
    return 1
  fi

  if ! git -C "$repo_path" worktree remove "$worktree_path" 2>/dev/null; then
    echo "mypod: warning — could not remove worktree, manual cleanup may be needed: $worktree_path" >&2
    return 1
  fi

  if ! git -C "$repo_path" branch -d "$branch" >/dev/null 2>&1; then
    echo "mypod: kept branch '$branch' — not fully merged (safe default, no data loss)" >&2
  fi
  return 0
}
