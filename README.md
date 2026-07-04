# MyPod

By [Sudarshan Chaudhari](https://github.com/SUDARSHANCHAUDHARI) — SudarshanTechLabs

Internal tool for running multiple Claude Code autonomous tasks in parallel, each in its own isolated git worktree.

## Why

`autonomous.sh` (the existing Ralph Loop) runs `CLAUDE_TASKS.md` tasks **one at a time**, sequentially, in a single working directory. MyPod extends that to run several tasks **at once**, each in its own git worktree, so independent tasks across the 20+ app portfolio don't have to wait on each other.

Pattern is adapted from [stablyai/orca](https://github.com/stablyai/orca) (MIT) — specifically its worktree-per-parallel-agent lifecycle management: `--no-track` on create, and never force-deleting a branch that might hold real, unpushed work. See [docs/PLAN.html](docs/PLAN.html) for the full writeup (companion `docs/PLAN.md` is kept local-only, not tracked in this repo).

## Status

Built, smoke-tested, and wired into `~/.claude/autonomous.sh` as an opt-in flag.

## Usage

Standalone:
```bash
bash mypod.sh [max-parallel] [timeout-seconds]
```

Or via `autonomous.sh` (delegates entirely to `mypod.sh` — the sequential Ralph Loop stays the default):
```bash
bash ~/.claude/autonomous.sh --parallel [max-parallel] [timeout-seconds]
```

Run from inside the target project's directory (same convention as `autonomous.sh`). Defaults: `max-parallel=3`, `timeout-seconds=1800` (30 min per task).

Reads pending tasks from that project's `CLAUDE_TASKS.md`, drains `~/.claude/inbox/inbox.jsonl` into it first (if present), claims up to `max-parallel` tasks, and for each one:

1. Creates an isolated git worktree on a new `mypod/<slug>-<timestamp>` branch
2. Runs `claude --print` with `MYPOD_TASK_PROMPT.md` + the task text, inside that worktree
3. Verifies there's a real commit, pushes, opens a PR (`gh pr create`)
4. Marks the task `Done` (with the PR link) or `Skipped` (with a reason) in `CLAUDE_TASKS.md`
5. Tears down the worktree — safely: a worktree with uncommitted changes, or a branch with unpushed/unmerged commits, is left in place rather than destroyed

Per-task logs land next to the worktrees dir at `../mypod-worktrees/<project>/<label>.mypod.log` and are kept after teardown for post-mortem review.

## Scope (deliberately smaller than Orca)

GitHub (`gh`) only — no GitLab/Bitbucket/SSH/sparse-checkout, no GUI, no interactive rebase
advisories. See [docs/PLAN.html](docs/PLAN.html) "Complexity Check" for the full list of what was
deliberately left out and why.

## Portability notes

Built and tested against what's actually on this machine, not what the plan assumed:
- No Homebrew Bash — ships with stock Bash 3.2 (macOS default). The concurrency cap is a
  portable `kill -0`-free `wait`-on-explicit-pids approach, not `wait -n` (Bash 4.3+).
- No `timeout`/`gtimeout` available — `lib/run-task.sh` implements its own timeout via a
  process-group kill (`set -m` + negative-PID `kill`), which also reaps any children the agent
  process spawns, not just the top-level process.

## Testing

```bash
bash tests/smoke-test.sh
bash tests/autonomous-integration-smoke.sh
```

`smoke-test.sh` runs mypod.sh against a throwaway local repo with `claude`/`gh` stubbed out (no
network, no API cost) — one task that succeeds, one that fails, one that hangs past the timeout.
Verifies: tasks are claimed/resolved correctly in `CLAUDE_TASKS.md`, worktrees are torn down after
completion, and the successful task's commit survives in git history.

`autonomous-integration-smoke.sh` verifies the `~/.claude/autonomous.sh --parallel` wiring itself —
that the flag is recognized and delegates to `mypod.sh` with a task actually processed end to end.

## License

MIT — see [LICENSE](LICENSE).

## Author

Built by **Sudarshan Chaudhari** — SudarshanTechLabs.
