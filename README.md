# simflick

Fast UI driving for iOS simulator apps, built for AI agents (in the spirit of
[jev-ultrafast](https://github.com/browser-use/jev-ultrafast), but for the iOS simulator).

A small Objective-C library is injected into the app at launch. It serves, over localhost:

- `GET /screen`: only what is actually on screen (visible, not covered, not clipped), with true
  screen coordinates, a tap point per element, visible text, scroll areas with "more" directions,
  and the keyboard state. ~25 ms.
- `GET /tap?x=&y=`: an in-process touch (UITouch + IOHIDEvent, KIF-style). ~75 ms.
- `GET /swipe?x1=&y1=&x2=&y2=&ms=`: a controlled drag that holds before lifting, so lists don't fling.

AXe (the out-of-process alternative) takes 0.4–2 s per screen read and ~1.3 s per tap.

## CLI

```sh
npm install && npm run build        # builds the dylib + the CLI
node dist/cli.js launch <bundle-id> [--udid U] [--port P]
node dist/cli.js screen               # numbered table; numbers work with tap
node dist/cli.js tap 7 --screen       # or a testID, or x,y
node dist/cli.js scroll S0 down
node dist/cli.js type "hello"         # refuses unless a text field is focused
node dist/cli.js run "<goal>" --shot  # decision loop (needs TYPESAFE_API_KEY in .env); trace + end screenshot
```

`run` writes `~/.simflick/runs/<time>.json`: per step the action and what was on screen (`--full-trace` keeps
the whole screen per step; the final entry always does). `--shot` adds an end-state PNG.

Every action re-checks its target on a fresh read, then waits for the screen to change and settle
(nothing animating, two identical reads). Element numbers refer to the last `screen` output.

## Raw HTTP

```sh
./build.sh
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$PWD/build/simflick.dylib \
  xcrun simctl launch --terminate-running-process <udid> <bundle-id>
curl localhost:8765/screen            # or: python3 scripts/screen.py
curl "localhost:8765/tap?x=220&y=670"
```

`SIMCTL_CHILD_SIMFLICK_PORT=<port>` picks another port (one per simulator).

## Status

Prototype. Typing still goes through `axe type`. Next: gesture-only surfaces (e.g. swipeable cards)
as elements, then a Jev-style decision loop. Relies on private UIKit APIs (simulator only); missing selectors
are reported in action responses instead of crashing.
