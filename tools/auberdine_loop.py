r"""Write Wayfinder's Auberdine loop: a closed gathering loop out of Auberdine through Darkshore and back, and a trace of
how the route was calculated, and docs/auberdine_pathing.html, which plays that trace back.

  python tools/auberdine_loop.py

The spots are Darkshore's herbs Chalice can pick and gain from (herbalism 88: Peacebloom 1, Silverleaf 1, Earthroot
15, Mageroyal 50, Briarthorn 70; Stranglekelp, 85, grows underwater and is left out; Bruiseweed needs 100) and
copper veins (mining 15; tin needs 65). Skill requirements: Wowhead classic tooltips, 10 Nov 2026.

Where they come from: her own picks first (Herbalore and Shan'do's notebooks in her saved variables), then the
classic GatherMate2 spawn table (private mod-assets repo), which matched her 8 Darkshore picks within 0.15 map-%.
Spots within MERGE of each other count as one; her own win. The MAX_SPOTS nearest the Auberdine mailbox (37.4, 43.7,
where she used it) make the loop.

The route: a closed tour from the mailbox. Nearest neighbour builds it (always walk to the closest spot not yet
visited, then back home), then 2-opt improves it: for every pair of legs A-B and C-D, if A-C plus B-D is shorter,
reverse the stretch between them (that uncrosses a crossing). Repeat until no swap helps. Distances are in map-%,
with x stretched by ASPECT because Darkshore's map is wider than tall in yards per percent. Every step is recorded.
"""
import json
import math
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = Path(os.environ.get("GATHERMATE_CLASSIC", ROOT.parent / "_mod-assets" / "gathermate_classic"))  # private
GAME = Path(os.environ.get("WOW_FOREVER", r"G:\World of Warcraft\_forever_"))
SAVED = next(iter(sorted((GAME / "WTF" / "Account").glob("*/SavedVariables"))), GAME)  # the account's folder
OUT = ROOT / "runs" / "auberdine.json"
TRACE = ROOT / "docs" / "auberdine_trace.json"
PAGE = ROOT / "docs" / "auberdine_pathing.html"           # from auberdine_pathing.template.html
MAP, ZONE = 1439, "Darkshore"
HOME = (37.4, 43.7)             # the Auberdine mailbox, from Wayfinder's own record of where she used it
ASPECT = 1.5                    # as tools in the market repo (lumber_runs.ASPECT)
MERGE = 1.2                     # map-% within which two spots count as one
MAX_SPOTS = 60
HERBS = {401: "Peacebloom", 402: "Silverleaf", 403: "Earthroot", 404: "Mageroyal", 405: "Briarthorn"}
ORE = {201: "Copper Vein"}
WANT = set(HERBS.values()) | set(ORE.values())


def dist(a, b):
    return math.hypot((a[0] - b[0]) * ASPECT, a[1] - b[1])


def spawns(path, names):
    """{name: [(x, y)]} on MAP from a classic GatherMate2 file (each map's brace on its own line)."""
    out, cur = {}, None
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*\[(\d+)\]\s*=\s*\{?\s*$", line)
        if m:
            cur = int(m.group(1))
            continue
        m = re.match(r"\s*\[(\d+)\]\s*=\s*(\d+),", line)
        if m and cur == MAP and int(m.group(2)) in names:
            c = int(m.group(1))
            out.setdefault(names[int(m.group(2))], []).append(((c // 1000000) / 100, ((c // 100) % 10000) / 100))
    return out


def picks():
    """Her own Darkshore picks: [(x, y, name)] from Herbalore's and Shan'do's notebooks."""
    out = []
    for table, file in (("HerbalorePicks", "Herbalore.lua"), ("ShandoHerbPicks", "Shando.lua")):
        sv = SAVED / file
        if not sv.exists():
            continue
        src = sv.read_text(encoding="utf-8")
        m = re.search(r"^" + table + r" = \{\n(.*?)^\}$", src, re.M | re.S)
        for name, body in re.findall(r'\["([^"]+)"\] = \{(.*?)\n\}', m.group(1) if m else "", re.S):
            for mp, x, y in re.findall(r'"(\d+):(\d+):(\d+)"', body):
                if int(mp) == MAP and name in WANT:
                    out.append((int(x) / 10, int(y) / 10, name))
    return out


def spots():
    own = picks()
    known = [(x, y, n) for path, names in ((DATA / "HerbalismData.lua", HERBS), (DATA / "MiningData.lua", ORE))
             for n, pts in spawns(path, names).items() for x, y in pts]
    kept = []
    for s in [(*p, "own") for p in own] + [(*p, "classic") for p in known]:
        if all(dist(s, k) > MERGE for k in kept):
            kept.append(s)
    kept.sort(key=lambda s: dist(s, HOME))
    return kept[:MAX_SPOTS], len(own)


def length(path):
    return sum(dist(a, b) for a, b in zip(path, path[1:]))


def tour(points):
    """Closed tour from HOME: nearest neighbour, then 2-opt. Returns the path and every step taken."""
    trace = {"nn": [], "swaps": []}
    left, path = list(points), [HOME]
    while left:
        nxt = min(left, key=lambda q: dist(path[-1], q))
        trace["nn"].append({"to": points.index(nxt), "leg": round(dist(path[-1], nxt), 3)})
        path.append(nxt)
        left.remove(nxt)
    path.append(HOME)
    trace["nn_length"] = round(length(path), 2)
    improved = True
    while improved:
        improved = False
        for i in range(1, len(path) - 2):
            for j in range(i + 1, len(path) - 1):
                a, b, c, d = path[i - 1], path[i], path[j], path[j + 1]
                gain = dist(a, b) + dist(c, d) - dist(a, c) - dist(b, d)
                if gain > 1e-9:
                    path[i:j + 1] = reversed(path[i:j + 1])
                    improved = True
                    trace["swaps"].append({"i": i, "j": j, "gain": round(gain, 3), "length": round(length(path), 2),
                                           "order": [points.index(p) for p in path[1:-1]]})
    trace["final_length"] = round(length(path), 2)
    return path, trace


def main():
    kept, picked = spots()
    own = sum(1 for k in kept if k[3] == "own")
    points = [(x, y) for x, y, _, _ in kept]
    path, trace = tour(points)
    name = {(x, y): n for x, y, n, _ in kept}
    steps = [{"id": "auberdine-0", "map": MAP, "x": HOME[0], "y": HOME[1], "title": "Auberdine: the mailbox, to start"}]
    steps += [{"id": f"auberdine-{i}", "map": MAP, "x": round(x, 1), "y": round(y, 1), "title": f"{name[(x, y)]}, {ZONE}"}
              for i, (x, y) in enumerate(path[1:-1], 1)]
    steps.append({"id": f"auberdine-{len(path) - 1}", "map": MAP, "x": HOME[0], "y": HOME[1],
                  "title": "Auberdine: back at the mailbox"})
    run = {"char": "Chalice", "game": "forever", "order": 32, "name": "Gather: Auberdine loop", "mode": "gather",
           "about": f"A loop out of Auberdine through Darkshore and back to the mailbox: {len(points)} herb and copper "
                    f"spots you can pick ({own} of them where you've gathered yourself, the rest from classic spawn "
                    "data). Peacebloom, Silverleaf, Earthroot, Mageroyal and Briarthorn; Bruiseweed joins at herbalism "
                    "100, tin at mining 65. The wisp moves on as you pass each spot.",
           "steps": steps}
    OUT.write_text(json.dumps(run, indent=2), encoding="utf-8")
    TRACE.parent.mkdir(exist_ok=True)
    data = {"zone": ZONE, "home": HOME, "aspect": ASPECT, "merge": MERGE,
            "points": [{"x": x, "y": y, "name": n, "source": s} for x, y, n, s in kept], **trace}
    TRACE.write_text(json.dumps(data, indent=1), encoding="utf-8")
    template = (ROOT / "docs" / "auberdine_pathing.template.html").read_text(encoding="utf-8")
    PAGE.write_text(template.replace("__TRACE__", json.dumps(data)), encoding="utf-8")
    print(f"{len(points)} spots ({own} from her own {picked} picks); nearest neighbour {trace['nn_length']} map-%, "
          f"{len(trace['swaps'])} 2-opt swaps, final {trace['final_length']} map-% -> {OUT}")


if __name__ == "__main__":
    main()
