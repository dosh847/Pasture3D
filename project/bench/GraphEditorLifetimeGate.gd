# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphEditorLifetimeGate — signal wiring, null nodes, and the state undo has to carry.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P5 §5.1-§5.4.
#
# P5's defects share a shape that no terrain comparison can see: the field comes out RIGHT, and what is
# wrong is who is still connected to what, or which node the graph thinks it is baking. So every criterion
# here asserts on wiring and identity rather than on heights.
#
# §5.1's FIRST symptom has no criterion, because it is not a defect on this engine version: the spec reads
# `is_connected(_on_node_changed)` against a connection made with `_on_node_changed.bind(n)` as permanently
# false, but `Signal.is_connected` matches on object+method and ignores binds, so the disconnect branch
# works and nothing is re-connected twice. (`Callable ==` DOES compare bind count — the two use different
# rules, which is why the same reading is right about `_connect_spline`, criterion [F], where the object
# and method are identical and only the bind differs.) Measured on 4.7; the §5.1 edit stands as clarity.
#
# Not covered, and deliberately: §5.4's editor-plugin lifetime fix (`EditorInterface.get_inspector()` is
# null outside the editor, so a headless gate would assert on an object that does not exist), and §5.2's
# leak itself (the fix — a named method instead of a self-capturing lambda — is asserted; proving the
# cycle needs OBJECT_COUNT across repeated scene reloads, which is not a gate).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphEditorLifetimeGate.tscn
extends Node

const GW := 16
const GH := 16
const RECT := Rect2(0, 0, 64, 64)

var _fail := 0


func _ready() -> void:
	print("=== GraphEditorLifetimeGate: editor lifetime, signals and undo (P5) ===\n")
	_b_a_foreign_node_does_not_rebake()
	_c_the_revision_hook_is_a_named_method()
	_d_a_null_node_degrades_to_zeros()
	_e_undo_must_carry_the_output_override()
	_f_two_splines_sharing_a_curve_are_both_connected()
	_g_a_layer_of_the_wrong_map_type_is_refused()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH EDITOR LIFETIME PASS" if _fail == 0 else "GRAPH EDITOR LIFETIME FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- B. A node the graph does not contain does not re-bake (§5.1) ------------------------------------
#
# The other half: `_on_node_changed` defaulted `affects_output` to true, so a node left wired by the dead
# branch above (`nodes.find(...)` == -1) unconditionally re-emitted `changed` — a bake for a node the
# graph no longer has. It is provably "changes nothing the bake would see", so it defaults to false.
func _b_a_foreign_node_does_not_rebake() -> void:
	print("[B] a node the graph does not contain does not trigger a bake (§5.1)")
	var g := Pasture3DTerrainGraph.new()
	var member := Pasture3DGraphNodeNoise.new()
	var o := Pasture3DGraphNodeOutput.new()
	var nodes: Array[Pasture3DGraphNode] = [member, o]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	g.output_node = 1

	var seen := [0]
	g.changed.connect(func() -> void: seen[0] += 1)

	# CONTROL: a node that IS wired to the output must still re-bake, or [B] would pass by muting the graph.
	g._on_node_changed(member)
	var on_member: int = seen[0]
	seen[0] = 0
	g._on_node_changed(Pasture3DGraphNodeNoise.new())
	var on_stranger: int = seen[0]

	print("    control: member node emitted %d (want >= 1); stranger emitted %d (want 0)" % [on_member, on_stranger])
	if on_member < 1:
		_fail += 1
		print("    !! a connected node no longer re-bakes")
	if on_stranger != 0:
		_fail += 1
		print("    !! a node outside the graph re-bakes the terrain")


# --- C. The revision hook is a named method (§5.2) ---------------------------------------------------
#
# `changed.connect(func(): _revision += 1)` touches a member, so GDScript wraps it in a
# GDScriptLambdaSelfCallable holding a strong reference to its host; storing that in the host's own signal
# list is a cycle a RefCounted graph never escapes, taking every node's `_cached_grid` with it. The leak
# is not asserted here (see the header); the shape that causes it is, because that is what regresses.
func _c_the_revision_hook_is_a_named_method() -> void:
	print("[C] `changed` is wired to a named method, not a self-capturing lambda (§5.2)")
	var g := Pasture3DTerrainGraph.new()
	var lambdas := 0
	var named := 0
	for c in g.changed.get_connections():
		var cb: Callable = c.get("callable", Callable())
		if cb.get_method() == &"_bump_revision":
			named += 1
		elif cb.get_object() == g:
			lambdas += 1
	print("    named `_bump_revision` = %d (want 1), other self-bound callables = %d (want 0)" % [named, lambdas])
	if named != 1 or lambdas != 0:
		_fail += 1
		print("    !! the revision counter is not on a named method")
		return

	# CONTROL: the named method has to actually still count, or [C] rewards deleting the connection.
	var before: int = g.content_key()
	g.emit_changed()
	print("    control: content_key %d -> %d (want a change)" % [before, g.content_key()])
	if g.content_key() == before:
		_fail += 1
		print("    !! the revision no longer moves on a change")


# --- D. A null node in the output's ancestry degrades, it does not crash (§5.3) ----------------------
#
# `_eval_order`'s ancestor walk bounds-checked but did not null-check, and `_fold_plan` then called
# `nodes[ni].input_count()` on null. The state is anticipated elsewhere in the same file (`graph_warnings`
# names it; the root check and `native_supported` both guard it), so this was an inconsistency, not an
# unconsidered case. Trigger is narrow: the null must be REACHABLE from the output — a .tres whose node
# script failed to load, i.e. a renamed script or a dev-flag script absent from a build.
func _d_a_null_node_degrades_to_zeros() -> void:
	print("[D] a null node reachable from the output evaluates to zeros (§5.3)")
	var g := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeNoise.new()
	var fnl := FastNoiseLite.new()
	fnl.seed = 3
	fnl.frequency = 0.03
	n.noise = fnl
	n.amplitude = 20.0
	var o := Pasture3DGraphNodeOutput.new()
	var nodes: Array[Pasture3DGraphNode] = [n, o]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	g.output_node = 1

	# CONTROL FIRST: with the node present the fixture must produce a NON-flat field, or "all zeros"
	# below is what this graph does anyway and the criterion measures nothing.
	var live := g.evaluate(GW, GH, RECT)
	var spread := 0.0
	for v in live:
		spread = maxf(spread, absf(v))
	print("    control: |max| with the node present = %.3f (want > 0)" % spread)
	if spread <= 0.0:
		_fail += 1
		print("    !! the fixture is flat with a real node, so [D] cannot tell degradation from normal")
		return

	var holed: Array[Pasture3DGraphNode] = [null, o]
	g.nodes = holed
	g.emit_signal("structure_changed")
	var out := g.evaluate(GW, GH, RECT)
	print("    with a null upstream: %d cells returned (want %d, and all zero)" % [out.size(), GW * GH])
	if out.size() != GW * GH:
		_fail += 1
		print("    !! a null node did not degrade to the flat field `evaluate` promises")
		return
	for v in out:
		if v != 0.0:
			_fail += 1
			print("    !! a null node's port did not bind the zero buffer")
			return


# --- E. Delete-node undo has to carry `output_override` (§5.4) ----------------------------------------
#
# `_action_delete_nodes` restored `nodes`, `connections` and `output_node` but not `output_override`,
# which `remove_node` shifts. The editor's UndoRedo is not reachable headless, so this asserts the claim
# the undo action rests on: restoring only those three does NOT restore the output, and adding the
# override does.
func _e_undo_must_carry_the_output_override() -> void:
	print("[E] restoring nodes/connections/output_node alone does not restore the output (§5.4)")
	var g := Pasture3DTerrainGraph.new()
	var a := Pasture3DGraphNodeNoise.new()
	var b := Pasture3DGraphNodeNoise.new()
	var c := Pasture3DGraphNodeNoise.new()
	var o := Pasture3DGraphNodeOutput.new()
	var nodes: Array[Pasture3DGraphNode] = [a, b, c, o]
	g.nodes = nodes
	g.output_node = 3
	g.output_override = 2 # solo-preview node c

	var was: Pasture3DGraphNode = g.nodes[g.output_index()]
	var old_nodes := g.nodes.duplicate()
	var old_conns := g.connections.duplicate()
	var old_out := g.output_node
	var old_override := g.output_override

	g.remove_node(0) # delete a; remove_node decrements the override to 1
	print("    after deleting node 0 the override shifted %d -> %d (want a shift)" % [old_override, g.output_override])
	if g.output_override == old_override:
		_fail += 1
		print("    !! remove_node no longer shifts the override, so [E]'s premise is gone")
		return

	# The old undo: three properties.
	var n3: Array[Pasture3DGraphNode] = old_nodes
	g.nodes = n3
	g.connections = old_conns
	g.output_node = old_out
	var partial: Pasture3DGraphNode = g.nodes[g.output_index()]
	# The landed undo: four.
	g.output_override = old_override
	var full: Pasture3DGraphNode = g.nodes[g.output_index()]

	print("    output after a 3-property undo = %s, after 4 = %s, wanted %s"
		% [partial.get_instance_id(), full.get_instance_id(), was.get_instance_id()])
	if partial == was:
		_fail += 1
		print("    !! the 3-property undo already restores the output, so the fix is untested")
	if full != was:
		_fail += 1
		print("    !! restoring output_override does not restore the soloed node")


# --- F. Two Path3Ds sharing one Curve3D are both connected (§5.4) ------------------------------------
#
# Godot shares the Curve3D when you Ctrl+D a Path3D. `_connect_spline` probed
# `is_connected(_schedule_spline_refresh.bind(path))`, and CallableCustomBind equality compares the base
# callable and the bind COUNT, not the bind VALUES — so B's probe matched A's entry on the same curve and
# B was never connected. Dragging the shared curve marked only A dirty; B kept its old stamp.
func _f_two_splines_sharing_a_curve_are_both_connected() -> void:
	print("[F] two splines sharing one Curve3D each get their own connection (§5.4)")
	var brush := Pasture3DTerrainBrush.new()
	add_child(brush)
	var shared := Curve3D.new()
	shared.add_point(Vector3.ZERO)
	shared.add_point(Vector3(10, 0, 0))
	var pa := Path3D.new()
	pa.curve = shared
	var pb := Path3D.new()
	pb.curve = shared
	brush.add_child(pa)
	brush.add_child(pb)

	# Counted as DISTINCT receivers, because the whole defect was two splines collapsing into one entry.
	# The brush also connects on child entry, so the absolute connection count has a baseline.
	var receivers := func() -> int:
		var seen := {}
		for c in shared.changed.get_connections():
			var cb: Callable = c.get("callable", Callable())
			var obj: Object = cb.get_object()
			if obj != null and cb.get_method() == &"on_changed":
				seen[obj.get_instance_id()] = true
		return seen.size()

	brush._connect_spline(pa)
	brush._connect_spline(pb)
	var after_b: int = receivers.call()
	print("    distinct receivers on the shared curve = %d (want 2, one per spline)" % after_b)
	if after_b != 2:
		_fail += 1
		print("    !! the two splines sharing the curve do not have their own connections")

	# CONTROL: still idempotent. The bind-count equality that broke B is also what kept re-entry cheap,
	# and `_connect_spline` is called again from `_on_path_curve_changed` and on every tree entry.
	var total_before := shared.changed.get_connections().size()
	brush._connect_spline(pa)
	brush._connect_spline(pb)
	var repeat := shared.changed.get_connections().size()
	print("    control: total connections %d -> %d after re-connecting both (want no change)"
		% [total_before, repeat])
	if repeat != total_before:
		_fail += 1
		print("    !! _connect_spline is no longer idempotent")

	brush.queue_free()


# --- G. A layer of the wrong map type is refused, not used (§5.4) ------------------------------------
#
# `_ensure_layer_for` push_warning'd that the resolved layer had the wrong map type and then returned its
# id anyway, so a height brush wrote float heights into a CONTROL layer. -1 is the destructive-fallback
# path the function's own docstring defines, and every caller already branches on it.
func _g_a_layer_of_the_wrong_map_type_is_refused() -> void:
	print("[G] a height brush refuses a CONTROL layer that already holds its owner id (§5.4)")
	var terrain := Pasture3D.new()
	terrain.name = "LifetimeTerrain"
	terrain.vertex_spacing = 1.0
	add_child(terrain)
	terrain.data.add_region_blankp(Vector3(64.0, 0.0, 64.0))

	var brush := Pasture3DMound.new()
	brush.name = "WrongTypeMound"
	add_child(brush)
	brush.terrain = terrain
	var owner: String = Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX + "WrongTypeMound"

	# CONTROL FIRST: with no pre-existing layer the same call must SUCCEED, or [G] cannot tell "refused
	# the wrong type" from "this brush cannot resolve a layer at all".
	var ok: int = brush._ensure_layer_for(owner, false)
	print("    control: a fresh height layer resolves to %d (want >= 0)" % ok)
	if ok < 0:
		_fail += 1
		print("    !! the fixture cannot resolve a layer even in the good case")
		terrain.queue_free()
		brush.queue_free()
		return

	# Now the same owner id, already taken by a CONTROL layer.
	var t2 := Pasture3D.new()
	t2.name = "LifetimeTerrain2"
	t2.vertex_spacing = 1.0
	add_child(t2)
	t2.data.add_region_blankp(Vector3(64.0, 0.0, 64.0))
	t2.data.create_owned_layer_typed(owner, "WrongTypeMound", 0, Pasture3DTerrainBrush.PASTURE_3D_MAPTYPE_CONTROL)
	brush.terrain = t2
	var bad: int = brush._ensure_layer_for(owner, false)
	print("    a CONTROL layer under a height brush's owner resolves to %d (want -1)" % bad)
	if bad >= 0:
		_fail += 1
		print("    !! a height brush would write float heights into a CONTROL layer")

	brush.queue_free()
	terrain.queue_free()
	t2.queue_free()
