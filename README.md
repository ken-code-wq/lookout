<p align="center">
  <img src="docs/assets/logo.png" width="128" alt="Lookout logo">
</p>

<h1 align="center">Lookout</h1>

<p align="center">
  A native macOS command center for your coding agents and local dev servers.<br>
  See what every agent is doing, what it costs, how close you are to your plan limits, and what's listening on your ports, all from the notch.
</p>

<p align="center">
  <a href="https://github.com/ken-code-wq/lookout/releases/latest"><b>Download</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="#privacy">Privacy</a>
</p>

<p align="center">
  <img src="docs/assets/screenshots/home-dark.png" width="820" alt="Lookout dashboard">
</p>

## Why

If you run Claude Code, Codex, Cursor and friends side by side, you end up alt-tabbing between terminals to see which agent is waiting on you, guessing how much of your 5-hour window is left, and running `lsof` to find what's on port 3000. Lookout watches all of it locally and puts the answer one glance away.

## Features

**Coding agents**
- Live sessions across **Claude Code, Codex, OpenCode, Antigravity, GitHub Copilot, Cursor, Pi and Qoder**, with state: *Working*, *Needs you*, *Your turn*, *Idle*
- Notifications when an agent needs approval or finishes its turn, and a jump straight to its terminal or editor
- Optional live hooks: answer Claude Code's permission prompts (Allow, Deny, Always allow) from the notch, Peek or the menu bar, and send a quick reply to a session's terminal when it's your turn
- Token usage, request counts and estimated API cost per agent, model and project
- A GitHub-style 12-month activity heatmap, streaks and daily breakdowns
- Plan limits (5-hour sessions, weekly windows, premium requests) with reset times and pace

**Local servers**
- Every listening TCP port with its process, project and working directory
- HTTP health probes with status, latency and page title
- Start, stop and relaunch dev servers; saved launchers survive restarts

**Repos, GitHub and your machine**
- Local repositories with branches, worktrees and pull requests, plus GitHub issues, CI runs, deployments and a contribution graph
- Agent hand-off (push, pull request, worktree cleanup), live diffs and step-by-step session replay
- Databases and Docker containers, `.env` files, server logs with crash detection, and a Disk page that clears build artifacts and caches
- Per-agent spending budgets, smart limit routing, a morning digest and a shareable weekly report
- A ⌘K command palette, plus a `lookout` CLI and `lookout://` links

**Everywhere on your Mac**
- **Notch**: agents, usage, limits, servers, now playing, per-app sound, a shelf for files and clipboard history, a focus timer and keep-awake
- **Peek**: a small floating panel that follows you across Spaces
- **Menu bar** panel and **desktop widgets**

## Screenshots

<table>
  <tr>
    <td><img src="docs/assets/screenshots/notch-expanded.png" alt="Notch: running agents"></td>
    <td><img src="docs/assets/screenshots/notch-limits.png" alt="Notch: plan limits"></td>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/usage-light.png" alt="Usage"></td>
    <td><img src="docs/assets/screenshots/limits-light.png" alt="Plan limits"></td>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/activity-light.png" alt="Agent sessions"></td>
    <td><img src="docs/assets/screenshots/notch-servers.png" alt="Notch: local servers"></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/screenshots/peek-large-dark.png" width="300" alt="Peek panel"></td>
    <td align="center"><img src="docs/assets/screenshots/menubar-light.png" width="300" alt="Menu bar panel"></td>
  </tr>
</table>

<sub>Screenshots use generated demo data.</sub>

## Install

1. Download `Lookout.zip` from the [latest release](https://github.com/ken-code-wq/lookout/releases/latest) and unzip it.
2. Move `Lookout.app` to `/Applications`.
3. Check the release notes: releases marked **notarized** open normally, and you can skip this step. For builds that aren't notarized by Apple, macOS will block the first launch. Clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Lookout.app
   ```

   or right-click the app › **Open** › **Open**.

Requires macOS 14.2 or later on Apple Silicon.

Desktop widgets need a build signed with a real certificate, so they won't appear in a prebuilt release that isn't notarized. Build from source to use them.

Releases with update signing turned on keep themselves current through Sparkle: **Lookout › Check for Updates…**, with automatic checks in Settings › General.

## Automation

Lookout can be driven from scripts, [Raycast](https://www.raycast.com) and Shortcuts.

**Command-line tool.** Settings › Automation › **Install command-line tool** links `lookout` into `/usr/local/bin` (or `~/.local/bin` when that isn't writable, and tells you which).

```bash
lookout status --json          # agents, plan limits, servers and today's usage
lookout agents                 # running sessions and their state
lookout limits                 # every plan-limit window and what's left
lookout open usage             # dashboard, sessions, usage, limits, repos, servers, launchers…
lookout launcher start web     # start, stop or toggle a saved launcher by name
lookout timer 25               # focus timer; `lookout awake toggle` for keep-awake
```

It reads the snapshot Lookout already writes for its desktop widgets, so it's instant and never scans anything itself. Actions go to the app through `lookout://` links.

**Links.** `lookout://open/<page>`, `lookout://launcher/<name>/start|stop|toggle`, `lookout://palette`, `lookout://new-task`, `lookout://weekly-report`, `lookout://keep-awake/on|off|toggle`, `lookout://timer/start/<minutes>`, `lookout://timer/stop`, `lookout://refresh`. Open them from anywhere: `open lookout://open/limits`.

**Raycast.** Make a [script command](https://github.com/raycast/script-commands) that runs `lookout limits` (with `@raycast.mode fullOutput`) or `lookout launcher toggle web` (`@raycast.mode silent`).

**Shortcuts.** Use a **Run Shell Script** action with `lookout status --json` and parse it with **Get Dictionary from Input**, or an **Open URLs** action with a `lookout://` link. Builds packaged with Xcode installed also expose native Shortcuts actions (agents needing attention, plan limit left, launchers, pages, keep-awake, focus timer); Settings › Automation says whether yours has them.

## Build from source

Only the Xcode Command Line Tools are needed.

```bash
git clone https://github.com/ken-code-wq/lookout.git
cd lookout
swift run LocalObserver            # run a debug build
./packaging/build-app.sh           # build Lookout.app (release)
swift run LocalObserverVerification  # parsing and core checks
```

For widgets and stable privacy permissions across rebuilds, create a local signing identity first with `packaging/make-signing-cert.sh`.

To cut a release, `packaging/release.sh` builds, notarizes when a Developer ID is available (`packaging/notarize.sh`), zips, signs the zip for Sparkle and updates `appcast.xml`. It publishes nothing; it prints the upload and push steps. One-time setup is described at the top of each script.

Regenerate the README screenshots from demo data:

```bash
LOCAL_OBSERVER_SNAPSHOT_DEMO=1 LOCAL_OBSERVER_SNAPSHOT_DIR=/tmp/shots .build/debug/LocalObserver
```

## How it works

- **Agents**: Lookout reads the session transcripts each agent already writes locally (for example `~/.claude/projects`, `~/.codex`) incrementally, and matches them to running processes from `ps`.
- **Hooks** (opt-in, Settings › Agents › Live hooks): Lookout adds a `lookout-hook` entry to Claude Code's `settings.json` or Codex's `notify`, which reports events over a local socket in `~/Library/Application Support/LocalObserver/`. If Lookout isn't running, agents ask in their terminal as usual.
- **Servers**: `lsof -iTCP -sTCP:LISTEN` for ports, `ps` and the process cwd for the project, then a short HTTP probe on `127.0.0.1`.
- **Usage history** is kept in a local ledger under `~/Library/Application Support/LocalObserver/`.

## Project history

Every feature is built on its own `feat/*` or `fix/*` branch and merged into `main` with a merge commit, so the history reads as one line per feature. `git log --first-parent main` lists them, and `git log main..feat/<name>` shows what a feature changed.

```mermaid
gitGraph
   commit id: "Menu bar view and servers page"
   commit id: "Coding agent monitoring"
   commit id: "Server and agent filters"
   commit id: "Shelf, notch, peek, widgets"
   commit id: "Dashboard and usage heatmap"
   commit id: "Add Qoder agent"
   commit id: "Fix Qoder reader warning"
   commit id: "Perf lower idle CPU"
   commit id: "Docs open-source release"
   branch feat/worktree-branches
   checkout feat/worktree-branches
   commit id: "Branches and worktrees on agents"
   checkout main
   merge feat/worktree-branches
   branch feat/repos-pillar
   checkout feat/repos-pillar
   commit id: "Repos pillar"
   checkout main
   merge feat/repos-pillar
   branch feat/github-screens
   checkout feat/github-screens
   commit id: "GitHub-style repo and PR screens"
   checkout main
   merge feat/github-screens
   branch feat/disk-cleanup
   checkout feat/disk-cleanup
   commit id: "Disk cleanup"
   checkout main
   merge feat/disk-cleanup
   branch feat/agent-pr-links
   checkout feat/agent-pr-links
   commit id: "Agent PR links"
   checkout main
   merge feat/agent-pr-links
   branch fix/notch-shadow
   checkout fix/notch-shadow
   commit id: "Fix notch shadow after drop-down"
   checkout main
   merge fix/notch-shadow
   branch feat/session-replay
   checkout feat/session-replay
   commit id: "Session replay"
   checkout main
   merge feat/session-replay
   branch feat/agent-handoff
   checkout feat/agent-handoff
   commit id: "Agent hand-off"
   checkout main
   merge feat/agent-handoff
   branch feat/agent-budgets
   checkout feat/agent-budgets
   commit id: "Agent budgets"
   checkout main
   merge feat/agent-budgets
   branch feat/ci-deploys
   checkout feat/ci-deploys
   commit id: "CI & Deploys"
   checkout main
   merge feat/ci-deploys
   branch feat/github-issues-inbox
   checkout feat/github-issues-inbox
   commit id: "Issues and inbox"
   checkout main
   merge feat/github-issues-inbox
   branch feat/pr-review-and-create
   checkout feat/pr-review-and-create
   commit id: "PR review and create"
   checkout main
   merge feat/pr-review-and-create
   branch feat/server-tools
   checkout feat/server-tools
   commit id: "Server tools"
   checkout main
   merge feat/server-tools
   branch feat/command-palette
   checkout feat/command-palette
   commit id: "Command palette"
   checkout main
   merge feat/command-palette
   branch feat/morning-digest
   checkout feat/morning-digest
   commit id: "Morning digest on the dashboard"
   checkout main
   merge feat/morning-digest
   branch feat/github-contributions
   checkout feat/github-contributions
   commit id: "GitHub contribution graph"
   checkout main
   merge feat/github-contributions
   branch fix/notch-shadow-clip
   checkout fix/notch-shadow-clip
   commit id: "Fix notch shadow fade"
   checkout main
   merge fix/notch-shadow-clip
   branch fix/notch-shadow-subtle
   checkout fix/notch-shadow-subtle
   commit id: "Fix lighter notch shadow"
   checkout main
   merge fix/notch-shadow-subtle
   branch feat/agent-live-diff
   checkout feat/agent-live-diff
   commit id: "Live diff per agent"
   checkout main
   merge feat/agent-live-diff
   branch feat/agent-launch
   checkout feat/agent-launch
   commit id: "New agent task"
   checkout main
   merge feat/agent-launch
   branch feat/limit-routing-weekly-report
   checkout feat/limit-routing-weekly-report
   commit id: "Smart limit routing"
   commit id: "Weekly report"
   checkout main
   merge feat/limit-routing-weekly-report
   branch feat/agent-approvals
   checkout feat/agent-approvals
   commit id: "Agent approvals from the notch"
   checkout main
   merge feat/agent-approvals
   branch feat/services-and-env
   checkout feat/services-and-env
   commit id: "Databases and Docker containers"
   commit id: ".env view for servers and repositories"
   checkout main
   merge feat/services-and-env
   branch feat/automation-and-updates
   checkout feat/automation-and-updates
   commit id: "lookout links, CLI, Shortcuts"
   commit id: "Sparkle auto-updates and a release script"
   commit id: "Notarization script and hardened-runtime"
   checkout main
   merge feat/automation-and-updates
   branch feat/server-logs
   checkout feat/server-logs
   commit id: "Server logs and crash detection"
   checkout main
   merge feat/server-logs
   branch fix/agent-reply-delivery
   checkout fix/agent-reply-delivery
   commit id: "Fix quick replies via Claude hooks"
   checkout main
   merge fix/agent-reply-delivery
   commit id: "Release 0.2.0"
```

## Privacy

Everything runs on your Mac. There are no analytics, accounts or servers of ours.

The only network requests are the optional plan-limit checks, which call each provider's own usage endpoint (Anthropic, OpenAI, GitHub, Cursor) with credentials already on your machine. They're off until you enable them per agent in Settings.

Builds that update themselves also fetch `appcast.xml` from this repository on GitHub about once a day to look for a new version. Turn that off in Settings › General › Updates.

Costs are estimates based on public API prices; subscription plans bill differently.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
