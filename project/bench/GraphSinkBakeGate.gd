# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSinkBakeGate — the sink pass reaches the terrain THROUGH A BAKE, on both raster routes, and a
# `layer_key` is what decides how many layers it writes into.
#
# ---- WHY THIS GATE EXISTS ----
#
# `GraphChannelSinkGate` and `GraphRuntimeSinkGate` both call the writer directly — `…ChannelSinks.run()`
# and `…RuntimeSinks.run()` — and never bake. Both passed for as long as they have existed while the
# wiring that calls them from a bake WAS ABSENT ENTIRELY: `_run_graph_sinks` lived inside
# `Pasture3DTerrainBrush._apply_graph_step`, and that function is the GDScript rasteriser only. A graph
# whose every op the native evaluator implements takes `BrushModStep::GRAPH` in C++ instead, so on every
# graph fast enough to lower natively — which is to say on every graph that works — the sinks wrote
# nothing, cleared nothing, published nothing, and said nothing about it.
#
# That is `component-gates-miss-wiring` exactly: a unit gate cannot see a caller that does not exist. So
# this gate asserts on what a BAKE produced, and it asserts it on the route a user actually takes.
#
# ---- WHAT EACH CRITERION IS MEASURING ----
#
# [A]  A bake on the NATIVE route creates the sink's layer and writes into it. The criterion first
#      asserts it is on that route (`native_supported()` true, `_stack_forces_gdscript()` false), because
#      without that it would silently degrade into a second copy of [B] the day a node stops lowering —
#      which is precisely the condition that hid the bug. CONTROL: `write_count` is zero before the bake
#      and non-zero after, so "a bake happened" and "a bake wrote" are different observations.
# [B]  The GDSCRIPT route writes too, and writes the same cells to within the loop rim. Route parity is
#      the property that makes `force_gdscript_raster` a debugging aid rather than a behaviour switch.
#      The rim tolerance is NOT slack taken to make the criterion pass — see the note below, which
#      records what it is covering and how large the disagreement measured.
# [C]  Two sinks sharing a `layer_key` share ONE layer: cleared once, both authoring, later over earlier.
#      CONTROL: making the clear per-sink again wipes the first sink's paint outside the second's mask —
#      the low-ground cell drops from A's base to the ground's. That is the criterion; the base at high
#      ground is NOT, because the second sink fully replaces the word there either way.
# [D]  An empty `layer_key` — the default — still gives one layer per sink and clears twice. The
#      historical behaviour has to survive the feature, or every graph that already exists changes.
# [E]  `layer_add_typed` makes a HAND layer and `create_owned_layer_typed` makes a TOOL layer, and they
#      differ in exactly the two fields that decide whether a stroke is refused. A dock that called the
#      second would hand the user a control layer that refuses every stroke and is cleared by the next
#      bake, which is indistinguishable from a broken dock until a brush bakes.
#
# ---- WHAT THIS GATE CANNOT SAY ----
#
# **It does not prove the native evaluator ran the graph.** It proves the brush CHOSE the native route
# and that the sinks fired. The kernel's own agreement with the GDScript oracle is `GraphNativeParityGate`'s
# question, and duplicating it here would be a tolerance dressed up as a second opinion.
#
# **[B]'s cell count is equal only to within the loop rim, and the residual is not the sink pass.**
# Measured on this fixture: both routes produce the same 86x86 grid, the same rect and the same height
# range, but the native raster leaves 1062 cells NaN and the GDScript raster 938 — a 124-cell
# disagreement about where the mound's own footprint ends. NaN means "the brush wrote nothing here", so
# that difference exists BEFORE the graph step runs and has nothing to do with sinks; the sink pass only
# makes it visible, because an ALTITUDE mask is NaN-off and therefore inherits the footprint exactly.
# [B] bounds the difference by the rim (2*(gw+gh)) and asserts the named interior cells agree, which is
# what the sink pass is answerable for. The footprint disagreement itself belongs to whichever gate owns
# `stamp_mound_loop` against its GDScript oracle, and is recorded rather than absorbed here.
#
# **It says nothing about the B3 publish sinks.** They travel the same hoisted pass and inherit the fix,
# but a publish needs consumer nodes in a scene and that is `GraphRuntimeSinkGate`'s fixture. What is
# asserted here is the pass they share, once.
#
# House discipline (`bench-gate-practices`): every criterion carries a control that must fail if the
# thing under test is removed, and `_checks` counts COMPLETIONS — a criterion that threw before asserting
# is a failure, not a silent skip (`gate-pass-can-mean-nothing-ran`).
extends Node

## The terrain is 128 cells of ground rising west→east, so an ALTITUDE mask has a real gradient to band
## on and "inside the band" is a set of cells that can be named by their x.
const N: int = 128
## Half-extent of the brush loop, in metres. The footprint is therefore x ∈ [24, 104].
const HALF: float = 40.0
## Ground height at x: 10 m rising by 0.5 m/cell. Inverted by `_x_at_height` below.
const GROUND_BASE: float = 10.0
const GROUND_SLOPE: float = 0.5
## Inside the footprint and below the high band — only the first sink writes here.
const LOW_X: float = 30.0
## Inside the footprint and inside the high band — both sinks write here.
const HIGH_X: float = 95.0

var _fail: int = 0
var _checks: int = 0
var _uniq: int = 0


func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
		print("    !! FAIL: %s" % p_msg)
	else:
		print("    ok: %s" % p_msg)


func _ready() -> void:
	print("=== GraphSinkBakeGate (the sink pass, through a bake, on both raster routes) ===")
	await _a_the_native_route_bakes_a_sink_layer()
	await _b_the_gdscript_route_agrees()
	await _c_a_shared_layer_key_is_one_layer()
	await _d_an_empty_layer_key_is_one_layer_per_sink()
	_e_a_hand_layer_and_a_tool_layer_differ()

	print("--- %d checks, %d failures" % [_checks, _fail])
	if _checks < 23:
		print("!! GATE INCOMPLETE: %d checks ran, expected at least 23 — a criterion threw before asserting"
				% _checks)
		_fail += 1
	print("=== GraphSinkBakeGate: %s ===" % ("PASS" if _fail == 0 else "FAIL"))
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------------

## A terrain with ground rising along +x. Fresh per criterion: a shared one would let an earlier
## criterion's layers decide a later one's layer indices, and [C]/[D] count layers.
func _terrain() -> Pasture3D:
	var t := Pasture3D.new()
	_uniq += 1
	t.name = "T%d" % _uniq
	t.vertex_spacing = 1.0
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	for iz in range(N):
		for ix in range(N):
			t.data.set_height(Vector3(float(ix) + 0.5, 0.0, float(iz) + 0.5),
					GROUND_BASE + float(ix) * GROUND_SLOPE)
	return t


## A Mound over the middle of the terrain with a square closed loop, so the bake grid is a known box.
func _mound(p_t: Pasture3D) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	_uniq += 1
	m.name = "M%d" % _uniq
	add_child(m)
	m.terrain = p_t
	m.global_position = Vector3(64.0, 0.0, 64.0)
	m.height = 20.0
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	m.add_child(path)
	return m


## An ALTITUDE mask banding everything at or above `p_min`. Hard edges: a falloff would make "inside the
## band" a feathered set and no single cell could be named as in or out.
func _mask(p_min: float) -> Pasture3DGraphNodeMask:
	var m := Pasture3DGraphNodeMask.new()
	m.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	m.band_min = p_min
	m.band_max = 1000000.0
	m.falloff_lo = 0.0
	m.falloff_hi = 0.0
	return m


func _control_sink(p_name: String, p_base: int, p_key: String) -> Pasture3DGraphNodeControlSink:
	var s := Pasture3DGraphNodeControlSink.new()
	s.resource_name = p_name
	s.base_texture = p_base
	s.overlay_texture = 4
	s.layer_key = p_key
	return s


## Input → Mask → Output, plus each sink hung off its own mask. Returns the graph.
##
## The Output is wired so the graph LOWERS — a graph with no output node compiles to nothing and the
## native route would be unreachable for reasons that have nothing to do with sinks.
func _graph(p_sinks: Array, p_bands: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = []
	nodes.append(Pasture3DGraphNodeInput.new())          # 0
	nodes.append(_mask(5.0))                             # 1 — drives the Output
	nodes.append(Pasture3DGraphNodeOutput.new())         # 2
	var conns: Array = [[0, 0, 1, 0], [1, 0, 2, 0]]
	for i in range(p_sinks.size()):
		var band_i := nodes.size()
		nodes.append(_mask(p_bands[i]))
		nodes.append(p_sinks[i])
		conns.append([0, 0, band_i, 0])                  # Input → this sink's band mask
		conns.append([band_i, 0, band_i + 1, 0])         # band mask → sink.mask
	g.nodes = nodes
	g.connections = conns
	g.output_node = 2
	return g


## Bake. `refresh()` is editor-hint gated (`pasture3d_terrain_brush.gd`), so headless drives the owner
## directly — the same entry `refresh()` reaches, minus the guard headless cannot satisfy.
func _bake(p_m: Pasture3DMound) -> void:
	p_m._stamp_cache.clear()
	p_m._refresh_owner(p_m._layer_owner, false, [])
	await get_tree().process_frame


func _base_at(p_t: Pasture3D, p_x: float) -> int:
	var w: int = p_t.data.get_control(Vector3(p_x, 0.0, 64.0))
	return -1 if w == 0xFFFFFFFF else (w >> 27) & 0x1F


## Control layers in the stack that a brush owns, as [{"id","name","reserved","owner"}].
func _owned_control_layers(p_t: Pasture3D) -> Array:
	var out: Array = []
	var st = p_t.data.get_layer_stack()
	if st == null:
		return out # No stack yet: a terrain nothing has baked into. Not an error, and not zero layers.
	for i in range(st.get_layer_count()):
		var l = st.get_layer(i)
		if l.get_map_type() == 1 and l.get_owner_id() != "":
			out.append({"id": i, "name": l.get_layer_name(), "reserved": l.is_reserved(),
					"owner": l.get_owner_id()})
	return out


func _drop(p_nodes: Array) -> void:
	for n in p_nodes:
		if n != null and is_instance_valid(n):
			n.queue_free()


# ---------------------------------------------------------------------------------------------------
# [A] The native route bakes a sink layer
# ---------------------------------------------------------------------------------------------------
func _a_the_native_route_bakes_a_sink_layer() -> void:
	print("  [A] a bake on the native raster route creates and fills the sink's layer")
	var t := _terrain()
	var m := _mound(t)
	var sink := _control_sink("A", 3, "")
	var g := _graph([sink], [5.0])
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	m.modifiers = [mod] as Array[Pasture3DNode]

	# THE ROUTE ASSERTION, and the reason this is not a duplicate of [B]. The bug being guarded against
	# is "the sinks only fire on the slow route", so a criterion that did not establish which route it
	# was on could pass while measuring the slow one.
	_check(g.native_supported(), "the graph lowers natively, so the bake takes the C++ rasteriser")
	_check(not m._stack_forces_gdscript(), "nothing in the stack forces the GDScript rasteriser")

	Pasture3DGraphChannelSinks.write_count = 0
	Pasture3DGraphChannelSinks.clear_count = 0
	# CONTROL: no bake has happened, so the counters are zero. Distinguishes "the bake wrote" from
	# "the counters were already non-zero when we looked".
	_check(Pasture3DGraphChannelSinks.write_count == 0, "control: nothing is written before the bake")
	_check(_owned_control_layers(t).is_empty(), "control: no owned control layer exists before the bake")

	await _bake(m)

	_check(Pasture3DGraphChannelSinks.write_count > 0,
			"the bake authored %d cells" % Pasture3DGraphChannelSinks.write_count)
	_check(Pasture3DGraphChannelSinks.clear_count == 1,
			"the bake cleared the sink's footprint once (%d)" % Pasture3DGraphChannelSinks.clear_count)
	var owned := _owned_control_layers(t)
	_check(owned.size() == 1, "exactly one owned control layer exists (%d)" % owned.size())
	_check(owned.size() == 1 and owned[0]["reserved"], "the sink's layer is reserved")
	_check(_base_at(t, LOW_X) == 3, "the sink's base texture reached the terrain (%d)" % _base_at(t, LOW_X))
	_drop([t, m])


# ---------------------------------------------------------------------------------------------------
# [B] The GDScript route agrees
# ---------------------------------------------------------------------------------------------------
func _b_the_gdscript_route_agrees() -> void:
	print("  [B] the GDScript raster route writes the same cells")
	var t := _terrain()
	var m := _mound(t)
	m.force_gdscript_raster = true
	var sink := _control_sink("B", 3, "")
	var g := _graph([sink], [5.0])
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	m.modifiers = [mod] as Array[Pasture3DNode]

	_check(not m._native_raster("stamp_mound_loop"),
			"control: force_gdscript_raster really does refuse the native route")
	Pasture3DGraphChannelSinks.write_count = 0
	await _bake(m)
	var gd_written: int = Pasture3DGraphChannelSinks.write_count
	_check(gd_written > 0, "the GDScript bake authored %d cells" % gd_written)
	_check(_base_at(t, LOW_X) == 3, "the same base texture reached the same cell")

	# ROUTE PARITY. The same graph on the native route must author the same COUNT — the two rasterisers
	# compute the surface differently but the sink taps its own inputs, so the stencil is the same set.
	var t2 := _terrain()
	var m2 := _mound(t2)
	var sink2 := _control_sink("B2", 3, "")
	var mod2 := Pasture3DNodeGraph.new()
	mod2.graph = _graph([sink2], [5.0])
	m2.modifiers = [mod2] as Array[Pasture3DNode]
	Pasture3DGraphChannelSinks.write_count = 0
	await _bake(m2)
	var native_written: int = Pasture3DGraphChannelSinks.write_count
	# Bounded by the RIM, not equal. See "WHAT THIS GATE CANNOT SAY": the residual is the two mound
	# rasterisers disagreeing about the footprint edge, which predates the sink pass and is measured
	# here rather than absorbed. A whole-footprint divergence — a route that masked differently, or one
	# that tapped the wrong surface — is orders of magnitude larger than a rim and still fails this.
	var rim: int = 2 * (mod.last_gw + mod.last_gh)
	_check(absi(native_written - gd_written) <= rim,
			"both routes authored the same cells to within the loop rim (native %d, gdscript %d, "
					% [native_written, gd_written] + "difference %d, rim %d)"
					% [absi(native_written - gd_written), rim])
	# The INTERIOR, which must agree exactly: two named cells well inside the footprint, one in each
	# band. A rim tolerance that also covered the interior would cover the bug this gate exists for.
	_check(_base_at(t, LOW_X) == _base_at(t2, LOW_X) and _base_at(t2, LOW_X) == 3,
			"the interior agrees cell for cell (gdscript %d, native %d)"
					% [_base_at(t, LOW_X), _base_at(t2, LOW_X)])
	_check(_base_at(t, HIGH_X) == _base_at(t2, HIGH_X),
			"and again at the far end of the footprint (gdscript %d, native %d)"
					% [_base_at(t, HIGH_X), _base_at(t2, HIGH_X)])
	_drop([t, m, t2, m2])


# ---------------------------------------------------------------------------------------------------
# [C] A shared layer_key is one layer
# ---------------------------------------------------------------------------------------------------
func _c_a_shared_layer_key_is_one_layer() -> void:
	print("  [C] two sinks naming one layer_key share a layer, cleared once, later over earlier")
	var t := _terrain()
	var m := _mound(t)
	# A covers everything above 5 m; B only above 35 m. So LOW_X is A's alone and HIGH_X is both.
	var a := _control_sink("A", 3, "shared")
	var b := _control_sink("B", 7, "shared")
	var mod := Pasture3DNodeGraph.new()
	mod.graph = _graph([a, b], [5.0, 35.0])
	m.modifiers = [mod] as Array[Pasture3DNode]

	Pasture3DGraphChannelSinks.clear_count = 0
	await _bake(m)

	var owned := _owned_control_layers(t)
	_check(owned.size() == 1, "the two sinks share ONE layer (%d owned control layers)" % owned.size())
	_check(Pasture3DGraphChannelSinks.clear_count == 1,
			"the shared layer was cleared once, not once per sink (%d)"
					% Pasture3DGraphChannelSinks.clear_count)
	_check(owned.size() == 1 and owned[0]["name"] == "shared",
			"the layer is named for the key, so it is findable in the dock")

	# THE CRITERION. LOW_X is outside B's band, so A's paint must survive there — that is what the
	# once-per-layer clear buys, and it is the cell that changes when the clear goes back to per-sink.
	_check(_base_at(t, LOW_X) == 3,
			"the earlier sink's paint survives outside the later sink's mask (base %d, want 3)"
					% _base_at(t, LOW_X))
	# And inside both bands the later sink wins, which is what "layering" means.
	_check(_base_at(t, HIGH_X) == 7,
			"the later sink composites over the earlier one where both write (base %d, want 7)"
					% _base_at(t, HIGH_X))
	_drop([t, m])


# ---------------------------------------------------------------------------------------------------
# [D] An empty layer_key is one layer per sink
# ---------------------------------------------------------------------------------------------------
func _d_an_empty_layer_key_is_one_layer_per_sink() -> void:
	print("  [D] the default empty layer_key still gives each sink its own layer")
	var t := _terrain()
	var m := _mound(t)
	var a := _control_sink("A", 3, "")
	var b := _control_sink("B", 7, "")
	var mod := Pasture3DNodeGraph.new()
	mod.graph = _graph([a, b], [5.0, 35.0])
	m.modifiers = [mod] as Array[Pasture3DNode]

	Pasture3DGraphChannelSinks.clear_count = 0
	await _bake(m)

	var owned := _owned_control_layers(t)
	_check(owned.size() == 2, "two sinks with no key own two layers (%d)" % owned.size())
	_check(Pasture3DGraphChannelSinks.clear_count == 2,
			"each layer was cleared once (%d clears)" % Pasture3DGraphChannelSinks.clear_count)
	# CONTROL for [C]: the owner ids differ, so sharing in [C] was the KEY doing it and not two sinks
	# happening to land on one layer whatever they are told.
	_check(owned.size() == 2 and owned[0]["owner"] != owned[1]["owner"],
			"control: the two layers have different owner ids")
	_drop([t, m])


# ---------------------------------------------------------------------------------------------------
# [E] A hand layer and a tool layer differ
# ---------------------------------------------------------------------------------------------------
func _e_a_hand_layer_and_a_tool_layer_differ() -> void:
	print("  [E] layer_add_typed makes a HAND layer; create_owned_layer_typed makes a TOOL layer")
	var t := _terrain()
	_check(t.data.has_method("layer_add_typed"),
			"this build has layer_add_typed, so the dock can create a typed layer at all")

	var hand_id: int = t.data.layer_add_typed("Hand Control", Pasture3DLayer.REPLACE, 1)
	var hand = t.data.get_layer_stack().get_layer(hand_id)
	_check(hand != null and hand.get_map_type() == 1,
			"the hand layer is a CONTROL layer (type %d)" % (hand.get_map_type() if hand else -1))
	# The two fields that decide whether a stroke is refused. A dock that called create_owned_layer_typed
	# would look identical in the row and refuse every stroke.
	_check(hand != null and not hand.is_reserved(), "the hand layer is NOT reserved, so it takes strokes")
	_check(hand != null and hand.get_owner_id() == "", "the hand layer has no owner")

	# CONTROL: the tool call differs, and differs in exactly those two fields.
	var tool_id: int = t.data.create_owned_layer_typed("gate:E", "Tool Control", 0, 1)
	var tl = t.data.get_layer_stack().get_layer(tool_id)
	_check(tl != null and tl.is_reserved() and tl.get_owner_id() == "gate:E",
			"control: create_owned_layer_typed reserves and owns, and layer_add_typed does neither")
	_check(tool_id != hand_id, "control: the two calls made two different layers")
	_drop([t])
