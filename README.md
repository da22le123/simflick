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

## Usage

```sh
./build.sh
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$PWD/build/simflick.dylib \
  xcrun simctl launch --terminate-running-process <udid> <bundle-id>
curl localhost:8765/screen            # or: python3 scripts/screen.py
curl "localhost:8765/tap?x=220&y=670"
```

`SIMCTL_CHILD_SIMFLICK_PORT=<port>` picks another port (one per simulator).

## Status

Prototype. Typing still goes through `axe type`. Next: a CLI, settle detection, a pre-tap check,
then a Jev-style decision loop. Relies on private UIKit APIs (simulator only); missing selectors
are reported in action responses instead of crashing.
