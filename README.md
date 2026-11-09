# simflick

Fast UI driving for iOS simulator apps, built for AI agents (in the spirit of
[jev-ultrafast](https://github.com/browser-use/jev-ultrafast), but for the iOS simulator).

<a href="docs/demo.mp4"><img src="docs/demo.gif" alt="Claude Code uses simflick to test the Dex app: create a folder and a deck with two cards, practice it (one known, one unknown), reach the completion screen" width="100%" /></a>

## What it is

simflick is a small library that gets injected into an iOS simulator app at launch, wrapped in a CLI. From inside the app it reads what's actually on screen (visible elements, their text and tap points,
scroll areas, popups, web view content) in ~25 ms, and acts on it: taps, swipes and typing go through the app itself, not through the simulator from outside.

On top of that sits a loop: inspect the UI, let a decision model pick the next action, execute it, repeat. By default the model is TypeSafe's Jev (~200 ms per decision), but the loop doesn't care who decides — any model, or an agent like Claude Code calling `simflick screen` / `tap` / `type` itself.

## What you'd use it for

- **Letting a coding agent test what it just built.** Claude Code changes a screen, then runs `simflick run "<what to check>" --steps "<plan>"` and verifies the end state from a screenshot. The agent plans and checks; simflick does the fast clicking.
- **End-to-end checks without writing test scripts.** A goal plus a step list instead of a Maestro YAML file with test ids and waits.
- **Reproducing a bug or reaching a deep screen fast**, e.g. "open the third deck, practice it, swipe two cards left".
- **Demos and screen recordings** of a flow, at real speed.

### How fast

Measured on [Dex](https://dex.cards), my flashcard app: React Native + Expo, live on the App Store,
with its own Maestro suite of 17 end-to-end flows. Same flow for every tool (Profile → Language →
Spanish → check → English → check), same simulator (iPhone 16 Pro, iOS 18.6), app already open on Home:

| Driven by | Time | What it needs |
|---|---:|---|
| **simflick** (`run` + `--steps`) | **10.8 s** | A goal and a step plan in plain English |
| Maestro | 34–38 s per run<br>(~15 s flow + ~23 s driver startup) | A YAML flow with test ids and waits |
| AXe, scripted (no model) | 34–37 s | A script with test ids; each screen read 1–2 s, each tap ~1.3 s |
| Claude Code driving AXe step by step | 68 s | Nothing up front; one model turn per step |

The Claude Code row is a best case: it already knew the test ids and merged two steps.

## Install

```sh
npm install -g github:da22le123/simflick   # private repo: needs GitHub access; builds on install
# or, from a clone (for development):
npm install && npm run build && npm link    # puts `simflick` on PATH, pointing at this checkout
```

Needs Xcode (simulators + clang) and Node ≥ 18. The app must already be installed on the simulator;
`simflick launch` relaunches it with the library injected. Typing uses `axe` for now (`brew install cameroncooke/axe/axe`).

`simflick run` reads its keys from the environment only: `TYPESAFE_API_KEY` (decision model), and for
typing `ANTHROPIC_API_KEY` or `TEXT_MODEL_API_KEY` (+ `TEXT_MODEL_BASE_URL`, `TEXT_MODEL`). Use whatever
you already use for secrets, e.g. `export`, direnv, or `op run -- simflick run "..."`.
Everything else (`screen`, `tap`, `scroll`, `type`) needs no keys.

## CLI

```sh
simflick launch <bundle-id> [--udid U] [--port P]
simflick screen               # numbered table; numbers work with tap
simflick tap 7 --screen       # or a testID, or x,y
simflick scroll S0 down
simflick type "hello"         # refuses unless a text field is focused
simflick run "<goal>" --shot  # decision loop (needs TYPESAFE_API_KEY in .env); trace + end screenshot
```

`run` writes `~/.simflick/runs/<time>.json`: per step the action and what was on screen (`--full-trace` keeps
the whole screen per step; the final entry always does). `--shot` adds an end-state PNG.

Every action re-checks its target on a fresh read, then waits for the screen to change and settle
(nothing animating and no change for 150 ms). Element numbers refer to the last `screen` output.

## Security and caveats

- Simulator only. Touches are synthesized with private UIKit APIs (as KIF does), so an iOS update can
  break them; missing methods are reported instead of crashing the app.
- The injected server listens on `127.0.0.1` and only accepts requests with the per-launch token that
  `simflick launch` generates (kept in `~/.simflick/<udid>.json`, mode 600). Requests from browsers
  (`Origin` header) or with a non-local `Host` are rejected, and actions require `POST`.
- `~/.simflick/runs/` traces contain your app's on-screen text.

## Raw HTTP

```sh
./build.sh
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$PWD/build/simflick.dylib \
  xcrun simctl launch --terminate-running-process <udid> <bundle-id>
T=$(jq -r .session.token ~/.simflick/<udid>.json)
curl -H "X-Simflick-Token: $T" localhost:8765/screen
curl -X POST -H "X-Simflick-Token: $T" "localhost:8765/tap?x=220&y=670"
```

`SIMCTL_CHILD_SIMFLICK_PORT=<port>` picks another port (one per simulator).

## Status

Prototype. Typing still goes through `axe type`. Next: gesture-only surfaces (e.g. swipeable cards)
as elements, then a Jev-style decision loop. Relies on private UIKit APIs (simulator only); missing selectors
are reported in action responses instead of crashing.

## Credits

The goal loop (`simflick run`) is adapted from [jev-ultrafast](https://github.com/browser-use/jev-ultrafast)
(MIT, © 2026 Browser Use); see `NOTICE`. The in-process touch technique follows
[KIF](https://github.com/kif-framework/KIF). simflick is MIT licensed.
