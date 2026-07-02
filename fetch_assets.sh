#!/usr/bin/env bash
# Reconstruct Overland's dependencies (binary assets + the upstream template base + world.json),
# kept out of git to keep the repo focused on the game-specific code. Run once after cloning:
#   ./fetch_assets.sh && godot --headless --path . --import && \
#     godot --headless --path . --export-release "Web" out/index.html && cp world.json quests.json out/
set -euo pipefail
O="https://preview.myapping.com/godot-assets"
BUILD_ID="cloud-uhd0t0dyh3pylvbcsftn"   # where the two Meshy-generated .glb were staged on R2
mkdir -p models audio tools

echo "== library models (AnimRig clip libs + fallback player + drivable car) =="
curl -sfL "$O/animations/kk_rig_medium_general.glb"       -o models/kk_rig_medium_general.glb
curl -sfL "$O/animations/kk_rig_medium_movementbasic.glb" -o models/kk_rig_medium_movementbasic.glb
curl -sfL "$O/animations/kk_rig_medium_combatmelee.glb"   -o models/kk_rig_medium_combatmelee.glb
curl -sfL "$O/characters/kk_Rogue_Hooded.glb"             -o models/kk_Rogue_Hooded.glb
curl -sfL "$O/props/kk_city/car_hatchback.glb"            -o models/car_player.glb

echo "== Meshy-generated signature assets (fountain landmark + player hero) =="
curl -sfL "https://preview.myapping.com/$BUILD_ID/models/fountain.glb" -o models/fountain.glb || echo "  (fountain.glb unavailable - the plaza falls back gracefully)"
curl -sfL "https://preview.myapping.com/$BUILD_ID/models/hero.glb"     -o models/hero.glb     || echo "  (hero.glb unavailable - the player uses the KayKit fallback char)"

echo "== per-district music + positional ambience =="
curl -sfL "$O/audio/music/road.ogg"                      -o audio/music_city.ogg
curl -sfL "$O/audio/music/village.ogg"                   -o audio/music_town.ogg
curl -sfL "$O/audio/music/clearing.ogg"                  -o audio/music_country.ogg
curl -sfL "$O/audio/realistic/ambient/town_crowd.ogg"    -o audio/crowd.ogg
curl -sfL "$O/audio/realistic/ambient/forest_birds.ogg"  -o audio/birds.ogg
curl -sfL "$O/audio/realistic/ambient/forest.ogg"        -o audio/country.ogg

echo "== template baked SFX/weather beds + base template systems (RPG streaming starter) =="
tmp="$(mktemp -d)"
curl -sfL "https://preview.myapping.com/godot-tmpl-rpg/godot-tmpl-rpg.zip" -o "$tmp/t.zip"
unzip -o -q "$tmp/t.zip" -d "$tmp/tpl"
cp -rn "$tmp"/tpl/audio/. audio/ 2>/dev/null || true
for f in audio_manager.gd anim_rig.gd build_structure.gd cast.gd enemy.gd layout.gd \
         rpg_systems.gd scene_manager.gd surfaces.gd traffic.gd water.gd weather3d.gd \
         water.gdshader default_bus_layout.tres export_presets.cfg; do
  [ -f "$f" ] || cp -n "$tmp/tpl/$f" "./$f" 2>/dev/null || true
done
rm -rf "$tmp"
# our one export tweak: safe-area (viewport-fit=cover) on the Web preset's viewport meta
grep -q "viewport-fit=cover" export_presets.cfg 2>/dev/null || \
  sed -i 's/user-scalable=no/user-scalable=no,viewport-fit=cover/' export_presets.cfg 2>/dev/null || true

echo "== generate world.json (the world is authored by tools/gen_world.py) =="
python3 tools/gen_world.py
echo "Done. Assets restored under models/ and audio/, base systems restored, and world.json generated."
