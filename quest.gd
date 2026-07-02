class_name QuestSystem extends Node
## QUEST SYSTEM — tracks quests.json objectives, completes a quest when all steps are
## satisfied, grants rewards, and SETS FLAGS that gate seams (e.g. the vault door requires
## the 'dungeon_cleared' flag this sets). Collect objectives auto-update from
## RpgState.changed; kills come via notify_kill(). This flag-gating is exactly what
## qgcheck validates against world.json so a build can never ship an unwinnable quest graph.

signal objective_changed

var rpg: RpgState
var defs := {}          # id -> quest def
var st := {}            # id -> {status, kills:{type:n}, reached:{area:true}}


func setup(state: RpgState) -> void:
	rpg = state
	rpg.changed.connect(_recheck)


func load_quests(data: Dictionary) -> void:
	for q in data.get("quests", []):
		defs[q.id] = q
		st[q.id] = {status = "inactive", kills = {}, reached = {}, talked = {}}


func start(id: String) -> void:
	if defs.has(id) and st[id].status == "inactive":
		st[id].status = "active"
		objective_changed.emit()


func notify_kill(type: String) -> void:
	for id in st:
		if st[id].status == "active":
			st[id].kills[type] = int(st[id].kills.get(type, 0)) + 1
	_recheck()


func notify_area(area: String) -> void:
	for id in st:
		if st[id].status == "active":
			st[id].reached[area] = true
	_recheck()


func notify_talk(npc_id: String) -> void:
	for id in st:
		if st[id].status == "active":
			st[id].talked[npc_id] = true
	_recheck()


func _recheck() -> void:
	for id in defs:
		if st[id].status == "active" and _all_done(id):
			_complete(id)


func _all_done(id: String) -> bool:
	for step in defs[id].get("steps", []):
		if not _step_done(id, step.get("objective", {})):
			return false
	return true


func _step_done(id: String, o: Dictionary) -> bool:
	match o.get("type", ""):
		"kill_count": return int(st[id].kills.get(o.target, 0)) >= int(o.get("count", 1))
		"collect", "have_item": return rpg.has_item(o.target)
		"reach_area": return st[id].reached.has(o.target)
		"talk_to": return st[id].talked.has(o.target)
		"set_flag": return rpg.has_flag(o.target)
		_: return false


func _complete(id: String) -> void:
	st[id].status = "done"
	var q: Dictionary = defs[id]
	var r: Dictionary = q.get("rewards", {})
	if r.has("xp"): rpg.grant_xp(int(r.xp))
	if r.has("gold"): rpg.add_gold(int(r.gold))
	for it in r.get("items", []): rpg.add_item(it)
	for f in q.get("on_complete_flags", []): rpg.set_flag(f)   # opens the gated seam
	objective_changed.emit()


func current_objective() -> String:
	for id in defs:
		if st[id].status == "active":
			var parts: Array = []
			for step in defs[id].get("steps", []):
				var mark := "[x] " if _step_done(id, step.get("objective", {})) else "[ ] "
				parts.append(mark + str(step.get("desc", "")))
			return "QUEST: " + str(defs[id].get("name", id)) + " - " + "  ".join(parts)
		elif st[id].status == "done":
			return "QUEST: " + str(defs[id].get("name", id)) + " - COMPLETE"
	return ""
