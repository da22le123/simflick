// Shared session, screen reading and actions used by both the CLI and the agent loop.
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type El = { kind: string; id: string; label: string; context?: string; selected?: boolean; system?: boolean; frame: number[]; tap: number[]; in?: string; value?: string; clipped?: boolean };
export type Scroll = { ref: string; id: string; frame: number[]; more: string[]; offset: number[]; content: number[]; hiddenItems: number; paging?: boolean; ahead?: { dir: string; what: string }[] };
export type Hidden = { kind: string; id: string; label: string; context?: string; frame: number[]; in: string; dir: string };
export type Screen = { screen: number[]; active?: boolean | number; animating: boolean; loading?: boolean | number; keyboard: { open: boolean; frame?: number[]; focused?: string; returnKey?: string }; elements: El[]; textItems?: { label: string; tap: number[] }[]; hidden?: Hidden[]; remote?: { frame: number[]; host: string }[]; text: string[]; scrolls: Scroll[]; ms: number };
export type Session = { udid: string; port: number; bundleId: string; token: string };

export class SimflickError extends Error {
  constructor(message: string, public code = 1) { super(message); }
}

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const DYLIB = join(ROOT, "build", "simflick.dylib");
const STATE_DIR = join(homedir(), ".simflick");

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
export const keyOf = (sc: Screen) => JSON.stringify([sc.elements, sc.scrolls, sc.keyboard, sc.text]);
const sessionFile = (udid: string) => join(STATE_DIR, `${udid}.json`);

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
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  writeFileSync(sessionFile(s.udid), JSON.stringify({ session: s, screen }), { mode: 0o600 });
  chmodSync(sessionFile(s.udid), 0o600);  // mode is only applied on create; the file holds the launch token
}

export function lastScreen(s: Session): Screen | undefined {
  return JSON.parse(readFileSync(sessionFile(s.udid), "utf8")).screen;
}

// Reads are GET; anything that acts is POST. Every request carries the per-launch token.
export async function get<T>(s: Session, path: string): Promise<T> {
  let r: Response;
  const method = /^\/(screen|debug)\b/.test(path) ? "GET" : "POST";
  try { r = await fetch(`http://127.0.0.1:${s.port}${path}`, { method, headers: { "X-Simflick-Token": s.token } }); }
  catch { throw new SimflickError(`no app listening on port ${s.port}; relaunch with \`simflick launch\``); }
  if (!r.ok) throw new SimflickError(`${path} -> HTTP ${r.status}`);
  return r.json() as Promise<T>;
}

export async function launch(bundleId: string, udid: string, port: number): Promise<Session> {
  if (!existsSync(DYLIB)) throw new SimflickError(`missing ${DYLIB}; run ./build.sh`);
  const token = randomBytes(24).toString("hex");
  execFileSync("xcrun", ["simctl", "launch", "--terminate-running-process", udid, bundleId], {
    env: { ...process.env, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES: DYLIB, SIMCTL_CHILD_SIMFLICK_PORT: String(port), SIMCTL_CHILD_SIMFLICK_TOKEN: token }, stdio: "ignore",
  });
  const s: Session = { udid, port, bundleId, token };
  for (let i = 0; i < 150; i++) {
    if (await fetch(`http://127.0.0.1:${port}/screen`, { headers: { "X-Simflick-Token": token } }).then((r) => r.ok, () => false)) {
      mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
      writeFileSync(join(STATE_DIR, "current"), udid);
      save(s, await settled(s));
      return s;
    }
    await sleep(200);
  }
  throw new SimflickError("app launched but the library never answered (30 s)");
}

// Skeleton placeholders are static, so "nothing changed" isn't "loaded": several unlabelled list items and
// no text on screen at all means content is still arriving.
function looksLikeSkeleton(sc: Screen): boolean {
  const inLists = sc.elements.filter((e) => e.in);
  const blank = inLists.filter((e) => !e.label && !e.context && !e.value).length;
  return sc.text.length === 0 && inLists.length >= 4 && blank / inLists.length >= 0.7;
}

// RN reacts a few frames after a touch: first wait for the screen to differ from `before` (or give up),
// then until nothing changed for `quietMs` (Reanimated moves views without CA animations, and sheets
// often pause ~100 ms before sliding). Capped so looping animations can't hang us.
export async function settled(s: Session, before?: string, capMs = 5500, quietMs = 150): Promise<Screen> {
  const start = Date.now();
  let cur = await get<Screen>(s, "/screen");
  if (before) while (keyOf(cur) === before && Date.now() - start < 500) { await sleep(30); cur = await get<Screen>(s, "/screen"); }
  let prev = keyOf(cur), since = Date.now();
  while (Date.now() - start < capMs) {
    // While a spinner shows, keep waiting (up to 5 s) so the model doesn't judge a half-loaded screen.
    const loadingWait = (cur.loading || looksLikeSkeleton(cur)) && Date.now() - start < 5000;
    if (!cur.animating && !loadingWait && Date.now() - since >= quietMs) break;
    await sleep(35);
    cur = await get<Screen>(s, "/screen");
    const key = keyOf(cur);
    if (key !== prev || cur.animating) { prev = key; since = Date.now(); }
  }
  // The library sends active as 0/1; only an explicit inactive triggers the (slower) system-alert read.
  return cur.active !== undefined && !cur.active ? withSystemAlert(s, cur) : cur;
}

type AxNode = { type?: string; AXLabel?: string; frame?: { x: number; y: number; width: number; height: number }; children?: AxNode[] };

// System alerts (permissions, "Open in…") are drawn by iOS, outside the app, so the injected library can't
// see them; the app just goes inactive. Only then pay for an axe read and expose the alert's buttons.
function withSystemAlert(s: Session, sc: Screen): Screen {
  let tree: AxNode[];
  try { tree = JSON.parse(execFileSync("axe", ["describe-ui", "--udid", s.udid], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })); }
  catch { return sc; }
  const alerts: AxNode[] = [];
  const find = (n: AxNode) => { if (n.type === "Sheet" || n.type === "Alert") alerts.push(n); else (n.children ?? []).forEach(find); };
  tree.forEach(find);
  if (!alerts.length) return sc;
  const buttons: El[] = [], text: string[] = [];
  const walk = (n: AxNode) => {
    const f = n.frame;
    if (n.type === "Button" && f) buttons.push({ kind: "button", id: "", label: n.AXLabel ?? "", system: true,
      frame: [f.x, f.y, f.width, f.height].map(Math.round), tap: [Math.round(f.x + f.width / 2), Math.round(f.y + f.height / 2)] });
    else if (n.AXLabel && !/scroll bar/i.test(n.AXLabel) && !text.includes(n.AXLabel)) text.push(n.AXLabel);
    (n.children ?? []).forEach(walk);
  };
  alerts.forEach(walk);
  // While an alert is up, the app underneath can't be tapped: show only the alert.
  return { ...sc, elements: buttons, hidden: [], scrolls: [], text: [`System alert: ${text.join(" | ")}`] };
}

export const describe = (e: El) => `${e.kind} ${JSON.stringify(e.label)}${e.id ? " #" + e.id : ""}`;
type Ident = { id: string; label: string; kind: string; context?: string };
const sameEl = (a: Ident, b: Ident) => a.id === b.id && a.label === b.label && a.kind === b.kind && (!a.context || !b.context || a.context === b.context);

// Closed loop: swipe toward the item, re-read, repeat until fully visible, then tap. Works for free,
// paging and snapping scroll views alike because every step re-measures; stops if the offset stops moving.
export async function revealAndTap(s: Session, want: Ident): Promise<Screen> {
  let lastOffset = "";
  for (let i = 0; i < 12; i++) {
    const sc = await settled(s);
    const vis = sc.elements.find((e) => sameEl(e, want));
    const hid = vis ? undefined : sc.hidden?.find((e) => sameEl(e, want));
    if (vis && (!vis.clipped || vis.system)) return tapPoint(s, vis.tap[0], vis.tap[1], keyOf(sc), !!vis.system);
    const area = sc.scrolls.find((a) => a.ref === (vis?.in ?? hid?.in));
    if (!area) {
      if (vis) return tapPoint(s, vis.tap[0], vis.tap[1], keyOf(sc));
      throw new SimflickError(`target ${JSON.stringify(want.label)}${want.id ? " #" + want.id : ""} is not on screen any more`, 2);
    }
    const offset = JSON.stringify(area.offset);
    if (offset === lastOffset) {
      if (vis) return tapPoint(s, vis.tap[0], vis.tap[1], keyOf(sc));
      throw new SimflickError(`could not scroll ${JSON.stringify(want.label)} into view`, 2);
    }
    lastOffset = offset;
    const f = (vis ?? hid)!.frame, [x, y, w, h] = area.frame;
    const dx = f[0] + f[2] / 2 - (x + w / 2), dy = f[1] + f[3] / 2 - (y + h / 2);
    const horiz = Math.abs(dx) / w > Math.abs(dy) / h;
    const dist = horiz ? dx : dy, span = horiz ? w : h;
    // Paging views snap a page per swipe regardless of length; free views move by the drag minus touch slop.
    const len = area.paging ? span * 0.6 : Math.min(Math.max(Math.abs(dist) + 12, 40), span * 0.7);
    const d = Math.sign(dist) * len, cx = x + w / 2, cy = y + h / 2;
    const [x1, y1, x2, y2] = horiz ? [cx + d / 2, cy, cx - d / 2, cy] : [cx, cy + d / 2, cx, cy - d / 2];
    await get(s, `/swipe?x1=${x1}&y1=${y1}&x2=${x2}&y2=${y2}&ms=300`);
  }
  throw new SimflickError(`gave up scrolling to ${JSON.stringify(want.label)}`, 2);
}

// Re-reads the screen and taps the element where it is NOW; refuses if it is gone.
export async function tapElement(s: Session, want: El): Promise<Screen> {
  const fresh = await settled(s);
  const match = fresh.elements.find((e) => sameEl(e, want));
  if (!match) throw new SimflickError(`target ${describe(want)} is not on screen any more`, 2);
  return tapPoint(s, match.tap[0], match.tap[1], keyOf(fresh), !!match.system);
}

export let lastTapFellBack = false;

export async function tapPoint(s: Session, x: number, y: number, before?: string, system = false): Promise<Screen> {
  before ??= keyOf(await get<Screen>(s, "/screen"));
  if (system) {
    lastTapFellBack = false;
    execFileSync("axe", ["tap", "-x", String(x), "-y", String(y), "--udid", s.udid], { stdio: "ignore" });
    const sc = await settled(s, before);
    save(s, sc);
    return sc;
  }
  const r = await get<{ ok: boolean }>(s, `/tap?x=${x}&y=${y}`);
  if (!r.ok) throw new SimflickError(`tap at ${x},${y} hit nothing`);
  let sc = await settled(s, before);
  lastTapFellBack = false;
  // Some SwiftUI controls (e.g. buttons inside a ScrollView) ignore the synthetic in-app touch. If nothing
  // changed, repeat the tap as a real system touch via axe (slower, ~1.3 s).
  // Slow actions (network, then an alert) look unchanged at first: give them ~1.2 s before assuming the
  // synthetic touch was ignored, so a working tap is never repeated.
  for (const t0 = Date.now(); keyOf(sc) === before && sc.active !== 0 && sc.active !== false && Date.now() - t0 < 1200; ) {
    await sleep(100);
    sc = await get<Screen>(s, "/screen");
  }
  if (keyOf(sc) === before && sc.active !== 0 && sc.active !== false) {
    try {
      execFileSync("axe", ["tap", "-x", String(Math.round(x)), "-y", String(Math.round(y)), "--udid", s.udid], { stdio: "ignore" });
      sc = await settled(s, before);
      lastTapFellBack = true;
    } catch { /* axe missing: keep the in-app result */ }
  }
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
  // focused can be "" (a field without an id): only undefined means nothing has focus.
  if (now.keyboard.focused === undefined) throw new SimflickError("no text field is focused; tap one first", 2);
  const focusedInput = (sc: Screen) => sc.elements.find((e) => e.kind === "input" && e.id === sc.keyboard.focused);
  const current = focusedInput(now)?.value ?? "";
  if (replace && current) execFileSync("axe", ["key-combo", "--modifiers", "227", "--key", "4", "--udid", s.udid], { stdio: "ignore" });
  execFileSync("axe", ["type", text, "--udid", s.udid], { stdio: "ignore" });
  const sc = await settled(s, keyOf(now));
  save(s, sc);
  const value = focusedInput(sc)?.value ?? "";
  // Controlled RN inputs can drop keystrokes while JS is busy; report what actually landed.
  // iOS may autocapitalise the first letter: a case-only difference still means the text landed.
  if (!value.toLowerCase().endsWith(text.toLowerCase())) throw new SimflickError(`typed ${JSON.stringify(text)} but the field now holds ${JSON.stringify(value)}`, 3);
  return { screen: sc, value };
}
