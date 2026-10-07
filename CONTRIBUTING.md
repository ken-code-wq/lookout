# Contributing to Lookout

Thanks for helping. Lookout is a native macOS app written in Swift and SwiftUI, built with SwiftPM. Only the Xcode Command Line Tools are needed.

## Set up

```bash
git clone https://github.com/ken-code-wq/lookout.git
cd lookout
swift run LocalObserver              # run a debug build
swift run LocalObserverVerification  # parsing and core checks
./packaging/build-app.sh             # build Lookout.app (release)
```

For widgets and privacy permissions that survive rebuilds, create a local signing identity once with `packaging/make-signing-cert.sh`.

The user-facing name is **Lookout**. The module, bundle ID and path names still say `LocalObserver` on purpose, so don't rename them.

## Layout

- `Sources/LocalObserver`: the app (notch, Peek, menu bar, dashboard)
- `Sources/LocalObserverCore`: agent readers, usage ledger, limits
- `Sources/LocalObserverServices`, `…Repos`, `…Disk`, `…Env`, `…Shelf`: one module per area
- `Sources/LocalObserverHooks`, `LookoutHook`: live hooks for agent approvals and replies
- `Sources/LookoutCLI`: the `lookout` command
- `Sources/LocalObserverVerification`: checks that run with `swift run LocalObserverVerification`
- `packaging/`: app bundle, signing, notarization and release scripts

## Making a change

1. Open an issue first for anything big, so we can agree on the shape.
2. Branch from `main` (`feat/…` or `fix/…`) and keep each pull request to one change.
3. Match the surrounding code: naming, comment density, idiom.
4. Add a check to `LocalObserverVerification` when you touch parsing, usage or hook logic, and make sure `swift run LocalObserverVerification` passes.
5. Keep it light. Lookout sits in the notch all day, so avoid `repeatForever` animations, tight polling and full rescans. Scans should be incremental.
6. Keep it local. No analytics or phone-home calls. Network requests must be opt-in and go only to the provider the user already uses.

## Adding a coding agent

Add a reader in `LocalObserverCore` that parses the agent's local session files into the shared session model, register it with the other readers, and add a verification check with a small sample transcript. Use made-up data in samples, never real transcripts.

## Screenshots

README screenshots come from demo data, so no real projects or spend appear:

```bash
LOCAL_OBSERVER_SNAPSHOT_DEMO=1 LOCAL_OBSERVER_SNAPSHOT_DIR=/tmp/shots .build/debug/LocalObserver
```

## Pull requests

Describe what changed and why, and include a screenshot for UI changes. Check your diff for personal paths, emails and tokens before pushing.

By contributing, you agree your work is released under the [MIT license](LICENSE).
