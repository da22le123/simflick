// Records /screen for fixed app states so a reader change can be diffed: node scripts/golden.mjs <outdir> [app...]
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = process.argv[2] ?? "golden";
const only = process.argv.slice(3);
const udid = process.env.UDID ?? execFileSync("xcrun", ["simctl", "list", "devices", "booted"], { encoding: "utf8" }).match(/[0-9A-F-]{36}/)?.[0];
if (!udid) throw new Error("no booted simulator; set UDID");
const sf = (...a) => execFileSync("simflick", a, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 60000 });
const screen = () => JSON.parse(sf("screen", "--json"));
const find = (re) => {
  const e = screen().elements.find((x) => re.test(x.label) || re.test(x.id));
  if (!e) throw new Error(`no element matching ${re}`);
  return e;
};
const tap = (re) => sf("tap", find(re).tap.join(","));

// Each step acts, then the settled screen is saved as <app>-<n>-<name>.json.
const apps = {
  demo: { bundle: "dev.simflick.demo", port: 8770, steps: [
    ["home", () => {}],
    ["carousel-scrolled", () => sf("scroll", "S1", "right")],
    ["list-scrolled", () => sf("scroll", "S0", "down")],
    ["settings", () => tap(/^Settings$/)],
  ] },
  wikipedia: { bundle: "org.wikimedia.wikipedia", port: 8769, steps: [
    ["search-tab", () => { for (let i = 0; i < 4 && screen().elements.some((e) => e.id === "BackButton"); i++) tap(/^BackButton$/); tap(/^Search$/); }],
    ["results", () => { tap(/Search Field/); sf("type", "Riga"); }],
    ["article", () => tap(/Capital and largest city of Latvia/)],
    ["saved", () => { tap(/^Back$/); tap(/^Saved$/); }],
  ] },
  icecubes: { bundle: "com.example.IceCubesApp", port: 8768, steps: [
    ["explore", () => tap(/^Explore$/)],
    ["trending", () => tap(/^Trending Posts$/)],
    ["post", () => sf("tap", screen().elements.find((e) => e.kind === "row").tap.join(","))],
  ] },
  dex: { bundle: "cards.dex.app", port: 8771, steps: [["home", () => {
    for (let i = 0; i < 90 && !screen().elements.some((e) => e.id.startsWith("home-")); i++) execFileSync("sleep", ["1"]);
  }]] },
};

mkdirSync(out, { recursive: true });
for (const [name, app] of Object.entries(apps)) {
  if (only.length && !only.includes(name)) continue;
  try { execFileSync("xcrun", ["simctl", "terminate", udid, app.bundle], { stdio: "ignore" }); } catch {}
  sf("launch", app.bundle, "--udid", udid, "--port", String(app.port));
  app.steps.forEach(([step, act], i) => {
    try { act(); sf("wait"); } catch (e) { console.error(`${name}/${step}: ${e.message.split("\n")[0]}`); }
    const sc = screen();
    delete sc.ms;
    writeFileSync(join(out, `${name}-${i}-${step}.json`), JSON.stringify(sc, null, 1));
    writeFileSync(join(out, `${name}-${i}-${step}.txt`), sf("screen"));
    console.log(`${name}/${step}: ${sc.elements.length} elements`);
  });
}
