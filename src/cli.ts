#!/usr/bin/env node
// simflick CLI: launch an app with the injected library, read the screen, act on it, or run a goal.
import {
  El, Screen, SimflickError, bootedUdid, describe, get, keyOf, lastScreen, launch, loadSession,
  save, scrollArea, settled, swipe, tapElement, tapPoint, typeText,
} from "./core.js";
import { run } from "./run.js";

const USAGE = `usage: simflick <command>
  launch <bundle-id> [--udid U] [--port P] [--lang de]   inject + launch, wait until it answers
  screen [--json]                            what's on screen now (numbers usable by tap)
  tap <n|testID|x,y> [--screen]              tap an element from the last screen
  scroll <S0|testID> <up|down|left|right>    controlled drag inside a scroll area [--amount 0.6]
  swipe x1,y1 x2,y2 [--ms 300] [--fling]     raw drag
  type "text"                                type into the focused field (via axe for now)
  wait                                       wait until the screen stops changing
  run "<goal>" [--max-steps 60]              let the decision model drive until DONE/BLOCKED
      [--shot] [--full-trace]                end-state screenshot; full screen per step in the trace
      [--never "Follow,Like,Post"]           labels the agent may never tap
Every action waits for the screen to settle; --screen prints it afterwards.`;

function args() {
  const pos: string[] = [];
  const flags: Record<string, string | true> = {};
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { pos.push(a); continue; }
    const [k, v] = a.slice(2).split("=", 2);
    const next = argv[i + 1];
    flags[k] = v ?? (next && !next.startsWith("--") && ["udid", "port", "ms", "amount", "max-steps", "never"].includes(k) ? (i++, next) : true);
  }
  return { pos, flags };
}

function print(sc: Screen) {
  console.log(sc.keyboard.open ? `keyboard: open, covers y>=${sc.keyboard.frame?.[1]}, editing #${sc.keyboard.focused ?? "?"} (return=${sc.keyboard.returnKey ?? "?"})` : "keyboard: closed");
  sc.elements.forEach((e, i) => {
    const bits = [`[${i + 1}]`, e.kind.padEnd(7), JSON.stringify(e.label), e.id ? `#${e.id}` : "", `@${e.tap.join(",")}`];
    if (e.in) bits.push(`in ${e.in}`);
    if (e.value !== undefined) bits.push(`value=${JSON.stringify(e.value)}`);
    if (e.clipped) bits.push("(partly visible)");
    if (e.selected) bits.push("(selected)");
    if (e.gestures?.length) bits.push(`(${e.gestures.join(", ")})`);
    if (e.system) bits.push("[iOS system alert]");
    if (e.context) bits.push(`— ${e.context}`);
    console.log(bits.filter(Boolean).join(" "));
  });
  for (const r of sc.scrolls) {
    console.log(`${r.ref} scroll ${r.id ? "#" + r.id : ""} more: ${r.more.join("/") || "none"}, ${r.hiddenItems} items out of view`);
    for (const x of (r.ahead ?? []).slice(0, 6)) console.log(`   ${x.dir}: ${x.what}`);
  }
  for (const r of sc.remote ?? []) console.log(`UNREADABLE: content from another process (${r.host}) covers ${r.frame.join(",")}; only a screenshot shows it`);
  if (sc.text.length) console.log(`text: ${sc.text.join(" | ")}`);
}

async function main() {
  const { pos, flags } = args();
  const [cmd, ...rest] = pos;
  const udid = typeof flags.udid === "string" ? flags.udid : undefined;
  if (cmd === "launch") {
    if (!rest[0]) throw new SimflickError("usage: simflick launch <bundle-id> [--udid U] [--port P] [--lang de]");
    const s = await launch(rest[0], udid ?? bootedUdid(), Number(flags.port ?? 8765), flags.lang as string | undefined);
    console.log(`launched ${s.bundleId} on ${s.udid}, port ${s.port}`);
    return;
  }
  if (!["screen", "tap", "scroll", "swipe", "type", "wait", "run"].includes(cmd)) {
    console.log(USAGE);
    process.exit(cmd && cmd !== "help" ? 1 : 0);
  }
  const s = loadSession(udid);
  let sc: Screen | undefined;
  if (cmd === "screen") {
    sc = await settled(s);
    save(s, sc);
    flags.json ? console.log(JSON.stringify(sc)) : print(sc);
    return;
  } else if (cmd === "tap") {
    const spec = rest[0] ?? "";
    if (/^\d+(\.\d+)?,\d+(\.\d+)?$/.test(spec)) {
      const [x, y] = spec.split(",").map(Number);
      sc = await tapPoint(s, x, y);
      console.log(`tapped ${x},${y}`);
    } else {
      let want: El | undefined = /^\d+$/.test(spec) ? lastScreen(s)?.elements[Number(spec) - 1] : (await settled(s)).elements.find((e) => e.id === spec);
      if (!want) throw new SimflickError(spec ? `no element ${spec} on screen; run \`simflick screen\`` : "usage: simflick tap <n|testID|x,y>", 2);
      sc = await tapElement(s, want);
      console.log(`tapped ${describe(want)}`);
    }
  } else if (cmd === "scroll") {
    const [ref, dir] = rest;
    if (!ref || !dir) throw new SimflickError("usage: simflick scroll <S0|testID> <up|down|left|right> [--amount 0.6]");
    sc = await scrollArea(s, ref, dir, Number(flags.amount ?? 0.6), Number(flags.ms ?? 300));
    console.log(`scrolled ${ref} ${dir}`);
  } else if (cmd === "swipe") {
    const [a, b] = rest;
    if (!a?.includes(",") || !b?.includes(",")) throw new SimflickError("usage: simflick swipe x1,y1 x2,y2 [--ms 300] [--fling]");
    const [x1, y1] = a.split(",").map(Number), [x2, y2] = b.split(",").map(Number);
    sc = await swipe(s, x1, y1, x2, y2, Number(flags.ms ?? 300), !!flags.fling);
    console.log(`swiped ${a} -> ${b}`);
  } else if (cmd === "type") {
    const text = rest.join(" ");
    if (!text) throw new SimflickError('usage: simflick type "text"');
    const r = await typeText(s, text);
    sc = r.screen;
    console.log(`typed ${JSON.stringify(text)} -> field holds ${JSON.stringify(r.value)}`);
  } else if (cmd === "wait") {
    sc = await settled(s, keyOf(await get<Screen>(s, "/screen")));
    save(s, sc);
    console.log("settled");
  } else if (cmd === "run") {
    const goal = rest.join(" ");
    if (!goal) throw new SimflickError('usage: simflick run "<goal>" [--max-steps 60]');
    const never = typeof flags.never === "string" ? flags.never.split(",") : undefined;
    const result = await run(s, goal, { maxSteps: Number(flags["max-steps"] ?? 60), fullTrace: !!flags["full-trace"], shot: !!flags.shot, never });
    process.exit(result === "done" ? 0 : 4);
  }
  if (flags.screen && sc) print(sc);
}

main().catch((e) => {
  console.error(`simflick: ${e instanceof Error ? e.message : e}`);
  process.exit(e instanceof SimflickError ? e.code : 1);
});
