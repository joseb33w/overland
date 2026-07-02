class_name InteractionSystem extends Node
## INTERACTION + DIALOGUE. Chest / NPC / SEAM / DOOR, checked against RpgState. NPC talk is VOICE:
## the shared brain (npc.myapping.com/chat) writes an in-character line, the shared /speak endpoint
## synthesizes it as audio (a distinct per-character voice) so the player HEARS the NPC. Visuals live
## under the current cell/area root (freed on eviction/transition); clear()/remove_cell() drop the refs.

const NPC_BRAIN := "https://npc.myapping.com/chat"
const NPC_SPEAK := "https://npc.myapping.com/speak"
# Distinct stable voices; an NPC is assigned one deterministically from its id, so the
# same character always sounds the same and different characters sound different.
const VOICES := ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

var player: Node3D
var rpg: RpgState
var scene_manager
var quest                      # QuestSystem - for talk_to objective progress
var area_parent: Node          # current area root (set per area by AreaBuilder)
var items: Array = []

var prompt: Label
var dlg_box: PanelContainer    # ONLY system messages now (chest/door/locked) - at the TOP
var dlg_label: RichTextLabel   # so it never covers the bottom touch controls. NPC talk = VOICE.
var dlg_queue: Array = []
var active := false

# --- spoken NPC dialogue ---
var voice_player: AudioStreamPlayer = null
var _speak_queue: Array = []   # Array of {text, voice, name}
var _speaking := false
var _speaker_name := ""


func setup(p: Node3D, state: RpgState, sm, qs, hud: CanvasLayer) -> void:
	player = p
	rpg = state
	scene_manager = sm
	quest = qs
	_build_ui(hud)


func set_area_parent(node: Node) -> void:
	area_parent = node


func clear() -> void:
	items = []          # the visual nodes are freed with the old area root
	active = false
	if dlg_box:
		dlg_box.visible = false
	_speak_queue.clear()
	_speaking = false
	_speaker_name = ""
	if voice_player:
		voice_player.stop()


func _physics_process(_d: float) -> void:
	if player == null or prompt == null:
		return
	if scene_manager and scene_manager.transitioning:
		prompt.text = ""
		return
	if _speaking:
		prompt.text = _speaker_name + " is speaking..."
		return
	if active:
		prompt.text = "tap dialogue / USE to continue"
		return
	var it = _nearest(2.9)
	prompt.text = ("USE  >  " + it.label) if it else ""


# ---------------- registration (visuals under area_parent) ----------------

func add_chest(pos: Vector3, contents: Array, gold := 0, parent: Node = null, cell_key := "") -> void:
	var node := _box(pos + Vector3(0, 0.45, 0), Vector3(0.9, 0.9, 0.9), Color(0.85, 0.68, 0.22), parent)
	items.append({kind = "chest", pos = pos, node = node, label = "Open Chest",
		contents = contents, gold = gold, opened = false, cell = cell_key})


func add_npc(pos: Vector3, npc_id: String, npc_name: String, persona: String, lines: Array, model: Node = null, parent: Node = null, cell_key := "", sound := "") -> void:
	var par: Node = parent if parent != null else area_parent
	if model and model is Node3D:
		var m3 := model as Node3D
		m3.position = pos
		par.add_child(m3)
		# SEAT the character so feet rest on the floor (character GLB origins sit at the hips).
		m3.position.y -= _subtree_aabb(m3).position.y
		_idle_animate(m3)
	else:
		_capsule(pos, Color(0.30, 0.78, 0.42), par)
	# SOLID body so the player can't walk THROUGH the NPC
	var npc_body := StaticBody3D.new()
	npc_body.collision_layer = 1
	npc_body.position = pos + Vector3(0, 0.9, 0)
	var npc_cs := CollisionShape3D.new()
	var npc_cap := CapsuleShape3D.new()
	npc_cap.radius = 0.5
	npc_cap.height = 1.8
	npc_cs.shape = npc_cap
	npc_body.add_child(npc_cs)
	par.add_child(npc_body)
	# POSITIONAL character sound (an NPC murmur loop) - localized to THIS NPC, fades with distance.
	if sound != "" and ResourceLoader.exists("res://audio/%s.ogg" % sound):
		AudioManager.attach_loop(npc_body, load("res://audio/%s.ogg" % sound), -10.0, 12.0, 4.0)
	items.append({kind = "npc", pos = pos, label = "Talk to " + npc_name, npc_id = npc_id,
		npc_name = npc_name, persona = persona, lines = lines, asked = false, cell = cell_key})


func add_seam(pos: Vector3, to_area: String, spawn: String, lock: String, label: String) -> void:
	var col := Color(0.35, 0.5, 0.75) if lock == "" else Color(0.55, 0.32, 0.18)
	var node := _box(pos + Vector3(0, 1.6, 0), Vector3(3.0, 3.2, 0.5), col)
	items.append({kind = "seam", pos = pos, node = node, label = label,
		to = to_area, spawn = spawn, lock = lock})


# A PHYSICAL openable door (chunk open worlds). A leaf on a hinge pivot with a blocking collider;
# USE swings it open (Tween) + disables the collider so you walk through.
func add_door(pos: Vector3, facing: float, lock: String, label: String, parent: Node = null, cell_key := "") -> void:
	var par: Node = parent if parent != null else area_parent
	var pivot := Node3D.new()
	pivot.position = pos
	pivot.rotation.y = deg_to_rad(facing)
	par.add_child(pivot)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.2, 3.0, 0.22)
	mi.mesh = bm
	mi.material_override = _mat(Color(0.46, 0.30, 0.17) if lock == "" else Color(0.30, 0.20, 0.12))
	mi.position = Vector3(1.1, 1.5, 0.0)
	pivot.add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.4, 3.0, 0.4)
	cs.shape = bs
	cs.position = Vector3(1.1, 1.5, 0.0)
	body.add_child(cs)
	pivot.add_child(body)
	items.append({kind = "door", pos = pos, label = label, lock = lock,
		pivot = pivot, shape = cs, open = false, cell = cell_key})


# A readable world SIGN (billboarded so it always faces the camera + is never mirrored).
func add_sign(text: String, pos: Vector3, color: Color = Color(0.95, 0.9, 0.6), parent: Node = null) -> Label3D:
	var par: Node = parent if parent != null else area_parent
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 64
	lbl.pixel_size = 0.012
	lbl.modulate = color
	lbl.outline_size = 12
	lbl.outline_modulate = Color(0, 0, 0, 0.8)
	lbl.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	lbl.position = pos
	par.add_child(lbl)
	return lbl


# Drop a cell's interactables from the registry when the cell is evicted (chunk mode).
func remove_cell(cell_key: String) -> void:
	if cell_key == "":
		return
	var kept: Array = []
	for it in items:
		if String(it.get("cell", "")) != cell_key:
			kept.append(it)
	items = kept


# ---------------- use ----------------

func try_use() -> void:
	if scene_manager and scene_manager.transitioning:
		return
	if _speaking:
		return
	if active:
		_advance()
		return
	var it = _nearest(2.9)
	if it == null:
		return
	match it.kind:
		"chest": _open_chest(it)
		"npc": _talk(it)
		"seam": _use_seam(it)
		"door": _open_door(it)


func _nearest(rng: float):
	var best = null
	var bd := rng
	for it in items:
		if it.kind == "chest" and it.opened:
			continue
		if it.kind == "door" and it.get("open", false):
			continue
		var d: float = player.global_position.distance_to(it.pos)
		if d < bd:
			bd = d
			best = it
	return best


func _open_chest(it: Dictionary) -> void:
	it.opened = true
	AudioManager.play_sfx("pickup")
	if is_instance_valid(it.node):
		(it.node as MeshInstance3D).material_override = _mat(Color(0.35, 0.28, 0.12))
	var got: Array = []
	for entry in it.contents:
		rpg.add_item(entry)
		got.append(rpg.item_name(entry))
		if rpg.item_type(entry) == "weapon":
			rpg.equip(entry)
	if it.gold > 0:
		rpg.add_gold(it.gold)
		got.append("%d gold" % it.gold)
	_show(["You opened the chest.", "Found: " + ", ".join(got) + "."])


func _use_seam(it: Dictionary) -> void:
	if it.lock != "" and not rpg.has_item(it.lock) and not rpg.has_flag(it.lock):
		var need := rpg.item_name(it.lock) if rpg.ITEMS.has(it.lock) else "to clear the dungeon first"
		_show(["The door is locked.", "You need " + need + "."])
		return
	scene_manager.goto_area(it.to, it.spawn)


func _open_door(it: Dictionary) -> void:
	if it.get("open", false):
		return
	if it.lock != "" and not rpg.has_item(it.lock) and not rpg.has_flag(it.lock):
		var need := rpg.item_name(it.lock) if rpg.ITEMS.has(it.lock) else "a key"
		_show(["The door is locked.", "You need " + need + "."])
		return
	it.open = true
	AudioManager.play_sfx("door")
	if is_instance_valid(it.shape):
		(it.shape as CollisionShape3D).disabled = true   # walk through now
	if is_instance_valid(it.pivot):
		var pv := it.pivot as Node3D
		var tw := create_tween()
		tw.tween_property(pv, "rotation:y", pv.rotation.y + deg_to_rad(95.0), 0.45)
	_show(["The door swings open."])


func _talk(it: Dictionary) -> void:
	# VOICE, not a text box: speak the NPC's lines aloud (distinct per-character voice).
	if quest and String(it.get("npc_id", "")) != "":
		quest.notify_talk(it.npc_id)   # advances any talk_to quest objective
	var v := _npc_voice(it)
	for line in it.lines:
		_enqueue_speech(String(line), v, String(it.get("npc_name", "")))
	if not it.asked:
		it.asked = true
		_ask_brain(it)   # the live in-character reply gets SPOKEN when it returns


# ---------------- dialogue ----------------

func _show(lines: Array) -> void:
	dlg_queue = lines.duplicate()
	active = true
	dlg_box.visible = true
	_advance(true)


func _advance(first := false) -> void:
	if not first and not dlg_queue.is_empty():
		dlg_queue.pop_front()
	if dlg_queue.is_empty():
		active = false
		dlg_box.visible = false
		return
	dlg_label.text = str(dlg_queue[0])


func _ask_brain(it: Dictionary) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	var v := _npc_voice(it)
	req.request_completed.connect(func(_r: int, c: int, _h: PackedStringArray, b: PackedByteArray) -> void:
		if c == 200:
			var d = JSON.parse_string(b.get_string_from_utf8())
			if d is Dictionary and d.has("reply") and str(d["reply"]) != "":
				_enqueue_speech(str(d["reply"]), v, String(it.get("npc_name", "")))
		req.queue_free())
	var payload := JSON.stringify({
		"persona": it.persona,
		"messages": [{"role": "user", "content": "Greet the hero in one short sentence and give a hint."}],
	})
	req.request(NPC_BRAIN, ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)


# ---------------- spoken NPC dialogue (TTS) ----------------

func _enqueue_speech(text: String, voice: String, name: String) -> void:
	var clean := _strip_speaker(text)
	if clean.strip_edges() == "":
		return
	_speak_queue.append({"text": clean, "voice": voice, "name": name})
	if not _speaking:
		_speak_next()


func _speak_next() -> void:
	if _speak_queue.is_empty():
		_speaking = false
		_speaker_name = ""
		return
	_speaking = true
	var item: Dictionary = _speak_queue.pop_front()
	_speaker_name = String(item.get("name", ""))
	if voice_player == null:
		_speak_next()
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, c: int, _h: PackedStringArray, b: PackedByteArray) -> void:
		req.queue_free()
		if c == 200 and b.size() > 0:
			var stream := AudioStreamMP3.new()
			stream.data = b
			voice_player.stream = stream
			voice_player.play()   # _on_voice_finished advances the queue when it ends
		else:
			_on_voice_finished())
	var payload := JSON.stringify({"text": item.get("text", ""), "voice": item.get("voice", "")})
	req.request(NPC_SPEAK, ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)


func _on_voice_finished() -> void:
	_speak_next()


# Deterministic distinct voice per character (stable across a session) from its id/name.
func _npc_voice(it: Dictionary) -> String:
	var key := String(it.get("npc_id", it.get("npc_name", "")))
	if key == "":
		return VOICES[0]
	var h := 0
	for i in key.length():
		h = (h * 31 + key.unicode_at(i)) % 1000000007
	return VOICES[h % VOICES.size()]


# Drop a leading "Name: " label from an authored line so TTS speaks only the words.
func _strip_speaker(text: String) -> String:
	var idx := text.find(": ")
	if idx > 0 and idx < 24:
		return text.substr(idx + 2)
	return text


# ---------------- build helpers ----------------

func _build_ui(hud: CanvasLayer) -> void:
	prompt = Label.new()
	prompt.add_theme_font_size_override("font_size", 26)
	prompt.add_theme_color_override("font_color", Color(1, 1, 0.6))
	prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.position = Vector2(-160, -270)
	hud.add_child(prompt)

	dlg_box = PanelContainer.new()
	dlg_box.set_anchors_preset(Control.PRESET_TOP_WIDE)
	dlg_box.offset_left = 40
	dlg_box.offset_right = -40
	dlg_box.offset_top = 40
	dlg_box.offset_bottom = 150
	dlg_box.visible = false
	dlg_box.mouse_filter = Control.MOUSE_FILTER_STOP
	dlg_box.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventScreenTouch or e is InputEventMouseButton) and e.is_pressed():
			_advance())
	dlg_label = RichTextLabel.new()
	dlg_label.bbcode_enabled = true
	dlg_label.fit_content = true
	dlg_label.add_theme_font_size_override("normal_font_size", 28)
	dlg_box.add_child(dlg_label)
	hud.add_child(dlg_box)

	voice_player = AudioStreamPlayer.new()
	add_child(voice_player)
	voice_player.finished.connect(_on_voice_finished)


func _box(pos: Vector3, sz: Vector3, col: Color, parent: Node = null) -> MeshInstance3D:
	var par: Node = parent if parent != null else area_parent
	var body := StaticBody3D.new()
	body.position = pos
	body.collision_layer = 1
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = _mat(col)
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = sz
	cs.shape = bs
	body.add_child(cs)
	par.add_child(body)
	return mi


func _capsule(pos: Vector3, col: Color, parent: Node = null) -> void:
	var par: Node = parent if parent != null else area_parent
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.7
	mi.mesh = cm
	mi.position = pos + Vector3(0, 0.85, 0)
	mi.material_override = _mat(col)
	par.add_child(mi)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


# Idle-animate an NPC model IN PLACE. Self-animated models loop their idle clip; unanimated
# library rigs (empty AnimationPlayer) fall back to a procedural breathe.
func _idle_animate(model: Node) -> void:
	var ap := _find_anim_player(model)
	if ap != null and not ap.get_animation_list().is_empty():
		var clips := ap.get_animation_list()
		var pick := String(clips[0])
		for n in clips:
			if "idle" in String(n).to_lower():
				pick = String(n)
				break
		var a := ap.get_animation(pick)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		ap.play(pick)
		return
	_procedural_idle(model)


# A tiny looping breathe bob so unanimated library characters feel alive instead of dead-frozen.
func _procedural_idle(model: Node) -> void:
	if not (model is Node3D):
		return
	var m := model as Node3D
	var base_y := m.position.y
	var phase := randf() * TAU   # desync crowds so they don't bob in lockstep
	# BIND the looping tween to the MODEL (not this persistent system) so it auto-dies when the
	# model is freed on cell eviction - a tween bound to the system keeps firing with a freed
	# capture ("Lambda capture ... was freed"). This is the looping-tween ownership rule.
	var bob := m.create_tween().set_loops()
	bob.tween_method(func(t: float) -> void:
		if is_instance_valid(m):
			m.position.y = base_y + sin(t) * 0.025,
		phase, phase + TAU, 2.4).set_trans(Tween.TRANS_LINEAR)


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null


# Merged world-space mesh bounds of a subtree - for grounding a character so its feet rest at y=0.
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
