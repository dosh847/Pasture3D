# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDLA — a mountain grown by diffusion-limited aggregation, as a graph-native SOLVER.
# Particles random-walk until they stick to a branching cluster; blurring that skeleton at doubling radii
# and summing turns it into a massif of major ridges and minor spurs. A ridge network is the topological
# dual of a drainage network, so a DLA massif lands on the same branching statistics erosion produces
# WITHOUT simulating water — which is why `Input → DLA → Erosion` reinforces rather than fights.
#
# ---- Two routes, one answer ----
#
# Native (GRAPH_OP_DLA) runs the C++ port of the growth, src/pasture_3d_dla.cpp. The GDScript route here
# composes Pasture3DReliefDLA and drives its `grow_into` hook, so the tuned growth path — six growth bugs,
# each a *plausible* field — is reused byte-for-byte and stays the oracle the port is gated against
# (GraphDLANativeParityGate). Every float parameter is rounded to float32 before the growth sees it,
# because that is all the native program can carry; without it the two routes grow different massifs.
#
# ---- Two outputs ----
#
#   port 0  "height"  HEIGHT  the massif, in metres (amplitude · normalised field)
#   port 1  "mask"    MASK    the normalised field itself [0,1] — the mountain's footprint/intensity, for a
#                             downstream Blend that stamps rock detail only on the massif.
#
# ---- Optional seed input (what makes it a SOLVER, not a bare Generator) ----
#
# With Ridge Seeding on, the wired input field is the surface the cluster grows OUT OF: its crest lines
# become the starting skeleton, so `Input → Erosion → DLA` grows the ridge network along what erosion
# actually cut. Unwired (or seeding off) it grows from a single central seed — a pure generator.
#
# ---- Per-solver freeze (defaults to FROZEN) ----
#
# Growing a cluster is seconds; re-running it on every evaluation is unusable, so this node defaults to
# FROZEN, on both routes. The cache is the UNIT massif — [mask-or-NaN, mask] — and amplitude is multiplied in
# after it, so an Amplitude edit moves the mountain without a re-growth and without going stale.
@tool
class_name Pasture3DGraphNodeDLA
extends Pasture3DGraphSolverNode

const ReliefDLA = preload("res://addons/pasture_3d/connectors/pasture3d_relief_dla.gd")


## The massif's height, in metres — the amplitude of the finished mountain. The grown field is normalised
## [0,1], so this is a straight multiplier on it.
@export_range(0.0, 4000.0, 1.0, "or_greater") var amplitude: float = 30.0:
	set(v):
		amplitude = maxf(v, 0.0)
		# Not `_param_changed`: amplitude is applied after the cache, so the frozen massif is not stale.
		emit_changed()

@export_group("Shape")
## Outer radius as a fraction of the rect's half-extent: 1.0 reaches the edge, 0.5 sits in the middle with
## clear ground around it. The SIZE control — the cluster and the blur that widens it both derive from it.
@export_range(0.2, 1.0, 0.01) var coverage: float = 0.95:
	set(v):
		coverage = clampf(v, 0.2, 1.0)
		_param_changed()
## Ridge spacing as a fraction of the massif's radius — small is a finely divided massif of thin spurs,
## large a few broad arms. Independent of `coverage`: sizing the mountain does not restyle it.
@export_range(0.03, 0.50, 0.005) var detail_size: float = 0.12:
	set(v):
		detail_size = clampf(v, 0.03, 0.50)
		_param_changed()
## Remap on the normalised field: 1 linear, above 1 pulls the flanks down and sharpens the summit, below 1
## fattens toward a plateau.
@export_range(0.25, 4.0, 0.05) var profile_power: float = 1.0:
	set(v):
		profile_power = clampf(v, 0.25, 4.0)
		_param_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Growth")
## Widest working grid the cluster is grown on, in cells. Only powers of two do anything; the final blur
## dominates how it reads, so resolution beyond the output grid buys little. 512² ≈ 2 s to grow.
@export_enum("64:64", "128:128", "256:256", "512:512", "1024:1024") var resolution: int = 256:
	set(v):
		resolution = clampi(v, 64, 1024)
		_param_changed()
## How many grow-then-upscale rounds — the number of ridge SCALES, not a quality knob. Capped by
## `resolution` (the coarsest grid floors at 16 cells).
@export_range(1, 8) var hierarchy_levels: int = 4:
	set(v):
		hierarchy_levels = clampi(v, 1, 8)
		_param_changed()
## Sideways throw of an inserted midpoint when the grid doubles, as a fraction of the branch length. 0 keeps
## the cluster axis-aligned; ~0.3 reads as a ridge.
@export_range(0.0, 1.0, 0.01) var wander: float = 0.32:
	set(v):
		wander = clampf(v, 0.0, 1.0)
		_param_changed()

# The Massing group is gone with the blur cascade that needed it: `blur_levels` and `blur_growth` shaped a
# sum of blurred skeletons, and the massif is now a max-plus distance transform off the ridge tree, which
# takes its one length from `detail_size` and its curve from `profile_power`. P10 and P11 stay reserved and
# are written as 0 rather than renumbering every parameter after them.

@export_group("Ridge Seeding")
## Grow the cluster OUT OF the ridges in the wired input field instead of from a single central point. The
## crest lines of the input become the starting skeleton — the `Erosion → DLA` workflow. Needs an input.
@export var ridge_seeding: bool = false:
	set(v):
		ridge_seeding = v
		_param_changed()
## What fraction of the cells inside the mountain count as ridge — small picks only the sharpest crests.
@export_range(0.01, 0.30, 0.005) var ridge_amount: float = 0.05:
	set(v):
		ridge_amount = clampf(v, 0.01, 0.30)
		_param_changed()

@export_group("Evaluation")

@export_tool_button("Bake Mountain") var _bake_btn = clear_cache


## This solve is heavy enough that FROZEN is the right default; the base defaults to LIVE.
func _init() -> void:
	# `super()` is not optional. Pasture3DGraphNode._init connects `changed` to the revision bump, and a
	# subclass `_init` that does not chain silently drops that connection — every parameter on this node,
	# `muted` included, then becomes invisible to invalidation and it serves its first grid forever.
	# GraphNodeParamGate names each one that stops bumping.
	super()
	evaluation = Evaluation.FROZEN


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Mountain"


## Amplitude never enters the cache; see the header.
func serve_time_properties() -> PackedStringArray:
	return PackedStringArray(["amplitude"])


func op() -> StringName:
	return &"dla"


## P0 amplitude, P1 coverage, P2 detail_size, P3 profile_power, P4..P6 seed as 24/24/16-bit chunks (a float32
## slot is exact only to 2^24, and a seed is an int64), P7 resolution, P8 hierarchy_levels, P9 wander,
## P10, P11 reserved (were blur_levels, blur_growth), P12 ridge_seeding, P13 ridge_amount. Read by GRAPH_OP_DLA.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = amplitude
	p[1] = coverage
	p[2] = detail_size
	p[3] = profile_power
	p[4] = float(seed & 0xFFFFFF)
	p[5] = float((seed >> 24) & 0xFFFFFF)
	p[6] = float((seed >> 48) & 0xFFFF)
	p[7] = float(resolution)
	p[8] = float(hierarchy_levels)
	p[9] = wander
	p[10] = 0.0 # reserved (was blur_levels)
	p[11] = 0.0 # reserved (was blur_growth)
	p[12] = 1.0 if ridge_seeding else 0.0
	p[13] = ridge_amount
	return {"params": p}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 0, 1, 2])


func native_out_count() -> int:
	return 2 # height, mask


## The seed surface, then coverage and detail size: those restyle the growth. Amplitude is not in the key.
func freeze_key_grid_ports() -> PackedInt32Array:
	return PackedInt32Array([0])


func freeze_key_scalar_ports() -> PackedInt32Array:
	return PackedInt32Array([2, 3])


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "amplitude", "coverage", "detail_size"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return amplitude
		2: return coverage
		3: return detail_size
		_: return 0.0


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func node_warnings() -> PackedStringArray:
	var w := super()
	if amplitude <= 0.0:
		w.append("%s has zero amplitude, so it deposits no height." % display_name())
	return w


## Two channels: [0] massif height (metres), [1] normalised field [0,1]. Applies the per-solver freeze to the
## unit massif, then the amplitude — the same order GRAPH_OP_DLA uses.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)
	var a := _f32(_scalar(p_inputs, 1, amplitude))
	var cov := clampf(_f32(_scalar(p_inputs, 2, coverage)), 0.2, 1.0)
	var det := clampf(_f32(_scalar(p_inputs, 3, detail_size)), 0.03, 0.50)
	var unit: Array = solve_cached(freeze_key(p_inputs, p_gw, p_gh), func(): return _solve(surface, p_gw, p_gh, p_rect, cov, det))
	var cached_h: PackedFloat32Array = unit[0]
	var h := PackedFloat32Array()
	h.resize(cached_h.size())
	for i in range(cached_h.size()):
		h[i] = a * cached_h[i]
	return [h, unit[1]]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


## A driven scalar port's value, or the export when unwired.
static func _scalar(p_inputs: Array, p_port: int, p_default: float) -> float:
	if p_inputs.size() > p_port and p_inputs[p_port] is PackedFloat32Array and p_inputs[p_port].size() > 0:
		return float(p_inputs[p_port][0])
	return p_default


## The value a float32 params slot holds. The native program carries nothing wider.
static func _f32(p_v: float) -> float:
	return PackedFloat32Array([p_v])[0]


## Grow the cluster and sample the UNIT field onto the output grid: [mask-or-NaN, mask]. The growth runs on a
## configured Pasture3DReliefDLA through its `grow_into` hook (which writes only into a state Dictionary). The
## field is normalised [0,1] and stretched once over the whole rect, exactly as the relief samplers do. A NaN
## in a wired input passes through as NaN / 0 mask — the brush-loop boundary is where the mountain stops.
func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_coverage: float, p_detail: float) -> Array:
	var n := p_gw * p_gh
	var engine := _make_engine(p_surface, p_gw, p_gh, p_rect, p_coverage, p_detail)
	var state := {}
	engine.grow_into(state)
	var field: PackedFloat32Array = state.get("field", PackedFloat32Array())
	var grown_n: int = int(state.get("n", 0))
	var dims: Vector2i = state.get("dims", Vector2i.ZERO)
	var unit := PackedFloat32Array(); unit.resize(n)
	var mask := PackedFloat32Array(); mask.resize(n)
	if field.is_empty() or grown_n <= 0 or dims.x <= 0 or dims.y <= 0:
		# Growth produced nothing (e.g. degenerate params): a flat zero massif is the honest empty result.
		return [unit, mask]
	# Crop the square working field to the loop's own rectangle (the relief material's own crop), then
	# stretch that w×h field over the whole rect.
	var cropped: PackedFloat32Array = engine._crop(field, grown_n, dims.x, dims.y)
	var w := dims.x
	var h := dims.y
	var input_wired := _is_input_wired(p_surface)
	for iz in range(p_gh):
		var row := iz * p_gw
		var v := (float(iz) + 0.5) / float(p_gh)
		var fy := v * float(h - 1)
		for ix in range(p_gw):
			var i := row + ix
			if input_wired and is_nan(p_surface[i]):
				unit[i] = NAN
				mask[i] = 0.0
				continue
			var u := (float(ix) + 0.5) / float(p_gw)
			var fx := u * float(w - 1)
			var s := _bilinear01(cropped, w, h, fx, fy)
			mask[i] = s
			unit[i] = s
	return [unit, mask]


## A fresh Pasture3DReliefDLA configured to this node's params, its loop frame, and (when seeding) the
## input surface as the seed. Private fields are set directly rather than through the material's setters:
## the setters emit `changed` / set brush-dirty flags meant for the relief stack host, and this node is not
## that host — it only wants the growth. See the engine's own header for what each field means.
func _make_engine(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_coverage: float, p_detail: float) -> Object:
	var e = ReliefDLA.new()
	e.coverage = p_coverage
	e.resolution = resolution
	e.hierarchy_levels = hierarchy_levels
	e.detail_size = p_detail
	e.wander = _f32(wander)
	e.seed = seed
	e.profile_power = _f32(profile_power)
	e.ridge_seeding = ridge_seeding
	e.ridge_amount = _f32(ridge_amount)
	# The loop's half-extents drive the field's aspect (the engine crops the square grid to this ratio).
	e._host_ex = maxf(p_rect.size.x * 0.5, 0.001)
	e._host_ez = maxf(p_rect.size.y * 0.5, 0.001)
	# Seed surface: only when seeding AND an input is actually wired. The engine samples it through a frame
	# that maps loop-local metres back to grid indices; our grid is axis-aligned over the rect with square
	# cells, so cos/sin are 1/0 and vs is the cell size. min_x/min_z carry the half-cell so a world point at
	# a cell centre lands on an integer index (the engine's _bilinear reads cell centres at integers).
	if _is_input_wired(p_surface):
		var dx := p_rect.size.x / float(maxi(p_gw, 1))
		var dz := p_rect.size.y / float(maxi(p_gh, 1))
		var ex := p_rect.size.x * 0.5
		var ez := p_rect.size.y * 0.5
		var frame := [p_rect.position.x + ex, p_rect.position.y + ez, 1.0, 0.0, ex, ez,
				p_rect.position.x + 0.5 * dx, p_rect.position.y + 0.5 * dz, dx]
		var cap := {"surface": p_surface, "gw": p_gw, "gh": p_gh, "frame": frame}
		# The outline whenever an input is wired; the ridges only when asked. A wired input is NaN outside the
		# brush loop, and that boundary is the envelope the cluster grows to — see the engine's `_shape`.
		e._shape = cap
		e._shape_hash = hash(p_surface) ^ (hash(p_gw) * 31)
		if ridge_seeding:
			e._seed = cap
			e._seed_hash = e._shape_hash
	return e


## Whether the input field is actually connected: an unwired HEIGHT input reads the all-zero default, and a
## flat-zero surface is not a seed. Any NaN (a brush loop) or any non-zero value means a real input.
func _is_input_wired(p_surface: PackedFloat32Array) -> bool:
	for v in p_surface:
		if v != 0.0:
			return true
	return false


## Bilinear read of a [0,1] field with clamped edges. The field carries no NaN (it is 0 outside the massif),
## so no propagation is needed.
func _bilinear01(g: PackedFloat32Array, w: int, h: int, fx: float, fy: float) -> float:
	var x0 := clampi(int(fx), 0, w - 1)
	var y0 := clampi(int(fy), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var a := g[y0 * w + x0]
	var b := g[y0 * w + x1]
	var c := g[y1 * w + x0]
	var d := g[y1 * w + x1]
	return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty
