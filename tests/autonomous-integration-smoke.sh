#!/usr/bin/env bash
# tests/autonomous-integration-smoke.sh — verifies `~/.claude/autonomous.sh
# --parallel` correctly delegates to MyPod (not re-testing MyPod's own
# internals, which tests/smoke-test.sh already covers — just the wiring: the
# flag is recognized, args pass through, and mypod.sh actually runs).
set -euo pipefail

AUTONOMOUS_SH="$HOME/.claude/autonomous.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BARE_REMOTE="$WORK/origin.git"
REPO="$WORK/repo"
STUB_BIN="$WORK/bin"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

if [ ! -f "$AUTONOMOUS_SH" ]; then
  fail "$AUTONOMOUS_SH not found — is this being run on the machine where it's installed?"
fi

git init --bare -q "$BARE_REMOTE"
git clone -q "$BARE_REMOTE" "$REPO"
cd "$REPO"
git config user.email "test@mypod.local"
git config user.name "MyPod Test"
git config core.hooksPath /dev/null
echo "hello" > README.md
git add README.md
git commit -q -m "chore: init"
git push -q -u origin "$(git rev-parse --abbrev-ref HEAD)"

cat > CLAUDE_TASKS.md <<'EOF'
# Claude Task Queue

## Pending
- [ ] SUCCEED add a hello file

## In Progress

## Done

## Skipped (needs human)
EOF
git add CLAUDE_TASKS.md
git commit -q -m "chore: add task queue"

mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
echo "did the thing" > mypod-smoke-output.txt
git add mypod-smoke-output.txt
git commit -q -m "feat: smoke test success"
exit 0
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

output="$(bash "$AUTONOMOUS_SH" --parallel 3 10 2>&1)" || true
echo "$output"
echo ""

[[ "$output" == *"MyPod —"* ]] || fail "--parallel did not delegate to mypod.sh (no MyPod banner in output)"
pass "autonomous.sh --parallel delegates to mypod.sh"

done_section="$(grep -A2 "## Done" CLAUDE_TASKS.md)"
[[ "$done_section" == *SUCCEED* ]] || fail "task not processed through the delegated path"
pass "task claimed, run, and resolved through the --parallel path"

echo ""
echo "All autonomous.sh --parallel integration tests passed."
