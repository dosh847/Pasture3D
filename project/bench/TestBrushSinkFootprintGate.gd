# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# TestBrushSinkFootprintGate — moving a brush that writes a channel sink (here the Mound's ColorSink) leaves
# no stale sink colour behind.
#
# "No stale colour" is asserted as: the incremental bake equals a FROM-SCRATCH bake at the same position.
# The from-scratch bake wipes every layer the owner has, then does a full refresh; anything the incremental
# path forgot to clear shows up as a difference. This does not depend on the scene's layout. The first
# version of this gate compared the old position to the base colour. That only holds if the brush has moved
# clean off its old footprint and no other brush paints there. In simple_pasture neither is true: the Mound
# is ~330 m across, so a 70 m move leaves the old point inside it, and the Troughs ColorSink covers the same
# spot. The gate failed on a correct bake.
#
#   1  _refresh_owner_rect after a move == from scratch  (control: the move changed the sink)
#   2  _refresh_owner (with the previous footprints) after a move == from scratch  (same control)
#   3  _restore_owner brings back the snapshot's sink tiles  (control: the bake in between changed them)
#
# Every check counts. A run that finishes with fewer than MIN_CHECKS checks FAILs, so a crash part-way
# cannot pass.
extends Node

const MIN_CHECKS := 14
## Byte tolerance on RGBA8 sink tiles, and per-channel tolerance on composited colour. The two routes paint
## in a different order, so allow one step of 8-bit rounding and nothing more.
const BYTE_TOL := 1
const COLOR_TOL := 2.0 / 255.0

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
	print("=== TestBrushSinkFootprintGate (sink layer follows the brush) ===")
	_run_tests.call_deferred()


## {region: {tile: PackedByteArray}} copy of a layer's tiles.
func _layer_bytes(p_layer) -> Dictionary:
	var out := {}
	var tiles: Dictionary = p_layer.get_tiles()
	for reg in tiles:
		var per := {}
		var tmap: Dictionary = tiles[reg]
		for tc in tmap:
			var img: Image = tmap[tc]
			if img != null:
				per[tc] = img.get_data()
		out[reg] = per
	return out


## [tile keys equal, max byte difference, first differing tile]
func _compare_bytes(p_a: Dictionary, p_b: Dictionary) -> Array:
	var keys_ok := true
	var worst := 0
	var where := ""
	var regs := {}
	for r in p_a: regs[r] = true
	for r in p_b: regs[r] = true
	for r in regs:
		var ta: Dictionary = p_a.get(r, {})
		var tb: Dictionary = p_b.get(r, {})
		var tcs := {}
		for t in ta: tcs[t] = true
		for t in tb: tcs[t] = true
		for t in tcs:
			if not ta.has(t) or not tb.has(t):
				keys_ok = false
				if where == "":
					where = "%s/%s only in %s" % [r, t, "incremental" if ta.has(t) else "scratch"]
				continue
			var da: PackedByteArray = ta[t]
			var db: PackedByteArray = tb[t]
			if da.size() != db.size():
				worst = 255
				continue
			for i in da.size():
				var d := absi(da[i] - db[i])
				if d > worst:
					worst = d
					where = "%s/%s" % [r, t]
	return [keys_ok, worst, where]


func _colors(p_data, p_probes: Array) -> Array:
	var out := []
	for p in p_probes:
		out.append(p_data.get_color(p))
	return out


func _color_worst(p_a: Array, p_b: Array) -> float:
	var w := 0.0
	for i in p_a.size():
		var a: Color = p_a[i]
		var b: Color = p_b[i]
		w = maxf(w, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	return w


## Wipe every layer the owner has and bake it again from nothing.
func _bake_from_scratch(p_mound, p_owner: String) -> void:
	var everything := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))
	for idx in p_mound._all_layers_for_owner(p_owner):
		p_mound.terrain.data.clear_layer_in_area(idx, everything, false)
	p_mound.terrain.data.composite_area(everything, false)
	p_mound._refresh_owner(p_owner, false, [])


## Probe points: the mound's old and new centres, plus a grid across both footprints.
func _probes(p_fps: Array, p_extra: Array) -> Array:
	var out := p_extra.duplicate()
	for box: AABB in p_fps:
		for i in 5:
			for j in 5:
				out.append(Vector3(box.position.x + box.size.x * (i + 0.5) / 5.0, 0.0,
						box.position.z + box.size.z * (j + 0.5) / 5.0))
	return out


## Bake incrementally (already done by the caller), then from scratch, and report the two agree.
func _agrees_with_scratch(p_label: String, p_mound, p_owner: String, p_layer, p_probes: Array) -> void:
	var data = p_mound.terrain.data
	var inc_bytes := _layer_bytes(p_layer)
	var inc_cols := _colors(data, p_probes)
	_bake_from_scratch(p_mound, p_owner)
	var cmp := _compare_bytes(inc_bytes, _layer_bytes(p_layer))
	_check(cmp[0], "%s: sink tile set equals the from-scratch bake's %s" % [p_label, cmp[2] if not cmp[0] else ""])
	_check(cmp[1] <= BYTE_TOL, "%s: sink tiles equal the from-scratch bake (worst byte diff %d at %s, want <= %d)"
			% [p_label, cmp[1], cmp[2], BYTE_TOL])
	var cw := _color_worst(inc_cols, _colors(data, p_probes))
	_check(cw <= COLOR_TOL, "%s: composited colour at %d probes equals the from-scratch bake (worst %.4f)"
			% [p_label, p_probes.size(), cw])


func _run_tests() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var scene: PackedScene = load("res://simple_pasture.tscn")
	_check(scene != null, "simple_pasture.tscn loads")
	if scene == null:
		_finish()
		return
	var root = scene.instantiate()
	get_tree().root.add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	var terr: Pasture3D = root.get_node_or_null("Pasture3D")
	var mound = terr.get_node_or_null("Mound") if terr != null else null
	_check(mound != null, "Pasture3D and its Mound brush exist")
	if mound == null:
		_finish()
		return
	var data = terr.data
	var stack = data.get_layer_stack()
	var owner_id: String = mound._layer_owner
	var color_layer = null
	for idx in mound._all_layers_for_owner(owner_id):
		if stack.get_layer(idx).get_owner_id() == owner_id + "#graph_color":
			color_layer = stack.get_layer(idx)
	_check(color_layer != null, "found the '%s#graph_color' sink layer" % owner_id)
	if color_layer == null:
		root.queue_free()
		_finish()
		return

	# Start from a clean bake, so the scene's saved sink tiles (which may predate a code change) are not the
	# baseline.
	_bake_from_scratch(mound, owner_id)
	var pos_0: Vector3 = mound.global_position
	var fps_0: Array = mound._own_footprints()
	var bytes_0 := _layer_bytes(color_layer)

	# --- Test 1: dirty-rect bake -------------------------------------------------------------------------
	print("\n--- Test 1: move, then _refresh_owner_rect ---")
	var splines := {}
	for s in mound._get_splines():
		splines[s.get_instance_id()] = true
	var offset := Vector3(-70.0, 0.0, -70.0)
	mound.global_position += offset
	var pos_1: Vector3 = mound.global_position
	mound._refresh_owner_rect(owner_id, splines, true)
	var moved := _compare_bytes(bytes_0, _layer_bytes(color_layer))
	_check(moved[1] > BYTE_TOL or not moved[0], "control: the move changed the sink layer (worst byte diff %d)" % moved[1])
	_agrees_with_scratch("rect", mound, owner_id, color_layer,
			_probes(fps_0 + mound._own_footprints(), [pos_0, pos_1]))

	# --- Test 2: full bake with the previous footprints --------------------------------------------------
	print("\n--- Test 2: move, then _refresh_owner ---")
	var fps_1: Array = mound._own_footprints()
	var bytes_1 := _layer_bytes(color_layer)
	mound.global_position += offset
	var pos_2: Vector3 = mound.global_position
	mound._refresh_owner(owner_id, false, fps_1)
	var moved2 := _compare_bytes(bytes_1, _layer_bytes(color_layer))
	_check(moved2[1] > BYTE_TOL or not moved2[0], "control: the move changed the sink layer (worst byte diff %d)" % moved2[1])
	_agrees_with_scratch("full", mound, owner_id, color_layer,
			_probes(fps_1 + mound._own_footprints(), [pos_1, pos_2]))

	# --- Test 3: snapshot and restore --------------------------------------------------------------------
	print("\n--- Test 3: snapshot, move and bake, restore ---")
	var snap: Dictionary = mound._snapshot_owner(owner_id)
	_check(snap.has(owner_id), "snapshot holds the primary layer '%s'" % owner_id)
	_check(snap.has(owner_id + "#graph_color"), "snapshot holds the sink layer '%s#graph_color'" % owner_id)
	var bytes_2 := _layer_bytes(color_layer)
	var probes_3 := _probes(mound._own_footprints(), [pos_0, pos_1, pos_2])
	var cols_2 := _colors(data, probes_3)
	var fps_2: Array = mound._own_footprints()
	mound.global_position -= offset
	mound._refresh_owner(owner_id, false, fps_2)
	var moved3 := _compare_bytes(bytes_2, _layer_bytes(color_layer))
	_check(moved3[1] > BYTE_TOL or not moved3[0], "control: the bake between snapshot and restore changed the sink (worst byte diff %d)" % moved3[1])
	mound._restore_owner(owner_id, snap)
	var back := _compare_bytes(bytes_2, _layer_bytes(color_layer))
	_check(back[0] and back[1] == 0, "restore brings back the snapshot's sink tiles exactly (keys %s, worst byte diff %d at %s)"
			% [str(back[0]), back[1], back[2]])
	var cw := _color_worst(cols_2, _colors(data, probes_3))
	_check(cw <= COLOR_TOL, "restore brings back the composited colour at %d probes (worst %.4f)" % [probes_3.size(), cw])

	root.queue_free()
	_finish()


func _finish() -> void:
	print("\n--- %d checks, %d failures ---" % [_checks, _fail])
	var is_pass: bool = _fail == 0 and _checks >= MIN_CHECKS
	print("=== TestBrushSinkFootprintGate: %s ===" % ("PASS" if is_pass else "FAIL"))
	get_tree().quit(0 if is_pass else 1)
