# Overland

One big **seamless open world you walk and drive across**, built with **Godot 4.6.3** and exported
for mobile web (Compatibility / WebGL2, single-threaded `nothreads`). It deliberately stress-tests the
engine: rolling streamed terrain, three very different districts, crowds, traffic, day->night + weather,
voiced NPCs, and a Supabase backend - all in one continuous world with no invisible walls.

**Play:** open the preview link from the pull request. On a phone: left side of the screen to move,
drag the right side to look, **USE** to talk, **DRIVE** to get in/out of the car. Tap once to start (unlocks audio).

## The world

- **Downtown** - a grid of glass-facade towers of varying heights (parametric buildings that light up
  their windows at night), a cross-road street grid with **cars in traffic**, and **crowds** wandering
  the sidewalks. A civic monument marks the spawn plaza.
- **Countryside + boulevard** - **real rolling terrain** you climb and descend, streamed seamlessly to a
  fog-faded horizon. A long **tree-lined boulevard** (grass verge + a terrain-following road + light
  traffic) carries you north from the city to the old town.
- **Old-Town** - cozy **timber gable houses** ringed around a **radial plaza with a fountain**, cobbled
  ground, and villagers milling about.

Everything streams in as you move (a 3x3 resident cell ring, no loading walls). Walk off in any direction
and the world keeps going.

## Alive

- **Wandering pedestrians** per district (retargeted so they actually walk, not slide).
- **Ambient traffic** driving the streets and the boulevard.
- **Voiced NPCs you can talk to** (Mira, Jonah, Rell, Old Bram) - a shared LLM brain writes the reply and
  they **answer out loud in distinct per-character voices** (text-to-speech).
- **Full day->night cycle** with changing light + a bit of weather, and **music + ambient sound that fit
  each area** (city / countryside / town).

## Backend (Supabase)

Remembers **where you've been** and **how many districts you've discovered**, and shows a live
**world-stats readout** (total visitors, districts found across everyone) pulled from the backend.

- Table `usr_nmexs7bytxq2_overland_visits` (RLS enabled; no direct anon/authenticated grants).
- Anonymous clients reach it only through three `SECURITY DEFINER` RPCs: `_save`, `_load`, `_stats`.

## Build it yourself

Binary assets, `world.json`, and the unmodified upstream template systems are kept out of git and
restored by one script (so the repo highlights the game-specific code). After cloning:

```bash
./fetch_assets.sh          # restores models/ + audio/, the base template systems, and generates world.json
godot --headless --path . --import
godot --headless --path . --export-release "Web" out/index.html
cp world.json quests.json out/                                 # loose data files, fetched at runtime
```

Then serve `out/` with a static server that sends `.wasm` as `application/wasm` (no COOP/COEP headers -
this is a single-threaded build).

## How it's structured

- `tools/gen_world.py` - authors the entire world as data (the `world.json` chunk grid: `terrain`,
  `sky` cycle, per-cell `ground`/`structures`/`roads`/`traffic`/`populate`/`scatter`/`props`/`npc`).
- `quests.json` - the "Grand Tour" objective (reach the old-town fountain plaza).
- `main.gd` - player, animation, terrain gravity, drive mode, per-district music, world-stats HUD,
  district discovery + backend save/load, mobile safe-area.
- `backend.gd` - the Supabase client (anon key + the three `SECURITY DEFINER` RPCs).
- `chunk_manager.gd` / `terrain.gd` / `wander.gd` / `interaction.gd` / `shapes.gd` / `area_builder.gd` /
  `quest.gd` - the Godot RPG streaming template, **extended here** for per-cell terrain materials,
  terrain-following roads, animated (retargeted) crowds, and open-world facing/audio polish.
- The remaining base systems (weather, audio manager, parametric building, layout, etc.) are the
  upstream template, restored by `fetch_assets.sh`.

## QA

An independent adversarial QA pass is committed at `docs/qa_report.md` (verdict: PASS, 0 ship-blockers).
