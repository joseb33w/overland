class_name WanderAgent extends Node3D
## CROWD LOCOMOTION — makes a populated character (a Meshy/library person) WALK instead of standing still: it
## strolls to a random target within a radius of its home, pauses, picks a new one — following the terrain, facing
## its heading, and playing its WALK clip while moving / IDLE while paused (so a `populate` cast reads as a LIVING
## crowd, not statues). Cheap: pure transform movement (no physics body), so dozens can run at once. The model is a
## child of this node; `setup()` wires it. Used by chunk_manager when a `populate` entry sets behaviour:"wander".

var terrain: GTerrain = null
var home: Vector2 = Vector2.ZERO
var radius := 6.0
var speed := 1.6
var _target: Vector2
var _pause := 0.0
var _anim: AnimationPlayer = null
var _walk := ""
var _idle := ""
var _rng := RandomNumberGenerator.new()


func setup(t: GTerrain, home_xz: Vector2, r: float, spd: float, seed_i: int) -> void:
	terrain = t
	home = home_xz
	radius = maxf(1.0, r)
	speed = maxf(0.2, spd)
	_rng.seed = seed_i
	_anim = _find_anim(self)
	if _anim != null:
		_walk = _match_clip(["walk", "run", "move"])
		_idle = _match_clip(["idle", "stand"])
	_pick_target()
	set_process(true)


func _process(delta: float) -> void:
	if _pause > 0.0:
		_pause -= delta
		_play(_idle)
		return
	var here := Vector2(position.x, position.z)
	var to := _target - here
	var dist := to.length()
	if dist < 0.4:
		_pause = _rng.randf_range(1.5, 4.5)   # arrived -> idle a beat, then a new target
		_pick_target()
		return
	var dir := to / dist
	var np := here + dir * speed * delta
	position = Vector3(np.x, _ground(np.x, np.y), np.y)
	rotation.y = atan2(dir.x, dir.y)   # face the heading (model -Z forward)
	_play(_walk)


func _pick_target() -> void:
	var ang := _rng.randf() * TAU
	var rr := sqrt(_rng.randf()) * radius   # uniform over the disc
	_target = home + Vector2(cos(ang) * rr, sin(ang) * rr)


func _ground(x: float, z: float) -> float:
	return terrain.height(x, z) if terrain != null else 0.0


func _play(clip: String) -> void:
	if _anim == null or clip == "":
		return
	if _anim.current_animation != clip:
		var a := _anim.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		_anim.play(clip)


func _match_clip(keys: Array) -> String:
	if _anim == null:
		return ""
	var clips := _anim.get_animation_list()
	for k in keys:
		for c in clips:
			if String(k) in String(c).to_lower():
				return String(c)
	return String(clips[0]) if clips.size() > 0 else ""


func _find_anim(n: Node) -> AnimationPlayer:
	# Prefer an AnimationPlayer that actually HAS clips: a retargeted crowd char has BOTH the empty
	# imported player AND the AnimRig "RigPlayer" — we must pick the one with animations or it slides.
	var any: AnimationPlayer = null
	var stack: Array = [n]
	while not stack.is_empty():
		var cur = stack.pop_front()
		if cur is AnimationPlayer:
			var ap := cur as AnimationPlayer
			if not ap.get_animation_list().is_empty():
				return ap
			if any == null:
				any = ap
		for c in cur.get_children():
			stack.append(c)
	return any
