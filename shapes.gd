class_name GShapes
## SHAPE VOCABULARY - the FORM axis of the construction system. A small, VETTED, render-tested library of
## parametric solid factories. The agent only PARAMETERIZES these (it never emits raw vertices), so any
## architectural silhouette - house, pyramid, obelisk, pylon, tower, column, dome, spire - composes from the
## SAME vocabulary. Theme-agnostic: a pyramid and a gable house are two parameterizations, not two generators.
##
## Built mostly from Godot built-in primitive meshes (BoxMesh / CylinderMesh with top+bottom radius / PrismMesh /
## SphereMesh hemisphere) + transforms, so there is almost no hand-authored geometry to get wrong. The ONLY
## ArrayMesh shape is the rectangular frustum/pyramid; its faces are emitted with outward normals + correct
## winding computed from the convex centroid, so it can never render inside-out. gl_compatibility / WebGL2-safe.
##
## CONTRACT: every factory returns a MeshInstance3D (or Node3D for composed shapes) whose visual BASE sits at
## local y=0 and is CENTERED at local x=z=0. Materials are applied by the caller (surfaces.gd); add_collider() wraps.

# primitive-based solids

## A box. size = (width, height, depth). Base at y=0.
static func box(size: Vector3) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _mi(m, size.y * 0.5)


## A round/cone/n-gon vertical solid. bottom_r/top_r taper (top_r=0 -> cone/spire); sides = cross-section. Base y=0.
static func cylinder(bottom_r: float, top_r: float, height: float, sides: int = 24) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.bottom_radius = maxf(0.0, bottom_r)
	m.top_radius = maxf(0.0, top_r)
	m.height = height
	m.radial_segments = maxi(3, sides)
	m.rings = 1
	return _mi(m, height * 0.5)


## An n-sided straight prism (column/pier). sides=6 hex, 8 octagon, etc.
static func prism_ngon(sides: int, radius: float, height: float) -> MeshInstance3D:
	return cylinder(radius, radius, height, sides)


## A symmetric wedge / gable cross-section (triangular prism). For a GABLE ROOF: size=(span, ridge_height, depth).
static func wedge(size: Vector3) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = size
	return _mi(m, size.y * 0.5)


## A gable roof spanning footprint (x=span, y=depth) rising to ridge_height. (Alias of a wedge sized for a roof.)
static func roof_gable(footprint: Vector2, ridge_height: float) -> MeshInstance3D:
	return wedge(Vector3(footprint.x, ridge_height, footprint.y))


## A single-slope ramp (right-triangle prism). Rises along +X across `run`, by `rise`, `width` deep along Z.
static func ramp(run: float, rise: float, width: float) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = Vector3(run, rise, width)
	m.left_to_right = 0.0   # peak at one edge -> a right triangle, i.e. a single slope
	return _mi(m, rise * 0.5)


## A hemispherical / squashed dome. radius = base radius, height = how tall. Base at y=0.
static func dome(radius: float, height: float, segments: int = 16) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = height          # for a hemisphere, `height` IS the vertical extent (base at y=0)
	m.is_hemisphere = true
	m.radial_segments = maxi(6, segments * 2)
	m.rings = maxi(3, segments)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	return mi


# ArrayMesh: rectangular frustum / pyramid

## A rectangular solid that tapers with height: base (x=width, y=depth) at y=0 -> top (x,y) at y=height.
##   top == base -> a box;  top < base -> battered/tapered;  top == (0,0) -> a true pyramid. Base at y=0.
static func frustum(base: Vector2, top: Vector2, height: float) -> MeshInstance3D:
	var bx := base.x * 0.5
	var bz := base.y * 0.5
	var b := [
		Vector3(-bx, 0.0, -bz), Vector3(bx, 0.0, -bz),
		Vector3(bx, 0.0, bz), Vector3(-bx, 0.0, bz),
	]
	var centroid := Vector3(0.0, height * 0.5, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if top.x <= 0.001 and top.y <= 0.001:
		# pyramid: 4 triangular sides to an apex + a base quad
		var apex := Vector3(0.0, height, 0.0)
		for i in 4:
			_emit_face(st, [b[i], b[(i + 1) % 4], apex], centroid)
		_emit_face(st, [b[0], b[1], b[2], b[3]], centroid)
	else:
		var tx := top.x * 0.5
		var tz := top.y * 0.5
		var t := [
			Vector3(-tx, height, -tz), Vector3(tx, height, -tz),
			Vector3(tx, height, tz), Vector3(-tx, height, tz),
		]
		for i in 4:
			_emit_face(st, [b[i], b[(i + 1) % 4], t[(i + 1) % 4], t[i]], centroid)
		_emit_face(st, [b[0], b[1], b[2], b[3]], centroid)   # bottom
		_emit_face(st, [t[0], t[1], t[2], t[3]], centroid)   # top
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	return mi


## A true pyramid (base -> apex). Convenience over frustum().
static func pyramid(base: Vector2, height: float) -> MeshInstance3D:
	return frustum(base, Vector2.ZERO, height)


# composed: a column

## A column = round shaft + optional base plinth + optional capital flare. Returns a Node3D.
static func column(radius: float, height: float, sides: int = 24, capital: bool = true, plinth: bool = true) -> Node3D:
	var root := Node3D.new()
	var cap_h := height * 0.10 if capital else 0.0
	var base_h := height * 0.06 if plinth else 0.0
	var shaft_h := height - cap_h - base_h
	if plinth:
		var p := cylinder(radius * 1.25, radius * 1.1, base_h, sides)
		root.add_child(p)
	var shaft := cylinder(radius * 1.05, radius * 0.92, shaft_h, sides)   # slight entasis taper
	shaft.position.y = base_h
	root.add_child(shaft)
	if capital:
		var c := cylinder(radius * 0.95, radius * 1.3, cap_h, sides)       # flare out at the top
		c.position.y = base_h + shaft_h
		root.add_child(c)
	return root


# colliders + materials

## Apply a material to every MeshInstance3D under `node` (or to a single MeshInstance3D).
static func set_material(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for c in node.get_children():
		set_material(c, mat)


## Wrap a built shape with a solid STATIC collider. mode "box" (cheap, from AABB) or "mesh" (trimesh, exact).
static func add_collider(node: Node3D, mode: String = "box") -> Node3D:
	if mode == "mesh":
		for mi in _all_meshes(node):
			mi.create_trimesh_collision()
	else:
		var ab := _aabb(node)
		if ab.size.length() > 0.01:
			var body := StaticBody3D.new()
			body.collision_layer = 1
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = ab.size
			cs.shape = box
			cs.position = ab.position + ab.size * 0.5
			body.add_child(cs)
			node.add_child(body)
	return node


# internals

static func _mi(mesh: Mesh, base_offset_y: float) -> MeshInstance3D:
	# Built-in primitive meshes are centred at the origin; lift by half-height so the BASE rests at y=0.
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position.y = base_offset_y
	return mi


# Emit one convex, planar face (tri or quad) with an OUTWARD normal + Godot-correct CW-from-outside winding.
static func _emit_face(st: SurfaceTool, verts: Array, centroid: Vector3) -> void:
	var v0: Vector3 = verts[0]
	var v1: Vector3 = verts[1]
	var v2: Vector3 = verts[2]
	var g := (v1 - v0).cross(v2 - v0)
	if g.length() < 1e-9:
		return   # degenerate
	var fc := Vector3.ZERO
	for v in verts:
		fc += v
	fc /= float(verts.size())
	var outward := fc - centroid
	var n: Vector3
	var ordered: Array
	if g.dot(outward) > 0.0:
		n = g.normalized()
		ordered = verts.duplicate()
		ordered.reverse()
	else:
		n = (-g).normalized()
		ordered = verts
	for ti in range(1, ordered.size() - 1):
		for vert in [ordered[0], ordered[ti], ordered[ti + 1]]:
			st.set_normal(n)
			st.set_uv(_planar_uv(vert, n))
			st.add_vertex(vert)


# Simple world-space planar UV (1 unit = 1 tile).
static func _planar_uv(v: Vector3, n: Vector3) -> Vector2:
	var an := Vector3(absf(n.x), absf(n.y), absf(n.z))
	if an.y >= an.x and an.y >= an.z:
		return Vector2(v.x, v.z)
	if an.x >= an.z:
		return Vector2(v.z, v.y)
	return Vector2(v.x, v.y)


static func _all_meshes(node: Node) -> Array:
	var out: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


static func _aabb(node: Node3D) -> AABB:
	# Relative-to-node bounds via accumulated local transforms - add_collider() runs on a freshly
	# built, NOT-yet-parented structure, so reading global_transform would print "!is_inside_tree()".
	var merged := AABB()
	var first := true
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair = stack.pop_back()
		var n = pair[0]
		var xf: Transform3D = pair[1]
		if n is Node3D:
			xf = xf * (n as Node3D).transform
		for c in n.get_children():
			stack.append([c, xf])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var wa: AABB = xf * (n as MeshInstance3D).get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged
