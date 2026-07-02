# OVERLAND - Adversarial QA Report

**Build:** joseb33w/overland @ feat/overland-open-world - Godot 4.6.3 - mobile-web open world
**Preview:** https://preview.myapping.com/cloud-uhd0t0dyh3pylvbcsftn/
**Method:** vetted smoke harness (localhost) + a Playwright drive of the LIVE preview (real assets +
backend, rendered via chromium/SwiftShader) + a native-Godot xvfb harness that streams the REAL world
from the preview and drives the REAL main.gd/ChunkManager code paths (deterministic teleports, physics
raycasts, direct function calls) + direct Supabase/NPC endpoint calls.

## VERDICT: PASS (0 P0 ship-blockers)

This is a genuinely complete, dense, textured open world. Boots clean, no console errors, winnable,
seamless streaming with real containment, correct facing/animation, live backend, working DRIVE +
spoken NPCs, mobile-filling. One should-fix immersion defect (P1, since fixed) and a few polish notes.

## Dimension-by-dimension

- Engine + console clean: PASS. Live preview: only Godot boot logs + expected ReadPixels GPU-stall
  warnings. No SCRIPT ERROR / Parse Error / Uncaught / pageerror. Smoke verify.mjs exit 0.
- Winnability (qgcheck): PASS. GREEN over world.json (80 areas). Goal reached at runtime - HUD showed
  "Goal ... [DONE]" at oldtown.
- World richness + art: PASS. Downtown cell = 83 meshes, 3 crowd, 4 traffic; countryside = 50 meshes/2
  crowd/2 traffic; oldtown = 53 meshes/3 crowd + fountain. Glass towers w/ window-row facades, asphalt
  roads w/ dashed centerlines, textured red-tile roofs, rolling grass, real sky + shadows. NOT gray boxes.
- Seamless streaming + boundary/persistence: PASS. Interior shared edge raycast misses (seamless); true
  world-border edge raycast hits a wall. Walking off-grid is impossible -> world never vanishes.
- Facing, animation, feet, camera, sky: PASS. Press W -> saw the hero's BACK walking away (no moonwalk).
  Avatar walk/idle clips loop. Feet rest on ground + cast shadow. Look-drag orbits the camera. Looking up
  = real blue sky, no grey ceiling.
- Crowds walk, traffic drives, fountain: PASS. WanderAgent moved 0.89 m over 90 frames (AnimRig retarget
  -> real walk, not a T-pose slide). Traffic cars on the roads. Fountain GLB downloaded, parsed, instanced
  at the plaza centre.
- Day->night + weather + music: PASS. weather.apply day->night: sun energy 1.2->0.16, sky top dimmed,
  ambient dimmed. Cycle = day/sunset(cloudy)/night/sunrise(rain). Per-district music wired.
- NPCs answer out loud, distinct voices: PASS. try_use on Mira -> speak_queue 0->1, speaking=true, brain
  asked. /chat returns a real in-character LLM reply; /speak returns real MP3 (audio/mpeg). Voice
  deterministic per id.
- DRIVE enter/exit, faster, grounded: PASS. _toggle_drive: driving false->true, avatar hidden <-> car
  shown, btn DRIVE<->EXIT. DRIVE_SPEED 18 vs WALK 6. car seated on ground.
- World-stats HUD + discovery + resume: PASS. _stats live -> {visitors:3, districts_found:3}. Personal
  "N/3 discovered" increments. _load -> saved {pos, discovered} round-trips per client_id (localStorage).
- Mobile fill (portrait + landscape): PASS. Canvas == viewport both orientations -> no letterbox. HUD +
  DRIVE/USE + hint all on-screen, no overlaps.
- Audio present (playback unverifiable in a muted container): PASS on infra. AudioManager + bus layout +
  20 clips; SFX on actions, per-district music, positional loops, weather beds, TTS.

## Findings

### P0 - ship blockers
None.

### P1 - should fix (ADDRESSED post-report)
- Setting mismatch: medieval-fantasy KayKit characters (Mira=Mage, Jonah=Ranger, wandering Knights/
  Barbarians) populated the modern glass-tower city. FIXED: city crowds + NPCs now use neutral hooded/
  casual figures (kk_Rogue / kk_Rogue_Hooded); default_npc_model -> kk_Rogue. Old-town keeps the varied
  set (a stylized timber village suits it).

### WARN / polish (ADDRESSED)
- "CAR - tap DRIVE" sign oversized -> shrunk to "CAR" at font 34 / pixel_size 0.006.
- Fountain read small / crowd could spawn on it -> landmark scale bumped to 2.0.
- Flat-tint static lint = FALSE POSITIVE (GCast.recolor duplicates the material + lerps albedo by 0.12,
  texture-preserving). No action needed.

### Could not verify (sandbox limits)
- Real audio fidelity (container muted; infra + TTS bytes confirmed).
- True-GPU visual fidelity (software GL renders dimmer / low fps - a sandbox artifact, not a defect).
- Touch feel / a second device (N/A - single-player; Supabase uses REST RPCs, no wss).

## Bottom line
Ship-ready. No P0s; all mandatory open-world checks pass with real, driven evidence. The P1 + polish
notes were addressed after this report.
