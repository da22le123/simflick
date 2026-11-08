// Shared session, screen reading and actions used by both the CLI and the agent loop.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type El = { kind: string; id: string; label: string; frame: number[]; tap: number[]; in?: string; value?: string; clipped?: boolean };
export type Scroll = { ref: string; id: string; frame: number[]; more: string[]; offset: number[]; content: number[]; hiddenItems: number };
export type Screen = { screen: number[]; animating: boolean; keyboard: { open: boolean; frame?: number[]; focused?: string; returnKey?: string }; elements: El[]; text: string[]; scrolls: Scroll[]; ms: number };
export type Session = { udid: string; port: number; bundleId: string };

export class SimflickError extends Error {
  constructor(message: string, public code = 1) { super(message); }
}

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const DYLIB = join(ROOT, "build", "simflick.dylib");
const STATE_DIR = join(homedir(), ".simflick");

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
export const keyOf = (sc: Screen) => JSON.stringify([sc.elements, sc.scrolls, sc.keyboard, sc.text]);
const sessionFile = (udid: string) => join(STATE_DIR, `${udid}.json`);

// Loads KEY=value lines from the package's .env without overriding the real environment.
export function loadEnv() {
  const file = join(ROOT, ".env");
  if (!existsSync(file)) return;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2];
  }
}

export function bootedUdid(): string {
  const out = JSON.parse(execFileSync("xcrun", ["simctl", "list", "devices", "booted", "-j"], { encoding: "utf8" }));
  const booted = Object.values(out.devices as Record<string, { udid: string }[]>).flat();
  if (booted.length !== 1) throw new SimflickError(booted.length ? `${booted.length} simulators booted; pass --udid` : "no booted simulator");
  return booted[0].udid;
}

export function loadSession(udidFlag?: string): Session {
  const current = join(STATE_DIR, "current");
  const udid = udidFlag ?? (existsSync(current) ? readFileSync(current, "utf8").trim() : "");
  if (!udid || !existsSync(sessionFile(udid))) throw new SimflickError("no session; run `simflick launch <bundle-id>` first");
  return JSON.parse(readFileSync(sessionFile(udid), "utf8")).session;
}

export function save(s: Session, screen: Screen) {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(sessionFile(s.udid), JSON.stringify({ session: s, screen }));
}

export function lastScreen(s: Session): Screen | undefined {
  return JSON.parse(readFileSync(sessionFile(s.udid), "utf8")).screen;
}

export async function get<T>(s: Session, path: string): Promise<T> {
  let r: Response;
  try { r = await fetch(`http://127.0.0.1:${s.port}${path}`); }
  catch { throw new SimflickError(`no app listening on port ${s.port}; relaunch with \`simflick launch\``); }
  if (!r.ok) throw new SimflickError(`${path} -> HTTP ${r.status}`);
  return r.json() as Promise<T>;
}

export async function launch(bundleId: string, udid: string, port: number): Promise<Session> {
  if (!existsSync(DYLIB)) throw new SimflickError(`missing ${DYLIB}; run ./build.sh`);
  execFileSync("xcrun", ["simctl", "launch", "--terminate-running-process", udid, bundleId], {
    env: { ...process.env, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES: DYLIB, SIMCTL_CHILD_SIMFLICK_PORT: String(port) }, stdio: "ignore",
  });
  const s: Session = { udid, port, bundleId };
  for (let i = 0; i < 150; i++) {
    if (await fetch(`http://127.0.0.1:${port}/screen`).then((r) => r.ok, () => false)) {
      mkdirSync(STATE_DIR, { recursive: true });
      writeFileSync(join(STATE_DIR, "current"), udid);
      save(s, await settled(s));
      return s;
    }
    await sleep(200);
  }
  throw new SimflickError("app launched but the library never answered (30 s)");
}

// RN reacts a few frames after a touch: first wait for the screen to differ from `before` (or give up),
// then poll until two consecutive reads match with nothing animating. Capped so loops can't hang us.
export async function settled(s: Session, before?: string, capMs = 2000): Promise<Screen> {
  const start = Date.now();
  let cur = await get<Screen>(s, "/screen");
  if (before) while (keyOf(cur) === before && Date.now() - start < 500) { await sleep(30); cur = await get<Screen>(s, "/screen"); }
  let prev = "";
  while (Date.now() - start < capMs) {
    const key = keyOf(cur);
    if (key === prev && !cur.animating) break;
    prev = key;
    await sleep(40);
    cur = await get<Screen>(s, "/screen");
  }
  return cur;
}

export const describe = (e: El) => `${e.kind} ${JSON.stringify(e.label)}${e.id ? " #" + e.id : ""}`;
const sameEl = (a: El, b: El) => a.id === b.id && a.label === b.label && a.kind === b.kind;

// Re-reads the screen and taps the element where it is NOW; refuses if it is gone.
export async function tapElement(s: Session, want: El): Promise<Screen> {
  const fresh = await settled(s);
  const match = fresh.elements.find((e) => sameEl(e, want));
  if (!match) throw new SimflickError(`target ${describe(want)} is not on screen any more`, 2);
  return tapPoint(s, match.tap[0], match.tap[1], keyOf(fresh));
}

export async function tapPoint(s: Session, x: number, y: number, before?: string): Promise<Screen> {
  before ??= keyOf(await get<Screen>(s, "/screen"));
  const r = await get<{ ok: boolean }>(s, `/tap?x=${x}&y=${y}`);
  if (!r.ok) throw new SimflickError(`tap at ${x},${y} hit nothing`);
  const sc = await settled(s, before);
  save(s, sc);
  return sc;
}

// "down" reveals content below, so the finger drags up inside the area.
export async function scrollArea(s: Session, ref: string, dir: string, amount = 0.6, ms = 300): Promise<Screen> {
  const sc = await settled(s);
  const area = sc.scrolls.find((a) => a.ref === ref || a.id === ref);
  if (!area) throw new SimflickError(`no scroll area ${ref} on screen`, 2);
  const d = ({ down: [0, -1], up: [0, 1], right: [-1, 0], left: [1, 0] } as Record<string, number[]>)[dir];
  if (!d) throw new SimflickError(`bad direction ${dir}`);
  const [x, y, w, h] = area.frame, cx = x + w / 2, cy = y + h / 2, dx = (d[0] * w * amount) / 2, dy = (d[1] * h * amount) / 2;
  await get(s, `/swipe?x1=${cx - dx}&y1=${cy - dy}&x2=${cx + dx}&y2=${cy + dy}&ms=${ms}`);
  const out = await settled(s, keyOf(sc));
  save(s, out);
  return out;
}

export async function swipe(s: Session, x1: number, y1: number, x2: number, y2: number, ms = 300, fling = false): Promise<Screen> {
  const before = keyOf(await get<Screen>(s, "/screen"));
  await get(s, `/swipe?x1=${x1}&y1=${y1}&x2=${x2}&y2=${y2}&ms=${ms}${fling ? "&fling=1" : ""}`);
  const sc = await settled(s, before);
  save(s, sc);
  return sc;
}

// Types into the focused field via axe, optionally replacing its contents, then checks what landed.
export async function typeText(s: Session, text: string, replace = false): Promise<{ screen: Screen; value: string }> {
  const now = await get<Screen>(s, "/screen");
  // Without a focused field, keystrokes hit the app (in RN dev builds "r" reloads, "d" opens the dev menu).
  if (!now.keyboard.focused) throw new SimflickError("no text field is focused; tap one first", 2);
  const current = now.elements.find((e) => e.kind === "input" && e.id === now.keyboard.focused)?.value ?? "";
  if (replace && current) execFileSync("axe", ["key-combo", "--modifiers", "227", "--key", "4", "--udid", s.udid], { stdio: "ignore" });
  execFileSync("axe", ["type", text, "--udid", s.udid], { stdio: "ignore" });
  const sc = await settled(s, keyOf(now));
  save(s, sc);
  const value = sc.elements.find((e) => e.kind === "input" && e.id === sc.keyboard.focused)?.value ?? "";
  // Controlled RN inputs can drop keystrokes while JS is busy; report what actually landed.
  if (!value.endsWith(text)) throw new SimflickError(`typed ${JSON.stringify(text)} but the field now holds ${JSON.stringify(value)}`, 3);
  return { screen: sc, value };
}
