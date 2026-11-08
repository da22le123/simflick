# simflick

Fast UI driving for iOS simulator apps, built for AI agents (in the spirit of
[jev-ultrafast](https://github.com/browser-use/jev-ultrafast), but for the iOS simulator).

A small Objective-C library is injected into the app at launch. It serves, over localhost:

- `GET /screen`: only what is actually on screen (visible, not covered, not clipped), with true
  screen coordinates, a tap point per element, visible text, scroll areas with "more" directions,
  and the keyboard state. ~25 ms.
- `POST /tap?x=&y=`: an in-process touch (UITouch + IOHIDEvent, KIF-style). ~75 ms.
- `POST /swipe?x1=&y1=&x2=&y2=&ms=`: a controlled drag that holds before lifting, so lists don't fling.

AXe (the out-of-process alternative) takes 0.4–2 s per screen read and ~1.3 s per tap.

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
