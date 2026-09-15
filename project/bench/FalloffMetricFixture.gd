# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# FalloffMetricFixture — the ONE definition of the Falloff cases that FalloffBaselineCapture records and
# GraphDistanceMetricGate replays. Two copies of the matrix would be two chances to hash different graphs
# and call the difference a regression.
#
# Deliberately not a class_name: `--check-only` cannot see a new global class until the project is
# reimported, and a bench helper does not need to be global. Callers `preload` it.
extends RefCounted

const GW := 129 # >= 128 rows, so the thread pool actually splits the CPU kernel.
const GH := 129
const RECT := Rect2(-83.0, -47.0, 161.25, 161.25) # off-origin, non-integer cell size
const CENTRE := Vector2(13.25, -7.5)


## The height field. A NaN strip exercises the loop-mask pass-through on both routes.
func terrain() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(GW * GH)
	var dx := RECT.size.x / GW
	var dz := RECT.size.y / GH
	for iz in GH:
		for ix in GW:
			var x := RECT.position.x + (ix + 0.5) * dx
			var z := RECT.position.y + (iz + 0.5) * dz
			h[iz * GW + ix] = 12.0 + 0.15 * x - 0.08 * z + 4.0 * sin(x * 0.11) * cos(z * 0.07)
			if ix >= 120 and iz < 20:
				h[iz * GW + ix] = NAN
	return h


## 4 shapes x hard/soft edge x invert x noise x strength = 64 cases.
func cases() -> Array:
	var out := []
	for shape in 4:
		for feather in [0.0, 37.5]:
			for invert in [false, true]:
				for noise in [0.0, 0.6]:
					for strength in [1.0, 0.35]:
						out.append({"shape": shape, "feather": feather, "invert": invert,
								"distance_noise": noise, "strength": strength})
	return out


func case_name(p_cfg: Dictionary) -> String:
	return "s%d f%.1f i%d n%.1f st%.2f" % [int(p_cfg["shape"]), float(p_cfg["feather"]),
			int(bool(p_cfg["invert"])), float(p_cfg["distance_noise"]), float(p_cfg["strength"])]


func io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return g


## Input -> Falloff.in, Input -> Falloff.noise (a deterministic perturbation field), Falloff -> Output.
## `p_feather_bump` exists for the gate's control: the same case with a slightly different feather.
func graph(p_cfg: Dictionary, p_feather_bump := 0.0) -> Pasture3DTerrainGraph:
	var f := Pasture3DGraphNodeFalloff.new()
	f.shape = int(p_cfg["shape"])
	f.centre = CENTRE
	f.radius = 41.0
	f.feather = float(p_cfg["feather"]) + p_feather_bump
	f.invert = bool(p_cfg["invert"])
	f.distance_noise = float(p_cfg["distance_noise"])
	f.strength = float(p_cfg["strength"])
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), f, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	var conns: Array = [[0, 0, 1, 0], [1, 0, 2, 0]]
	if float(p_cfg["distance_noise"]) > 0.0:
		conns.append([0, 0, 1, 3])
	g.connections = conns
	return g


func sha(p_grid: PackedFloat32Array) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(p_grid.to_byte_array())
	return ctx.finish().hex_encode()


## Eight fixed cells, including one in the NaN strip, as float strings (JSON would round a float32).
func samples(p_grid: PackedFloat32Array) -> Array:
	var out := []
	for i in [0, 64, GW * 64 + 64, GW * 10 + 125, GW * 100 + 3, GW * 128 + 128, GW * 40 + 90, GW * 77 + 21]:
		out.append(var_to_str(p_grid[i]) if i < p_grid.size() else "")
	return out
