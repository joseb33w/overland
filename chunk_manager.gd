class_name ChunkManager extends Node
## CHUNK MANAGER - resident-RING streaming for mode=="chunk" worlds. Maintains a 3x3 ring of
## live cells around the player (Chebyshev radius RING_RADIUS), builds AT MOST ONE queued cell
## per frame (no ring-shift burst -> no main-thread jank), and EVICTS cells outside the ring
## (queue_free root+enemies) - eviction is what BOUNDS memory so the ring fits mobile Safari.
##
## This REPLACES SceneManager for chunk worlds. It exposes the SAME public fields SceneManager does
## (enemies / current_id / current_root / transitioning) so main.gd's reads stay drop-in.
##
## Overland extensions: per-cell terrain MATERIAL (_terrain_cell_mat), terrain-FOLLOWING roads
## (_road_strip), and AnimRig crowd retarget in _place_populate (rig:"kaykit"). build_cell also
## builds LOCAL geometry (floor/roads/structures) BEFORE the streamed-asset await so the world's
## ground + buildings appear instantly and never wait on decor downloads.

const SKELETON := "/godot-assets/enemies/skeleton_warrior.glb"
const EnemyScript := preload("res://enemy.gd")

const RING_RADIUS := 1                 # Chebyshev radius -> 3x3 footprint
const MAX_RESIDENT_CELLS := 9          # hard cap = (2*RING_RADIUS+1)^2 = 9
const PROP_CAP := 12                    # max INDIVIDUAL props placed per cell (live-node budget is 9*N)
const SCATTER_MAX := 40                 # max instances per MultiMesh scatter entry (1 draw call regardless)
const DEFAULT_GROUND := [0.3, 0.33, 0.38]

# --- public surface mirrored from SceneManager (main.gd reads these in chunk mode) ---
var enemies: Array = []
var current_root: Node3D = null
var current_id := "chunk"
var transitioning := false

# Emitted when the player crosses into a new cell -> main.gd wires it to quest.notify_area +
# _on_area_entered. The id matches the reassembler's idFor(gx,gz) = "c<gx>_<gz>".
signal area_entered(area_id: String)

# --- wiring (set in setup) ---
var builder: AreaBuilder
var player: Node3D
var world_main: Node
var env: Environment
var interaction: InteractionSystem
var rpg: RpgState

# --- chunk world data ---
var cell_size := 16.0
var grid := {}                         # cell_key "gx,gz" -> cell record Dictionary
var start_cell := Vector2i.ZERO
var default_npc_model := ""
var terrain: GTerrain = null           # OPT-IN rolling terrain (world.json top-level `terrain`)

# --- resident ring state ---
var resident := {}
var _build_queue: Array = []
var _cur_cell := Vector2i(2147483647, 0)
var _building := false
var _started := false
var _heading := Vector2i.ZERO
var _reloading := false

# --- shared flat nav ---
var _nav_region: NavigationRegion3D = null
var _nav_root: Node3D = null
var _far: MeshInstance3D = null
var _far_centre := Vector2(1e9, 1e9)
var water_cfg = null
var water_level := 0.0
var _water: MeshInstance3D = null
var _water_centre := Vector2(1e9, 1e9)


func setup(p: Node3D, b: AreaBuilder, main: Node, environment: Environment, inter: InteractionSystem = null, state: RpgState = null) -> void:
	player = p
	builder = b
	world_main = main
	env = environment
	interaction = inter
	rpg = state


# Called by main._boot when world.mode == "chunk" (in place of scene_manager.start()).
func start(world: Dictionary) -> void:
	cell_size = float(world.get("grid", {}).get("cell_size", 16.0))
	if cell_size <= 0.0:
		cell_size = 16.0

	var sc: Array = world.get("start_cell", [0, 0])
	if sc.size() >= 2:
		start_cell = Vector2i(int(sc[0]), int(sc[1]))

	default_npc_model = String(world.get("default_npc_model", ""))

	var tcfg = world.get("terrain", null)
	if typeof(tcfg) == TYPE_DICTIONARY or tcfg == true:
		terrain = GTerrain.new()
		terrain.setup(tcfg if typeof(tcfg) == TYPE_DICTIONARY else {})
	else:
		terrain = null

	var wcfg = world.get("water", null)
	if typeof(wcfg) == TYPE_DICTIONARY or wcfg == true:
		water_cfg = wcfg if typeof(wcfg) == TYPE_DICTIONARY else {}
		water_level = float(water_cfg.get("level", 0.0))
	else:
		water_cfg = null

	grid.clear()
	for c in world.get("cells", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc: Array = c.get("cell", [])
		if cc.size() < 2:
			continue
		grid[_key(int(cc[0]), int(cc[1]))] = c

	if env and not env.has_meta("weather_owned"):
		var a = world.get("ambient", [0.6, 0.6, 0.66])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)

	_nav_root = Node3D.new()
	world_main.add_child(_nav_root)
	_rebuild_shared_nav()

	var spawn := _cell_centre(start_cell.x, start_cell.y)
	spawn.y = _ground_y(spawn.x, spawn.z) + 1.5
	player.global_position = spawn
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO

	current_root = _nav_root
	current_id = "chunk"
	transitioning = false
	_started = true

	_cur_cell = start_cell
	await _build_cell_at(start_cell.x, start_cell.y)
	_update_ring(start_cell)
	_update_far(player.global_position)
	_update_water(player.global_position)
	current_id = _area_id(start_cell)
	area_entered.emit(current_id)


func tick(delta: float) -> void:
	if not _started:
		return

	var here := _player_cell()
	if here != _cur_cell:
		var step := here - _cur_cell
		if step != Vector2i.ZERO:
			_heading = Vector2i(signi(step.x), signi(step.y))
		_cur_cell = here
		_update_ring(here)
		_update_far(player.global_position)
		_update_water(player.global_position)
		current_id = _area_id(here)
		area_entered.emit(current_id)

	if not _building and not _reloading and not _build_queue.is_empty():
		var next: Vector2i = _build_queue.pop_front()
		if not resident.has(_key(next.x, next.y)) and grid.has(_key(next.x, next.y)):
			_building = true
			await _build_cell_at(next.x, next.y)
			_building = false

	_prune_enemies()


# ---------------- live hot-reload ----------------

func reload(new_world: Dictionary) -> void:
	if not _started:
		return

	var new_size := float(new_world.get("grid", {}).get("cell_size", cell_size))
	if new_size <= 0.0:
		new_size = cell_size
	var new_sc: Array = new_world.get("start_cell", [start_cell.x, start_cell.y])
	if new_sc.size() >= 2:
		start_cell = Vector2i(int(new_sc[0]), int(new_sc[1]))
	default_npc_model = String(new_world.get("default_npc_model", default_npc_model))

	var new_grid := {}
	for c in new_world.get("cells", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc: Array = c.get("cell", [])
		if cc.size() < 2:
			continue
		new_grid[_key(int(cc[0]), int(cc[1]))] = c

	if env and not env.has_meta("weather_owned"):
		var a = new_world.get("ambient", [env.ambient_light_color.r, env.ambient_light_color.g, env.ambient_light_color.b])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)

	var old_grid := grid

	if not is_equal_approx(new_size, cell_size):
		cell_size = new_size
		grid = new_grid
		var all_keys: Array = resident.keys()
		for rk: String in all_keys:
			_evict(rk)
		_build_queue.clear()
		_rebuild_shared_nav()
		_cur_cell = _player_cell()
		_update_ring(_cur_cell)
		return

	grid = new_grid
	_reloading = true

	var resident_keys: Array = resident.keys()
	for rk: String in resident_keys:
		var new_rec = new_grid.get(rk)
		var old_rec = old_grid.get(rk)
		if new_rec == null:
			_evict(rk)
			continue
		if _records_equal(old_rec, new_rec):
			continue
		var gx := 0
		var gz := 0
		var parts := rk.split(",")
		if parts.size() >= 2:
			gx = int(parts[0])
			gz = int(parts[1])
		_evict(rk)
		var built: Dictionary = await build_cell(new_rec, gx, gz)
		if built.is_empty():
			continue
		resident[rk] = built
		for e in built.get("enemies", []):
			enemies.append(e)

	_rebuild_shared_nav()
	_reloading = false
	_update_ring(_cur_cell)


func _records_equal(a, b) -> bool:
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY:
		return a == b
	return (a as Dictionary) == (b as Dictionary)


# ---------------- ring maintenance ----------------

func _update_ring(centre: Vector2i) -> void:
	var wanted := {}
	for gx in range(centre.x - RING_RADIUS, centre.x + RING_RADIUS + 1):
		for gz in range(centre.y - RING_RADIUS, centre.y + RING_RADIUS + 1):
			var k := _key(gx, gz)
			if grid.has(k):
				wanted[k] = Vector2i(gx, gz)

	var resident_keys: Array = resident.keys()
	for rk: String in resident_keys:
		if not wanted.has(rk):
			_evict(rk)

	var order: Array = wanted.values()
	order.sort_custom(_ring_priority.bind(centre))
	for cell: Vector2i in order:
		var k := _key(cell.x, cell.y)
		if resident.has(k):
			continue
		if cell in _build_queue:
			continue
		_build_queue.append(cell)


func _ring_priority(a: Vector2i, b: Vector2i, centre: Vector2i) -> bool:
	var ah := _ahead_score(a, centre)
	var bh := _ahead_score(b, centre)
	if ah != bh:
		return ah > bh
	return _cheb(a, centre) < _cheb(b, centre)


func _ahead_score(cell: Vector2i, centre: Vector2i) -> int:
	if _heading == Vector2i.ZERO:
		return 0
	var d := cell - centre
	return d.x * _heading.x + d.y * _heading.y


func _evict(k: String) -> void:
	var rec = resident.get(k)
	if rec == null:
		resident.erase(k)
		return
	var root = rec.get("root")
	if root != null and is_instance_valid(root):
		(root as Node).queue_free()
	resident.erase(k)
	var cell_enemies: Array = rec.get("enemies", [])
	for e in cell_enemies:
		enemies.erase(e)
	if interaction != null:
		interaction.remove_cell(k)


# ---------------- cell build ----------------

func _build_cell_at(gx: int, gz: int) -> void:
	var k := _key(gx, gz)
	if resident.has(k) or not grid.has(k):
		return
	var rec: Dictionary = grid[k]
	var built: Dictionary = await build_cell(rec, gx, gz)
	if built.is_empty():
		return
	resident[k] = built
	for e in built.get("enemies", []):
		enemies.append(e)
	_rebuild_shared_nav()

	while resident.size() > MAX_RESIDENT_CELLS:
		_evict_farthest()


func build_cell(rec: Dictionary, gx: int, gz: int) -> Dictionary:
	var half := cell_size * 0.5
	var ox := float(gx) * cell_size
	var oz := float(gz) * cell_size
	var centre := Vector3(ox + half, 0.0, oz + half)

	var enemy_n := int(rec.get("enemies", 0))

	# ---- gather EVERY asset url (enemy + scenery) for ONE parallel download (cache-shared) ----
	var scatter_list = rec.get("scatter", [])
	var prop_list = rec.get("props", [])
	var landmark = rec.get("landmark", null)
	var urls: Array = []
	if enemy_n > 0:
		var eu := _enemy_model_url(rec)
		if eu != "" and not urls.has(eu):
			urls.append(eu)
	if scatter_list is Array:
		for s in scatter_list:
			var su := _asset_url(s)
			if su != "" and not urls.has(su):
				urls.append(su)
	if prop_list is Array:
		for p in prop_list:
			var pu := _asset_url(p)
			if pu != "" and not urls.has(pu):
				urls.append(pu)
	if landmark != null:
		var lu := _asset_url(landmark)
		if lu != "" and not urls.has(lu):
			urls.append(lu)
	for lk in ["rows", "rings"]:
		var ll = rec.get(lk, [])
		if ll is Array:
			for entry in ll:
				if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("part", null)) == TYPE_DICTIONARY:
					var pu2 := _asset_url(entry["part"])
					if pu2 != "" and not urls.has(pu2):
						urls.append(pu2)
	var pl = rec.get("populate", [])
	if pl is Array:
		for entry in pl:
			if typeof(entry) == TYPE_DICTIONARY and entry.get("set", []) is Array:
				for su2 in entry["set"]:
					var ru := _resolve(String(su2))
					if ru != "" and not urls.has(ru):
						urls.append(ru)
	var tspec = rec.get("traffic", null)
	if typeof(tspec) == TYPE_DICTIONARY and tspec.get("set", []) is Array:
		for cu in tspec["set"]:
			var ru2 := _resolve(String(cu))
			if ru2 != "" and not urls.has(ru2):
				urls.append(ru2)
	if typeof(rec.get("npc", null)) == TYPE_DICTIONARY:
		var nu := _npc_model_url(rec.get("npc"))
		if nu != "" and not urls.has(nu):
			urls.append(nu)

	var root := Node3D.new()
	world_main.add_child(root)

	# FLOOR + ROADS + STRUCTURES are LOCAL geometry (no network). Build them BEFORE the streamed-asset
	# download so ground + buildings appear INSTANTLY and never wait on (or get blocked by) decor downloads.
	var ground_spec = rec.get("ground", DEFAULT_GROUND)
	if terrain != null:
		root.add_child(terrain.cell_terrain(centre, cell_size, _terrain_cell_mat(ground_spec)))
		_terrain_border_walls(root, gx, gz, centre, half)
	else:
		builder._ground_box(root, centre + Vector3(0.0, -0.5, 0.0), Vector3(cell_size, 1.0, cell_size), ground_spec, false)
		var ground := builder._spec_color(ground_spec)
		var wall := Color(ground.r * 0.7, ground.g * 0.7, ground.b * 0.78)
		var wall_h := 4.0
		var wall_t := 1.0
		var apron := half * 0.25
		if grid.has(_key(gx, gz - 1)):
			_collider_box(root, centre + Vector3(0.0, -0.5, -half - apron * 0.5), Vector3(cell_size, 1.0, apron))
		else:
			builder._box(root, centre + Vector3(0.0, wall_h * 0.5 - 0.5, -half), Vector3(cell_size, wall_h, wall_t), wall)
		if grid.has(_key(gx, gz + 1)):
			_collider_box(root, centre + Vector3(0.0, -0.5, half + apron * 0.5), Vector3(cell_size, 1.0, apron))
		else:
			builder._box(root, centre + Vector3(0.0, wall_h * 0.5 - 0.5, half), Vector3(cell_size, wall_h, wall_t), wall)
		if grid.has(_key(gx - 1, gz)):
			_collider_box(root, centre + Vector3(-half - apron * 0.5, -0.5, 0.0), Vector3(apron, 1.0, cell_size))
		else:
			builder._box(root, centre + Vector3(-half, wall_h * 0.5 - 0.5, 0.0), Vector3(wall_t, wall_h, cell_size), wall)
		if grid.has(_key(gx + 1, gz)):
			_collider_box(root, centre + Vector3(half + apron * 0.5, -0.5, 0.0), Vector3(apron, 1.0, cell_size))
		else:
			builder._box(root, centre + Vector3(half, wall_h * 0.5 - 0.5, 0.0), Vector3(wall_t, wall_h, cell_size), wall)

	var road_list = rec.get("roads", [])
	if road_list is Array:
		for r in road_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_road(root, r, centre, half)

	var struct_list = rec.get("structures", [])
	if struct_list is Array:
		for st in struct_list:
			if typeof(st) == TYPE_DICTIONARY:
				_place_structure(root, st, centre, half)

	# NOW fetch the streamed GLBs (crowd / cars / trees / props / landmark / npc).
	await builder._ensure(urls)

	var traffic_spec = rec.get("traffic", null)
	if typeof(traffic_spec) == TYPE_DICTIONARY and road_list is Array:
		_place_traffic(root, traffic_spec, road_list, centre, half)

	var row_list = rec.get("rows", [])
	if row_list is Array:
		for r in row_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_row(root, r, centre, half)
	var ring_list = rec.get("rings", [])
	if ring_list is Array:
		for r in ring_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_ring(root, r, centre, half)

	var pop_list = rec.get("populate", [])
	if pop_list is Array:
		for pp in pop_list:
			if typeof(pp) == TYPE_DICTIONARY:
				_place_populate(root, pp, centre, half)

	if landmark != null:
		_place_one(root, landmark, centre, half)
	if prop_list is Array:
		var placed := 0
		for p in prop_list:
			if placed >= PROP_CAP:
				break
			if _place_one(root, p, centre, half):
				placed += 1
	if scatter_list is Array:
		for s in scatter_list:
			_place_scatter(root, s, centre, half)

	var ckey := _key(gx, gz)
	if interaction != null:
		var npc = rec.get("npc", null)
		if typeof(npc) == TYPE_DICTIONARY:
			var np := _xz(npc.get("pos", [0, 0]))
			var npos := centre + Vector3(clampf(np.x, -half + 1.0, half - 1.0), 0.0, clampf(np.y, -half + 1.0, half - 1.0))
			npos.y = _ground_y(npos.x, npos.z)
			var nmu := _npc_model_url(npc)
			var nmodel: Node = null
			if builder.cache.has(nmu):
				nmodel = (builder.cache[nmu] as Node).duplicate()
			interaction.add_npc(npos, String(npc.get("id", "")), String(npc.get("name", "Stranger")),
				String(npc.get("persona", "")), npc.get("lines", []), nmodel, root, ckey, String(npc.get("sound", "")))
		var chest = rec.get("chest", null)
		if typeof(chest) == TYPE_DICTIONARY:
			var cp := _xz(chest.get("pos", [0, 0]))
			var cpos := centre + Vector3(clampf(cp.x, -half + 1.0, half - 1.0), 0.0, clampf(cp.y, -half + 1.0, half - 1.0))
			cpos.y = _ground_y(cpos.x, cpos.z)
			interaction.add_chest(cpos, chest.get("contents", []), int(chest.get("gold", 0)), root, ckey)
		var door_list = rec.get("doors", [])
		if door_list is Array:
			for d in door_list:
				if typeof(d) != TYPE_DICTIONARY:
					continue
				var dp := _xz(d.get("pos", [0, 0]))
				var dpos := centre + Vector3(clampf(dp.x, -half + 1.0, half - 1.0), 0.0, clampf(dp.y, -half + 1.0, half - 1.0))
				dpos.y = _ground_y(dpos.x, dpos.z)
				interaction.add_door(dpos, float(d.get("facing", 0.0)), String(d.get("lock", "")),
					String(d.get("label", "Door")), root, ckey)

	var cell_enemies: Array = []
	var emu := _enemy_model_url(rec)
	if enemy_n > 0 and builder.cache.has(emu):
		for i in range(enemy_n):
			var e := CharacterBody3D.new()
			e.set_script(EnemyScript)
			root.add_child(e)
			var ang := TAU * float(i) / float(enemy_n)
			e.global_position = centre + Vector3(cos(ang) * (half * 0.45), 0.0, sin(ang) * (half * 0.45))
			var model: Node = (builder.cache[emu] as Node).duplicate()
			e.setup(player, model, world_main, i, enemy_n, String(rec.get("enemy_type", "skeleton")))
			cell_enemies.append(e)

	return {root = root, enemies = cell_enemies}


func _collider_box(parent: Node, pos: Vector3, sz: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = sz
	cs.shape = box
	body.add_child(cs)
	parent.add_child(body)


func _terrain_border_walls(root: Node, gx: int, gz: int, centre: Vector3, half: float) -> void:
	var wall_h := 8.0
	var wall_t := 1.0
	if not grid.has(_key(gx, gz - 1)):
		_edge_wall(root, centre + Vector3(0.0, 0.0, -half), Vector3(cell_size, wall_h, wall_t))
	if not grid.has(_key(gx, gz + 1)):
		_edge_wall(root, centre + Vector3(0.0, 0.0, half), Vector3(cell_size, wall_h, wall_t))
	if not grid.has(_key(gx - 1, gz)):
		_edge_wall(root, centre + Vector3(-half, 0.0, 0.0), Vector3(wall_t, wall_h, cell_size))
	if not grid.has(_key(gx + 1, gz)):
		_edge_wall(root, centre + Vector3(half, 0.0, 0.0), Vector3(wall_t, wall_h, cell_size))


func _edge_wall(root: Node, edge_centre: Vector3, sz: Vector3) -> void:
	var gy := _ground_y(edge_centre.x, edge_centre.z)
	_collider_box(root, Vector3(edge_centre.x, gy + sz.y * 0.5 - 1.0, edge_centre.z), sz)


# ---------------- roads (terrain-following) ----------------

func _place_road(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var dir := String(spec.get("dir", "ew")).to_lower()
	var width := clampf(float(spec.get("width", 6.0)), 2.0, cell_size)
	if dir == "x" or dir == "cross" or dir == "+":
		_road_strip(root, centre, "ew", width)
		_road_strip(root, centre, "ns", width)
	else:
		_road_strip(root, centre, dir, width)


func _road_strip(root: Node, centre: Vector3, dir: String, width: float) -> void:
	var ew := dir != "ns"
	# TERRAIN-FOLLOWING: lay the asphalt as SHORT segments each dropped onto the heightfield.
	var asphalt := GSurf.surface("asphalt")
	var seg_len := 2.5
	var segs := maxi(1, int(cell_size / seg_len))
	seg_len = cell_size / float(segs)
	for i in range(segs):
		var t := -cell_size * 0.5 + seg_len * (float(i) + 0.5)
		var sp: Vector3 = centre + (Vector3(t, 0.0, 0.0) if ew else Vector3(0.0, 0.0, t))
		var sy := _ground_y(sp.x, sp.z) + 0.05
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(seg_len + 0.06, 0.08, width) if ew else Vector3(width, 0.08, seg_len + 0.06)
		mi.mesh = bm
		mi.material_override = asphalt
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(sp.x, sy, sp.z)
		root.add_child(mi)
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.95, 0.86, 0.35)
	line_mat.emission_enabled = true
	line_mat.emission = Color(0.8, 0.7, 0.2)
	line_mat.emission_energy_multiplier = 0.6
	var step := 3.0
	var n := int(cell_size / step)
	for i in range(n):
		var t := -cell_size * 0.5 + step * (float(i) + 0.5)
		var lp: Vector3 = centre + (Vector3(t, 0.0, 0.0) if ew else Vector3(0.0, 0.0, t))
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.6, 0.04, 0.22) if ew else Vector3(0.22, 0.04, 1.6)
		mi.mesh = bm
		mi.material_override = line_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(lp.x, _ground_y(lp.x, lp.z) + 0.11, lp.z)
		root.add_child(mi)


# ---------------- structures ----------------

func _place_structure(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var node := GBuild.structure(spec)
	if node == null:
		return
	var xz := _xz(spec.get("pos", [0, 0]))
	var p := centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
	p.y = _ground_y(p.x, p.z)
	node.position = p
	root.add_child(node)
	var snd := String(spec.get("sound", ""))
	if snd != "" and ResourceLoader.exists("res://audio/%s.ogg" % snd):
		AudioManager.attach_loop(node, load("res://audio/%s.ogg" % snd))


# ---------------- layout ----------------

func _place_row(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var part = spec.get("part", null)
	if typeof(part) != TYPE_DICTIONARY:
		return
	var pts := GLayout.along(_xz(spec.get("from", [0, 0])), _xz(spec.get("to", [0, 0])),
		maxf(0.3, float(spec.get("spacing", 3.0))), float(spec.get("jitter", 0.0)))
	_place_parts(root, part, pts, centre, half)


func _place_ring(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var part = spec.get("part", null)
	if typeof(part) != TYPE_DICTIONARY:
		return
	var hv := _xz(spec.get("half", [4, 4]))
	var pts := GLayout.around(hv.x, hv.y, maxf(0.3, float(spec.get("spacing", 2.0))))
	_place_parts(root, part, pts, centre, half)


func _place_parts(root: Node, part: Dictionary, pts: Array, centre: Vector3, half: float) -> void:
	var cap := mini(pts.size(), 80)
	for i in cap:
		var p: Vector2 = pts[i]
		var node := _make_part(part)
		if node == null:
			continue
		var wp := centre + Vector3(clampf(p.x, -half + 0.3, half - 0.3), 0.0, clampf(p.y, -half + 0.3, half - 0.3))
		wp.y = _ground_y(wp.x, wp.z)
		node.position = wp
		if part.has("rot"):
			node.rotation.y = deg_to_rad(float(part["rot"]))
		root.add_child(node)


func _make_part(part: Dictionary) -> Node3D:
	if typeof(part.get("structure", null)) == TYPE_DICTIONARY:
		return GBuild.structure(part["structure"])
	if part.has("shape"):
		var node := _shape_part(part)
		if node != null:
			GShapes.set_material(node, GSurf.surface(part.get("material", "concrete")))
			if String(part.get("collider", "box")) != "none":
				GShapes.add_collider(node, String(part.get("collider", "box")))
		return node
	var u := String(part.get("url", part.get("model", part.get("asset", ""))))
	if u != "":
		u = _resolve(u)
	elif part.has("kind"):
		u = builder._palette_url(part)
	if u != "" and builder.cache.has(u) and builder.cache[u] != null:
		var g := (builder.cache[u] as Node).duplicate() as Node3D
		if g == null:
			return null
		var ab := builder._world_aabb(g)
		var wrap := Node3D.new()
		g.position.y = -maxf(0.0, ab.position.y)
		wrap.add_child(g)
		if String(part.get("collider", "box")) != "none":
			GShapes.add_collider(wrap, String(part.get("collider", "box")))
		return wrap
	return null


func _shape_part(part: Dictionary) -> Node3D:
	match String(part.get("shape", "")).to_lower():
		"box": return GShapes.box(_v3(part.get("size", [1, 2, 1])))
		"column": return GShapes.column(float(part.get("radius", 0.5)), float(part.get("height", 6.0)), int(part.get("sides", 24)))
		"cylinder": return GShapes.cylinder(float(part.get("radius", 0.5)), float(part.get("top_radius", part.get("radius", 0.5))), float(part.get("height", 3.0)), int(part.get("sides", 24)))
		"pyramid": return GShapes.pyramid(_xz(part.get("base", [2, 2])), float(part.get("height", 2.0)))
		"frustum": return GShapes.frustum(_xz(part.get("base", [2, 2])), _xz(part.get("top", [1, 1])), float(part.get("height", 3.0)))
		"wedge": return GShapes.wedge(_v3(part.get("size", [2, 1, 2])))
		"dome": return GShapes.dome(float(part.get("radius", 2.0)), float(part.get("height", 1.5)))
		"prism": return GShapes.prism_ngon(int(part.get("sides", 6)), float(part.get("radius", 0.5)), float(part.get("height", 3.0)))
	return null


func _v3(a) -> Vector3:
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3(1, 1, 1)


# ---------------- populate ----------------

func _place_populate(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var set = spec.get("set", [])
	if not (set is Array) or (set as Array).is_empty():
		return
	var count := clampi(int(spec.get("count", 6)), 1, 30)
	var do_vary := bool(spec.get("vary", true))
	var collide := String(spec.get("collider", "none"))
	var snd := String(spec.get("sound", ""))
	var behaviour := String(spec.get("behaviour", spec.get("behavior", "static")))
	var rig := String(spec.get("rig", ""))   # "kaykit" -> retarget so a KayKit crowd actually WALKS
	var cell_seed := int(centre.x) * 73856093 + int(centre.z) * 19349663
	for i in count:
		var rng := GCast.rng_for(cell_seed + i * 1013)
		var u := _resolve(GCast.pick(set, rng))
		if u == "" or not builder.cache.has(u) or builder.cache[u] == null:
			continue
		var n := (builder.cache[u] as Node).duplicate() as Node3D
		if n == null:
			continue
		var ab := builder._world_aabb(n)
		n.position.y = -maxf(0.0, ab.position.y)
		if collide != "none":
			GShapes.add_collider(n, collide)
		# KayKit library characters import an EMPTY AnimationPlayer, so a walking crowd would SLIDE in a
		# frozen T-pose. Retarget idle/walk from the packed kk_rig_medium_* libraries so the crowd is ALIVE.
		if rig == "kaykit":
			AnimRig.attach(n, {"idle": "Idle_A", "walk": "Walking_A"}, ["idle", "walk"])
		var wrap: Node3D = WanderAgent.new() if behaviour == "wander" else Node3D.new()
		wrap.add_child(n)
		if do_vary:
			GCast.vary(wrap, rng)
		var spot := Vector2(rng.randf_range(-half + 1.0, half - 1.0), rng.randf_range(-half + 1.0, half - 1.0))
		var wp := centre + Vector3(spot.x, 0.0, spot.y)
		wp.y = _ground_y(wp.x, wp.z)
		wrap.position = wp
		root.add_child(wrap)
		if behaviour == "wander":
			(wrap as WanderAgent).setup(terrain, Vector2(wp.x, wp.z), float(spec.get("radius", 6.0)), float(spec.get("speed", 1.5)), cell_seed + i)
		if snd != "" and ResourceLoader.exists("res://audio/%s.ogg" % snd):
			AudioManager.attach_loop(wrap, load("res://audio/%s.ogg" % snd))


# ---------------- ambient traffic ----------------

func _place_traffic(root: Node, spec: Dictionary, road_list: Array, centre: Vector3, half: float) -> void:
	var set = spec.get("set", [])
	if not (set is Array) or (set as Array).is_empty():
		return
	var count := clampi(int(spec.get("count", 3)), 1, 10)
	var speed := float(spec.get("speed", 6.0))
	var lane := clampf(float(spec.get("lane", half * 0.25)), 0.5, half - 0.5)
	var cell_seed := int(centre.x) * 9176 + int(centre.z) * 4423
	var idx := 0
	for r in road_list:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var dir := String(r.get("dir", "ew")).to_lower()
		var dds: Array = ["ew", "ns"] if (dir == "x" or dir == "cross" or dir == "+") else [dir]
		for dd in dds:
			var a: Vector3
			var b: Vector3
			if dd == "ns":
				a = centre + Vector3(-lane, 0.0, -half)
				b = centre + Vector3(-lane, 0.0, half)
			else:
				a = centre + Vector3(-half, 0.0, lane)
				b = centre + Vector3(half, 0.0, lane)
			for k in count:
				var rng := GCast.rng_for(cell_seed + idx)
				idx += 1
				var u := _resolve(GCast.pick(set, rng))
				if u == "" or not builder.cache.has(u) or builder.cache[u] == null:
					continue
				var model := (builder.cache[u] as Node).duplicate() as Node3D
				if model == null:
					continue
				var ab := builder._world_aabb(model)
				model.position.y = -maxf(0.0, ab.position.y)
				var car := TrafficCar.new()
				car.add_child(model)
				root.add_child(car)
				car.setup(a, b, speed, terrain, float(k) / float(count))


# ---------------- per-cell scenery ----------------

func _asset_url(ref) -> String:
	if typeof(ref) != TYPE_DICTIONARY:
		return ""
	var u := String(ref.get("url", ref.get("model", ref.get("asset", ""))))
	if u != "":
		return _resolve(u)
	return builder._palette_url(ref)


func _resolve(u: String) -> String:
	if u.begins_with("http"):
		return u
	if u.begins_with("/"):
		return builder.origin + u
	return builder.origin + "/godot-assets/" + u


func _npc_model_url(npc) -> String:
	if typeof(npc) == TYPE_DICTIONARY:
		var u := String(npc.get("model", npc.get("url", npc.get("asset", ""))))
		if u != "":
			return _resolve(u)
	if default_npc_model != "":
		return _resolve(default_npc_model)
	return builder.origin + AreaBuilder.NPC_MODEL


func _enemy_model_url(rec) -> String:
	if typeof(rec) == TYPE_DICTIONARY:
		var u := String(rec.get("enemy_model", rec.get("enemy_url", "")))
		if u != "":
			return _resolve(u)
	return builder.origin + SKELETON


func _xz(p) -> Vector2:
	if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2:
		var zi := 2 if (p as Array).size() > 2 else 1
		return Vector2(float(p[0]), float(p[zi]))
	return Vector2.ZERO


func _place_one(root: Node, ref, centre: Vector3, half: float) -> bool:
	if typeof(ref) != TYPE_DICTIONARY:
		return false
	var url := _asset_url(ref)
	if url == "" or not builder.cache.has(url):
		return false
	var src = builder.cache[url]
	if src == null:
		return false
	var n := (src as Node).duplicate() as Node3D
	if n == null:
		return false
	root.add_child(n)
	var xz := _xz(ref.get("pos", [0, 0]))
	n.position = centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
	if ref.has("rot"):
		n.rotation.y = deg_to_rad(float(ref.get("rot", 0.0)))
	var sc := float(ref.get("scale", 1.0))
	if sc > 0.0 and sc != 1.0:
		n.scale = Vector3(sc, sc, sc)
	var foot_ab := builder._world_aabb(n)
	var foot := maxf(foot_ab.size.x, foot_ab.size.z)
	if foot > half * 2.0 and foot > 0.001:
		n.scale *= (half * 2.0) / foot
	var ab := builder._world_aabb(n)
	n.position.y -= maxf(0.0, ab.position.y)
	n.position.y += _ground_y(n.position.x, n.position.z)
	if String(ref.get("collider", "box")) == "mesh":
		_add_mesh_collision(n)
	else:
		builder._add_prop_collision(n, root)
	var snd := String(ref.get("sound", ""))
	if snd != "" and ResourceLoader.exists("res://audio/%s.ogg" % snd):
		AudioManager.attach_loop(n, load("res://audio/%s.ogg" % snd))
	return true


func _place_scatter(root: Node, ref, centre: Vector3, half: float) -> void:
	if typeof(ref) != TYPE_DICTIONARY:
		return
	var url := _asset_url(ref)
	if url == "" or not builder.cache.has(url):
		return
	var src = builder.cache[url]
	if src == null:
		return
	var cnt := clampi(int(ref.get("count", 8)), 1, SCATTER_MAX)
	var mesh := _extract_mesh(src as Node)
	if mesh != null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = cnt
		var drop := maxf(0.0, mesh.get_aabb().position.y)
		var msz := mesh.get_aabb().size
		var mdim := maxf(msz.x, msz.z)
		var base := 1.0 if (mdim <= 5.0 or mdim < 0.001) else 5.0 / mdim
		for i in range(cnt):
			var sj := randf_range(0.8, 1.2) * base
			var b := Basis().rotated(Vector3.UP, randf() * TAU).scaled(Vector3(sj, sj, sj))
			var spot := Vector2(randf_range(-half + 1.0, half - 1.0), randf_range(-half + 1.0, half - 1.0))
			var sy := -drop * sj + _ground_y(centre.x + spot.x, centre.z + spot.y)
			mm.set_instance_transform(i, Transform3D(b, Vector3(spot.x, sy, spot.y)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.position = centre
		root.add_child(mmi)
		return
	for i in range(mini(cnt, 6)):
		var d := (src as Node).duplicate() as Node3D
		if d == null:
			continue
		root.add_child(d)
		d.position = centre + Vector3(randf_range(-half + 1.0, half - 1.0), 0.0, randf_range(-half + 1.0, half - 1.0))
		d.rotation.y = randf() * TAU
		var ab := builder._world_aabb(d)
		d.position.y -= maxf(0.0, ab.position.y)


func _extract_mesh(scene: Node) -> Mesh:
	var stack: Array = [scene]
	while not stack.is_empty():
		var nn = stack.pop_back()
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			return (nn as MeshInstance3D).mesh
		if nn is ImporterMeshInstance3D and (nn as ImporterMeshInstance3D).mesh != null:
			return (nn as ImporterMeshInstance3D).mesh.get_mesh()
		for c in nn.get_children():
			stack.append(c)
	return null


func _add_mesh_collision(node: Node) -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		var nn = stack.pop_back()
		for c in nn.get_children():
			stack.append(c)
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			(nn as MeshInstance3D).create_trimesh_collision()


# ---------------- shared flat nav ----------------

func _rebuild_shared_nav() -> void:
	if _nav_root == null:
		return
	if _nav_region != null and is_instance_valid(_nav_region):
		_nav_region.queue_free()
		_nav_region = null

	var min_gx: int = start_cell.x
	var max_gx: int = start_cell.x
	var min_gz: int = start_cell.y
	var max_gz: int = start_cell.y
	for k: String in resident.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var cgx := int(parts[0])
		var cgz := int(parts[1])
		min_gx = mini(min_gx, cgx)
		max_gx = maxi(max_gx, cgx)
		min_gz = mini(min_gz, cgz)
		max_gz = maxi(max_gz, cgz)

	var pad := 1.0
	var x0 := float(min_gx) * cell_size - pad
	var x1 := float(max_gx + 1) * cell_size + pad
	var z0 := float(min_gz) * cell_size - pad
	var z1 := float(max_gz + 1) * cell_size + pad

	var nav := NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.7
	var verts := PackedVector3Array([
		Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z0),
		Vector3(x1, 0.0, z1), Vector3(x0, 0.0, z1),
	])
	nm.set_vertices(verts)
	nm.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav.navigation_mesh = nm
	_nav_root.add_child(nav)
	_nav_region = nav


# ---------------- enemy union upkeep ----------------

func _prune_enemies() -> void:
	var live: Array = []
	for e in enemies:
		if is_instance_valid(e):
			live.append(e)
	enemies = live


# ---------------- helpers ----------------

func _key(gx: int, gz: int) -> String:
	return str(gx) + "," + str(gz)


func _area_id(c: Vector2i) -> String:
	return "c" + str(c.x) + "_" + str(c.y)


func _player_cell() -> Vector2i:
	var p := player.global_position
	return Vector2i(floori(p.x / cell_size), floori(p.z / cell_size))


func _cell_centre(gx: int, gz: int) -> Vector3:
	return Vector3(float(gx) * cell_size + cell_size * 0.5, 0.0, float(gz) * cell_size + cell_size * 0.5)


func _update_far(pc: Vector3) -> void:
	if terrain == null or _nav_root == null:
		return
	if Vector2(pc.x, pc.z).distance_to(_far_centre) < cell_size * 1.5:
		return
	_far_centre = Vector2(pc.x, pc.z)
	if _far != null and is_instance_valid(_far):
		_far.queue_free()
	_far = terrain.far_skirt(Vector3(pc.x, 0.0, pc.z), cell_size * 14.0, 44)
	_nav_root.add_child(_far)


func _update_water(pc: Vector3) -> void:
	if water_cfg == null or _nav_root == null:
		return
	if Vector2(pc.x, pc.z).distance_to(_water_centre) < cell_size * 1.5:
		return
	_water_centre = Vector2(pc.x, pc.z)
	if _water != null and is_instance_valid(_water):
		_water.queue_free()
	_water = GWater.body(Vector3(pc.x, 0.0, pc.z), cell_size * 14.0, water_level, terrain, 48, water_cfg)
	_nav_root.add_child(_water)


func _ground_y(wx: float, wz: float) -> float:
	return terrain.height(wx, wz) if terrain != null else 0.0


# Resolve a per-cell terrain floor material from the cell's `ground` spec: a surface-preset name
# ("asphalt"/"sandstone"/"grass") or a {material} dict overrides the global terrain material for THIS
# cell; a legacy [r,g,b] array or the default returns null (keep the global terrain material).
func _terrain_cell_mat(spec) -> Material:
	if typeof(spec) == TYPE_STRING and String(spec) != "":
		return GSurf.surface(String(spec))
	if typeof(spec) == TYPE_DICTIONARY and (spec.has("material") or spec.has("preset")):
		return GSurf.surface(spec)
	return null


func _cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _evict_farthest() -> void:
	var worst_key := ""
	var worst_d := -1
	for k: String in resident.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var d := _cheb(Vector2i(int(parts[0]), int(parts[1])), _cur_cell)
		if d > worst_d:
			worst_d = d
			worst_key = k
	if worst_key != "":
		_evict(worst_key)


func grid_world_rect() -> Rect2:
	var min_gx := 2147483647
	var max_gx := -2147483648
	var min_gz := 2147483647
	var max_gz := -2147483648
	for k: String in grid.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var gx := int(parts[0])
		var gz := int(parts[1])
		min_gx = mini(min_gx, gx)
		max_gx = maxi(max_gx, gx)
		min_gz = mini(min_gz, gz)
		max_gz = maxi(max_gz, gz)
	if min_gx > max_gx:
		return Rect2(cell_size * 0.5, cell_size * 0.5, cell_size, cell_size)
	var x0 := float(min_gx) * cell_size + cell_size * 0.5
	var z0 := float(min_gz) * cell_size + cell_size * 0.5
	var w := float(max_gx - min_gx) * cell_size
	var h := float(max_gz - min_gz) * cell_size
	return Rect2(x0, z0, w, h)
