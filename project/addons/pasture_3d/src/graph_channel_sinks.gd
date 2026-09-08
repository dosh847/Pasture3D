# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphChannelSinks — the bake-time half of the B1 terrain channel sinks.
# PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.1. The node classes declare what a sink IS; this runs them.
#
# ---- WHY THIS IS A TAP AND NOT AN EVALUATION ----
#
# §9.1: "What reaches the bake is a tap on each sink's INPUTS." A sink is terminal, so it has no slot of
# its own in any compiled program (Pasture3DGraphNodeChannelSink's header). Its inputs do. So the whole
# mechanism is V2's: compile with the sink's source nodes as roots, ask `graph_eval_grid_taps` for those
# slots, and write what comes back. Nothing about the graph's own output changes, and the compiled
# program the host bakes with is untouched — which is what makes criterion [E] true by construction
# rather than by care.
#
# ---- THE FOUR STEPS, AND WHY STEP 2 IS THE ONE THAT MATTERS ----
#
# PASTURE3D_LAYERS_GUIDE.md §8.1: resolve/create, CLEAR OUR OWN LAYER over the affected area, write,
# recomposite. Step 2 is what makes a re-bake idempotent and is the entire reason a moved brush leaves no
# stale paint behind: without it the old footprint is simply never revisited, so it survives forever and
# looks exactly like intentional paint. `pasture3d_road_connector.gd`'s `#holes` layer is the precedent.
#
# ---- WHAT NEVER HAPPENS HERE ----
#
# No preview path reaches this file. It is called from `Pasture3DTerrainBrush._apply_graph_step`, which
# runs at bake and only at bake; the editor's thumbnail and inspector passes call
# `Pasture3DUtil.graph_eval_grid_taps` directly and never touch a layer. `write_count` is counted at the
# write, so gate [F] measures that rather than inferring it.
@tool
class_name Pasture3DGraphChannelSinks
extends RefCounted

## Cells actually authored, across every sink, since the counter was last reset. Counted AT the write —
## a criterion that counted calls to `run()` would pass on a run that resolved nothing and wrote nothing.
static var write_count: int = 0
## Times a layer's footprint was cleared (§8.1 step 2). Separately counted so a gate can tell "the clear
## ran and wrote nothing" from "the clear never ran".
static var clear_count: int = 0


## Node indices of every channel sink in `p_graph`, in graph order. Empty is the common case and the
## caller's fast path: a graph with no sinks must cost a bake nothing at all.
static func sinks_of(p_graph) -> PackedInt32Array:
	var out := PackedInt32Array()
	if p_graph == null:
		return out
	for i in range(p_graph.nodes.size()):
		var n = p_graph.nodes[i]
		if n != null and n is Pasture3DGraphNodeChannelSink:
			out.append(i)
	return out


## Which node/port drives `p_to`:`p_port`, as {"node": int, "port": int}, or {} when unwired.
static func source_of(p_graph, p_to: int, p_port: int) -> Dictionary:
	if p_graph == null:
		return {}
	for c in p_graph.connections:
		if int(c[2]) == p_to and int(c[3]) == p_port:
			return {"node": int(c[0]), "port": int(c[1])}
	return {}


## Run every sink in `p_graph` over one bake grid.
##
## `p_terrain` is the Pasture3DTerrain (for `.data`); `p_owner_base` is the host brush's owner id, so the
## layers a sink creates belong to that brush and `bake_all_brushes()`'s per-layer-owner clearing keeps
## working unchanged (§9.1 rule 2). `p_input` is the absolute surface the graph reads, so a sink's mask
## sees the same ground the bake does.
##
## Returns a report: {"written": int, "sinks": int, "skipped": Array[String], "layers": PackedInt32Array}.
static func run(p_graph, p_terrain, p_owner_base: String, p_gw: int, p_gh: int, p_rect: Rect2,
		p_input: PackedFloat32Array) -> Dictionary:
	var report := {"written": 0, "sinks": 0, "skipped": [], "layers": PackedInt32Array()}
	var idx := sinks_of(p_graph)
	if idx.is_empty():
		return report
	if p_terrain == null or p_terrain.data == null:
		report["skipped"].append("no terrain data to write into")
		return report
	var data = p_terrain.data
	if not data.has_method("create_owned_layer_typed"):
		# Older build without the typed tool API. Refused by name rather than falling back to a
		# destructive region-map write: a sink whose whole contract is "one reserved layer, cleared and
		# re-authored" has no honest destructive equivalent (§12.16 would stop holding).
		report["skipped"].append("this build has no typed layer API; sinks need one")
		return report
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		report["skipped"].append("this build has no graph_eval_grid_taps")
		return report

	# Layer ids whose footprint has already been cleared THIS run. Two sinks sharing a `layer_key` share a
	# layer, and the clear is per LAYER per bake, not per sink — see `layer_key`. Without this the second
	# sink on a shared layer would clear the first's work every bake and the layer would only ever show
	# the last write.
	#
	# The CARRY-FORWARD on a shared layer needs nothing here, which is worth stating because it looks like
	# it should. Step 3 reads the composited word beneath so the bits a sink does not author survive, and
	# step 4 recomposites at the end of `_write_one` — per SINK, not at the end of this loop. So by the
	# time the second sink on a shared layer reads `get_control`, the first sink's write is already in the
	# composite. A scratch grid of authored words was written here to solve that and removed again: its
	# red watch passed with the grid cut out, because there was nothing for it to fix.
	var cleared := {}
	for ni in idx:
		var sink: Pasture3DGraphNodeChannelSink = p_graph.nodes[ni]
		var warn := sink.sink_warnings()
		if not warn.is_empty():
			# The refusal IS the behaviour (§9.1, the negative-index rule). Named, never clamped.
			for w in warn:
				report["skipped"].append("%s: %s" % [_label_of(sink, ni), w])
			continue
		var resolved := _resolve_ports(p_graph, sink, ni, p_gw, p_gh, p_rect, p_input)
		if resolved.has("error"):
			report["skipped"].append("%s: %s" % [_label_of(sink, ni), resolved["error"]])
			continue
		var mask: PackedFloat32Array = resolved["mask"]
		var n := _write_one(sink, ni, data, p_owner_base, p_gw, p_gh, p_rect, mask, resolved["values"],
				report, cleared)
		report["written"] = int(report["written"]) + n
		report["sinks"] = int(report["sinks"]) + 1
	return report


static func _label_of(p_sink, p_index: int) -> String:
	var nm: String = p_sink.resource_name
	return nm if nm != "" else "%s #%d" % [p_sink.op(), p_index]


## Tap every wired input port of one sink in a SINGLE multi-root pass, and return
## {"mask": PackedFloat32Array, "values": Dictionary} or {"error": String}.
##
## Value ports (base, overlay) are read from cell 0 of their source's slot rather than from the source
## node's properties. That is deliberate: it is exactly how the native evaluator reads a driven param
## port, so a wire cannot mean one thing to the sink and another to the kernel. The COLOR port is the one
## exception and the Color Sink's header says why.
static func _resolve_ports(p_graph, p_sink, p_index: int, p_gw: int, p_gh: int, p_rect: Rect2,
		p_input: PackedFloat32Array) -> Dictionary:
	var mask_port: int = p_sink.mask_port()
	var names: PackedStringArray = p_sink.input_names()
	var types: PackedInt32Array = p_sink.input_port_types()

	# EACH SINK NAMES WHAT IT CANNOT WRITE WITHOUT. This used to be the mask for every sink, on the
	# grounds that an unwired stencil is "paint nowhere" rather than "paint everywhere". That rule
	# predates the Blend nodes: mixing is what a Blend does and writing is what a sink does, so
	# requiring a stencil in order to write a flat default made the ordinary case unexpressible. See
	# Pasture3DGraphNodeChannelSink.required_ports.
	var required: PackedInt32Array = p_sink.required_ports() if p_sink.has_method("required_ports") \
			else PackedInt32Array([mask_port])
	for req in required:
		if source_of(p_graph, p_index, int(req)).is_empty():
			var nm: String = String(names[int(req)]) if int(req) < names.size() else str(req)
			return {"error": "the `%s` port is unwired, and this sink has nothing to write without it" % nm}
	var mask_required: bool = required.has(mask_port)
	var ctx := {"gw": p_gw, "gh": p_gh, "rect": p_rect, "input": p_input}
	var roots: Array = []
	var port_of_root := {} # port -> {"node","port"}
	for port in range(p_sink.input_count()):
		var src := source_of(p_graph, p_index, port)
		if src.is_empty():
			continue
		if int(types[port]) == Pasture3DGraphNode.PortType.COLOR:
			continue # Not tappable; read from the source node below.
		port_of_root[port] = src
		if not roots.has(int(src["node"])):
			roots.append(int(src["node"]))

	var values := {}
	var mask := PackedFloat32Array()

	# NO TAPPABLE ROOT IS NOT AN ERROR any more. A Color Sink whose only wire is a Const Color into its
	# COLOR port has nothing to compile: a colour travels the sideband, not the program. The old code
	# reached `compile_graph_program_multi` with an empty root list and reported a graph that does not
	# lower -- which is why "paint the footprint this colour" could not be expressed even after the mask
	# stopped being required.
	if roots.is_empty():
		var err := _resolve_colours(p_graph, p_sink, p_index, ctx, values)
		if err != "":
			return {"error": err}
		return {"mask": _whole_footprint(p_gw, p_gh, p_input), "values": values}

	var compiled: Dictionary = p_graph.compile_graph_program_multi(roots)
	if compiled.is_empty():
		return {"error": "the graph does not lower, so its slots cannot be tapped"}
	var slot_of: Dictionary = compiled["slot_of"]
	var slots := PackedInt32Array()
	var chans := PackedInt32Array()
	var order: Array = [] # request index -> port
	for port in port_of_root.keys():
		var src: Dictionary = port_of_root[port]
		if not slot_of.has(int(src["node"])):
			continue
		order.append(port)
		slots.append(int(slot_of[int(src["node"])]))
		chans.append(int(src["port"]))
	if order.is_empty():
		return {"error": "no wired port compiled to a slot"}

	var result: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], p_gw, p_gh, p_rect,
			p_input, slots, chans)
	var unserved: PackedInt32Array = result.get("unserved", PackedInt32Array())
	var fields: Array = result.get("fields", [])
	for r in range(order.size()):
		var port: int = order[r]
		if unserved.has(r) or r >= fields.size() or not (fields[r] is PackedFloat32Array):
			# §4.4: an unserved channel is NOT zeros. A mask that could not be served writes nothing; a
			# value port that could not be served falls back to the node's own property, which is the
			# declared default rather than an impostor.
			if port == mask_port and mask_required:
				return {"error": "the mask channel is not served by this graph"}
			continue
		var field: PackedFloat32Array = fields[r]
		if port == p_sink.mask_port():
			mask = field
		elif Pasture3DGraphNode.is_field_type(int(types[port])):
			values[String(names[port])] = field
		elif field.size() > 0:
			values[String(names[port])] = int(round(field[0])) \
					if int(types[port]) == Pasture3DGraphNode.PortType.INT else field[0]
	if mask.size() != p_gw * p_gh:
		# A REQUIRED mask that did not arrive is still a refusal, and so is a WIRED one that the graph
		# could not serve -- a stencil the author drew and the bake could not honour is a bug, not a
		# default. An optional mask that was never wired is the whole footprint.
		if mask_required or not source_of(p_graph, p_index, mask_port).is_empty():
			return {"error": "the mask tap returned %d cells, not %d" % [mask.size(), p_gw * p_gh]}
		mask = _whole_footprint(p_gw, p_gh, p_input)

	var cerr := _resolve_colours(p_graph, p_sink, p_index, ctx, values)
	if cerr != "":
		return {"error": cerr}
	return {"mask": mask, "values": values}


## Fill `r_values` with every COLOR port's colour, read from the wired node rather than from a slot.
## Returns "" or the error to report. See the Color Sink's header for why a colour is not tapped.
##
## Shared by both exits of `_resolve_ports`: the tapped path and the no-tappable-root path a sink takes
## when its only wire is a colour. One copy, because two would be two chances to disagree about what a
## COLOR port means.
static func _resolve_colours(p_graph, p_sink, p_index: int, p_ctx: Dictionary, r_values: Dictionary) -> String:
	var names: PackedStringArray = p_sink.input_names()
	var types: PackedInt32Array = p_sink.input_port_types()
	for port in range(p_sink.input_count()):
		if port >= types.size() or int(types[port]) != Pasture3DGraphNode.PortType.COLOR:
			continue
		var src := source_of(p_graph, p_index, port)
		if src.is_empty():
			continue
		var col = _color_of(p_graph, int(src["node"]), p_ctx)
		if col == null:
			return ("the `%s` port is wired to a node that carries no colour. A vector or field cannot "
					+ "travel a COLOR port; wire a Const Color or leave it unwired.") % String(names[port])
		r_values[String(names[port])] = col
	return ""


## The mask a sink writes with when its stencil port is unwired and optional: on everywhere the brush
## actually put ground.
##
## NOT a flat 1.0. A cell the brush loop never wrote is NaN in the input surface, and painting there
## would spill the sink outside the footprint the rest of the bake respects -- so a no-data cell is off.
## With no surface to consult (an empty p_input) there is no footprint to be outside of, and the whole
## grid is on.
static func _whole_footprint(p_gw: int, p_gh: int, p_input: PackedFloat32Array) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)
	var have_surface: bool = p_input.size() == n
	for i in range(n):
		out[i] = 1.0 if (not have_surface or is_finite(p_input[i])) else 0.0
	return out


## Evaluate the field wired into `p_port` of the node at `p_to`, over the bake grid in `p_ctx`.
##
## A SECOND PASS, and deliberately so. The sink's own ports are tapped in one multi-root pass because
## they all hang off the sink; a Color Blend's mask hangs off the Blend, which the sink reaches only
## through a COLOR wire the program does not carry. Folding it into the sink's pass would mean the
## colour walk and the tap compile knowing about each other. This is paid once per Color Blend per bake,
## and only by graphs that contain one.
##
## Empty when the port is unwired, when the graph does not lower, or when the channel is unserved —
## three different failures that all mean the same thing to the caller: there is no field, fall back to
## the uniform colour rather than to a grid of zeros (section 4.4).
static func _tap_field(p_graph, p_to: int, p_port: int, p_ctx: Dictionary) -> PackedFloat32Array:
	var src := source_of(p_graph, p_to, p_port)
	if src.is_empty():
		return PackedFloat32Array()
	var compiled: Dictionary = p_graph.compile_graph_program_multi([int(src["node"])])
	if compiled.is_empty():
		return PackedFloat32Array()
	var slot_of: Dictionary = compiled["slot_of"]
	if not slot_of.has(int(src["node"])):
		return PackedFloat32Array()
	var res: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"],
			int(p_ctx["gw"]), int(p_ctx["gh"]), p_ctx["rect"], p_ctx.get("input", PackedFloat32Array()),
			PackedInt32Array([int(slot_of[int(src["node"])])]), PackedInt32Array([int(src["port"])]))
	var unserved: PackedInt32Array = res.get("unserved", PackedInt32Array())
	if unserved.has(0):
		return PackedFloat32Array()
	var fields: Array = res.get("fields", [])
	if fields.is_empty() or not (fields[0] is PackedFloat32Array):
		return PackedFloat32Array()
	return fields[0]


## The COLOR produced by the node at `p_index`, or null if it produces none.
##
## ---- WHY THIS IS NOT `"color" in node`, AND WHY IT RECURSES ----
##
## It was `"color" in node`, and that read Const Color — the ONE producer of a COLOR port in the whole
## registry — as carrying no colour, because its export is named `value`, not `color`. Wiring the only
## legal source into a Color Sink returned the "wired to a node that carries no colour" refusal. The
## refusal itself is right (see the Color Sink's header); it was asking the wrong question.
##
## The recursion is what makes a COLOR OPERATOR possible at all. The SSA program's buffers are scalar, so
## a colour cannot flow through the evaluator; it is a COMPILE-TIME sideband, folded here by walking
## upstream. That is the whole reason a Color Mix is safe: it never lowers, never appears in
## `graph_op_ids()`, and so cannot cost the graph its native path (§10).
##
## A node whose colour is computed rather than stored implements `graph_color(p_upstream)`, where
## `p_upstream` maps its own COLOR input NAMES to the resolved Colors. An input that resolves to nothing
## is ABSENT from the dictionary rather than present as a default — the node decides what an unwired port
## means, exactly as `input_unwired_default` lets a field node decide.
static func _color_of(p_graph, p_index: int, p_ctx: Dictionary = {}, p_depth: int = 0) -> Variant:
	if p_graph == null or p_index < 0 or p_index >= p_graph.nodes.size():
		return null
	var node = p_graph.nodes[p_index]
	if node == null:
		return null
	if node.has_method("graph_color"):
		var upstream := {}
		# The depth cap is a cycle guard. The graph editor refuses to author a cycle, but a hand-edited
		# .tres can carry one and a colour fold has no visited set of its own.
		if p_depth < 16:
			var names: PackedStringArray = node.input_names()
			var types: PackedInt32Array = node.input_port_types()
			for port in range(node.input_count()):
				if port >= types.size() or int(types[port]) != Pasture3DGraphNode.PortType.COLOR:
					continue
				var src := source_of(p_graph, p_index, port)
				if src.is_empty():
					continue
				var up = _color_of(p_graph, int(src["node"]), p_ctx, p_depth + 1)
				if up != null and port < names.size():
					upstream[String(names[port])] = up
		# ---- THE PER-CELL BRANCH ----
		#
		# A node that answers `graph_color_cells` wants a FIELD, not just its upstream colours: a Color
		# Blend chooses between A and B per cell from a mask. The field is tapped from the program the
		# same way the sink's own mask is, so a wire cannot mean one thing here and another to the
		# kernel — and when it cannot be tapped (no grid context, or an unwired mask) the node's own
		# uniform `graph_color` answers instead, which is why that method is not optional.
		if node.has_method("graph_color_cells") and node.has_method("color_mask_port") and not p_ctx.is_empty():
			var field := _tap_field(p_graph, p_index, int(node.color_mask_port()), p_ctx)
			var cells: int = int(p_ctx.get("gw", 0)) * int(p_ctx.get("gh", 0))
			if field.size() == cells and cells > 0:
				var per_cell = node.graph_color_cells(upstream, field, cells)
				if per_cell is PackedColorArray and per_cell.size() == cells:
					return per_cell
		var g = node.graph_color(upstream)
		return g if g is Color else null
	if "color" in node and node.color is Color:
		return node.color
	if "value" in node and node.value is Color:
		return node.value
	return null


## Resolve/clear/write/recomposite one sink. Returns the number of cells authored.
static func _write_one(p_sink, p_index: int, p_data, p_owner_base: String, p_gw: int, p_gh: int,
		p_rect: Rect2, p_mask: PackedFloat32Array, p_values: Dictionary, p_report: Dictionary,
		p_cleared: Dictionary) -> int:
	# STEP 1 — resolve/create. The node index is in the owner id so two Control Sinks in one graph own
	# two layers; without it the second's clear would wipe the first's paint on every bake.
	#
	# A `layer_key` REPLACES the index, which is how two sinks name the same layer on purpose. The
	# suffix stays either way, so a Control Sink and a Color Sink that happen to share a key still get
	# their own layers — they have different map types and could not share a tile format anyway.
	var key: String = p_sink.layer_key if "layer_key" in p_sink else ""
	var owner: String = ("%s%s:%s" % [p_owner_base, p_sink.sink_owner_suffix(), key]) if key != "" 			else ("%s%s%d" % [p_owner_base, p_sink.sink_owner_suffix(), p_index])
	var label: String = key if key != "" else "%s %d" % [p_sink.sink_layer_label(), p_index]
	var layer_id: int = p_data.create_owned_layer_typed(owner, label, Pasture3DGraphNodeChannelSink.BLEND_REPLACE,
			p_sink.sink_map_type())
	if layer_id < 0:
		p_report["skipped"].append("%s: no layer could be reserved" % _label_of(p_sink, p_index))
		return 0
	var layers: PackedInt32Array = p_report["layers"]
	layers.append(layer_id)
	p_report["layers"] = layers

	# STEP 2 — clear OUR footprint. Composite is deferred to step 4: compositing the cleared area now
	# would push a frame of bare ground to the GPU and then overwrite it, for two full passes.
	var area := AABB(Vector3(p_rect.position.x, -100000.0, p_rect.position.y),
			Vector3(p_rect.size.x, 200000.0, p_rect.size.y))
	# ONCE PER LAYER PER BAKE, not once per sink. On a shared `layer_key` the second sink must find the
	# first's paint still there to composite over — see `layer_key`. On the unshared default this is
	# exactly the old behaviour, because each sink is the only one that ever names its layer.
	var is_color: bool = p_sink.sink_map_type() == Pasture3DGraphNodeChannelSink.MAPTYPE_COLOR
	if not p_cleared.has(layer_id):
		p_data.clear_layer_in_area(layer_id, area, false)
		p_cleared[layer_id] = true
		clear_count += 1

	# STEP 3 — write, and ONLY where the mask is on. Outside it nothing is authored, so the cell stays
	# uncovered in this layer and the composite leaves whatever is beneath byte-identical. That is the
	# write-stencil rule, and it is why this is an `if` and not a weight.
	var written := 0
	for iz in range(p_gh):
		var wz: float = p_rect.position.y + (float(iz) + 0.5) * p_rect.size.y / float(p_gh)
		var row := iz * p_gw
		for ix in range(p_gw):
			var m: float = p_mask[row + ix]
			if not (m > Pasture3DGraphNodeChannelSink.MASK_EPSILON):
				continue
			var wx: float = p_rect.position.x + (float(ix) + 0.5) * p_rect.size.x / float(p_gw)
			var pos := Vector3(wx, 0.0, wz)
			if is_color:
				p_data.set_color_on_layer(layer_id, pos, p_sink.color_at(p_values, row + ix), 1.0, false)
			else:
				# Read the COMPOSITED word beneath, so the bits this sink does not author survive. See
				# Pasture3DGraphNodeControlSink's header: under topmost-covered-wins there is no
				# "leave alone", only "carry forward" and "destroy".
				var below: int = p_data.get_control(pos)
				if below == 0xFFFFFFFF:
					below = 0
				var word: int = p_sink.control_word(below, p_values, row + ix)
				if word < 0:
					continue # Refused at the node. Authors nothing rather than authoring texture 0.
				p_data.set_control_on_layer(layer_id, pos, word, 1.0, false)
			written += 1
	write_count += written

	# STEP 4 — recomposite once over the whole footprint, and push it.
	p_data.composite_area(area, true)
	return written
