# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSinkNativeWriteGate — a channel sink's grid goes to the layer in one native call, and paints exactly
# what the per-cell GDScript loop painted.
#
#   A  Color Sink: set_colors_on_layer_grid vs the per-cell loop, both through _write_one onto their own
#      terrain; every composited colour equal, and the same count written. Control: a different colour
#      field reads back different, so the readback sees the write.
#   B  Control Sink: set_controls_on_layer_grid vs the loop, for a blend field, preserve_base, and a
#      refused base (nothing written on either route). Control: overlay 8 instead of 7 reads back different.
#   C  The native route is the one taken: native_writes counts the native calls and not the forced loop.
#   E  A grid COARSER than the terrain covers every texel under it, for a gate-aligned grid and a
#      brush-aligned one (cells centred on vertices, vertex spacing 2). It used to write one texel per
#      cell, and a bake_scale 2 brush painted a field of dots (demo island, 2026-11-12). Controls: a cell
#      masked off leaves its texels unpainted, and texels past the rect stay unpainted.
#   D  Every criterion completed.
#
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphSinkNativeWriteGate.tscn
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(0.0, 0.0, 32.0, 32.0)
const CRITERIA := ["A", "B", "C", "E"]

var _fail := 0
var _seen := {}
var _native_calls := 0


func _ready() -> void:
	print("=== GraphSinkNativeWriteGate: native sink writes ===")
	for entry in [["A", _a_color], ["B", _b_control], ["C", _c_route], ["E", _e_coarse]]:
		entry[1].call()
		if not _seen.has(entry[0]):
			print("!! [%s] returned without reporting" % entry[0])
	var completed := 0
	for name in CRITERIA:
		if _seen.has(name):
			completed += 1
	_check("D", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== SINK NATIVE WRITE %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _control(p_ok: bool, p_detail: String) -> void:
	print("    control: %s — %s" % ["ok" if p_ok else "DEAD", p_detail])
	if not p_ok:
		_fail += 1


## One blank region with non-default control underneath, so carried bits and preserve_base have a source.
func _terrain(p_name: String) -> Pasture3D:
	var t := Pasture3D.new()
	t.name = p_name
	t.vertex_spacing = 1.0
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	for iz in GH:
		for ix in GW:
			var pre: int = Pasture3DUtil.enc_base((ix + iz) % 9) | Pasture3DUtil.enc_overlay(3) \
					| Pasture3DUtil.enc_blend(40) | Pasture3DUtil.enc_nav(ix % 2 == 0) | (ix % 3)
			t.data.set_control(Vector3(ix + 0.5, 0.0, iz + 0.5), pre)
	return t


## A ramp with a hole: cells at or under MASK_EPSILON must be skipped on both routes.
func _mask() -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			m[iz * GW + ix] = 0.0 if (ix > 10 and ix < 16) else float(iz) / float(GH - 1)
	return m


func _write(p_terrain: Pasture3D, p_sink, p_values: Dictionary, p_loop: bool) -> int:
	Pasture3DGraphChannelSinks.force_cell_loop = p_loop
	var before := Pasture3DGraphChannelSinks.native_writes
	var report := {"written": 0, "sinks": 0, "skipped": [], "layers": PackedInt32Array()}
	var n: int = Pasture3DGraphChannelSinks._write_one(p_sink, 0, p_terrain.data, "gate:", GW, GH, RECT,
			_mask(), p_values, report, {})
	_native_calls += Pasture3DGraphChannelSinks.native_writes - before
	Pasture3DGraphChannelSinks.force_cell_loop = false
	return n


func _colors(p_terrain: Pasture3D) -> PackedColorArray:
	var out := PackedColorArray()
	for iz in GH:
		for ix in GW:
			out.append(p_terrain.data.get_color(Vector3(ix + 0.5, 0.0, iz + 0.5)))
	return out


func _controls(p_terrain: Pasture3D) -> PackedInt64Array:
	var out := PackedInt64Array()
	for iz in GH:
		for ix in GW:
			out.append(p_terrain.data.get_control(Vector3(ix + 0.5, 0.0, iz + 0.5)))
	return out


func _color_field(p_shift: float) -> PackedColorArray:
	var c := PackedColorArray()
	for i in GW * GH - 7: # short on purpose: the tail falls back to the sink's colour on both routes
		c.append(Color(fmod(i * 0.013 + p_shift, 1.0), 0.3, fmod(i * 0.007, 1.0), 1.0))
	return c


# --- A. colour -----------------------------------------------------------------------------------------
func _a_color() -> void:
	print("[A] Color Sink: native grid write == per-cell loop")
	var sink := Pasture3DGraphNodeColorSink.new()
	sink.color = Color(0.9, 0.1, 0.2)
	var tn := _terrain("ColNative")
	var tl := _terrain("ColLoop")
	var tc := _terrain("ColControl")
	var wn := _write(tn, sink, {"color": _color_field(0.0)}, false)
	var wl := _write(tl, sink, {"color": _color_field(0.0)}, true)
	_write(tc, sink, {"color": _color_field(0.5)}, false)
	var a := _colors(tn)
	var b := _colors(tl)
	var diff := 0
	for i in a.size():
		if a[i] != b[i]:
			diff += 1
	var ctl := 0
	var c := _colors(tc)
	for i in a.size():
		if a[i] != c[i]:
			ctl += 1
	_check("A", wn == wl and wn > 0 and diff == 0, "written %d vs %d; cells that differ %d (want 0)" % [wn, wl, diff])
	_control(ctl > 0, "a shifted colour field differs on %d cells (want > 0)" % ctl)
	for t in [tn, tl, tc]:
		t.queue_free()


# --- B. control ----------------------------------------------------------------------------------------
func _control_case(p_preserve: bool, p_base: int, p_overlay: int, p_blend) -> Array:
	var sink := Pasture3DGraphNodeControlSink.new()
	sink.preserve_base = p_preserve
	sink.blend_amount = 0.25
	var values := {"base": p_base, "overlay": p_overlay}
	if p_blend != null:
		values["blend"] = p_blend
	var tn := _terrain("CtlNative")
	var tl := _terrain("CtlLoop")
	var wn := _write(tn, sink, values, false)
	var wl := _write(tl, sink, values, true)
	var a := _controls(tn)
	var b := _controls(tl)
	tn.queue_free()
	tl.queue_free()
	var diff := 0
	for i in a.size():
		if a[i] != b[i]:
			diff += 1
	return [wn, wl, diff, a]


func _b_control() -> void:
	print("[B] Control Sink: native grid write == per-cell loop")
	var ramp := PackedFloat32Array()
	for i in GW * GH:
		ramp.append(float(i % 97) / 96.0)
	var field := _control_case(false, 5, 7, ramp)
	var keep := _control_case(true, 5, 7, 0.6)
	var refused := _control_case(false, 40, 7, null)
	var ok: bool = field[0] == field[1] and field[0] > 0 and field[2] == 0 \
			and keep[0] == keep[1] and keep[0] > 0 and keep[2] == 0 \
			and refused[0] == 0 and refused[1] == 0 and refused[2] == 0
	_check("B", ok, "blend field: written %d/%d, differ %d; preserve_base: %d/%d, differ %d; base 40: %d/%d written (want 0)"
			% [field[0], field[1], field[2], keep[0], keep[1], keep[2], refused[0], refused[1]])
	var other := _control_case(false, 5, 8, ramp)
	var ctl := 0
	for i in (field[3] as PackedInt64Array).size():
		if field[3][i] != other[3][i]:
			ctl += 1
	_control(ctl > 0, "overlay 8 differs from overlay 7 on %d cells (want > 0)" % ctl)


# --- C. route ------------------------------------------------------------------------------------------
func _c_route() -> void:
	print("[C] the native writer is the route taken")
	# A wrote natively twice (the parity arm and its control) and B four times (blend field, preserve_base,
	# the refused base, and the overlay control); the four forced loops made no native call.
	_check("C", _native_calls == 6, "native writes %d (want 6: 2 colour + 4 control, loops 0)" % _native_calls)


# --- E. a coarse grid covers every texel ----------------------------------------------------------------
## Writes a gw x gh grid over p_rect (mask on except one cell) and counts, over texels [0, p_texels) on
## each axis, how many read back the sink's red. Returns [red inside, red on the masked-off cell's texels,
## red past the rect].
func _coarse(p_vs: float, p_rect: Rect2, p_gw: int, p_gh: int, p_texels: int) -> Array:
	var t := Pasture3D.new()
	t.vertex_spacing = p_vs
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	var sink := Pasture3DGraphNodeColorSink.new()
	sink.color = Color.RED
	var mask := PackedFloat32Array()
	mask.resize(p_gw * p_gh)
	mask.fill(1.0)
	var off := 2 * p_gw + 3 # cell (3, 2) is masked off
	mask[off] = 0.0
	var report := {"written": 0, "sinks": 0, "skipped": [], "layers": PackedInt32Array()}
	Pasture3DGraphChannelSinks._write_one(sink, 0, t.data, "gate:", p_gw, p_gh, p_rect, mask, {}, report, {})
	var sx := p_rect.size.x / p_gw
	var sz := p_rect.size.y / p_gh
	var inside := 0
	var on_hole := 0
	var past := 0
	var hole_texels := 0
	for pz in p_texels + 2:
		for px in p_texels + 2:
			var w := Vector3((px + 0.5) * p_vs, 0.0, (pz + 0.5) * p_vs)
			var red := _near_red(t.data.get_color(w))
			var vx := px * p_vs
			var vz := pz * p_vs
			var ix := floori((vx - p_rect.position.x) / sx)
			var iz := floori((vz - p_rect.position.y) / sz)
			if px >= p_texels or pz >= p_texels:
				past += int(red)
			elif iz * p_gw + ix == off:
				hole_texels += 1
				on_hole += int(red)
			else:
				inside += int(red)
	t.queue_free()
	return [inside, on_hole, past, p_texels * p_texels - hole_texels, hole_texels]


func _near_red(c: Color) -> bool:
	return c.r > 0.98 and c.g < 0.02 and c.b < 0.02


func _e_coarse() -> void:
	print("[E] a grid coarser than the terrain covers every texel")
	# Gate-aligned: cells start on a vertex. 16 x 16 cells of 2 m over 32 m at 1 m spacing.
	var a := _coarse(1.0, RECT, 16, 16, 32)
	_check("E", a[0] == a[3], "gate-aligned 2 m cells over 1 m texels: %d of %d texels painted" % [a[0], a[3]])
	_control(a[4] > 0 and a[1] == 0, "the masked-off cell's %d texels: %d painted (want 0)" % [a[4], a[1]])
	_control(a[2] == 0, "texels past the rect: %d painted (want 0)" % a[2])
	# Brush-aligned: the rect starts half a texel early, so cell centres sit on vertices. 8 x 8 cells of 4 m
	# over 32 m at 2 m spacing (bake_scale 2): 16 texels per axis.
	var b := _coarse(2.0, Rect2(-1.0, -1.0, 32.0, 32.0), 8, 8, 16)
	_check("E", b[0] == b[3], "brush-aligned 4 m cells over 2 m texels: %d of %d texels painted" % [b[0], b[3]])
	_control(b[4] > 0 and b[1] == 0, "the masked-off cell's %d texels: %d painted (want 0)" % [b[4], b[1]])
	_control(b[2] == 0, "texels past the rect: %d painted (want 0)" % b[2])
