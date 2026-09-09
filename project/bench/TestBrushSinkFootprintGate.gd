# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# TestBrushSinkFootprintGate — Regression gate verifying that moving or detaching a terrain brush
# that writes to secondary channel sinks (such as ColorSink or ControlSink) cleanly removes its
# footprint from affiliated sink layers and returns the terrain to base color/control.
#
# House discipline:
# - Bitwise or exact epsilon assertions on returned terrain colors and layer tile existence.
# - Explicit control checks so failures report rather than silently pass.
# - Verified completions count.
extends Node

const PASTURE_3D_MAPTYPE_COLOR: int = 2

var _fail: int = 0
var _checks: int = 0

func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
		print("    !! FAIL: %s" % p_msg)
	else:
		print("    ok: %s" % p_msg)


func _ready() -> void:
	print("=== TestBrushSinkFootprintGate (Sink Layer Footprint Invalidation) ===")
	_run_tests.call_deferred()


func _get_base_color_at(terr: Pasture3D, world_pos: Vector3) -> Color:
	var data = terr.data
	var stack = data.get_layer_stack()
	var base_idx = stack.find_base_layer(PASTURE_3D_MAPTYPE_COLOR)
	if base_idx < 0:
		return Color(NAN, NAN, NAN, 1.0)
	var base_layer = stack.get_layer(base_idx)
	var reg_loc = data.get_region_location(world_pos)
	var reg_offset = reg_loc * terr.region_size
	var descaled = Vector2(world_pos.x, world_pos.z) / terr.vertex_spacing
	var img_pos = Vector2i(int(descaled.x - reg_offset.x), int(descaled.y - reg_offset.y))
	img_pos = img_pos.clamp(Vector2i.ZERO, Vector2i(terr.region_size - 1, terr.region_size - 1))
	var tile_size = base_layer.get_tile_size()
	var tile_coord = Vector2i(img_pos.x / tile_size, img_pos.y / tile_size)
	var local_px = Vector2i(img_pos.x % tile_size, img_pos.y % tile_size)
	var tile_img: Image = base_layer.get_tile(reg_loc, tile_coord)
	if tile_img != null:
		var c: Color = tile_img.get_pixelv(local_px)
		c.a = 1.0
		return c
	return Color(NAN, NAN, NAN, 1.0)


func _run_tests() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var scene: PackedScene = load("res://simple_pasture.tscn")
	_check(scene != null, "simple_pasture.tscn loads successfully")
	if scene == null:
		_finish()
		return

	var root = scene.instantiate()
	get_tree().root.add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	var terr: Pasture3D = root.get_node_or_null("Pasture3D")
	_check(terr != null and is_instance_valid(terr), "Pasture3D terrain node exists")
	if terr == null:
		_finish()
		return

	var mound = terr.get_node_or_null("Mound")
	_check(mound != null and is_instance_valid(mound), "Mound brush node exists")
	if mound == null:
		_finish()
		return

	var data = terr.data
	_check(data != null, "Pasture3DData instance is valid")
	var stack = data.get_layer_stack() if data else null
	_check(stack != null, "Layer stack is valid")

	var owner_id: String = mound._layer_owner
	_check(owner_id == "pasture3d_brush:Mounds", "Mound has expected layer owner 'pasture3d_brush:Mounds'")

	var aff_layers: PackedInt32Array = mound._all_layers_for_owner(owner_id)
	_check(aff_layers.size() >= 2, "Found affiliated layers for brush owner (expected at least height + color sink, got %d)" % aff_layers.size())

	var color_layer_idx: int = -1
	for idx in aff_layers:
		var lyr = stack.get_layer(idx)
		if lyr and lyr.get_owner_id() == owner_id + "#graph_color":
			color_layer_idx = idx
			break
	_check(color_layer_idx >= 0, "Found '#graph_color' sink layer at index %d" % color_layer_idx)

	var color_layer = stack.get_layer(color_layer_idx) if color_layer_idx >= 0 else null

	# Initial state: old_pos inside region (-1, -1)
	var old_pos: Vector3 = mound.global_position
	var initial_color: Color = data.get_color(old_pos)
	var initial_base_color: Color = _get_base_color_at(terr, old_pos)

	_check(not is_nan(initial_base_color.r), "Retrieved valid base color at initial mound position (%s)" % initial_base_color)
	_check(initial_color != initial_base_color, "Initial mound color (%s) is distinct from base color (%s)" % [initial_color, initial_base_color])

	var old_reg_loc = data.get_region_location(old_pos)
	var old_img_pos = Vector2i(int((old_pos.x / terr.vertex_spacing) - (old_reg_loc.x * terr.region_size)),
			int((old_pos.z / terr.vertex_spacing) - (old_reg_loc.y * terr.region_size)))
	var old_tile_coord = Vector2i(old_img_pos.x / color_layer.get_tile_size(), old_img_pos.y / color_layer.get_tile_size())

	_check(color_layer.get_tile(old_reg_loc, old_tile_coord) != null, "Color sink layer has tile at initial mound tile coord %s" % old_tile_coord)

	# -----------------------------------------------------------------------------------------------
	# Test 1: Move Brush within region (-1, -1) using dirty-rect _refresh_owner_rect
	# -----------------------------------------------------------------------------------------------
	print("\n--- Test 1: Move Brush with _refresh_owner_rect ---")
	var splines: Dictionary = {}
	for s in mound._get_splines():
		splines[s.get_instance_id()] = true

	var offset_1 := Vector3(-70.0, 0.0, -70.0)
	mound.global_position += offset_1
	var pos_1: Vector3 = mound.global_position

	var tiles_before_dict: Dictionary = color_layer.get_tiles().get(old_reg_loc, {}).duplicate()

	# Trigger dirty-rect bake
	mound._refresh_owner_rect(owner_id, splines, true)

	var tiles_after_dict: Dictionary = color_layer.get_tiles().get(old_reg_loc, {}).duplicate()

	var color_at_old_pos: Color = data.get_color(old_pos)
	var old_diff := absf(color_at_old_pos.r - initial_base_color.r) + absf(color_at_old_pos.g - initial_base_color.g) + absf(color_at_old_pos.b - initial_base_color.b)
	_check(old_diff < 0.005, "Old position color returned exactly to Color Base (got %s, expected %s, diff=%.4f)" % [color_at_old_pos, initial_base_color, old_diff])

	# Check that tiles exclusive to the previous position were dropped
	var dropped_tile := Vector2i(-1, -1)
	for t in tiles_before_dict:
		if not tiles_after_dict.has(t):
			dropped_tile = t
			break
	_check(dropped_tile != Vector2i(-1, -1), "At least one exclusive tile from old footprint was dropped (dropped %s)" % dropped_tile)

	var pos_1_base_color: Color = _get_base_color_at(terr, pos_1)
	var color_at_pos_1: Color = data.get_color(pos_1)
	var pos_1_tint_diff := absf(color_at_pos_1.r - pos_1_base_color.r) + absf(color_at_pos_1.g - pos_1_base_color.g) + absf(color_at_pos_1.b - pos_1_base_color.b)
	_check(pos_1_tint_diff > 0.02, "New position pos_1 is tinted by ColorSink (got %s, base %s, diff=%.4f)" % [color_at_pos_1, pos_1_base_color, pos_1_tint_diff])

	var pos_1_img_pos = Vector2i(int((pos_1.x / terr.vertex_spacing) - (old_reg_loc.x * terr.region_size)),
			int((pos_1.z / terr.vertex_spacing) - (old_reg_loc.y * terr.region_size)))
	var pos_1_tile_coord = Vector2i(pos_1_img_pos.x / color_layer.get_tile_size(), pos_1_img_pos.y / color_layer.get_tile_size())
	_check(color_layer.get_tile(old_reg_loc, pos_1_tile_coord) != null, "Color sink layer has written tile at new position tile coord %s" % pos_1_tile_coord)

	# -----------------------------------------------------------------------------------------------
	# -----------------------------------------------------------------------------------------------
	# Test 2: Move Brush with full refresh _refresh_owner
	# -----------------------------------------------------------------------------------------------
	print("\n--- Test 2: Full Refresh _refresh_owner ---")
	var prev_fps_test2: Array = mound._own_footprints()
	# Move further along offset_1: pos_1 sits at local (+70, +70) from pos_2, which is outside the curve
	var offset_2 := offset_1
	mound.global_position += offset_2
	var pos_2: Vector3 = mound.global_position

	var tiles_before_test2: Dictionary = color_layer.get_tiles().get(old_reg_loc, {}).duplicate()
	mound._refresh_owner(owner_id, false, prev_fps_test2)
	var tiles_after_test2: Dictionary = color_layer.get_tiles().get(old_reg_loc, {}).duplicate()

	var color_at_pos_1_after_move2: Color = data.get_color(pos_1)
	var pos_1_diff2 := absf(color_at_pos_1_after_move2.r - pos_1_base_color.r) + absf(color_at_pos_1_after_move2.g - pos_1_base_color.g) + absf(color_at_pos_1_after_move2.b - pos_1_base_color.b)
	_check(pos_1_diff2 < 0.005, "pos_1 returned exactly to Color Base after full refresh (got %s, expected %s, diff=%.4f)" % [color_at_pos_1_after_move2, pos_1_base_color, pos_1_diff2])

	var dropped_tile2 := Vector2i(-1, -1)
	for t in tiles_before_test2:
		if not tiles_after_test2.has(t):
			dropped_tile2 = t
			break
	_check(dropped_tile2 != Vector2i(-1, -1), "At least one tile exclusive to pos_1 footprint was dropped on full refresh (dropped %s)" % dropped_tile2)

	var pos_2_base_color: Color = _get_base_color_at(terr, pos_2)
	var color_at_pos_2: Color = data.get_color(pos_2)
	var pos_2_tint_diff := absf(color_at_pos_2.r - pos_2_base_color.r) + absf(color_at_pos_2.g - pos_2_base_color.g) + absf(color_at_pos_2.b - pos_2_base_color.b)
	_check(pos_2_tint_diff > 0.02, "pos_2 is tinted by ColorSink (got %s, base %s, diff=%.4f)" % [color_at_pos_2, pos_2_base_color, pos_2_tint_diff])

	# -----------------------------------------------------------------------------------------------
	# Test 3: Multi-layer Snapshot and Restore
	# -----------------------------------------------------------------------------------------------
	print("\n--- Test 3: Multi-layer Snapshot and Restore ---")
	var snap_before: Dictionary = mound._snapshot_owner(owner_id)
	_check(snap_before.has(owner_id), "Snapshot contains primary layer '%s'" % owner_id)
	_check(snap_before.has(owner_id + "#graph_color"), "Snapshot contains sink layer '%s#graph_color'" % owner_id)

	# Move mound back to pos_1 and bake
	var prev_fps_test3: Array = mound._own_footprints()
	mound.global_position -= offset_1
	var pos_3: Vector3 = mound.global_position
	mound._refresh_owner(owner_id, false, prev_fps_test3)

	# Now restore snapshot (restores pos_2)
	mound._restore_owner(owner_id, snap_before)

	var color_at_pos_2_restored: Color = data.get_color(pos_2)
	var restore_diff := absf(color_at_pos_2_restored.r - color_at_pos_2.r) + absf(color_at_pos_2_restored.g - color_at_pos_2.g) + absf(color_at_pos_2_restored.b - color_at_pos_2.b)
	_check(restore_diff < 0.005, "Snapshot restore recovers sink color at snapshotted position pos_2 (got %s, expected %s, diff=%.4f)" % [color_at_pos_2_restored, color_at_pos_2, restore_diff])

	var color_at_old_pos_restored: Color = data.get_color(old_pos)
	var old_restore_diff := absf(color_at_old_pos_restored.r - initial_base_color.r) + absf(color_at_old_pos_restored.g - initial_base_color.g) + absf(color_at_old_pos_restored.b - initial_base_color.b)
	_check(old_restore_diff < 0.005, "Snapshot restore preserves clean base color at original mound position (diff=%.4f)" % old_restore_diff)

	# Clean up
	root.queue_free()
	_finish()


func _finish() -> void:
	print("\n--- %d checks, %d failures ---" % [_checks, _fail])
	var is_pass: bool = (_fail == 0 and _checks >= 18)
	print("=== TestBrushSinkFootprintGate: %s ===" % ("PASS" if is_pass else "FAIL"))
	get_tree().quit(0 if is_pass else 1)
