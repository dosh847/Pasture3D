# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Render probe for streaming phase 1: the shaders read the RF region map and slot-indexed arrays, and a
# region far outside the old 32x32 map draws. Headless compiles no shaders, so this needs a window. It is a
# correctness check (a handful of frames, one pixel read per view), not a benchmark.
#
# world_background is NONE, so a location with no region discards and shows the clear colour: the control
# for every "draws" check is a view over empty ground, which must show the clear colour.
#
# Run (windowed): Godot_v4.7-stable_win64_console.exe --path project bench/RegionSlotRenderProbe.tscn
extends Node3D

const DIR := "user://region_slot_render_probe"
const CLEAR := Color(1, 0, 1)

var _fail := 0
var _terrain
var _cam: Camera3D


func _ready() -> void:
	RenderingServer.set_default_clear_color(CLEAR)
	DirAccess.make_dir_recursive_absolute(DIR)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, 30, 0)
	add_child(light)
	_cam = Camera3D.new()
	_cam.rotation_degrees = Vector3(-90, 0, 0)
	add_child(_cam)
	_cam.current = true
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	_terrain.set_camera(_cam)
	_terrain.material.world_background = 0 # NONE
	var d = _terrain.data
	for loc in [Vector2i(0, 0), Vector2i(100, 100), Vector2i(-100, -100), Vector2i(127, -128)]:
		d.add_region_blank(loc, false)
	d.update_maps()
	await _frames(10)
	print("\n=== Region slot render probe ===\n")
	for loc in [Vector2i(0, 0), Vector2i(100, 100), Vector2i(-100, -100), Vector2i(127, -128)]:
		_check("region %s draws" % loc, not await _is_clear_at(loc))
	for loc in [Vector2i(50, 50), Vector2i(-100, 100), Vector2i(3, 0)]:
		_check("control: empty %s shows the clear colour" % loc, await _is_clear_at(loc))
	# A load into a freed slot draws the NEW region: unload (100,100), add (3,0) into its slot.
	d.unload_region(Vector2i(100, 100))
	d.add_region_blank(Vector2i(3, 0))
	_check("unloaded (100, 100) stops drawing", await _is_clear_at(Vector2i(100, 100)))
	_check("(3, 0) in the reused slot draws", not await _is_clear_at(Vector2i(3, 0)))
	print("\n=== %s (%d failures) ===\n" % ["RENDER PROBE PASS" if _fail == 0 else "RENDER PROBE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _is_clear_at(p_loc: Vector2i) -> bool:
	_cam.global_position = Vector3(p_loc.x * 256 + 128, 60, p_loc.y * 256 + 128)
	# The clipmap snaps to the camera in _physics_process, so a jump draws on the first frame after the next
	# physics tick; a count of render frames alone races it (at a high frame rate 6 frames can be one tick).
	for i in 2:
		await get_tree().physics_frame
	await _frames(3)
	var img := get_viewport().get_texture().get_image()
	var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	print("    %s centre pixel %s" % [p_loc, c])
	return c.is_equal_approx(CLEAR) or (absf(c.r - 1) < 0.02 and c.g < 0.02 and absf(c.b - 1) < 0.02)


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1
