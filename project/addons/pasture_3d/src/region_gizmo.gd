# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The region gizmo (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §G): every known region drawn as a flat
# outline at the top of its height range, tinted by its type's editor colour. Loaded is solid, unloaded is
# dashed, locked is hatched, selected gets a white inner outline. A drag's box selection is drawn too.
#
# `lines()` is pure (the region selection model in, line segments out) so a headless gate can check what is
# drawn; `show()` puts it on a MeshInstance3D kept as an INTERNAL child of the terrain, which is never
# saved with the scene. No class_name: preload it.
@tool
extends RefCounted

const RegionSelection := preload("res://addons/pasture_3d/src/region_selection.gd")

## Dashes per edge of an unloaded region, and hatch lines across a locked one.
const DASHES := 12
const HATCHES := 8
const INSET := 0.01 # of the region's width, so neighbouring outlines do not draw over each other
const SELECT_INSET := 0.035
const LIFT := 1.0 # metres above the region's top, so the outline is not buried in its own ground
const SELECT_COLOR := Color(1, 1, 1, 1)
const BOX_COLOR := Color(1.0, 0.9, 0.2, 1.0)

var _mi: MeshInstance3D = null


## {vertices, colors, regions: {loc: {state, dashed, hatched, selected, segments}}}; vertices pair into
## PRIMITIVE_LINES segments. p_box, when not null, is [corner_a, corner_b] in region locations.
func lines(p_model: RegionSelection, p_box: Variant = null) -> Dictionary:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var regions := {}
	var out := {"vertices": verts, "colors": cols, "regions": regions}
	var terrain = p_model.terrain
	if terrain == null or not is_instance_valid(terrain) or terrain.data == null:
		return out
	var rsw: float = float(terrain.get_region_size()) * terrain.get_vertex_spacing()
	for loc in p_model.known():
		var inf := p_model.info(loc)
		var st: int = inf["state"]
		var hr: Vector2 = inf.get("height_range", Vector2.ZERO)
		var y: float = (hr.y if is_finite(hr.y) else 0.0) + LIFT
		var col: Color = inf.get("type_color", Color.WHITE)
		var dashed := st == RegionSelection.STATE_UNLOADED
		var hatched := bool(inf.get("locked", false))
		var sel := p_model.selected.has(loc)
		if dashed:
			col.a *= 0.75
		var before := verts.size()
		var o := Vector2(loc.x, loc.y) * rsw
		var a := o + Vector2(rsw, rsw) * INSET
		var b := o + Vector2(rsw, rsw) * (1.0 - INSET)
		_rect(verts, cols, a, b, y, col, dashed)
		if hatched:
			_hatch(verts, cols, a, b, y, col)
		if sel:
			_rect(verts, cols, o + Vector2(rsw, rsw) * SELECT_INSET, o + Vector2(rsw, rsw) * (1.0 - SELECT_INSET),
				y, SELECT_COLOR, false)
		regions[loc] = {"state": st, "dashed": dashed, "hatched": hatched, "selected": sel,
				"segments": (verts.size() - before) / 2, "color": col}
	if p_box != null:
		var ca: Vector2i = p_box[0]
		var cb: Vector2i = p_box[1]
		var lo := Vector2(mini(ca.x, cb.x), mini(ca.y, cb.y)) * rsw
		var hi := (Vector2(maxi(ca.x, cb.x), maxi(ca.y, cb.y)) + Vector2.ONE) * rsw
		_rect(verts, cols, lo, hi, LIFT, BOX_COLOR, false)
		out["box"] = Rect2(lo, hi - lo)
	return out


func _seg(p_v: PackedVector3Array, p_c: PackedColorArray, p_a: Vector2, p_b: Vector2, p_y: float, p_col: Color) -> void:
	p_v.append(Vector3(p_a.x, p_y, p_a.y))
	p_v.append(Vector3(p_b.x, p_y, p_b.y))
	p_c.append(p_col)
	p_c.append(p_col)


func _rect(p_v: PackedVector3Array, p_c: PackedColorArray, p_a: Vector2, p_b: Vector2, p_y: float,
		p_col: Color, p_dashed: bool) -> void:
	var corners := [p_a, Vector2(p_b.x, p_a.y), p_b, Vector2(p_a.x, p_b.y), p_a]
	for k in 4:
		var e0: Vector2 = corners[k]
		var e1: Vector2 = corners[k + 1]
		if not p_dashed:
			_seg(p_v, p_c, e0, e1, p_y, p_col)
			continue
		# DASHES dashes with a gap after each: the edge in 2 * DASHES pieces, the even ones drawn.
		for i in DASHES:
			_seg(p_v, p_c, e0.lerp(e1, float(2 * i) / (2 * DASHES)), e0.lerp(e1, float(2 * i + 1) / (2 * DASHES)),
				p_y, p_col)


## 45-degree lines x + z = c across the rectangle, clipped to it.
func _hatch(p_v: PackedVector3Array, p_c: PackedColorArray, p_a: Vector2, p_b: Vector2, p_y: float, p_col: Color) -> void:
	var w := p_b.x - p_a.x
	var h := p_b.y - p_a.y
	for k in range(1, HATCHES * 2):
		var c := float(k) / (HATCHES * 2) * (w + h) # along x + z, measured from p_a
		var s := Vector2(p_a.x + minf(c, w), p_a.y + maxf(c - w, 0.0))
		var e := Vector2(p_a.x + maxf(c - h, 0.0), p_a.y + minf(c, h))
		_seg(p_v, p_c, s, e, p_y, p_col)


## Draw the model into the terrain's viewport. Hidden with p_visible false.
func show(p_model: RegionSelection, p_visible: bool, p_box: Variant = null) -> void:
	var terrain = p_model.terrain
	if not p_visible or terrain == null or not is_instance_valid(terrain) or not terrain.is_inside_tree():
		if _mi != null and is_instance_valid(_mi):
			_mi.visible = false
		return
	if _mi == null or not is_instance_valid(_mi) or _mi.get_parent() != terrain:
		detach()
		_mi = MeshInstance3D.new()
		_mi.name = "RegionGizmo"
		_mi.top_level = true
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true
		mat.vertex_color_use_as_albedo = true
		_mi.material_override = mat
		terrain.add_child(_mi, false, Node.INTERNAL_MODE_BACK)
	_mi.global_transform = Transform3D.IDENTITY
	var l := lines(p_model, p_box)
	var verts: PackedVector3Array = l["vertices"]
	if verts.is_empty():
		_mi.visible = false
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = l["colors"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	# Outlines hang above their own ground and the whole world is in view: no culling by the default AABB.
	_mi.custom_aabb = AABB(Vector3(-1e7, -1e5, -1e7), Vector3(2e7, 2e5, 2e7))
	_mi.mesh = mesh
	_mi.visible = true


func detach() -> void:
	if _mi != null and is_instance_valid(_mi):
		_mi.queue_free()
	_mi = null
