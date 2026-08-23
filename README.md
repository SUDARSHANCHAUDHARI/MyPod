# MyPod

By [Sudarshan Chaudhari](https://github.com/SUDARSHANCHAUDHARI) — SudarshanTechLabs

Internal tool for running multiple Claude Code autonomous tasks in parallel, each in its own isolated git worktree.

## Table of Contents

- [Why](#why)
- [Status](#status)
- [Usage](#usage)
- [Scope (deliberately smaller than Orca)](#scope-deliberately-smaller-than-orca)
- [Portability notes](#portability-notes)
- [Testing](#testing)
- [License](#license)
- [About](#about)

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

---

## About

I'm Sudarshan Chaudhari, a Senior Quality Engineer, Test Automation specialist, and AI systems builder based in Bangkok, Thailand.

I have 13+ years of experience in software quality engineering, working across SaaS, fintech, gaming, web, mobile, cloud, and digital signage platforms. My background combines hands-on test automation with QA leadership, test strategy, CI/CD, release quality, production investigation, and cross-platform validation.

Alongside my professional QA career, I run [SudarshanTechLabs](https://sudarshantechlabs.com/), my independent engineering and product lab where I design, build, test, and ship software across Android, web, AI, cybersecurity, developer tooling, and cross-platform applications.

### What I work on

- ⚙️ **Quality Engineering & Test Automation** — Playwright, Selenium, Cypress, Appium, API testing, automation frameworks, end-to-end testing, CI/CD, release gates, GitHub Actions, risk-based testing, and production validation
- 🤖 **AI Systems & Automation** — AI agents, multi-agent orchestration, MCP servers, AI-assisted QA, prompt tooling, developer workflows, automation systems, and Claude Code plugins
- 📱 **Mobile & Cross-Platform Applications** — Android applications built with Kotlin and Jetpack Compose, Google Play releases, automated build and publishing pipelines, and cross-platform development spanning iOS, web, Windows, and macOS
- 🌐 **Web Applications & Platforms** — Full-stack applications using Next.js, TypeScript, Firebase, Cloudflare, REST APIs, and modern web infrastructure
- 🛠️ **Developer Tooling & CLI Engineering** — Rust, Python, TypeScript, CLI utilities, multi-repository tooling, build automation, release tooling, and engineering productivity systems
- 🛡️ **Cybersecurity & Observability** — Threat detection, log analysis, security auditing, vulnerability assessment, monitoring, and security-focused developer tools
- 📺 **Digital Signage & Device Platforms** — Content validation, playback testing, device compatibility, production investigation, monitoring, and QA across diverse hardware and operating-system environments

My work sits at the intersection of quality engineering, automation, AI, and software development. I approach products with a QA mindset from the beginning: understanding failure modes, designing for testability, automating repetitive work, and building release confidence into the engineering process.

Through SudarshanTechLabs, I also build products and tools from idea to production, covering architecture, development, testing, CI/CD, release automation, monitoring, and ongoing maintenance.

🌐 [sudarshantechlabs.com](https://sudarshantechlabs.com/) · 💼 [LinkedIn](https://linkedin.com/in/sudarshan-chaudhari) · 🐙 [GitHub](https://github.com/SUDARSHANCHAUDHARI) · ✉️ [sunny.sudarshan@gmail.com](mailto:sunny.sudarshan@gmail.com)
