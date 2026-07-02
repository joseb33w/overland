# Overland - engine stress-test open world

One big seamless open world you **walk and drive** across, built on the Godot 4.6.3 RPG
chunk-streaming template (mobile-web, gl_compatibility, nothreads). Three districts joined by
rolling countryside, streamed in with no invisible walls.

## Goal
- **Downtown** - a grid of glass-facade towers of varying heights (parametric `structures`),
  streets with **cars in traffic**, **crowds** on the sidewalks.
- **Old-town** - timber gable houses around a **radial plaza with a fountain**, joined to
  downtown by a long **tree-lined boulevard**.
- **Countryside** - real **rolling terrain** (heightmap) with scattered trees; the world keeps
  going to a fog-faded horizon. Seamless chunk streaming, no loading walls.
- **Alive** - wandering pedestrians per district, ambient traffic, **NPCs you talk to who answer
  out loud in distinct voices** (shared LLM brain + TTS).
- **Day->night cycle** with changing light + a bit of weather; **ambient sound + music per area**.
- **Supabase backend** - remembers where you've been + how many districts you've discovered,
  and shows a live **world-stats readout** (visitors, districts found) pulled from the backend.
- **Drive** - a car you can enter/exit (DRIVE button) to cross the world faster.

## Files to touch
- `tools/gen_world.py` -> `world.json` (chunk world: terrain, sky cycle, per-cell ground/
  structures/roads/traffic/populate/scatter/props/npc, districts + goal).
- `quests.json` - a light "discover the districts / reach old-town" objective.
- `main.gd` - animated third-person player, gravity on terrain, drive mode, per-district music,
  world-stats HUD, district discovery + backend save/load, safe-area insets.
- `backend.gd` (new) - Supabase persistence + world-stats via SECURITY DEFINER RPCs (anon key).
- `chunk_manager.gd` - per-cell terrain material; terrain-following roads; AnimRig crowd retarget.
- `terrain.gd` - `cell_terrain()` accepts an optional per-cell material.
- `wander.gd` - prefer an AnimationPlayer that actually has clips.
- `models/`, `audio/` - packed AnimRig clip libs, fallback player char, per-district music + ambience.

## Backend (Supabase, shared project - per-app prefix `usr_nmexs7bytxq2_overland`)
- Table `usr_nmexs7bytxq2_overland_visits` (RLS on; no anon/authenticated grants).
- RPCs (`SECURITY DEFINER`, granted to anon): `_save`, `_load`, `_stats` -> `{visitors, districts_found}`.
  Verified end-to-end (anon can only reach the RPCs; direct table access is denied).

## Verification approach
- `node qgcheck.mjs world.json quests.json` - winnable.
- Smoke verify - engine boots, canvas, clean console, frames.
- Targeted checks: player facing, terrain gravity, discovery fires, crowds animate, mobile fill
  (portrait + landscape), backend save/load/stats, NPC /chat + /speak contract, drive enter/exit.
- Final independent QA pass; fix P0/P1 before the PR.

## Out of scope
- Full vehicle physics (arcade enter/drive/exit is enough for "walk and drive").
- Combat (no enemies; this is an exploration world).
