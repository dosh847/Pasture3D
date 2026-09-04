extends Node

## Gate verifying that ALL registered graph nodes can be created, populated in the GraphEdit UI,
## inspected, connected, and evaluated without any GDScript errors or warnings.

func _ready() -> void:
	print("\n=== GraphNodeEditorUIGate: Testing All Nodes in Graph Editor UI ===\n")
	var failures: int = 0

	var entries: Array[Dictionary] = Pasture3DGraphNodeRegistry.entries(true)
	print("Found %d registered nodes to validate..." % entries.size())

	var editor_script = load("res://addons/pasture_3d/src/graph_editor.gd")
	var editor = VBoxContainer.new()
	editor.set_script(editor_script)
	add_child(editor)

	var graph = Pasture3DTerrainGraph.new()
	editor.graph = graph

	for entry in entries:
		var op_name: StringName = entry.get("op", &"")
		var title: String = entry.get("title", "")
		print("  -> Testing node: %s ('%s')" % [title, op_name])

		var node = Pasture3DGraphNodeRegistry.create(op_name)
		if node == null:
			print("     !! FAIL: Failed to instantiate node '%s'" % op_name)
			failures += 1
			continue

		# Verify port contracts
		var in_cnt := node.input_count()
		var in_names := node.input_names()
		var in_types := node.input_port_types()
		if in_names.size() != in_cnt:
			print("     !! FAIL: input_names().size() (%d) != input_count() (%d)" % [in_names.size(), in_cnt])
			failures += 1
		if in_types.size() != in_cnt:
			print("     !! FAIL: input_port_types().size() (%d) != input_count() (%d)" % [in_types.size(), in_cnt])
			failures += 1

		var out_cnt := node.output_count()
		var out_names := node.output_names()
		var out_types := node.output_port_types()
		if out_names.size() != out_cnt:
			print("     !! FAIL: output_names().size() (%d) != output_count() (%d)" % [out_names.size(), out_cnt])
			failures += 1
		if out_types.size() != out_cnt:
			print("     !! FAIL: output_port_types().size() (%d) != output_count() (%d)" % [out_types.size(), out_cnt])
			failures += 1

		# Test slot population in editor UI
		var gn := GraphNode.new()
		editor._populate_node_slots_and_controls(gn, 0, node)
		gn.free()

	# Evaluate EVERY node standalone, not only the zero-input generators.
	#
	# This loop used to `continue` on `input_count() > 0`, so filters, combiners and every solver were
	# skipped while the docstring above claimed "ALL registered graph nodes" — a gate that could not fail
	# on the majority of the thing it names (§7.4). Each input port is now fed by its own Noise source, so
	# a node that needs a surface gets one.
	print("
Testing standalone evaluate for all nodes...")
	var gw: int = 32
	var gh: int = 32
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var evaluated: int = 0

	for entry in entries:
		var op_name: StringName = entry.get("op", &"")
		var node = Pasture3DGraphNodeRegistry.create(op_name)
		if node == null:
			continue

		var test_graph := Pasture3DTerrainGraph.new()
		var out_node := Pasture3DGraphNodeOutput.new()
		test_graph.nodes = [node, out_node]
		test_graph.connections = [PackedInt32Array([0, 0, 1, 0])]
		# One source per input port. A shared source would be legal too, but a distinct node per port
		# means a combiner that reads the WRONG port still gets a finite surface rather than an error
		# that masks the real one.
		for port in range(node.input_count()):
			var src := Pasture3DGraphNodeNoise.new()
			src.amplitude = 20.0
			var si: int = test_graph.nodes.size()
			test_graph.nodes.append(src)
			test_graph.connections.append(PackedInt32Array([si, 0, 0, port]))

		var res: PackedFloat32Array = test_graph.evaluate(gw, gh, rect)
		evaluated += 1
		if res.size() != gw * gh:
			print("     !! FAIL: evaluate failed for node '%s' (%d cells, expected %d)"
					% [op_name, res.size(), gw * gh])
			failures += 1

	# A gate that quietly evaluated nothing must not read as a pass. This is the check the `continue`
	# above defeated for years.
	print("  evaluated %d of %d registered nodes" % [evaluated, entries.size()])
	if evaluated < entries.size():
		print("     !! FAIL: %d node(s) were never evaluated" % (entries.size() - evaluated))
		failures += 1

	if failures == 0:
		print("\n=== GRAPH NODE EDITOR UI GATE PASS (0 failures) ===\n")
	else:
		print("\n=== GRAPH NODE EDITOR UI GATE FAIL (%d failures) ===\n" % failures)

	get_tree().quit(0 if failures == 0 else 1)
