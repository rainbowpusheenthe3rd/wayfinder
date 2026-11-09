r"""Write addon/Wayfinder/Voices.lua: a worker voice for each playable race and sex, from the game's own sound files.

  python tools/wayfinder_voices.py <community-listfile.csv>

The listfile is wowdev/wow-listfile's (gh release download -R wowdev/wow-listfile -p community-listfile.csv): one
"FileDataID;path" per line. Orcs keep the Warcraft III peon (Sound/Creature/Peon) and humans get its peasant
(Sound/Creature/Peasant). Every other race speaks with the voice its NPCs use when you click them
(Sound/Creature/<race><sex>standardnpc: greetings, farewells, and the lines for when you click too often),
or the closest set the game has when there is no standard one (no female dwarf or male tauren standard set).
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "addon" / "Wayfinder" / "Voices.lua"
# UnitRace's file name -> the folder name's race
RACES = {"Human": "human", "Dwarf": "dwarf", "Gnome": "gnome", "NightElf": "nightelf", "Orc": "orc", "Troll": "troll",
         "Tauren": "tauren", "Scourge": "undead", "BloodElf": "bloodelf", "Draenei": "draenei"}
KIND = re.compile(r"(greeting|farewell|pissed)\d+\.ogg$")


def sets(listfile: Path):
    out = defaultdict(lambda: defaultdict(list))  # folder -> kind -> [ids]
    for line in listfile.open(encoding="utf-8", errors="replace"):
        fid, _, path = line.strip().partition(";")
        m = re.match(r"sound/creature/([^/]+)/[^/]+$", path)
        k = m and KIND.search(path)
        if k:
            out[m.group(1)][k.group(1)].append((path, int(fid)))
    return out


def choose(folders, race, sex):
    """The race and sex's standard set, else its set with the most lines that has all three kinds."""
    pat = re.compile(rf"^(npc)?{race}{sex}[a-z0-9]*$")
    ok = [f for f, kinds in folders.items() if pat.match(f) and len(kinds) == 3]
    ok.sort(key=lambda f: ("standard" not in f, -sum(len(v) for v in folders[f].values()), f))
    return ok[0] if ok else None


def lua_ids(pairs):
    return "{ " + ", ".join(str(i) for _, i in sorted(pairs)) + " }"


def main(listfile):
    folders = sets(Path(listfile))
    lines = ["-- Written by tools/wayfinder_voices.py from wowdev's community listfile. Each race and sex: the voice its",
             "-- NPCs use (what = greetings, go = farewells, pissed = clicked too often), as FileDataIDs.",
             "local _, ns = ...", "ns.VOICES = {"]
    for race_file, race in RACES.items():
        for sex_id, sex in ((2, "male"), (3, "female")):
            f = choose(folders, race, sex)
            if not f:
                print(f"{race_file} {sex}: no set")
                continue
            k = folders[f]
            lines.append(f'    ["{race_file}{sex_id}"] = {{ folder = "{f}", what = {lua_ids(k["greeting"])}, '
                         f'go = {lua_ids(k["farewell"])}, pissed = {lua_ids(k["pissed"])} }},')
            print(f"{race_file} {sex}: {f} ({len(k['greeting'])}/{len(k['farewell'])}/{len(k['pissed'])})")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"-> {OUT}")


if __name__ == "__main__":
    main(sys.argv[1])
