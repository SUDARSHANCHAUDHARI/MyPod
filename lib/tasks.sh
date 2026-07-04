# lib/tasks.sh — parse, claim, and resolve tasks in CLAUDE_TASKS.md.
#
# Structural edits (claim / resolve) go through python3, the same approach
# ~/.claude/inbox/inbox-to-tasks.sh already uses — more robust than sed/awk
# against a Markdown file with several similarly-shaped "## " sections.
#
# Meant to be `source`d — no `set` calls here, the caller owns shell options.

MYPOD_LOCK_DIR=".mypod-lock"

# acquire_queue_lock
# Whole-queue lock (mkdir is atomic on POSIX filesystems) so two concurrent
# `mypod.sh` runs against the same repo can't both claim the same pending
# task. Held only for the brief read-and-claim phase, not the run's lifetime.
acquire_queue_lock() {
  local tries=0
  while ! mkdir "$MYPOD_LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      echo "mypod: could not acquire task queue lock ($MYPOD_LOCK_DIR) — another mypod run may be active" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}

release_queue_lock() {
  rmdir "$MYPOD_LOCK_DIR" 2>/dev/null || true
}

# parse_pending_tasks <tasks_file>
# Prints one pending task per line (task text only, checkbox stripped).
# Skips lines containing "[SKIP]" (existing convention — needs a human).
parse_pending_tasks() {
  local tasks_file="$1"
  python3 - "$tasks_file" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

in_pending = False
for line in lines:
    stripped = line.rstrip("\n")
    if stripped.startswith("## "):
        in_pending = (stripped.strip() == "## Pending")
        continue
    if not in_pending:
        continue
    if stripped.startswith("- [ ] "):
        body = stripped[len("- [ ] "):].strip()
        if body and "[SKIP]" not in body:
            print(body)
PYEOF
}

# claim_task <tasks_file> <task_text> <label>
# Moves the exact task line from ## Pending to ## In Progress, tagged with
# the worktree/branch label handling it. Caller must hold the queue lock.
# Returns 1 (no-op) if the line is no longer present verbatim.
claim_task() {
  local tasks_file="$1" task_text="$2" label="$3"
  python3 - "$tasks_file" "$task_text" "$label" <<'PYEOF'
import sys

def insert_after_section(lines, header, new_line):
    idx = None
    for i, line in enumerate(lines):
        if line.rstrip("\n") == header:
            idx = i
            break
    if idx is None:
        return lines + [f"\n{header}\n", new_line]
    pos = idx + 1
    while pos < len(lines) and lines[pos].strip() == "":
        pos += 1
    return lines[:pos] + [new_line] + lines[pos:]

path, task_text, label = sys.argv[1], sys.argv[2], sys.argv[3]
needle = f"- [ ] {task_text}"

with open(path) as f:
    lines = f.readlines()

idx = None
for i, line in enumerate(lines):
    if line.rstrip("\n") == needle:
        idx = i
        break
if idx is None:
    sys.exit(1)

del lines[idx]

claimed_line = f"- [~] {task_text}  <!-- mypod:{label} -->\n"
lines = insert_after_section(lines, "## In Progress", claimed_line)

with open(path, "w") as f:
    f.writelines(lines)
PYEOF
}

# resolve_task <tasks_file> <task_text> <label> <status> <detail>
# Moves the claimed line out of ## In Progress into ## Done (status=done,
# detail=PR URL) or ## Skipped (needs human) (status=skipped, detail=reason).
# Matched by the same mypod:<label> tag claim_task wrote, so a task_text that
# happens to collide with another line is never touched by mistake.
resolve_task() {
  local tasks_file="$1" task_text="$2" label="$3" status="$4" detail="$5"
  python3 - "$tasks_file" "$task_text" "$label" "$status" "$detail" <<'PYEOF'
import sys

def insert_after_section(lines, header, new_line):
    idx = None
    for i, line in enumerate(lines):
        if line.rstrip("\n") == header:
            idx = i
            break
    if idx is None:
        return lines + [f"\n{header}\n", new_line]
    pos = idx + 1
    while pos < len(lines) and lines[pos].strip() == "":
        pos += 1
    return lines[:pos] + [new_line] + lines[pos:]

path, task_text, label, status, detail = sys.argv[1:6]
marker = f"<!-- mypod:{label} -->"

with open(path) as f:
    lines = f.readlines()

idx = None
for i, line in enumerate(lines):
    if line.rstrip("\n").startswith(f"- [~] {task_text}") and marker in line:
        idx = i
        break
if idx is None:
    sys.exit(1)

del lines[idx]

if status == "done":
    resolved_line = f"- [x] {task_text} — PR: {detail}\n"
    target_section = "## Done"
else:
    resolved_line = f"- [ ] {task_text} — skipped: {detail}\n"
    target_section = "## Skipped (needs human)"

lines = insert_after_section(lines, target_section, resolved_line)

with open(path, "w") as f:
    f.writelines(lines)
PYEOF
}
