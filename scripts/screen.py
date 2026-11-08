# Prints the /screen JSON as a numbered table. Usage: python3 scripts/screen.py [port]
import json, sys, time, urllib.request
t = time.perf_counter(); d = json.load(urllib.request.urlopen("http://127.0.0.1:" + (sys.argv[1] if len(sys.argv) > 1 else "8765") + "/screen")); rt = (time.perf_counter() - t) * 1000
print("KEYBOARD:", d.get("keyboard"))
print(f"walk {d['ms']:.1f} ms · round trip {rt:.1f} ms · {len(d['elements'])} elements · windows {d['windows']}")
for i, e in enumerate(d["elements"], 1):
    extra = (" in " + e["in"] if "in" in e else "") + (" CLIPPED" if e.get("clipped") else "") + (f" value={e['value']!r}" if "value" in e else "")
    print(f"[{i}] {e['kind']:7} {e['label'][:60]!r} #{e['id']} tap@{e['tap'][0]},{e['tap'][1]}{extra}")
for s in d["scrolls"]:
    print(f"{s['ref']} #{s['id']} frame={s['frame']} offset={s['offset']} content={s['content']} more={s['more']} hiddenItems={s['hiddenItems']}")
print("TEXT:", " | ".join(d.get("text", [])))
