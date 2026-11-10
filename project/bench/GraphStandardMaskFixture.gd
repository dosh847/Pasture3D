# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The fixture GraphStandardMaskGate [E] and its pre-phase recording share: one surface, one mask field and
# one graph per migrated node, built the same way before and after P5
# (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §9.4). The recording in `bench/golden/graph_standard_mask/`
# was taken with the nodes as they were BEFORE the phase, through this file, with `PRE_PORT` naming the
# port the mask field went into then. It cannot be re-taken: the pre-phase kernels are gone.
#
# 96 x 128: [E] needs 128 rows or more so the thread pool actually splits.
@tool
extends RefCounted

const GW := 96
const GH := 128
const RECT := Rect2(0.0, 0.0, 960.0, 1280.0)
const GOLDEN_DIR := "res://bench/golden/graph_standard_mask/"

## Every migrated node, and the port its mask field is wired into AFTER the phase.
const POST_PORT := {
	&"contrast": &"mask", &"recast_canyon": &"mask", &"recast_cliff": &"mask", &"ridge_sharpen": &"mask",
	&"strata": &"mask", &"terrace": &"mask",
	&"displace": &"mask", &"warp_downslope": &"mask", &"smooth_fill": &"mask",
	&"hydraulic_saleve": &"mask", &"hydraulic_particle": &"mask", &"hydraulic_stream_log": &"mask",
	&"mudslide": &"source", &"leveler": &"area",
}

## The same, BEFORE the phase. Only what differs from POST_PORT.
const PRE_PORT := {&"terrace": &"amount", &"mudslide": &"mask", &"leveler": &"mask"}


## The surface handed to the graph's Input node: rolling terrain, 10..110 m.
static func surface() -> PackedFloat32Array:
	var nz := FastNoiseLite.new()
	nz.seed = 7
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.frequency = 0.004
	nz.fractal_octaves = 4
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var wx := (float(ix) + 0.5) * RECT.size.x / float(GW)
			var wz := (float(iz) + 0.5) * RECT.size.y / float(GH)
			g[iz * GW + ix] = 60.0 + 50.0 * nz.get_noise_2d(wx, wz)
	return g


## The graph for `p_op`: Input -> node -> Output, with a mask field in [0.05, 0.95] (Noise + Const through
## a Blend ADD; Leveler's runs past both ends) wired into `p_mask_port` of the node. `p_invert` wires 1 - mask instead, which is the
## control. An empty `p_mask_port` wires nothing.
## Returns `{"graph", "node": int}`, or `{}` when the node has no such port.
static func build(p_op: StringName, p_mask_port: StringName, p_invert: bool = false) -> Dictionary:
	var g := Pasture3DTerrainGraph.create_empty()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var node := Pasture3DGraphNodeRegistry.create(p_op)
	_configure(p_op, node)
	var i_node := g.add_node(node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_node, 0)
	g.connect_ports(i_node, 0, i_out, 0)
	g.set_output(i_out)
	if p_op == &"displace":
		var cdx := Pasture3DGraphNodeRegistry.create(&"const")
		cdx.set("value", 25.0)
		g.connect_ports(g.add_node(cdx), 0, i_node, node.input_index_of(&"dx"))
	if p_mask_port != &"":
		var mp := node.input_index_of(p_mask_port)
		if mp < 0:
			return {}
		var nz := FastNoiseLite.new()
		nz.seed = 23
		nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		nz.frequency = 0.006
		nz.fractal_type = FastNoiseLite.FRACTAL_NONE
		var noise := Pasture3DGraphNodeRegistry.create(&"noise")
		noise.set("noise", nz)
		# Leveler's area is where the mask reaches 1, so its field has to: [-0.4, 1.4], clamped by the node.
		var amp := 0.9 if p_op == &"leveler" else 0.45
		noise.set("amplitude", -amp if p_invert else amp)
		var half := Pasture3DGraphNodeRegistry.create(&"const")
		half.set("value", 0.5)
		var add := Pasture3DGraphNodeRegistry.create(&"blend")
		add.set("mode", Pasture3DGraphNodeBlend.Mode.ADD)
		var i_noise := g.add_node(noise)
		var i_half := g.add_node(half)
		var i_add := g.add_node(add)
		g.connect_ports(i_noise, 0, i_add, 0)
		g.connect_ports(i_half, 0, i_add, 1)
		# Assigned directly when `connect_ports` refuses, so a wire the type matrix dislikes still reaches
		# the evaluator and is the gate's business to notice, not this builder's.
		if not g.connect_ports(i_add, 0, i_node, mp):
			g.connections.append([i_add, 0, i_node, mp])
	return {"graph": g, "node": i_node}


# Parameters that make each node do visible work on this surface and keep the solvers short.
static func _configure(p_op: StringName, p_node: Pasture3DGraphNode) -> void:
	match p_op:
		&"hydraulic_saleve":
			p_node.set("iterations", 60)
			p_node.set("control_points", 2000)
		&"leveler":
			p_node.set("target_height", 55.0)
		&"contrast":
			p_node.set("amount", 2.5) # 1.0 is the identity curve


static func golden_path(p_op: StringName) -> String:
	return GOLDEN_DIR + String(p_op) + ".f32"


static func load_golden(p_op: StringName) -> PackedFloat32Array:
	var f := FileAccess.open(golden_path(p_op), FileAccess.READ)
	if f == null:
		return PackedFloat32Array()
	return f.get_buffer(f.get_length()).to_float32_array()
