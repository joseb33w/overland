extends Node3D
## OVERLAND - orchestration for a chunk-streamed open world you WALK and DRIVE across.
## Built on the RPG streaming template: fetches loose world.json + quests.json + the asset manifest,
## wires the streaming systems, keeps the player/camera/HUD PERSISTENT across cell streaming, and adds:
##   - an ANIMATED third-person avatar (Meshy hero if generated, else a library char + AnimRig retarget)
##   - GRAVITY so the player walks the rolling terrain, and a DRIVE mode (enter/exit a car via the DRIVE btn)
##   - per-DISTRICT music + a live WORLD-STATS HUD + district-discovery persistence (Supabase, backend.gd)
## CHUNK MODE (world.mode=="chunk") replaces the one-resident zone streamer with ChunkManager (3x3 ring).

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4

const CAM_DIST := 8.5
const DRIVE_CAM_DIST := 12.5
const CAM_HEAD := 1.6
const CAM_PITCH_MIN := -1.30
const CAM_PITCH_MAX := -0.12
const LOOK_SENS := 0.006

const WALK_SPEED := 6.0
const DRIVE_SPEED := 18.0
const GRAVITY := 26.0

# The three districts the player can discover (drives the backend "districts found" + music).
const DISTRICTS := {"downtown": "Downtown", "country": "Countryside", "oldtown": "Old-Town"}
const DISTRICT_MUSIC := {"downtown": "music_city", "country": "music_country", "oldtown": "music_town"}
const DISTRICT_COUNT := 3

var origin := "https://preview.myapping.com"
var world_url := "https://preview.myapping.com/world.json"
var build_id := ""
var props_pool: Array = []

var world_data := {}
var quests_data := {}
var _world_raw := ""
var _polling := false

var env: Environment
var sun: DirectionalLight3D
var player: CharacterBody3D
var cam: Camera3D
var cam_rig: Node3D
var cam_spring: SpringArm3D
var cam_yaw := 0.0
var cam_pitch := -0.5
var look_idx := -1
var look_last := Vector2.ZERO

# animated avatar
var body_mesh: MeshInstance3D
var player_avatar: Node3D
var player_anim: AnimationPlayer
var clip_idle := ""
var clip_walk := ""
var clip_run := ""

# drive mode
var driving := false
var car_world: Node3D           # the parked car in the world (persistent)
var car_on_player: Node3D       # the car shown on the player while driving
var car_base_y := 0.0           # the car mesh's base offset (so it seats on the ground)

var rpg: RpgState
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var quest: QuestSystem
var weather: Weather3D
var chunk_manager: ChunkManager
var chunk_mode := false
var auto_roam := false
var _roam_t := 0.0

# backend + discovery
var backend: OverlandBackend
var discovered := {}
var current_district := ""
var _save_t := 0.0
var _pending_teleport = null

var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO

var hud_layer: CanvasLayer
var title_label: Label
var world_panel: PanelContainer
var world_label: RichTextLabel
var hint_label: Label
var _hint_t := 0.0
var use_btn: Button
var drive_btn: Button
var _insets := {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}


func _ready() -> void:
	if OS.has_feature("web"):
		var o = JavaScriptBridge.eval("window.location.origin", true)
		if typeof(o) == TYPE_STRING and String(o) != "":
			origin = String(o)
		var dir = JavaScriptBridge.eval("window.location.href.replace(/[^/]*$/, '')", true)
		if typeof(dir) == TYPE_STRING and String(dir) != "":
			world_url = String(dir) + "world.json"
		var bid = JavaScriptBridge.eval("location.pathname.split('/').filter(Boolean)[0] || ''", true)
		if typeof(bid) == TYPE_STRING and String(bid) != "":
			build_id = String(bid)
		var soak = JavaScriptBridge.eval("window.location.search.indexOf('soak=1')>=0", true)
		if typeof(soak) == TYPE_BOOL and soak:
			auto_roam = true

	# force full-screen fill + relayout on resize (web canvas size isn't final on frame 0)
	var w := get_window()
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	w.size_changed.connect(_relayout_ui)

	_build_env()
	_build_player()
	weather = Weather3D.new()
	add_child(weather)
	weather.setup(env, sun, cam_rig)
	_build_hud()
	AudioManager.show_tap_overlay()

	rpg = RpgState.new()
	add_child(rpg)

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.world_url = world_url
	builder.env = env
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(player, builder, self, env, interaction, rpg)
	chunk_manager.area_entered.connect(quest.notify_area)
	chunk_manager.area_entered.connect(_on_area_entered)

	backend = OverlandBackend.new()
	add_child(backend)
	backend.stats_updated.connect(_on_world_stats)
	backend.loaded.connect(_on_backend_loaded)

	var poll := Timer.new()
	poll.wait_time = 4.0
	poll.autostart = true
	poll.timeout.connect(_poll_world)
	add_child(poll)

	await get_tree().process_frame
	await get_tree().process_frame
	_relayout_ui()
	_boot()


func _boot() -> void:
	var man := HTTPRequest.new()
	add_child(man)
	man.request(origin + "/godot-assets/manifest.json")
	var mr = await man.request_completed
	man.queue_free()
	if mr[1] == 200:
		_parse_manifest(mr[3])
	builder.props_pool = props_pool

	var wq := HTTPRequest.new()
	add_child(wq)
	wq.request(world_url)
	var wr = await wq.request_completed
	wq.queue_free()
	if wr[1] != 200:
		title_label.text = "world.json fetch failed (HTTP %s)" % str(wr[1])
		return
	var raw := (wr[3] as PackedByteArray).get_string_from_utf8()
	var world = JSON.parse_string(raw)
	if not (world is Dictionary):
		title_label.text = "world.json parse error"
		return
	world_data = world
	_world_raw = raw
	_apply_weather(world)

	var qq := HTTPRequest.new()
	add_child(qq)
	qq.request(world_url.replace("world.json", "quests.json"))
	var qr = await qq.request_completed
	qq.queue_free()
	if qr[1] == 200:
		var qdata = JSON.parse_string((qr[3] as PackedByteArray).get_string_from_utf8())
		if qdata is Dictionary:
			quests_data = qdata
			quest.load_quests(qdata)
			var first_quest = quests_data.get("quests", [])
			if first_quest.size() > 0:
				quest.start(first_quest[0].get("id", ""))

	if String(world.get("mode", "")) == "chunk":
		chunk_mode = true
		scene_manager._fade.visible = false
		sun.shadow_enabled = true
		sun.shadow_normal_bias = 2.0
		sun.directional_shadow_max_distance = 46.0
		await chunk_manager.start(world)
		_spawn_car()
		backend.boot()   # load save (teleport) + fetch shared world stats
	else:
		scene_manager.start(world)


# ---------------- movement ----------------

func _physics_process(delta: float) -> void:
	if player == null:
		return
	if chunk_mode:
		_chunk_physics(delta)
		return
	if scene_manager == null or scene_manager.transitioning or scene_manager.current_root == null:
		return
	var v := _keyboard_vec() + move_vec
	if v.length() > 1.0:
		v = v.normalized()
	var dir := Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	player.velocity.x = dir.x * WALK_SPEED
	player.velocity.z = dir.z * WALK_SPEED
	player.velocity.y = -2.0 if player.is_on_floor() else player.velocity.y - GRAVITY * delta
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_animate_player(dir.length() > 0.1)


func _chunk_physics(delta: float) -> void:
	var v := _keyboard_vec() + move_vec
	if auto_roam and chunk_manager != null:
		_roam_t += delta
		var rect := chunk_manager.grid_world_rect()
		var tt := fmod(_roam_t * 0.05, 2.0)
		var f := tt if tt <= 1.0 else (2.0 - tt)
		var target := Vector3(rect.position.x, 0.0, rect.position.y).lerp(
			Vector3(rect.end.x, 0.0, rect.end.y), f)
		var to := target - player.global_position
		v = Vector2(to.x, to.z)
	if v.length() > 1.0:
		v = v.normalized()
	var dir := Vector3(v.x, 0.0, v.y) if auto_roam else Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	var spd := DRIVE_SPEED if driving else WALK_SPEED
	player.velocity.x = dir.x * spd
	player.velocity.z = dir.z * spd
	player.velocity.y = -2.0 if player.is_on_floor() else player.velocity.y - GRAVITY * delta
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_animate_player(dir.length() > 0.1)


func _process(delta: float) -> void:
	if cam_rig and player:
		cam_rig.global_position = player.global_position + Vector3(0.0, CAM_HEAD + (0.9 if driving else 0.0), 0.0)
		cam_rig.rotation.y = cam_yaw
		cam_spring.rotation.x = cam_pitch
		var target_len := DRIVE_CAM_DIST if driving else CAM_DIST
		cam_spring.spring_length = lerpf(cam_spring.spring_length, target_len, clampf(delta * 4.0, 0.0, 1.0))
	if chunk_mode and chunk_manager != null:
		chunk_manager.tick(delta)
	# periodic autosave (position + discovered) so a refresh RESUMES where you were
	if backend != null and chunk_mode:
		_save_t += delta
		if _save_t >= 8.0:
			_save_t = 0.0
			backend.save(_save_data(), discovered.size())
	if _hint_t > 0.0:
		_hint_t -= delta
		if _hint_t <= 0.0 and hint_label != null:
			hint_label.visible = false
	_refresh_stats()


# ---------------- district discovery + music ----------------

func _district_for(area_id: String) -> String:
	# area_id is "c<gx>_<gz>"; classify by gz band (matches the authored layout).
	var us := area_id.substr(1).split("_")
	if us.size() < 2:
		return "country"
	var gz := int(us[1])
	if gz <= 2:
		return "downtown"
	if gz >= 10:
		return "oldtown"
	return "country"


func _on_area_entered(area_id: String) -> void:
	var d := _district_for(area_id)
	if d == current_district:
		return
	current_district = d
	var mk := String(DISTRICT_MUSIC.get(d, ""))
	if mk != "" and ResourceLoader.exists("res://audio/%s.ogg" % mk):
		AudioManager.play_music(load("res://audio/%s.ogg" % mk))
	if not discovered.has(d):
		discovered[d] = true
		_flash_hint("Discovered %s!  (%d/%d districts)" % [DISTRICTS.get(d, d), discovered.size(), DISTRICT_COUNT])
		AudioManager.play_sfx("pickup")
		if backend != null:
			backend.save(_save_data(), discovered.size())


func _save_data() -> Dictionary:
	return {"pos": [snappedf(player.global_position.x, 0.1), snappedf(player.global_position.z, 0.1)],
		"discovered": discovered.keys()}


func _on_backend_loaded(data: Dictionary) -> void:
	var disc = data.get("discovered", [])
	if disc is Array:
		for d in disc:
			if DISTRICTS.has(String(d)):
				discovered[String(d)] = true
	var pos = data.get("pos", null)
	if pos is Array and (pos as Array).size() >= 2 and player != null:
		var px := float(pos[0])
		var pz := float(pos[1])
		player.global_position = Vector3(px, _ground_y(px, pz) + 1.5, pz)
		_flash_hint("Welcome back - resuming where you left off.")


func _on_world_stats(_v: int, _d: int) -> void:
	_refresh_stats()


# ---------------- drive ----------------

func _spawn_car() -> void:
	if not ResourceLoader.exists("res://models/car_player.glb"):
		return
	car_world = (load("res://models/car_player.glb") as PackedScene).instantiate() as Node3D
	if car_world == null:
		return
	add_child(car_world)
	car_base_y = _subtree_aabb(car_world).position.y   # world min-y with the car at origin -> base offset
	var sp := player.global_position + Vector3(4.5, 0.0, 0.0)
	car_world.global_position = Vector3(sp.x, _ground_y(sp.x, sp.z) - car_base_y, sp.z)
	var car_sign := interaction.add_sign("CAR", car_world.global_position + Vector3(0, 2.4, 0), Color(0.7, 0.9, 1.0), self)
	car_sign.font_size = 34
	car_sign.pixel_size = 0.006
	car_sign.visible = true


func _toggle_drive() -> void:
	if driving:
		driving = false
		if car_on_player != null:
			car_on_player.visible = false
		if player_avatar != null:
			player_avatar.visible = true
		elif body_mesh != null:
			body_mesh.visible = true
		if car_world != null and is_instance_valid(car_world):
			car_world.visible = true
			car_world.rotation.y = player.rotation.y
			car_world.global_position = Vector3(player.global_position.x, _ground_y(player.global_position.x, player.global_position.z) - car_base_y, player.global_position.z)
		AudioManager.play_sfx("door")
		_flash_hint("You step out of the car.")
		if drive_btn: drive_btn.text = "DRIVE"
	elif car_world != null and is_instance_valid(car_world):
		# it's YOUR car - tapping DRIVE gets you in wherever you are (the parked car hides while you drive)
		driving = true
		car_world.visible = false
		if car_on_player != null:
			car_on_player.visible = true
		if player_avatar != null:
			player_avatar.visible = false
		elif body_mesh != null:
			body_mesh.visible = false
		AudioManager.play_sfx("door")
		_flash_hint("Driving! Left joystick to move, drag right to look. Tap EXIT to step out.")
		if drive_btn: drive_btn.text = "EXIT"
	else:
		_flash_hint("Your car isn't ready yet.")
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__ov_driving=" + ("true" if driving else "false"), true)


# ---------------- hooks (no enemies in this world; kept for enemy.gd contract) ----------------

func take_damage(d: float) -> void:
	AudioManager.play_sfx("hurt")
	if rpg and rpg.take_damage(d):
		rpg.hp = rpg.max_hp


func on_enemy_killed(type: String) -> void:
	if quest:
		quest.notify_kill(type)


# ---------------- live hot-reload ----------------

func _poll_world() -> void:
	if scene_manager == null or scene_manager.transitioning or world_data.is_empty() or _polling:
		return
	_polling = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request(world_url + "?t=" + str(Time.get_ticks_msec()))
	var res = await req.request_completed
	req.queue_free()
	_polling = false
	if res[1] != 200:
		return
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw == _world_raw or raw.strip_edges() == "":
		return
	var wjson = JSON.parse_string(raw)
	if not (wjson is Dictionary):
		return
	if chunk_mode:
		if not wjson.has("cells"):
			return
	elif not wjson.has("areas"):
		return
	_world_raw = raw
	world_data = wjson
	_apply_weather(wjson)
	if chunk_mode:
		chunk_manager.reload(world_data)
	else:
		scene_manager.reload(world_data)


# ---------------- input (unhandled so HUD buttons + dialogue consume their touch first) ----------------

func _unhandled_input(event: InputEvent) -> void:
	if scene_manager == null or scene_manager.transitioning:
		return
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x < half and move_idx == -1:
				move_idx = event.index
				move_origin = event.position
				move_vec = Vector2.ZERO
			elif event.position.x >= half and look_idx == -1:
				look_idx = event.index
				look_last = event.position
		else:
			if event.index == move_idx:
				move_idx = -1
				move_vec = Vector2.ZERO
			elif event.index == look_idx:
				look_idx = -1
	elif event is InputEventScreenDrag:
		if event.index == move_idx:
			move_vec = ((event.position - move_origin) / 80.0).limit_length(1.0)
		elif event.index == look_idx:
			_apply_look(event.position - look_last)
			look_last = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and move_idx == -1 and look_idx == -1:
		_apply_look(event.relative)


func _apply_look(d: Vector2) -> void:
	cam_yaw -= d.x * LOOK_SENS
	cam_pitch = clampf(cam_pitch - d.y * LOOK_SENS, CAM_PITCH_MIN, CAM_PITCH_MAX)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	return v


# ---------------- manifest ----------------

func _parse_manifest(body: PackedByteArray) -> void:
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary):
		return
	for p in data.get("props", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if String(p.get("category", "")) != "nature":
			continue
		var fn := String(p.get("file", "")).get_file().to_lower()
		if "terrain" in fn or "path" in fn or "cliff" in fn or "beach" in fn or "railway" in fn or "road" in fn or "fence" in fn:
			continue
		var u := _norm(String(p.get("file", "")))
		if u != "" and "/godot-assets/props/" in u:
			props_pool.append(u)


func _norm(s: String) -> String:
	if s.begins_with("http"):
		return s
	if s.begins_with("/"):
		return origin + s
	if "/" in s:
		return origin + "/godot-assets/" + s
	return ""


func _apply_weather(world: Dictionary) -> void:
	if weather == null:
		return
	var sky = world.get("sky", null)
	if sky is Dictionary:
		weather.apply(sky)


# ---------------- world build (persistent player/env/hud) ----------------

func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.14
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -45.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD | L_ENEMY
	player.floor_snap_length = 1.2
	player.floor_max_angle = deg_to_rad(52.0)
	player.up_direction = Vector3.UP
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.7
	cs.shape = cap
	cs.position.y = 0.9
	player.add_child(cs)
	# placeholder capsule body (hidden once the avatar loads)
	body_mesh = MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.7
	body_mesh.mesh = cm
	body_mesh.position.y = 0.9
	body_mesh.material_override = _mat(Color(0.3, 0.6, 0.95))
	player.add_child(body_mesh)
	_build_avatar()
	# a car model that rides ON the player while driving (hidden until entering the car)
	if ResourceLoader.exists("res://models/car_player.glb"):
		car_on_player = (load("res://models/car_player.glb") as PackedScene).instantiate() as Node3D
		if car_on_player != null:
			player.add_child(car_on_player)
			car_on_player.rotation.y = 0.0   # +Z model faces the body's heading (+Z), same as the avatar
			_seat_avatar(car_on_player)
			car_on_player.visible = false

	cam_rig = Node3D.new()
	add_child(cam_rig)
	cam_spring = SpringArm3D.new()
	cam_spring.spring_length = CAM_DIST
	cam_spring.collision_mask = L_WORLD
	cam_spring.margin = 0.3
	cam_spring.rotation.x = cam_pitch
	cam_rig.add_child(cam_spring)
	cam = Camera3D.new()
	cam.fov = 64.0
	cam.far = 900.0
	cam_spring.add_child(cam)


# Build the animated third-person avatar: prefer the Meshy hero (self-animated), else a library
# KayKit character retargeted via AnimRig (both face +Z; the body faces +Z heading, so 0 offset).
func _build_avatar() -> void:
	var model: Node3D = null
	var is_meshy := false
	if ResourceLoader.exists("res://models/hero.glb"):
		var ps = load("res://models/hero.glb")
		if ps is PackedScene:
			model = (ps as PackedScene).instantiate() as Node3D
			is_meshy = model != null
	if model == null and ResourceLoader.exists("res://models/kk_Rogue_Hooded.glb"):
		model = (load("res://models/kk_Rogue_Hooded.glb") as PackedScene).instantiate() as Node3D
	if model == null:
		return
	player_avatar = model
	player.add_child(player_avatar)
	player_avatar.rotation.y = 0.0
	_seat_avatar(player_avatar)
	if is_meshy:
		player_anim = _find_ap(player_avatar)
		if player_anim != null:
			clip_idle = _pick_clip(player_anim, ["idle", "stand"])
			clip_walk = _pick_clip(player_anim, ["walk"])
			clip_run = _pick_clip(player_anim, ["run", "jog", "sprint"])
	else:
		player_anim = AnimRig.attach(player_avatar, {"idle": "Idle_A", "walk": "Walking_A", "run": "Running_A"}, ["idle", "walk", "run"])
		clip_idle = "idle"
		clip_walk = "walk"
		clip_run = "run"
	if player_anim != null:
		if clip_run == "" or not player_anim.has_animation(clip_run):
			clip_run = clip_walk
		if clip_walk == "" or not player_anim.has_animation(clip_walk):
			clip_walk = clip_idle
		for c in [clip_idle, clip_walk, clip_run]:
			if c != "" and player_anim.has_animation(c):
				player_anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
	if body_mesh != null:
		body_mesh.visible = false
	_animate_player(false)


func _animate_player(moving: bool) -> void:
	if driving or player_anim == null:
		return
	var want := clip_run if moving else clip_idle
	if want == "":
		want = clip_walk if moving else clip_idle
	if want != "" and player_anim.current_animation != want and player_anim.has_animation(want):
		player_anim.play(want)


func _pick_clip(ap: AnimationPlayer, keys: Array) -> String:
	for k in keys:
		for c in ap.get_animation_list():
			if String(k) in String(c).to_lower():
				return String(c)
	return ""


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer and not (n as AnimationPlayer).get_animation_list().is_empty():
		return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


func _ground_y(wx: float, wz: float) -> float:
	if chunk_manager != null and chunk_manager.terrain != null:
		return chunk_manager.terrain.height(wx, wz)
	return 0.0


func _seat_avatar(node: Node3D) -> void:
	node.position.y -= _subtree_aabb(node).position.y


func _subtree_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


# ---------------- HUD ----------------

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)

	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 26)
	title_label.add_theme_color_override("font_color", Color(0.96, 0.98, 0.9))
	title_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	title_label.add_theme_constant_override("outline_size", 6)
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_layer.add_child(title_label)

	world_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.72)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	sb.border_width_left = 2; sb.border_width_top = 2; sb.border_width_right = 2; sb.border_width_bottom = 2
	sb.border_color = Color(0.4, 0.6, 0.8, 0.6)
	world_panel.add_theme_stylebox_override("panel", sb)
	world_label = RichTextLabel.new()
	world_label.bbcode_enabled = true
	world_label.fit_content = true
	world_label.scroll_active = false
	world_label.custom_minimum_size = Vector2(238, 0)
	world_label.add_theme_font_size_override("normal_font_size", 20)
	world_label.add_theme_font_size_override("bold_font_size", 22)
	world_panel.add_child(world_label)
	hud_layer.add_child(world_panel)

	hint_label = Label.new()
	hint_label.add_theme_font_size_override("font_size", 24)
	hint_label.add_theme_color_override("font_color", Color(1, 1, 0.7))
	hint_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hint_label.add_theme_constant_override("outline_size", 6)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_layer.add_child(hint_label)

	use_btn = _button("USE", func() -> void: interaction.try_use())
	drive_btn = _button("DRIVE", _toggle_drive)
	_flash_hint("Left side to move  /  drag right side to look  /  USE to talk  /  DRIVE the car")


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 26)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	hud_layer.add_child(b)
	return b


func _flash_hint(text: String) -> void:
	if hint_label == null:
		return
	hint_label.text = text
	hint_label.visible = true
	_hint_t = 6.0


func _relayout_ui() -> void:
	if hud_layer == null:
		return
	_insets = _safe_insets()
	var vp := get_viewport().get_visible_rect().size
	var mtop: float = maxf(14.0, float(_insets.get("top", 0.0)))
	var mleft: float = maxf(16.0, float(_insets.get("left", 0.0)))
	var mright: float = maxf(16.0, float(_insets.get("right", 0.0)))
	var mbot: float = maxf(18.0, float(_insets.get("bottom", 0.0)))
	var pw := 260.0
	if world_panel:
		world_panel.reset_size()
		pw = world_panel.size.x if world_panel.size.x > 0.0 else 260.0
		world_panel.position = Vector2(vp.x - pw - mright, mtop)
	if title_label:
		title_label.position = Vector2(mleft, mtop)
		title_label.size = Vector2(maxf(130.0, vp.x - pw - mright - mleft - 14.0), 0.0)
	var bw := 150.0
	var bh := 92.0
	var gap := 14.0
	if use_btn:
		use_btn.size = Vector2(bw, bh)
		use_btn.position = Vector2(vp.x - bw - mright, vp.y - bh - mbot)
	if drive_btn:
		drive_btn.size = Vector2(bw, bh)
		drive_btn.position = Vector2(vp.x - bw - mright, vp.y - bh * 2.0 - gap - mbot)
	if hint_label:
		hint_label.size = Vector2(vp.x - 40.0, 40.0)
		hint_label.position = Vector2(20.0, vp.y - bh - mbot - 56.0)


func _refresh_stats() -> void:
	if title_label == null:
		return
	var dname := String(DISTRICTS.get(current_district, "The Open Road"))
	title_label.text = "OVERLAND\n%s  |  %d fps" % [dname, Engine.get_frames_per_second()]
	if world_label != null and backend != null:
		var found := discovered.size()
		var names: Array = []
		for k in DISTRICTS:
			if discovered.has(k):
				names.append(String(DISTRICTS[k]))
		var yours := ", ".join(names) if not names.is_empty() else "none yet"
		var done := "  [DONE]" if (rpg and rpg.has_flag("saw_the_world")) else ""
		world_label.text = "[b]WORLD STATS[/b]\nVisitors: %d\nDistricts found: %d\n\n[b]You[/b]: %d / %d discovered\n%s\n\n[b]Goal[/b]: reach the old-town plaza%s" % [
			backend.last_visitors, backend.last_districts_found, found, DISTRICT_COUNT, yours, done]


# ---------------- safe area ----------------

func _safe_insets() -> Dictionary:
	if not OS.has_feature("web"):
		return {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	var js := """(() => { const d = document.createElement('div'); d.style.cssText =
		'position:fixed;top:env(safe-area-inset-top);bottom:env(safe-area-inset-bottom);left:env(safe-area-inset-left);right:env(safe-area-inset-right)';
		document.body.appendChild(d); const r = getComputedStyle(d);
		const o = {top:parseFloat(r.top)||0, bottom:parseFloat(r.bottom)||0, left:parseFloat(r.left)||0, right:parseFloat(r.right)||0};
		d.remove(); return JSON.stringify(o); })()"""
	var raw: String = str(JavaScriptBridge.eval(js, true))
	var d: Dictionary = JSON.parse_string(raw) if raw != "" and raw != "null" else {}
	return d if d is Dictionary else {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
