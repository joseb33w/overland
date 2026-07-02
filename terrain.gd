class_name GTerrain
## TERRAIN — a global noise heightfield + per-cell heightmap mesh + collider, so an open world is ROLLING ground
## (hills, dunes, valleys) instead of a dead flat slab (the #1 illusion-breaker). SEAMLESS by construction:
## height() is a PURE function of world (x,z), so adjacent streamed cells line up at their shared edge with no
## crack. OPT-IN per world (world.json top-level `terrain: {...}`); without it, cells stay flat (cities/structured
## worlds want flat).
##
## The chunk streamer calls cell_terrain() for the cell floor and height()/normal_at() to LIFT every placed object
## onto the surface; the player (CharacterBody3D + gravity) walks on the trimesh collider.
##
## world.json:  "terrain": { "amplitude": 8, "frequency": 0.012, "seed": 7, "octaves": 4, "material": "sand",
##                           "resolution": 8, "warp": 0.0, "floor": 0.0 }

var amplitude := 6.0       # peak-to-mid height variation (metres)
var frequency := 0.012     # base noise frequency (LOWER = broader, gentler hills)
var seed_i := 1337
var octaves := 4
var resolution := 8        # heightmap samples per cell EDGE (8 -> 8x8 quads/cell; cheap, 9-cell ring)
var floor_y := 0.0         # baseline the heightfield oscillates around
var warp_amt := 0.0        # optional domain warp (dunes/ridges); 0 = smooth rolling
var material_spec = "grass"

var _noise: FastNoiseLite
var _warp: FastNoiseLite
var _mat: Material
var _ready := false


func setup(cfg: Dictionary) -> void:
	amplitude = float(cfg.get("amplitude", 6.0))
	frequency = float(cfg.get("frequency", 0.012))
	seed_i = int(cfg.get("seed", 1337))
	octaves = clampi(int(cfg.get("octaves", 4)), 1, 7)
	resolution = clampi(int(cfg.get("resolution", 8)), 2, 24)
	floor_y = float(cfg.get("floor", 0.0))
	warp_amt = float(cfg.get("warp", 0.0))
	material_spec = cfg.get("material", "grass")
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = seed_i
	_noise.frequency = frequency
	_noise.fractal_octaves = octaves
	if warp_amt > 0.0:
		_warp = FastNoiseLite.new()
		_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_warp.seed = seed_i + 777
		_warp.frequency = frequency * 0.5
	_mat = GSurf.surface(material_spec)
	_ready = true


## The global heightfield: world-space y at (x,z). Deterministic + seamless — the SINGLE source of truth used by
## both the mesh builder and the placement/lift code, so a prop and the ground under it always agree.
func height(x: float, z: float) -> float:
	if not _ready:
		return floor_y
	var wx := x
	var wz := z
	if _warp != null:
		wx += _warp.get_noise_2d(x, z) * (1.0 / maxf(frequency, 0.0001)) * warp_amt * 0.15
		wz += _warp.get_noise_2d(z, x) * (1.0 / maxf(frequency, 0.0001)) * warp_amt * 0.15
	return floor_y + _noise.get_noise_2d(wx, wz) * amplitude


## Approximate surface normal at (x,z) via finite differences — for orienting props to the slope if wanted.
func normal_at(x: float, z: float) -> Vector3:
	var e := 0.5
	var hl := height(x - e, z)
	var hr := height(x + e, z)
	var hd := height(x, z - e)
	var hu := height(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## Build the floor for ONE cell: a heightmap MeshInstance3D (a grid sampling height() at WORLD coords) + a
## StaticBody3D trimesh collider that exactly matches what's rendered (so the player walks on the visible ground).
## Returns a Node3D positioned at the cell's world centre; the mesh is local to it.
func cell_terrain(centre: Vector3, size: float, mat_override: Material = null) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(centre.x, 0.0, centre.z)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := resolution
	var step := size / float(n)
	var half := size * 0.5
	# vertex grid: local (lx,lz) in [-half, half]; y = height at WORLD coord; UV in [0,1] across the cell
	for iz in n:
		for ix in n:
			var lx0 := -half + float(ix) * step
			var lz0 := -half + float(iz) * step
			var lx1 := lx0 + step
			var lz1 := lz0 + step
			var a := _vert(centre, lx0, lz0)
			var b := _vert(centre, lx1, lz0)
			var c := _vert(centre, lx1, lz1)
			var d := _vert(centre, lx0, lz1)
			# two TOP-FACING triangles. Winding (a,b,c)/(a,c,d) is CW-from-above = Godot front-face (visible from
			# the sky, not culled); normals are set EXPLICITLY to the upward heightfield normal (generate_normals
			# would derive them from winding and point them DOWN - wrong for lighting).
			_t(st, centre, a, b, c, size)
			_t(st, centre, a, c, d, size)
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	# a district cell can override the global terrain material (asphalt downtown, cobble plaza,
	# grass countryside) so the biomes read distinct even though ONE heightfield rolls under them
	mi.material_override = mat_override if mat_override != null else _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # big ground never casts into its own acne
	root.add_child(mi)
	mi.create_trimesh_collision()   # adds a StaticBody3D child whose shape exactly matches the surface
	# put the generated body on the world collision layer so the player/enemies collide with it
	for ch in mi.get_children():
		if ch is StaticBody3D:
			(ch as StaticBody3D).collision_layer = 1
	return root


# The far HORIZON skirt — one coarse, large-radius heightmap mesh covering `radius` metres around `centre`,
# sampling the SAME height() so it lines up with the detailed cells. Rendered slightly BELOW them (so the
# detailed cells cover it near the player; only the DISTANCE shows the skirt) and recentred on the player as
# they move. NO collider (the player only ever stands on detailed cells). This is what gives a terrain world a
# real landscape stretching to the (fog-faded) horizon instead of an abrupt resident-ring edge.
func far_skirt(centre: Vector3, radius: float, samples: int) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(8, samples)
	var step := (radius * 2.0) / float(n)
	var off := -0.5   # sit just under the detailed terrain so the seam at the ring edge is invisible at distance
	for iz in n:
		for ix in n:
			var x0 := centre.x - radius + float(ix) * step
			var z0 := centre.z - radius + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			var a := Vector3(x0, height(x0, z0) + off, z0)
			var b := Vector3(x1, height(x1, z0) + off, z0)
			var c := Vector3(x1, height(x1, z1) + off, z1)
			var d := Vector3(x0, height(x0, z1) + off, z1)
			_ft(st, a, b, c)   # same CW-from-above winding + explicit up normals as cell_terrain
			_ft(st, a, c, d)
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _ft(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for v in [a, b, c]:
		st.set_normal(normal_at(v.x, v.z))
		st.set_uv(Vector2(v.x * 0.05, v.z * 0.05))
		st.add_vertex(v)   # world-space verts (the MeshInstance sits at the origin)


# ────── internals ──────

func _vert(centre: Vector3, lx: float, lz: float) -> Vector3:
	return Vector3(lx, height(centre.x + lx, centre.z + lz), lz)


# Emit one triangle: explicit UPWARD per-vertex normals (smooth heightfield normal) + a planar UV (1 tile per
# cell; the triplanar material ignores UV anyway). Winding is the caller's (CW-from-above = front).
func _t(st: SurfaceTool, centre: Vector3, a: Vector3, b: Vector3, c: Vector3, size: float) -> void:
	for v in [a, b, c]:
		st.set_normal(normal_at(centre.x + v.x, centre.z + v.z))
		st.set_uv(Vector2((v.x + size * 0.5) / size, (v.z + size * 0.5) / size))
		st.add_vertex(v)
