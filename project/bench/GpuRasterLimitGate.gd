# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GpuRasterLimitGate — the GPU closed-loop field refuses a grid past the device's 2D texture limit before
# creating it, so an island-sized loop takes the CPU route without an engine ERROR (2026-10-26: "Texture
# dimensions exceed device maximum" on every bake of the Island Plow).
#
#   [A] gpu_raster_fits is true at the device limit and false one texel past it, on either axis.
#       Control: a small grid fits, so a false answer is the limit and not a missing device
#   [B] A thin Mound one loop wider than the limit bakes: its middle is raised and finite. Control: the
#       grid it bakes really is wider than the limit
#
# Needs a GPU, so it runs WINDOWED (no --headless):
#   Godot_v4.7-stable_win64_console.exe --path project res://bench/GpuRasterLimitGate.tscn
extends Node

const CRITERIA := 2

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GpuRasterLimitGate ===")
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_check("device", false, "no RenderingDevice: run this gate windowed, not --headless")
	else:
		var limit := int(rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D))
		var t := Pasture3D.new()
		t.name = "Terrain"
		t.vertex_spacing = 1.0
		t.region_size = 2048
		add_child(t)
		_a(t, limit)
		await _b(t, limit)
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== GPU RASTER LIMIT %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _a(p_t: Pasture3D, p_limit: int) -> void:
	var d := p_t.data
	var small := d.gpu_raster_fits(64, 64)
	_check("A control", small and d.gpu_raster_available(), "64 x 64 fits %s, GPU raster available %s" % [small, d.gpu_raster_available()])
	var at := d.gpu_raster_fits(p_limit, 8) and d.gpu_raster_fits(8, p_limit)
	var past := d.gpu_raster_fits(p_limit + 1, 8) or d.gpu_raster_fits(8, p_limit + 1)
	_check("A limit", at and not past, "limit %d: fits at it %s, fits one past it %s (want true, false)" % [p_limit, at, past])
	_ran += 1


func _b(p_t: Pasture3D, p_limit: int) -> void:
	var length := float(p_limit + 256)
	# Centred on the origin: the region map spans a fixed count of regions either side of it.
	var x0 := -floorf(length * 0.5)
	var rs := 2048.0
	var r0 := floori((x0 - 64.0) / rs)
	var r1 := floori((x0 + length + 64.0) / rs)
	for i in range(r0, r1 + 1):
		p_t.data.add_region_blankp(Vector3(i * rs + 1.0, 0.0, 1.0))
	p_t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	var m := Pasture3DMound.new()
	m.name = "Long"
	m.auto_refresh = false
	m.capped = true
	m.height = 10.0
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(x0, 0, 200), Vector3(x0 + length, 0, 200), Vector3(x0 + length, 0, 260), Vector3(x0, 0, 260)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = p_t
	var box := m._spline_footprint_aabb(path)
	_check("B control", box.size.x > float(p_limit), "the loop's grid is %.0f cells wide against a limit of %d" % [box.size.x, p_limit])
	m._refresh_owner(m._layer_owner, false, [])
	var ok := true
	var worst := INF
	for x in [200.0, length * 0.5, length - 100.0]:
		var h := p_t.data.get_height(Vector3(x0 + x, 0.0, 230.0))
		worst = minf(worst, h)
		ok = ok and is_finite(h) and h > 5.0
	_check("B bakes past the limit", ok, "lowest of three samples along the middle %.3f m (want finite, > 5)" % worst)
	remove_child(m)
	m.free()
	_ran += 1
