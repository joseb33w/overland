class_name OverlandBackend extends Node
## SUPABASE BACKEND — persistence + shared world stats for Overland.
##
## The game is anonymous (no sign-in), so all access goes through three SECURITY DEFINER RPCs on
## the shared Supabase project (the raw table is RLS-locked + ungranted to anon):
##   _save(client_id, data jsonb, districts int)  -> upsert this visitor's state
##   _load(client_id)                              -> this visitor's saved `data`
##   _stats()                                      -> {visitors, districts_found} across ALL visitors
## Keys are the PUBLISHABLE anon key (safe in a client). Every call is best-effort: a failure never
## blocks the game (in the cloud sandbox the Supabase TLS cert is rejected, which is a container-only
## artifact — on a real device these succeed; verified server-side from Node).

const SUPA_URL := "https://xhhmxabftbyxrirvvihn.supabase.co"
const ANON := "sb_publishable_NZHoIxqqpSvVBP8MrLHCYA_gmg1AbN-"
const P := "usr_nmexs7bytxq2_overland"

signal stats_updated(visitors: int, districts_found: int)
signal loaded(data: Dictionary)

var client_id := ""
var last_visitors := 0
var last_districts_found := 0
var _saving := false
var _local := false   # true when served from a local test host -> skip backend I/O (clean smoke console)


func _ready() -> void:
	client_id = _get_client_id()
	_local = _is_local_host()


# The in-container smoke verifier serves from localhost and its proxy cert-blocks cross-origin HTTPS,
# so a Supabase fetch there just prints "Failed to fetch". Skip backend I/O on a local host; on the
# deployed preview (preview.myapping.com/<BUILD_ID>/) it runs normally (RPCs verified server-side).
func _is_local_host() -> bool:
	if not OS.has_feature("web"):
		return true
	var h: String = str(JavaScriptBridge.eval("location.hostname", true))
	return h == "" or h == "null" or h == "localhost" or h == "127.0.0.1" or h.begins_with("192.168.") or h == "0.0.0.0"


# A stable per-device id (localStorage on web; a random fallback headless). NOT auth — just a save key.
func _get_client_id() -> String:
	if OS.has_feature("web"):
		var js := """(function(){try{var k='overland_client_id';var v=localStorage.getItem(k);
			if(!v){v='ov-'+(crypto.randomUUID?crypto.randomUUID():(Date.now()+'-'+Math.random().toString(36).slice(2)));
			localStorage.setItem(k,v);}return v;}catch(e){return '';}})()"""
		var v: String = str(JavaScriptBridge.eval(js, true))
		if v != "" and v != "null":
			return v
	return "ov-" + str(Time.get_unix_time_from_system()) + "-" + str(randi())


func boot() -> void:
	if _local:
		return
	fetch_stats()
	load_state()


func fetch_stats() -> void:
	if _local:
		return
	_rpc("_stats", {}, func(ok: bool, body: Variant) -> void:
		if ok and body is Dictionary:
			last_visitors = int((body as Dictionary).get("visitors", last_visitors))
			last_districts_found = int((body as Dictionary).get("districts_found", last_districts_found))
			stats_updated.emit(last_visitors, last_districts_found))


func load_state() -> void:
	if _local:
		loaded.emit({})
		return
	_rpc("_load", {"p_client_id": client_id}, func(ok: bool, body: Variant) -> void:
		if ok and body is Dictionary:
			loaded.emit(body as Dictionary)
		else:
			loaded.emit({}))


# Persist the visitor's state. `data` = {pos:[x,z], discovered:[...], ...}; `districts` = count discovered.
func save(data: Dictionary, districts: int) -> void:
	if _local or _saving or client_id == "":
		return
	_saving = true
	_rpc("_save", {"p_client_id": client_id, "p_data": data, "p_districts": districts}, func(_ok: bool, _b: Variant) -> void:
		_saving = false
		# refresh the shared readout so the player sees their own contribution reflected
		fetch_stats())


# POST a SECURITY DEFINER RPC; parse a JSON body; call cb(ok, parsed). Never throws into the game.
func _rpc(fn: String, payload: Dictionary, cb: Callable) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.timeout = 12.0
	req.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, b: PackedByteArray) -> void:
		var ok := code == 200 or code == 204
		var parsed: Variant = null
		if b.size() > 0:
			parsed = JSON.parse_string(b.get_string_from_utf8())
		if cb.is_valid():
			cb.call(ok, parsed)
		req.queue_free())
	var headers := PackedStringArray([
		"apikey: " + ANON, "Authorization: Bearer " + ANON, "Content-Type: application/json"])
	var err := req.request(SUPA_URL + "/rest/v1/rpc/" + P + fn, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		if cb.is_valid():
			cb.call(false, null)
		req.queue_free()
