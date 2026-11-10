# Wayfinder

A see-through arrow that walks a route of waypoints (the decor-recipe trainer run by default). /wf for commands.

## Install

From a release zip: unzip the `Wayfinder` folder into `World of Warcraft\_forever_\Interface\AddOns`.

For development, link the game's folder to this repo (a directory junction, run once):

```powershell
New-Item -ItemType Junction -Path "<WoW folder>\_forever_\Interface\AddOns\Wayfinder" -Target "<this repo>"
```

`tools/` holds the generators for its art, `tests/` its smoke tests (`uv run --with lupa python tests/<file>.py`).

## Talks to

Reads `ProfessionLedgerDB` and calls `ProfessionQueueAPI` when those are loaded. `Route.lua` is written from `runs/*.json` by wow-market (`wowmarket wayfinder`).

## Releasing

```sh
git tag -a v1.2.0 -m "1.2.0" && git push origin v1.2.0      # builds the zip, makes the GitHub Release
```

CurseForge uploads are by hand for now, from the zip on the GitHub Release; nothing uploads there automatically.
