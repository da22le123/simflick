#!/usr/bin/env node
// simflick CLI: launch an app with the injected library, read the screen, act on it.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

type El = { kind: string; id: string; label: string; frame: number[]; tap: number[]; in?: string; value?: string; clipped?: boolean };
type Scroll = { ref: string; id: string; frame: number[]; more: string[]; offset: number[]; content: number[]; hiddenItems: number };
type Screen = { screen: number[]; animating: boolean; keyboard: { open: boolean; frame?: number[]; focused?: string; returnKey?: string }; elements: El[]; text: string[]; scrolls: Scroll[]; ms: number };
type Session = { udid: string; port: number; bundleId: string };

const STATE_DIR = join(homedir(), ".simflick");
const DYLIB = join(dirname(fileURLToPath(import.meta.url)), "..", "build", "simflick.dylib");

function die(msg: string, code = 1): never {
  console.error(`simflick: ${msg}`);
  process.exit(code);
}

function args() {
  const pos: string[] = [];
  const flags: Record<string, string | true> = {};
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { pos.push(a); continue; }
    const [k, v] = a.slice(2).split("=", 2);
    const next = argv[i + 1];
    flags[k] = v ?? (next && !next.startsWith("--") && ["udid", "port", "ms", "amount"].includes(k) ? (i++, next) : true);
  }
  return { pos, flags };
}

function bootedUdid(): string {
  const out = JSON.parse(execFileSync("xcrun", ["simctl", "list", "devices", "booted", "-j"], { encoding: "utf8" }));
  const booted = Object.values(out.devices as Record<string, { udid: string }[]>).flat();
  if (booted.length !== 1) die(booted.length ? `${booted.length} simulators booted; pass --udid` : "no booted simulator");
  return booted[0].udid;
}

function sessionFile(udid: string) { return join(STATE_DIR, `${udid}.json`); }

function loadSession(flags: Record<string, string | true>): Session {
  const current = join(STATE_DIR, "current");
  const udid = typeof flags.udid === "string" ? flags.udid : existsSync(current) ? readFileSync(current, "utf8").trim() : "";
  if (!udid || !existsSync(sessionFile(udid))) die("no session; run `simflick launch <bundle-id>` first");
  return JSON.parse(readFileSync(sessionFile(udid), "utf8")).session;
}

async function get<T>(s: Session, path: string): Promise<T> {
  const r = await fetch(`http://127.0.0.1:${s.port}${path}`).catch(() => die(`no app listening on port ${s.port}; relaunch with \`simflick launch\``));
  if (!r.ok) die(`${path} -> HTTP ${r.status}`);
  return r.json() as Promise<T>;
}

const keyOf = (sc: Screen) => JSON.stringify([sc.elements, sc.scrolls, sc.keyboard, sc.text]);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// RN reacts a few frames after a touch: first wait for the screen to differ from `before` (or give up),
// then poll until two consecutive reads match with nothing animating. Capped so loops can't hang us.
async function settled(s: Session, before?: string, capMs = 2000): Promise<Screen> {
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

function save(s: Session, screen: Screen) {
  writeFileSync(sessionFile(s.udid), JSON.stringify({ session: s, screen }));
}

function lastScreen(s: Session): Screen | undefined {
  return JSON.parse(readFileSync(sessionFile(s.udid), "utf8")).screen;
}

function print(sc: Screen) {
  const kb = sc.keyboard.open ? `keyboard: open, covers y>=${sc.keyboard.frame?.[1]}, editing #${sc.keyboard.focused ?? "?"} (return=${sc.keyboard.returnKey ?? "?"})` : "keyboard: closed";
  console.log(kb);
  sc.elements.forEach((e, i) => {
    const bits = [`[${i + 1}]`, e.kind.padEnd(7), JSON.stringify(e.label), e.id ? `#${e.id}` : "", `@${e.tap.join(",")}`];
    if (e.in) bits.push(`in ${e.in}`);
    if (e.value !== undefined) bits.push(`value=${JSON.stringify(e.value)}`);
    if (e.clipped) bits.push("(partly visible)");
    console.log(bits.filter(Boolean).join(" "));
  });
  for (const r of sc.scrolls) console.log(`${r.ref} scroll ${r.id ? "#" + r.id : ""} more: ${r.more.join("/") || "none"}, ${r.hiddenItems} items out of view`);
  if (sc.text.length) console.log(`text: ${sc.text.join(" | ")}`);
}

// Resolve "7" (ref from last screen), "testID", or "x,y" against a FRESH read; refuse if the target is gone.
async function target(s: Session, spec: string): Promise<{ x: number; y: number; what: string; before?: string }> {
  if (/^\d+(\.\d+)?,\d+(\.\d+)?$/.test(spec)) { const [x, y] = spec.split(",").map(Number); return { x, y, what: spec, before: keyOf(await get<Screen>(s, "/screen")) }; }
  let want: El | undefined;
  if (/^\d+$/.test(spec)) {
    want = lastScreen(s)?.elements[Number(spec) - 1];
    if (!want) die(`no element ${spec} in the last screen; run \`simflick screen\``);
  }
  const fresh = await settled(s);
  const match = want
    ? fresh.elements.find((e) => e.id === want!.id && e.label === want!.label && e.kind === want!.kind)
    : fresh.elements.find((e) => e.id === spec);
  if (!match) die(`target ${spec} is not on screen any more; run \`simflick screen\``, 2);
  return { before: keyOf(fresh), x: match.tap[0], y: match.tap[1], what: `${match.kind} ${JSON.stringify(match.label)}${match.id ? " #" + match.id : ""}` };
}

async function after(s: Session, flags: Record<string, string | true>, before?: string) {
  const sc = await settled(s, before);
  save(s, sc);
  if (flags.screen) print(sc);
}

async function main() {
  const { pos, flags } = args();
  const [cmd, ...rest] = pos;
  if (cmd === "launch") {
    const bundleId = rest[0] ?? die("usage: simflick launch <bundle-id> [--udid U] [--port P]");
    const udid = typeof flags.udid === "string" ? flags.udid : bootedUdid();
    const port = Number(flags.port ?? 8765);
    if (!existsSync(DYLIB)) die(`missing ${DYLIB}; run ./build.sh`);
    execFileSync("xcrun", ["simctl", "launch", "--terminate-running-process", udid, bundleId], {
      env: { ...process.env, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES: DYLIB, SIMCTL_CHILD_SIMFLICK_PORT: String(port) }, stdio: "ignore",
    });
    mkdirSync(STATE_DIR, { recursive: true });
    const s: Session = { udid, port, bundleId };
    for (let i = 0; i < 150; i++) {
      const ok = await fetch(`http://127.0.0.1:${port}/screen`).then((r) => r.ok, () => false);
      if (ok) { writeFileSync(join(STATE_DIR, "current"), udid); await after(s, flags); console.log(`launched ${bundleId} on ${udid}, port ${port}`); return; }
      await new Promise((r) => setTimeout(r, 200));
    }
    die("app launched but the library never answered (30 s)");
  }
  if (!["screen", "tap", "scroll", "swipe", "type", "wait"].includes(cmd)) {
    console.log(`usage: simflick <command>
  launch <bundle-id> [--udid U] [--port P]   inject + launch, wait until it answers
  screen [--json]                            what's on screen now (numbers usable by tap)
  tap <n|testID|x,y> [--screen]              tap an element from the last screen
  scroll <S0|testID> <up|down|left|right>    controlled drag inside a scroll area [--amount 0.6]
  swipe x1,y1 x2,y2 [--ms 300] [--fling]     raw drag
  type "text"                                type into the focused field (via axe for now)
  wait                                       wait until the screen stops changing
Every action waits for the screen to settle; --screen prints it afterwards.`);
    process.exit(cmd && cmd !== "help" ? 1 : 0);
  }
  const s = loadSession(flags);
  if (cmd === "screen") {
    const sc = await settled(s);
    save(s, sc);
    flags.json ? console.log(JSON.stringify(sc)) : print(sc);
  } else if (cmd === "tap") {
    const t = await target(s, rest[0] ?? die("usage: simflick tap <n|testID|x,y>"));
    const r = await get<{ ok: boolean; ms: number }>(s, `/tap?x=${t.x}&y=${t.y}`);
    if (!r.ok) die(`tap at ${t.x},${t.y} hit nothing`);
    console.log(`tapped ${t.what} at ${t.x},${t.y}`);
    await after(s, flags, t.before);
  } else if (cmd === "scroll") {
    const [ref, dir] = rest;
    if (!ref || !["up", "down", "left", "right"].includes(dir)) die("usage: simflick scroll <S0|testID> <up|down|left|right> [--amount 0.6]");
    const sc = await settled(s);
    const area = sc.scrolls.find((a) => a.ref === ref || a.id === ref) ?? die(`no scroll area ${ref} on screen`, 2);
    const [x, y, w, h] = area.frame, a = Number(flags.amount ?? 0.6), cx = x + w / 2, cy = y + h / 2;
    // "down" = reveal content below = drag the finger up.
    const d = { down: [0, -1], up: [0, 1], right: [-1, 0], left: [1, 0] }[dir as "up"]!;
    const dx = (d[0] * w * a) / 2, dy = (d[1] * h * a) / 2;
    const before = keyOf(sc);
    await get(s, `/swipe?x1=${cx - dx}&y1=${cy - dy}&x2=${cx + dx}&y2=${cy + dy}&ms=${flags.ms ?? 300}`);
    console.log(`scrolled ${area.ref}${area.id ? " #" + area.id : ""} ${dir}`);
    await after(s, flags, before);
  } else if (cmd === "swipe") {
    const [a, b] = rest;
    if (!a?.includes(",") || !b?.includes(",")) die("usage: simflick swipe x1,y1 x2,y2 [--ms 300] [--fling]");
    const [x1, y1] = a.split(","), [x2, y2] = b.split(",");
    const before = keyOf(await get<Screen>(s, "/screen"));
    await get(s, `/swipe?x1=${x1}&y1=${y1}&x2=${x2}&y2=${y2}&ms=${flags.ms ?? 300}${flags.fling ? "&fling=1" : ""}`);
    console.log(`swiped ${a} -> ${b}`);
    await after(s, flags, before);
  } else if (cmd === "type") {
    const text = rest.join(" ") || die('usage: simflick type "text"');
    const now = await get<Screen>(s, "/screen");
    // Without a focused field, keystrokes hit the app (in RN dev builds "r" reloads, "d" opens the dev menu).
    if (!now.keyboard.focused) die("no text field is focused; tap one first", 2);
    const before = keyOf(now);
    execFileSync("axe", ["type", text, "--udid", s.udid], { stdio: "ignore" });
    console.log(`typed ${JSON.stringify(text)}`);
    await after(s, flags, before);
  } else if (cmd === "wait") {
    await after(s, flags);
    console.log("settled");
  }
}

main();
