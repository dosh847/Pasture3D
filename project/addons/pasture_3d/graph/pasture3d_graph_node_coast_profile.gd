# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCoastProfile — a CLOSED island outline turned into a coastal cross-section.
#
# Signed distance from the shoreline (positive inland, negative at sea) pushed through a parametric
# profile: sea floor → drop-off → shelf → shoreline → beach → cliff → inland rise. The profile and why it is
# parametric rather than a free curve are in src/pasture_3d_coast_profile.h; the maths lives in C++ only.
#
# The optional `cliff` mask (unwired = 1) chooses cliffed coast per cell: where it is 1 the beach narrows to
# nothing and the cliff stands in the water; where it is 0 the coast is a beach with no cliff. A future
# Wave Exposure node is meant to drive it.
@tool
class_name Pasture3DGraphNodeCoastProfile
extends Pasture3DGraphNode

@export_group("Sea")
## Water depth at the outer edge of the shelf, metres below sea level.
@export_range(0.0, 100.0, 0.1, "or_greater") var shelf_depth: float = 6.0:
	set(v):
		shelf_depth = maxf(v, 0.0)
		emit_changed()
## How far the shallow shelf reaches out from the shoreline, metres.
@export_range(0.0, 2000.0, 1.0, "or_greater") var shelf_width: float = 250.0:
	set(v):
		shelf_width = maxf(v, 0.0)
		emit_changed()
## Open-sea floor depth, metres below sea level. Never shallower than the shelf.
@export_range(0.0, 1000.0, 1.0, "or_greater") var floor_depth: float = 80.0:
	set(v):
		floor_depth = maxf(v, 0.0)
		emit_changed()
## Horizontal width of the drop-off from shelf to sea floor, metres.
@export_range(0.0, 2000.0, 1.0, "or_greater") var drop_width: float = 150.0:
	set(v):
		drop_width = maxf(v, 0.0)
		emit_changed()

@export_group("Coast")
## Height the beach rises to at its back, metres above sea level.
@export_range(0.0, 20.0, 0.1, "or_greater") var beach_height: float = 1.5:
	set(v):
		beach_height = v
		emit_changed()
## Beach width where the coast is not cliffed, metres.
@export_range(0.0, 500.0, 0.5, "or_greater") var beach_width: float = 25.0:
	set(v):
		beach_width = maxf(v, 0.0)
		emit_changed()
## Cliff height at full cliff weight, metres.
@export_range(0.0, 300.0, 0.5, "or_greater") var cliff_height: float = 30.0:
	set(v):
		cliff_height = v
		emit_changed()
## Horizontal run of the cliff face, metres. Small = steep.
@export_range(0.0, 200.0, 0.5, "or_greater") var cliff_width: float = 12.0:
	set(v):
		cliff_width = maxf(v, 0.0)
		emit_changed()

@export_group("Inland")
## Extra height gained behind the cliff, metres.
@export_range(0.0, 2000.0, 1.0, "or_greater") var inland_height: float = 80.0:
	set(v):
		inland_height = v
		emit_changed()
## Distance over which the inland rise is gained, metres.
@export_range(0.0, 10000.0, 1.0, "or_greater") var inland_width: float = 600.0:
	set(v):
		inland_width = maxf(v, 0.0)
		emit_changed()
## Shape of the inland rise. Below 1 climbs early and plateaus (Milos), above 1 stays low then climbs.
@export_range(0.05, 4.0, 0.01) var inland_curve: float = 0.7:
	set(v):
		inland_curve = maxf(v, 0.01)
		emit_changed()

@export_group("Output")
## The shoreline's height. The whole profile is offset by it.
@export var sea_level: float = 0.0:
	set(v):
		sea_level = v
		emit_changed()
## Soft edge of the shelf / beach / cliff masks, metres.
@export_range(0.0, 50.0, 0.1, "or_greater") var mask_feather: float = 4.0:
	set(v):
		mask_feather = maxf(v, 0.0)
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"coast_profile"


## The sixteen-slot block. The order is `coast_profile_params_from`'s in src/pasture_3d_coast_profile.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = shelf_depth
	p[1] = shelf_width
	p[2] = floor_depth
	p[3] = drop_width
	p[4] = beach_height
	p[5] = beach_width
	p[6] = cliff_height
	p[7] = cliff_width
	p[8] = inland_height
	p[9] = inland_width
	p[10] = inland_curve
	p[11] = sea_level
	p[12] = mask_feather
	return p


func native_out_count() -> int:
	return 5 # height, signed_distance, shelf, beach, cliff


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## Port 0 is the outline; the cliff weight is the secondary grid, on port 1.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"outline", PortType.PATH).require(),
		Pasture3DGraphPort.field(&"cliff", PortType.MASK).unwired(1.0).as_aux(),
	]


## Port order is a wire format: APPEND only.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"signed_distance", PortType.SIGNED),
		Pasture3DGraphPort.field(&"shelf", PortType.MASK),
		Pasture3DGraphPort.field(&"beach", PortType.MASK),
		Pasture3DGraphPort.field(&"cliff", PortType.MASK),
	]


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[0] if p_paths.size() > 0 and p_paths[0] is Pasture3DGraphPath else null


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "coast_profile_grid"):
		push_error("[Pasture3D] Pasture3DUtil.coast_profile_grid is not bound. Rebuild GDExtension.")
		return _sea_fill(n)
	var cliff: PackedFloat32Array = p_inputs[1] if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array \
			and p_inputs[1].size() == n else PackedFloat32Array()
	# An open path has no inside: hand over nothing, which the kernel reads as open sea.
	var pts := _path.points if _path != null and _path.closed else PackedVector2Array()
	var res: Dictionary = Pasture3DUtil.coast_profile_grid(pts, cliff, p_gw, p_gh, p_rect, _params())
	var h: PackedFloat32Array = res.get("height", PackedFloat32Array())
	if h.size() != n:
		push_error("[Pasture3D] coast_profile_grid returned %d cells for a %d cell grid." % [h.size(), n])
		return _sea_fill(n)
	return [h, res["signed_distance"], res["shelf"], res["beach"], res["cliff"]]


## Open sea at floor depth: what "no island" means. Never sea level, which would be a flat continent.
func _sea_fill(p_n: int) -> Array:
	var h := PackedFloat32Array()
	h.resize(p_n)
	h.fill(sea_level - maxf(floor_depth, shelf_depth))
	var sd := PackedFloat32Array()
	sd.resize(p_n)
	sd.fill(-10000.0)
	var z := PackedFloat32Array()
	z.resize(p_n)
	return [h, sd, z, z.duplicate(), z.duplicate()]


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path != null and not _path.closed:
		out.append("Coast Profile needs a CLOSED outline; this path is open, so everything reads as open sea.")
	if floor_depth < shelf_depth:
		out.append("Floor depth is shallower than the shelf; the floor is held at the shelf depth.")
	return out
