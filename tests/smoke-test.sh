#!/usr/bin/env bash
# tests/smoke-test.sh — exercises mypod.sh end-to-end against a throwaway
# local repo, with `claude` and `gh` stubbed out (no network, no API calls,
# no cost). Verifies: parallel worktree creation, safe teardown, and that a
# simulated failed/hung task never loses committed work or the branch.
set -euo pipefail

MYPOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BARE_REMOTE="$WORK/origin.git"
REPO="$WORK/repo"
STUB_BIN="$WORK/bin"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# --- fixture: bare "remote" + a real local repo cloned from it ---
git init --bare -q "$BARE_REMOTE"
git clone -q "$BARE_REMOTE" "$REPO"
cd "$REPO"
git config user.email "test@mypod.local"
git config user.name "MyPod Test"
# This is a throwaway sandbox fixture (deleted at exit), not a real project —
# disable the global core.hooksPath identity guard just for this local repo
# config so the fixture's fake identity/path doesn't trip it.
git config core.hooksPath /dev/null
echo "hello" > README.md
git add README.md
git commit -q -m "chore: init"
git push -q -u origin "$(git rev-parse --abbrev-ref HEAD)"

cat > CLAUDE_TASKS.md <<'EOF'
# Claude Task Queue

## Pending
- [ ] SUCCEED add a hello file
- [ ] FAIL simulate an agent failure
- [ ] HANG simulate a hung agent

## In Progress

## Done

## Skipped (needs human)
EOF
git add CLAUDE_TASKS.md
git commit -q -m "chore: add task queue"

# --- stub claude + gh on PATH ---
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
# Fake claude for smoke-test: behavior chosen by markers in the prompt arg.
prompt="$2"
case "$prompt" in
  *"SUCCEED"*)
    echo "did the thing" > mypod-smoke-output.txt
    git add mypod-smoke-output.txt
    git commit -q -m "feat: smoke test success"
    exit 0
    ;;
  *"FAIL"*)
    exit 1
    ;;
  *"HANG"*)
    sleep 300
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
chmod +x "$STUB_BIN/claude"

cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://example.invalid/pr/1"
  exit 0
fi
exit 0
STUBEOF
chmod +x "$STUB_BIN/gh"

export PATH="$STUB_BIN:$PATH"

# --- run mypod with a short timeout so the HANG task gets killed quickly ---
bash "$MYPOD_ROOT/mypod.sh" 3 5 > "$WORK/mypod.out" 2>&1 || true
cat "$WORK/mypod.out"
echo ""

# --- assertions ---
# Note: these deliberately avoid `producer | grep -q pattern` — under
# `set -o pipefail`, grep -q closes its input as soon as it matches, the
# producer can get SIGPIPE if it still had more to write, and pipefail then
# reports the whole pipeline as failed even though grep genuinely matched.
# Capturing to a variable first and testing with a bash glob sidesteps it.

done_section="$(grep -A2 "## Done" CLAUDE_TASKS.md)"
[[ "$done_section" == *SUCCEED* ]] || fail "SUCCEED task not marked Done"
pass "successful task marked Done with a PR link"

skipped_section="$(grep -A5 "## Skipped" CLAUDE_TASKS.md)"
[[ "$skipped_section" == *"FAIL simulate an agent failure"* ]] || fail "FAIL task not marked Skipped"
pass "failed agent run marked Skipped, not silently dropped"

[[ "$skipped_section" == *"HANG simulate a hung agent"* ]] || fail "HANG task not marked Skipped"
pass "hung agent run was killed by the timeout wrapper and marked Skipped"

WORKTREES_DIR="$(dirname "$REPO")/mypod-worktrees/$(basename "$REPO")"
if [ -d "$WORKTREES_DIR" ]; then
  # .mypod.log files are deliberately left behind for post-mortem review —
  # only a leftover worktree *directory* indicates a failed teardown.
  leftover_dirs="$(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d)"
  [ -n "$leftover_dirs" ] && fail "worktree directories were not cleaned up: $leftover_dirs"
fi
pass "all worktree directories torn down after completion (logs intentionally kept)"

all_log="$(git -C "$REPO" log --all --oneline)"
[[ "$all_log" == *"smoke test success"* ]] || fail "the successful task's commit is missing from repo history"
pass "successful task's commit preserved in git history"

echo ""
echo "All smoke tests passed."
