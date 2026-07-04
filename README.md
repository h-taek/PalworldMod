# PalworldMod

한국어: [README.ko.md](README.ko.md)

Homemade QoL mods for **Palworld on macOS (native)**. They run on top of the
[UE4SS-Palworld-macOS](https://github.com/h-taek/UE4SS-Palworld-macOS) loader and are
installed, enabled, and auto-updated through the
[PalworldModManager](https://github.com/h-taek/PalworldModManager) app (manual drop-in also
supported).

> Platform: **macOS (Apple Silicon)** only. The content pak is Mac-cooked, so it does not
> attach on Windows.

## Mods

| Mod | Description | Version |
|---|---|---|
| [**MinimapWidget**](MinimapWidget/) | Homemade minimap that crops the static full map into a circular porthole. Size / zoom / position are adjustable live in the in-game ModConfigMenu. | `1.0.0` |

## Installation

**Recommended — mod manager app**: import the release zip into PalworldModManager and it
handles install, activation, and auto-update.

**Manual drop-in**: merge the `Pal/` folder inside the release zip into your game project
folder. See each mod's README for exact paths and prerequisites.

## Release layout (manager auto-update wiring)

Multiple mods live in a single repo, split into per-mod folders. Distribution zips are
uploaded as **GitHub Releases assets** (per-mod tag, e.g. `minimapwidget-v1.0.0`); only each
mod folder's `update.json` is committed to the repo.

Auto-update is a two-hop chain:

```
mod manifest.json's updateURL
  → remote update.json  {"version", "url"}          (repo: <mod>/update.json)
    → the zip at url                                 (GitHub Releases asset)
```

The manager only version-checks and replaces mods that have an `updateURL`.

## License

[MIT](LICENSE) © h-taek
