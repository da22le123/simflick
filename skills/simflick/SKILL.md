---
name: simflick
description: Drive or test an iOS simulator app fast with simflick (tap, type, swipe, run a plain-English goal with a step plan). Use when asked to test, check, demo or reproduce something in an app on the iOS simulator.
---

# simflick

simflick reads the app's screen from inside the app (~25 ms) and acts in it (tap ~75 ms, typing ~0.8 s).
`simflick run` drives a goal with a fast decision model; you plan, it executes, you verify.

## Setup (already done on this Mac)

- Keys: `~/.config/simflick/env` (mode 600) is loaded automatically. Never print it, never pass keys on the command line.
- Accounts for apps under test: `~/.config/simflick/accounts/*.env` (mode 600), e.g. `dex-dev-demo.env`
  (`DEX_DEMO_USERNAME`, `DEX_DEMO_EMAIL`, `DEX_DEMO_PASSWORD`; Dex dev backend). Source it in the same shell
  command that uses it; don't echo the password.
- **App notes live in the app's repo: `.simflick/README.md`** (e.g. dex-mobile): bundle id, port, where the test
  account is, and a map of the app's screens. Read it before anything else; it's linked from the repo's CLAUDE.md.
- Sims: `xcrun simctl list devices booted`. Address sims by UDID, never `booted`.

## Commands

```bash
simflick launch <bundle-id> --udid <UDID> --port <port>   # inject + launch (Dex: cards.dex.app, port 8771)
simflick screen                                          # numbered elements, scroll areas, page text
simflick tap <n|testID|x,y>    simflick type "text"    simflick swipe x1,y1 x2,y2 [--fling]
simflick run "<goal>" --steps "step 1; step 2; swipe right ×2; step 4" --shot
```

## Writing a run

- **Always pass `--steps`.** The decision model picks one action at a time; it does not keep a plan or count.
  Steps run in order; `×N` steps with a swipe/tap are counted by code; the run ends when the last step is ticked.
- Put typed values in quotes inside the step: `type 'Hola' into card 1 back`.
- Name the route when you know the app (from its code): `open Materials; open the folder 'German'; ...`.
  The model doesn't know where things live; a screen that merely mentions the word will attract it.
- Start from a clean state (a fresh practice session, an empty search history) or the run will see leftovers.
- Block what must never be tapped: `--never "Delete account,Sign out"`.

## Verify, don't trust DONE

The run's DONE is a claim. Check the end state yourself: the `--shot` screenshot (Read it), plus
`simflick screen` for the facts (a counter, a label, a value). Report what you checked.

## When it goes wrong

- The trace in `~/.simflick/runs/<time>.json` has, per step, what the model saw (`seen.elements`,
  `seen.page_text`) and its top choices with probabilities. Read it before guessing.
- `UNREADABLE: content from another process` = a share sheet / Safari sheet; simflick can't read it.
- "did not answer in 10 s; X is in front" = the app went to the background (e.g. it opened Settings).
