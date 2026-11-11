# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRangeSplines — crest lines for Path Range, laid out inside a closed outline.
#
# PASTURE3D_RANGES_SPEC.md step 3. Input: a CLOSED outline PATH (an island's Path Fractalize output).
# Output: a multi-part PATH (`part_starts`), one part per crest, each vertex carrying a height so Path
# Range's Use Path Heights gives taller ranges deeper inland. The maths is C++ only
# (src/pasture_3d_range_splines.cpp, which documents the three modes).
#
# ---- WHY THERE IS NO HEIGHT INPUT ----
#
# The spec sketched an optional HEIGHT (the coast profile). Every quantity this node needs — the inset from
# the shore, the depth that sets crest heights, the medial axis — is the outline's own inside distance, which
# the shared path query answers exactly. Taking no grid keeps this a pure PATH -> PATH reshape: the S4
# pre-pass resolves it host-side, and it never drops the graph off the native route.
@tool
class_name Pasture3DGraphNodeRangeSplines
extends Pasture3DGraphNodePathShape

enum Mode { SPINE, FOLDS, SCATTER }

## SPINE follows the outline's medial axis (a horseshoe island's hills follow its arms). FOLDS lays
## parallel crests across it (fold-belt ranges). SCATTER places short ridges (volcanic, rolling hills).
@export var mode: Mode = Mode.SPINE:
	set(v):
		mode = v
		_param_changed()
		notify_property_list_changed()
## Metres kept clear of the shore, by the inside distance. Every vertex of every crest is at least this
## far inside the outline.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var coast_inset: float = 50.0:
	set(v):
		coast_inset = maxf(v, 0.0)
		_param_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()
@export_group("Heights")
## Crest height in metres, written to every vertex.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var peak_height: float = 600.0:
	set(v):
		peak_height = maxf(v, 0.0)
		_param_changed()
## Scale the height by smoothstep(depth / Depth Scale), so crests near the shore are low.
@export var height_from_depth: bool = true:
	set(v):
		height_from_depth = v
		_param_changed()
		notify_property_list_changed()
## The inside distance at which a crest reaches its full height.
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:m") var depth_scale: float = 500.0:
	set(v):
		depth_scale = maxf(v, 1.0)
		_param_changed()
@export_group("Layout")
## Parts shorter than this are dropped. SPINE also prunes skeleton branches shorter than this.
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:m") var min_branch: float = 150.0:
	set(v):
		min_branch = maxf(v, 0.0)
		_param_changed()
## FOLDS: how many crests. SCATTER: how many ridges to place (fewer if they do not fit).
@export_range(0, 500, 1) var count: int = 5:
	set(v):
		count = clampi(v, 0, 500)
		_param_changed()
## Compass bearing of the crests, degrees (0 north = -Z, 90 east = +X). FOLDS and SCATTER.
@export_range(-180.0, 180.0, 0.1, "suffix:°") var angle: float = 45.0:
	set(v):
		angle = v
		_param_changed()
## FOLDS: distance between crests. SCATTER: the closest two ridges may come. 0 = auto: Count crests
## share the outline's usable width, 2 × (deepest inside distance - Coast Inset) / Count.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var spacing: float = 0.0:
	set(v):
		spacing = maxf(v, 0.0)
		_param_changed()
## Sideways bend as a fraction of the spacing (auto or not), so it scales with the layout. FOLDS and
## SCATTER. 0 = straight.
@export_range(0.0, 4.0, 0.01) var wander: float = 0.25:
	set(v):
		wander = clampf(v, 0.0, 4.0)
		_param_changed()
## SCATTER: ridge length. 0 = auto: the outline's usable width, 2 × (deepest inside distance - Coast Inset).
@export_range(0.0, 50000.0, 1.0, "or_greater", "suffix:m") var length: float = 0.0:
	set(v):
		length = maxf(v, 0.0)
		_param_changed()
## SCATTER: length varies by ± this fraction.
@export_range(0.0, 0.95, 0.01) var length_jitter: float = 0.4:
	set(v):
		length_jitter = clampf(v, 0.0, 0.95)
		_param_changed()
## SCATTER: bearing varies by ± this many degrees.
@export_range(0.0, 180.0, 0.1, "suffix:°") var angle_jitter: float = 30.0:
	set(v):
		angle_jitter = clampf(v, 0.0, 180.0)
		_param_changed()
@export_group("Sampling")
## SPINE: grid cells across the outline's longer side for the medial-axis trace.
@export_range(32, 2048, 1) var resolution: int = 256:
	set(v):
		resolution = clampi(v, 32, 2048)
		_param_changed()
## Metres between output vertices. 0 = the outline's extent / 256.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var step: float = 0.0:
	set(v):
		step = maxf(v, 0.0)
		_param_changed()


# What the last solve saw, for node_warnings: the outline's deepest inside distance (-1 = not solved), and
# the layout it used in metres (auto resolved), which `resolved_layout()` reports.
var _max_depth: float = -1.0
var _layout := {}
var _open_input: bool = false


func op() -> StringName:
	return &"range_splines"


func min_vertices() -> int:
	return 3


## The sixteen-slot block, in RangeSplinesParams order (src/pasture_3d_range_splines.h).
func solve_params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = mode
	p[1] = coast_inset
	p[2] = seed
	p[3] = peak_height
	p[4] = depth_scale
	p[5] = 1.0 if height_from_depth else 0.0
	p[6] = min_branch
	p[7] = count
	p[8] = angle
	p[9] = spacing
	p[10] = wander
	p[11] = length
	p[12] = length_jitter
	p[13] = angle_jitter
	p[14] = resolution
	p[15] = step
	return p


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	p_out.closed = false
	p_out.half_widths = PackedFloat32Array()
	p_out.points = PackedVector2Array()
	p_out.heights = PackedFloat32Array()
	p_out.part_starts = PackedInt32Array()
	_max_depth = -1.0
	_layout = {}
	_open_input = not p_src.closed
	if not p_src.closed:
		return
	if not ClassDB.class_has_method("Pasture3DUtil", "range_splines_solve"):
		push_error("[Pasture3D] Pasture3DUtil.range_splines_solve is not bound. Rebuild GDExtension.")
		return
	var res: Dictionary = Pasture3DUtil.range_splines_solve(p_src.points, true, solve_params())
	_max_depth = float(res.get("max_depth", -1.0))
	_layout = {"spacing": float(res.get("spacing", 0.0)), "length": float(res.get("length", 0.0)),
			"wander": float(res.get("wander", 0.0))}
	p_out.points = res.get("points", PackedVector2Array())
	p_out.heights = res.get("heights", PackedFloat32Array())
	p_out.part_starts = res.get("part_starts", PackedInt32Array())


## The spacing, length and wander the last solve used, in metres, with auto resolved. Empty before a solve.
func resolved_layout() -> Dictionary:
	return _layout


func _validate_property(p_property: Dictionary) -> void:
	var name: String = p_property.name
	var folds_scatter := ["count", "angle", "spacing", "wander"]
	var scatter_only := ["length", "length_jitter", "angle_jitter"]
	if (name in folds_scatter and mode == Mode.SPINE) or (name in scatter_only and mode != Mode.SCATTER) \
			or (name == "resolution" and mode != Mode.SPINE) or (name == "depth_scale" and not height_from_depth):
		p_property.usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _out == null or eval_path_count == 0 or not _out.points.is_empty():
		return out
	if _open_input:
		out.append("Generate Range Splines needs a CLOSED outline; the wired path is open.")
	elif _max_depth >= 0.0 and _max_depth <= coast_inset:
		out.append("No crests: the outline is only %.0f m deep at its deepest, and Coast Inset is %.0f m. "
				% [_max_depth, coast_inset] + "Lower Coast Inset below that.")
	elif _max_depth >= 0.0:
		out.append(("No crests: every crest is shorter than Min Branch (%.0f m). The outline is %.0f m deep at "
				+ "its deepest; lower Min Branch or Coast Inset.") % [min_branch, _max_depth])
	return out
