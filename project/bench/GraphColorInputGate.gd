# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphColorInputGate — Color Input passes the terrain's existing colour through a Color Sink.
#
# Over a ramp (altitude = x), Color Input -> Blend(red where x < 16) -> Blend(blue where x >= 24) -> a Color
# Sink with its mask UNWIRED (the whole footprint). The band 16..24 is claimed by no mask.
#
#   [A] The red and blue bands paint; the unclaimed band keeps the terrain's own green. CONTROL: the same
#       graph starting from a white Const Color paints that band white -- the over-paint the node removes.
#   [B] Alpha is premultiplied coverage: coverage_color((0.5, 0, 0, 0.5), 1) is red at coverage 0.5, and an
#       opaque colour is unchanged. Native writer == GDScript loop on a field of mixed alphas.
#       CONTROL: the alphas, not just the RGB, change what is written (an all-opaque field differs).
#   [C] A Multiply Blend over Color Input paints nothing (it keeps A's alpha), as the node's header says.
#       CONTROL: Multiply over white paints.
extends Node

const N := 32
const RECT := Rect2(0.0, 0.0, 32.0, 32.0)
const BASE := Color(0.0, 0.6, 0.0)

var _fail := 0
var _checks := 0


func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_msg])


func _ready() -> void:
	print("=== GraphColorInputGate ===")
	_a_bands()
	_b_alpha()
	_c_multiply()
	if _checks < 9:
		print("!! GATE INCOMPLETE: %d checks" % _checks)
		_fail += 1
	print("=== GraphColorInputGate: %s (%d failures, %d checks) ===" % ["PASS" if _fail == 0 else "FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _terrain() -> Pasture3D:
	var t := Pasture3D.new()
	t.vertex_spacing = 1.0
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	for iz in N:
		for ix in N:
			t.data.set_color(Vector3(ix + 0.5, 0.0, iz + 0.5), BASE)
	return t


func _ramp() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(N * N)
	for iz in N:
		for ix in N:
			z[iz * N + ix] = float(ix)
	return z


func _band(p_lo: float, p_hi: float) -> Pasture3DGraphNodeMask:
	var k := Pasture3DGraphNodeMask.new()
	k.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	k.band_min = p_lo
	k.band_max = p_hi
	k.falloff_lo = 0.0
	k.falloff_hi = 0.0
	return k


func _const(p_c: Color) -> Pasture3DGraphNodeConstColor:
	var c := Pasture3DGraphNodeConstColor.new()
	c.value = p_c
	return c


## start -> Blend(red where band 1) -> Blend(blue where band 2) -> sink (mask unwired).
func _graph(p_start: Pasture3DGraphNode, p_mode: int = 0) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var i_in := g.add_node(Pasture3DGraphNodeInput.new())
	var i_start := g.add_node(p_start)
	var i_m1 := g.add_node(_band(-1.0, 15.5))
	var i_m2 := g.add_node(_band(23.5, 100.0))
	var i_red := g.add_node(_const(Color.RED))
	var i_blue := g.add_node(_const(Color.BLUE))
	var b1 := Pasture3DGraphNodeColorBlend.new()
	b1.mode = p_mode
	var i_b1 := g.add_node(b1)
	var b2 := Pasture3DGraphNodeColorBlend.new()
	b2.mode = p_mode
	var i_b2 := g.add_node(b2)
	var i_sink := g.add_node(Pasture3DGraphNodeColorSink.new())
	g.connect_ports(i_in, 0, i_m1, 0)
	g.connect_ports(i_in, 0, i_m2, 0)
	g.connect_ports(i_start, 0, i_b1, 0)
	g.connect_ports(i_red, 0, i_b1, 1)
	g.connect_ports(i_m1, 0, i_b1, 2)
	g.connect_ports(i_b1, 0, i_b2, 0)
	g.connect_ports(i_blue, 0, i_b2, 1)
	g.connect_ports(i_m2, 0, i_b2, 2)
	g.connect_ports(i_b2, 0, i_sink, 1)
	return g


func _run(p_g: Pasture3DTerrainGraph) -> Pasture3D:
	var t := _terrain()
	var r: Dictionary = Pasture3DGraphChannelSinks.run(p_g, t, "gate:", N, N, RECT, _ramp())
	if not (r["skipped"] as Array).is_empty():
		print("      skipped: %s" % [r["skipped"]])
	return t


func _at(p_t: Pasture3D, p_x: float) -> Color:
	return p_t.data.get_color(Vector3(p_x + 0.5, 0.0, 10.5))


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02


func _a_bands() -> void:
	print("  [A] masked colours over Color Input leave the unclaimed band alone")
	var t := _run(_graph(Pasture3DGraphNodeColorInput.new()))
	_check(_near(_at(t, 5), Color.RED) and _near(_at(t, 28), Color.BLUE),
			"the bands paint (x=5 %s, x=28 %s)" % [_at(t, 5), _at(t, 28)])
	_check(_near(_at(t, 20), BASE), "the unclaimed band keeps the terrain colour (%s)" % _at(t, 20))
	t.queue_free()
	var c := _run(_graph(_const(Color.WHITE)))
	_check(_near(_at(c, 20), Color.WHITE), "control: a white Const Color start paints that band white (%s)" % _at(c, 20))
	c.queue_free()


func _b_alpha() -> void:
	print("  [B] alpha is premultiplied coverage, on both writers")
	var cc := Pasture3DGraphChannelSinks.coverage_color(Color(0.5, 0.0, 0.0, 0.5), 1.0)
	_check(_near(cc, Color.RED) and is_equal_approx(cc.a, 0.5), "(0.5, 0, 0, 0.5) is red at coverage 0.5 (%s)" % cc)
	var op := Pasture3DGraphChannelSinks.coverage_color(Color(0.2, 0.4, 0.6, 1.0), 0.75)
	_check(_near(op, Color(0.2, 0.4, 0.6)) and is_equal_approx(op.a, 0.75), "an opaque colour is unchanged, coverage = mask (%s)" % op)

	var field := PackedColorArray()
	var opaque := PackedColorArray()
	for i in N * N:
		var a := float(i % 5) / 4.0 # 0, .25, .5, .75, 1
		field.append(Color(0.8 * a, 0.3 * a, 0.1 * a, a))
		opaque.append(Color(0.8, 0.3, 0.1, 1.0))
	var mask := PackedFloat32Array()
	mask.resize(N * N)
	mask.fill(1.0)
	var native := _write(field, mask, false)
	var loop := _write(field, mask, true)
	var flat := _write(opaque, mask, false)
	var diff := 0
	var ctl := 0
	for iz in N:
		for ix in N:
			var w := Vector3(ix + 0.5, 0.0, iz + 0.5)
			var a: Color = native.data.get_color(w)
			if not _near(a, loop.data.get_color(w)):
				diff += 1
			if not _near(a, flat.data.get_color(w)):
				ctl += 1
	_check(diff == 0, "native writer == GDScript loop on mixed alphas (%d cells differ)" % diff)
	_check(ctl > 0, "control: the alphas change the result (%d cells differ from all-opaque)" % ctl)
	for t in [native, loop, flat]:
		t.queue_free()


func _write(p_colors: PackedColorArray, p_mask: PackedFloat32Array, p_loop: bool) -> Pasture3D:
	var t := _terrain()
	var sink := Pasture3DGraphNodeColorSink.new()
	Pasture3DGraphChannelSinks.force_cell_loop = p_loop
	var report := {"written": 0, "sinks": 0, "skipped": [], "layers": PackedInt32Array()}
	Pasture3DGraphChannelSinks._write_one(sink, 0, t.data, "gate:", N, N, RECT, p_mask, {"color": p_colors}, report, {})
	Pasture3DGraphChannelSinks.force_cell_loop = false
	return t


func _c_multiply() -> void:
	print("  [C] a Multiply over Color Input has nothing to multiply")
	var t := _run(_graph(Pasture3DGraphNodeColorInput.new(), Pasture3DGraphNodeColorBlend.Mode.MUL))
	_check(_near(_at(t, 5), BASE) and _near(_at(t, 28), BASE), "both bands keep the terrain colour (%s, %s)" % [_at(t, 5), _at(t, 28)])
	var c := _run(_graph(_const(Color.WHITE), Pasture3DGraphNodeColorBlend.Mode.MUL))
	_check(_near(_at(c, 5), Color.RED), "control: Multiply over white paints red (%s)" % _at(c, 5))
	t.queue_free()
	c.queue_free()
