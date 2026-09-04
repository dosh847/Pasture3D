# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeScree — the first graph-native SOLVER: loose rock shed off steep ground and piled at
# the foot of a slope. It READS its input field's steepness and concavity and deposits talus where rock is
# being shed, so it cannot be a per-cell op — it needs the whole grid (neighbour differences) and is a grid
# node.
#
# ---- Two outputs (the multi-output slice) ----
#
#   port 0  "height"  HEIGHT  the deposited relief (metres), gated to the shed region
#   port 1  "shed"    MASK    where scree is active [0,1] — the slope gate itself, so a downstream Blend's
#                             mask input (or a Mask node) can stamp further detail only where rock sheds.
#
# The grain texture and the toe-deposition ramp are the relief system's vetted `_scree` static; this node
# adds only the field derivation (slope / curvature / gradient from its input grid) and the slope gate. The
# gate (PASTURE3D_TERRAIN_GRAPH_SPEC.md Solvers, GraphSolverNodeGate) re-derives those independently and
# reuses `_scree`, isolating exactly the new code.
#
# ---- Per-solver freeze ----
#
# A SOLVER is the category a graph pays for, so it carries its OWN frozen cache (the pattern DLA and
# Erosion will need): when FROZEN it solves once, caches the two channels keyed by a hash of the input
# surface, and thereafter serves the cache — flagging itself stale (a node warning) when the surface or its
# own params have changed since the bake — until Bake Scree clears it. Scree itself is cheap, so it defaults
# to LIVE; the mechanism is here so the heavier solvers inherit a proven path. In memory only, like the
# erosion modifier's cache.
@tool
class_name Pasture3DGraphNodeScree
extends Pasture3DGraphSolverNode

const ReliefMaterial = preload("res://addons/pasture_3d/connectors/pasture3d_relief_material.gd")


## Size of the rubble texture, in metres. Scree is a thin skin over the rock beneath it.
@export_range(0.0, 20.0, 0.01, "or_greater") var amplitude: float = 2.0:
	set(v):
		amplitude = maxf(v, 0.0)
		_param_changed()
## Size of the individual rubble clumps, in metres. Below ~4 m on a 1 m terrain this stops resolving.
@export_range(1.0, 64.0, 0.5, "or_greater") var grain_size: float = 6.0:
	set(v):
		grain_size = maxf(v, 0.01)
		_param_changed()
## How far the rubble is smeared downhill, in metres — what makes it read as travelled material. 0 = none.
@export_range(0.0, 32.0, 0.1, "or_greater") var downslope_streak: float = 4.0:
	set(v):
		downslope_streak = maxf(v, 0.0)
		_param_changed()
## How much material piles into concavities — the toe of a slope, the floor of a gully.
@export_range(0.0, 20.0, 0.01, "or_greater") var toe_deposition: float = 3.0:
	set(v):
		toe_deposition = maxf(v, 0.0)
		_param_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Slope Gate")
## Below this angle, in degrees, no scree is generated — flat ground sheds nothing.
@export_range(0.0, 90.0, 0.5) var min_slope_degrees: float = 22.0:
	set(v):
		min_slope_degrees = clampf(v, 0.0, 90.0)
		_param_changed()
## Softness of that cut-off, in degrees. A hard cut leaves a visible contour line across the hillside.
@export_range(0.0, 45.0, 0.5) var slope_falloff_degrees: float = 12.0:
	set(v):
		slope_falloff_degrees = clampf(v, 0.0, 45.0)
		_param_changed()

@export_group("Evaluation")

@export_tool_button("Bake Scree") var _bake_btn = clear_cache

# ---- Runtime freeze state (not serialised — the caches rebuild on demand) ----
# Grain noise, rebuilt only when grain_size / seed change.
var _noise: FastNoiseLite = null
var _noise_dirty: bool = true


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Scree"


func op() -> StringName:
	return &"scree"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = amplitude
	p[1] = grain_size
	p[2] = downslope_streak
	p[3] = toe_deposition
	p[4] = min_slope_degrees
	p[5] = slope_falloff_degrees
	p[6] = float(seed)
	return {"params": p}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 0, 1, 4])


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "amplitude", "grain_size", "min_slope"])


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
		2: return grain_size
		3: return min_slope_degrees
		_: return 0.0


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "shed"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func node_warnings() -> PackedStringArray:
	var w := super()
	if amplitude <= 0.0 and toe_deposition <= 0.0:
		w.append("%s: both Amplitude and Toe Deposition are 0, so no talus accumulates." % display_name())
	return w


## Two channels: [0] deposited height (metres), [1] shed mask [0,1]. Applies the per-solver freeze.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var a: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else amplitude
	var gs: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else grain_size
	var ms: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else min_slope_degrees

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return solve_cached(_surface_hash(surface, p_gw, p_gh), func(): return _solve_dynamic(surface, p_gw, p_gh, p_rect, a, gs, ms))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	# Single-output callers (and the default lowering) get the primary height channel.
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	_noise_dirty = true
	mark_dirty_since_bake()
	emit_changed()


func _wobble() -> FastNoiseLite:
	if _noise_dirty or _noise == null:
		_noise = ReliefMaterial._configure_noise(1.0 / maxf(grain_size, 0.01), 3, 2.0, 0.5, seed, false)
		_noise_dirty = false
	return _noise


## Solve the two channels over `p_surface`. Field derivation (slope / curvature / gradient) is done here;
## the grain + toe are the vetted `_scree`. NaN in the surface (off a brush loop) passes through as NaN in
## the height and a 0 in the mask — the boundary is where nothing sheds.
func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	return _solve_dynamic(p_surface, p_gw, p_gh, p_rect, amplitude, grain_size, min_slope_degrees)


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_a: float, p_gs: float, p_ms: float) -> Array:
	var n := p_gw * p_gh
	var height := PackedFloat32Array(); height.resize(n)
	var shed := PackedFloat32Array(); shed.resize(n)
	var params := PackedFloat32Array([p_a, 1.0 / maxf(p_gs, 0.01), downslope_streak,
			toe_deposition, float(seed)])
	var noise := _wobble()
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	for iz in range(p_gh):
		var row := iz * p_gw
		var zm := maxi(iz - 1, 0) * p_gw
		var zp := mini(iz + 1, p_gh - 1) * p_gw
		for ix in range(p_gw):
			var i := row + ix
			var c := p_surface[i]
			if is_nan(c):
				height[i] = NAN
				shed[i] = 0.0
				continue
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_gw - 1)
			var hxm := _finite(p_surface[row + xm], c)
			var hxp := _finite(p_surface[row + xp], c)
			var hzm := _finite(p_surface[zm + ix], c)
			var hzp := _finite(p_surface[zp + ix], c)
			# Gradient (height per metre) and slope angle; curvature = ring mean minus centre (metres,
			# positive for a hollow, matching the relief system's SCREE curvature convention).
			var gx := (hxp - hxm) / (2.0 * dx)
			var gz := (hzp - hzm) / (2.0 * dz)
			var slope_deg := rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
			var curv := (hxm + hxp + hzm + hzp) * 0.25 - c
			var gate := _slope_gate_dynamic(slope_deg, p_ms)
			var w := cell_to_world_local(ix, iz, p_gw, p_gh, p_rect)
			var val := ReliefMaterial._scree(w.x, w.y, curv, gx, gz, params, 0, noise)
			height[i] = gate * val
			shed[i] = gate
	return [height, shed]


func _finite(p_v: float, p_fallback: float) -> float:
	return p_fallback if is_nan(p_v) else p_v


## Smooth slope band: 0 below `min - falloff`, ramping to 1 at `min_slope_degrees`, 1 up to vertical.
func _slope_gate_dynamic(p_slope_deg: float, p_ms: float) -> float:
	var lo := p_ms
	var fl := slope_falloff_degrees
	if p_slope_deg >= lo:
		return 1.0
	if fl <= 0.0 or p_slope_deg <= lo - fl:
		return 0.0
	return smoothstep(lo - fl, lo, p_slope_deg)


func _slope_gate(p_slope_deg: float) -> float:
	return _slope_gate_dynamic(p_slope_deg, min_slope_degrees)


## Cell-centre world XZ, identical to Pasture3DTerrainGraph.cell_to_world (kept local so the node does not
## depend on the graph instance when it solves).
func cell_to_world_local(p_ix: int, p_iz: int, p_gw: int, p_gh: int, p_rect: Rect2) -> Vector2:
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	return Vector2(p_rect.position.x + (float(p_ix) + 0.5) * dx,
			p_rect.position.y + (float(p_iz) + 0.5) * dz)


## A cheap order-sensitive hash of the surface, the freeze staleness key: a different upstream surface
## produces a different key, so a frozen solve knows it is looking at new ground.
func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	return solver_cache_key(p_gw, p_gh, [p_surface])
