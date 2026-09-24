# Local Observer

Native macOS menu-bar + dashboard app to see every local server running on your Mac, where it lives, and stop / start it.

UI follows the light minimal dashboard reference: white cards on `#F2F2F5`, small uppercase headers, purple accent, dotted/strip charts, gauge, dense data table.

## Features

- **Live scan** of listening TCP ports via `lsof` (no sudo needed for your own processes)
- **Enrichment**: PID → `ps` command, cwd via `lsof -p`, project guess (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Dockerfile`…), HTTP probe (status code, latency, `<title>`)
- **Dashboard**: Active servers, port mix, response health, ports/latency map, service-type breakdown + online gauge
- **Table**: search, type filter, favorites-only, show-system toggle, double-click to open, copy URL, reveal in Finder, stop (SIGTERM) + force (SIGKILL)
- **Start new**: `New server` sheet with **drag & drop a folder** → auto-suggests `npm run dev` / `python -m http.server` etc., runs detached, saved across restarts
- **Menu bar extra** (the battery-percentage bar): `⌁ N` icon with count, top servers, Open / Stop, refresh

## Run

```bash
swift run
```

Needs only Command Line Tools (no full Xcode). macOS 14+.

## How detection works

1. `lsof -iTCP -sTCP:LISTEN -P -n -F pcn` → pid / process / `host:port`
2. `ps -o pid=,args=` → full command
3. `lsof -p <pid> -Fn` → `fcwd` → working directory
4. Walk up ≤5 dirs for project markers → name + type
5. `URLSession` GET `http://127.0.0.1:port` (1.5s timeout) → online / status / ms / title

Refreshes every 4s (toggleable). Stopping sends SIGTERM, then suggests Force (SIGKILL) if still alive.

## Project layout

```
Package.swift
Sources/LocalObserver/
  LocalObserverApp.swift   # WindowGroup + MenuBarExtra
  Core/
    Models.swift           # ServerEntry, ProjectType
    Scanner.swift          # lsof/ps/cwd/project/HTTP probe
    ProcessManager.swift   # kill / launch / open / reveal
    AppState.swift         # store, filter, favorites, managed (UserDefaults)
  Views/
    Theme.swift            # colors, .card(), pills, dots
    Charts.swift           # Sparkline, MiniBars, DottedStrip, Gauge
    StatCards.swift        # top + middle rows
    ServerTable.swift      # main table + actions
    ContentView.swift      # sidebar + header + layout
    AddServerSheet.swift   # new server + folder drop
    MenuBarView.swift      # menu bar dropdown
```

## Next ideas

- Per-process CPU/RSS in table (via `ps -o %cpu,rss`)
- Request log / traffic sparkline per port
- `sudo` helper for root-owned listeners
- Launch-at-login + global hotkey
- Export table as CSV
