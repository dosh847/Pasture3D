# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphRuntimeSinkGate — PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.3, phase V7a.
#
# The B3 publish sinks: the arrow BACK from the graph to the two runtime consumers that already ship.
# `PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3 names the hole this closes — the solve can spawn a Pond, the Pond
# cannot read the solve, and editing terrain under one desynchronises them with no signal.
#
# ---- WHAT EACH CRITERION IS ALLOWED TO CONCLUDE ----
#
#   [A] a graph-published path REACHES `Pasture3DRoadRuntime.locate()`. Asserted on the runtime's own
#       answer at a world point, never on the run this gate built — `check-derived-values-outside-the-chain`:
#       comparing a run's plan to the points I handed it proves only that assignment works.
#       CONTROL: the same point on a network that was never published to reports nothing.
#   [B] editing the terrain UNDER a published water surface marks the consumer stale.
#       CONTROL: an edit somewhere ELSE, of the same magnitude, does not. That control is the criterion:
#       a staleness check that fired on any bake at all would pass the first half and fail this one, and
#       it is the difference between "re-derived" and "signalled" that §12.3 is actually about.
#   [C] the digest asserted is the CONSUMER'S STORED one, not the producer's.
#       CONTROL: a republish with unchanged content leaves the stored digest equal — so the digest is a
#       function of content and not of the act of publishing.
#   [D] a stale consumer STILL ANSWERS, and reports `stale`. A runtime consumer that started returning
#       nulls because somebody moved a spline in the editor is a crash in a shipped game.
#       CONTROL: a fresh one answers the same query and reports fresh.
#   [E] a CLOSED published path builds a `Pasture3DPool` outline and an OPEN one does not.
#       CONTROL: the open path is refused BY NAME, is accepted by a Stream instead, and the Pool's own
#       "this curve is not closed" refusal still fires when the open curve is forced onto it.
#   [F] a Pool fed a published loop is still FLAT (§14.1 Q4: a pool receives an EXTENT, not a level).
#       CONTROL: the published heights themselves vary by metres — otherwise "constant" would be a fact
#       about the fixture rather than about the Pool.
#   [G] terminality. The compiled program is byte-identical with the publish sinks present, and neither
#       sink appears in `graph_op_ids()`. Standing constraint: a GPU/native bail is graph-wide and
#       SILENT (`op-ids-omission-drops-graph-to-gdscript`), so "V7a adds no op" has to be measured, not
#       asserted in a header. CONTROL: a node that IS in the program changes the ops, so the comparison
#       can tell the two apart.
#
# ---- WHY THE FIXTURE DRAPES ----
#
# [B] is meaningless without a path whose CONTENT depends on the terrain. A Spline Source alone hands
# back the same points forever, and a staleness check over it could only ever report fresh. So the chain
# is Spline Source → Path Drape ← Input: the drape re-samples the surface, the heights move, and
# `content_digest()` moves with them. That is also why the writer stages the derive family against the
# caller's surface before resolving (`Pasture3DTerrainGraph.stage_paths_for`) — without it the drape would
# answer from the grid it captured at the previous evaluation and this gate's [B] would be measuring the
# wrong bake.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

const GW := 64
const GH := 64
const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)

## Where the fixture line runs. Everything in [B] depends on knowing which half of the domain is "under
## the path" and which half is not.
const LINE_Z := -80.0
const FAR_Z := 120.0

var _fail: int = 0
var _checks: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== GraphRuntimeSinkGate: the publish sinks (V7a) ===")
	print("    spec: PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.3")

	_a_a_published_path_reaches_locate()
	_b_an_edit_under_the_path_marks_it_stale()
	_c_the_digest_is_the_consumers_stored_one()
	_d_a_stale_consumer_still_answers()
	_e_closed_goes_to_a_pool_and_open_does_not()
	_f_a_pool_fed_a_loop_is_still_flat()
	_g_the_sinks_are_terminal()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	# Completion count, not just a failure count (`gate-pass-can-mean-nothing-ran`): a criterion that
	# threw before asserting reports nothing and would otherwise pass silently.
	if _checks < 39:
		_fail += 1
		print("!! only %d checks completed; expected at least 39" % _checks)
	print("=== GRAPH RUNTIME SINK %s (%d failures, %d checks) ==="
			% ["PASS" if _fail == 0 else "FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- criteria -------------------------------------------------------------------------------------

## [A] the published run is what `locate()` answers from.
func _a_a_published_path_reaches_locate() -> void:
	var key := _name("netA")
	var net := _network(key)
	var g := _graph(_line(false, LINE_Z), _path_publish(key))
	var probe := Vector3(0.0, 0.0, LINE_Z)

	# CONTROL FIRST, so a network that answered before anything was published could not be mistaken for
	# one that answered because of the publish.
	var before: Dictionary = net.runtime.locate(probe) if net.runtime != null else {}
	_check("A", before.is_empty(),
			"CONTROL an unpublished network locates nothing at %s: %s"
			% [probe, "{} " if before.is_empty() else str(before)])

	var report := _run(g, net)
	_check("A", int(report["published"]) == 1,
			"one sink published (skipped: %s)" % [report["skipped"]])
	_check("A", net.runtime != null, "the publish created the runtime the network had none of")

	var hit: Dictionary = net.runtime.locate(probe)
	_check("A", not hit.is_empty(), "the runtime now locates at %s" % probe)
	_check("A", bool(hit.get("on_road", false)),
			"and reports ON ROAD there: distance %.3f m" % float(hit.get("distance", -1.0)))

	# Off to the side by more than the corridor: the run has an extent, not merely an existence.
	var off: Dictionary = net.runtime.locate(Vector3(0.0, 0.0, LINE_Z + 60.0))
	_check("A", not bool(off.get("on_corridor", true)),
			"CONTROL 60 m off the line is off the corridor: distance %.3f m"
			% float(off.get("distance", -1.0)))

	# Republishing REPLACES rather than appends (§8.1's clear-first rule in runtime clothes). Two copies
	# of one road would leave `locate()` choosing between them by list order.
	_run(g, net)
	_check("A", net.runtime.runs.size() == 1,
			"a second publish replaced rather than appended: %d run(s)" % net.runtime.runs.size())


## [B] the staleness check is re-derived from the terrain, not signalled.
func _b_an_edit_under_the_path_marks_it_stale() -> void:
	var key := _name("netB")
	var net := _network(key)
	var g := _graph(_line(false, LINE_Z), _path_publish(key))
	var base := _ramp()

	_run(g, net, base)
	_check("B", not net.runtime.published_stale,
			"a fresh publish is not stale")

	# CONTROL: 40 m of ground raised on the FAR side of the domain. The drape never samples it.
	var elsewhere := _bump(base, FAR_Z, 40.0)
	var w_far := Pasture3DGraphRuntimeSinks.check_staleness(g, net, _ctx(elsewhere))
	_check("B", not net.runtime.published_stale,
			"CONTROL an edit %.0f m away leaves it fresh (%d warning(s))" % [FAR_Z - LINE_Z, w_far.size()])

	# The same edit, under the line.
	var beneath := _bump(base, LINE_Z, 40.0)
	var w_near := Pasture3DGraphRuntimeSinks.check_staleness(g, net, _ctx(beneath))
	_check("B", net.runtime.published_stale,
			"an edit UNDER the path marks it stale (%d warning(s))" % w_near.size())
	_check("B", w_near.size() == 1 and String(w_near[0]).contains(key),
			"and names the consumer: %s" % ["" if w_near.is_empty() else w_near[0]])

	# And it recovers: republishing against the moved ground clears it, so `stale` is a statement about
	# agreement and not a latch that any edit sets forever.
	_run(g, net, beneath)
	_check("B", not net.runtime.published_stale,
			"republishing against the moved ground clears it")


## [C] what is compared is the CONSUMER'S stored digest.
func _c_the_digest_is_the_consumers_stored_one() -> void:
	var key := _name("netC")
	var net := _network(key)
	var g := _graph(_line(false, LINE_Z), _path_publish(key))
	var base := _ramp()
	_run(g, net, base)

	var stored: int = net.runtime.published_digest
	_check("C", stored != 0, "the consumer stores a digest: %d" % stored)

	# Resolved INDEPENDENTLY of the publish, through the same public door the writer uses.
	var resolved := Pasture3DGraphRuntimeSinks.resolve_path(g, _sink_index(g), _ctx(base))
	_check("C", resolved != null and resolved.content_digest() == stored,
			"and it equals the path resolved outside the publish: %d"
			% [0 if resolved == null else resolved.content_digest()])

	# CONTROL: republish with nothing changed. A digest that moved here would be a function of the ACT of
	# publishing, and every consumer in a project would go stale on the bake after the one that fixed it.
	_run(g, net, base)
	_check("C", net.runtime.published_digest == stored,
			"CONTROL an unchanged republish leaves the stored digest at %d (now %d)"
			% [stored, net.runtime.published_digest])

	# And the stamp records WHO. A consumer published from a deleted node is otherwise unattributable.
	_check("C", String(net.runtime.published_by) != "",
			"the stamp names its producer: '%s'" % net.runtime.published_by)

	# The digest is stamped in ONE place for both sinks. A water body published from the same writer
	# carries one too — if `_stamp` lived inside each `publish()`, this is the half that would be missing.
	var pkey := _name("poolC")
	var pool := _pool(pkey)
	var gw := _graph(_loop(), _water_publish(pkey))
	_run(gw, pool, base)
	_check("C", pool.published_digest != 0,
			"the water sink is stamped by the same writer: %d" % pool.published_digest)
	pool.queue_free()


## [D] stale is a flag beside the data, never instead of it.
func _d_a_stale_consumer_still_answers() -> void:
	var key := _name("netD")
	var net := _network(key)
	var g := _graph(_line(false, LINE_Z), _path_publish(key))
	var base := _ramp()
	_run(g, net, base)
	var probe := Vector3(0.0, 0.0, LINE_Z)

	# CONTROL: fresh.
	var fresh: Dictionary = net.runtime.locate(probe)
	_check("D", not fresh.is_empty() and not bool(fresh["stale"]),
			"CONTROL a fresh consumer answers and reports fresh")

	Pasture3DGraphRuntimeSinks.check_staleness(g, net, _ctx(_bump(base, LINE_Z, 40.0)))
	var stale: Dictionary = net.runtime.locate(probe)
	_check("D", not stale.is_empty(),
			"a stale consumer STILL answers at %s" % probe)
	_check("D", bool(stale.get("stale", false)),
			"and reports stale alongside the answer")
	_check("D", not fresh.is_empty() and float(stale["distance"]) == float(fresh["distance"]),
			"with the same last-good geometry: distance %.3f m unchanged" % float(stale["distance"]))


## [E] closed → Pool, open → Stream, and the mismatch is refused by name.
func _e_closed_goes_to_a_pool_and_open_does_not() -> void:
	var base := _ramp()

	# The closed case.
	var pkey := _name("poolE")
	var pool := _pool(pkey)
	var g_closed := _graph(_loop(), _water_publish(pkey))
	var r_closed := _run(g_closed, pool, base)
	_check("E", int(r_closed["published"]) == 1,
			"a CLOSED path publishes to a Pool (skipped: %s)" % [r_closed["skipped"]])
	_check("E", pool.curve != null and pool.curve.closed and pool.curve.point_count >= 3,
			"the Pool received a closed Curve3D of %d point(s)"
			% [0 if pool.curve == null else pool.curve.point_count])
	# The Pool's OWN machinery, not the curve I just handed it: `_local_polygon` is what the mesh and
	# the mask are built from, and a curve that satisfied the setter but not the filler would look
	# identical until something asked for water.
	var poly: PackedVector2Array = pool._local_polygon(4.0)
	_check("E", poly.size() >= 3,
			"and the Pool's own outline fills: %d vertex(es)" % poly.size())

	# CONTROL: the same Pool, an OPEN path. Refused by name.
	var g_open := _graph(_line(false, LINE_Z), _water_publish(pkey))
	var r_open := _run(g_open, pool, base)
	_check("E", int(r_open["published"]) == 0,
			"CONTROL an OPEN path to a Pool publishes nothing")
	var why: String = "" if (r_open["skipped"] as Array).is_empty() else String(r_open["skipped"][0])
	_check("E", why.contains("Pool") and why.contains("closed"),
			"and the refusal names the reason: '%s'" % why)

	# CONTROL, second half: the Pool's own refusal is unchanged. Forcing the open curve on directly is
	# what the graph declined to do, and `_local_polygon` still returns nothing for it.
	var open_curve := Curve3D.new()
	for i in 6:
		open_curve.add_point(Vector3(-100.0 + 40.0 * i, 0.0, LINE_Z))
	pool.curve = open_curve
	_check("E", pool._local_polygon(4.0).is_empty(),
			"CONTROL the Pool still refuses an open curve on its own: %d vertex(es)"
			% pool._local_polygon(4.0).size())

	# The open path IS accepted by a Stream — so [E]'s first half measured the discriminant and not a
	# publish that fails for every water body.
	var skey := _name("streamE")
	var stream := _stream(skey)
	var g_stream := _graph(_line(false, LINE_Z), _water_publish(skey))
	var r_stream := _run(g_stream, stream, base)
	_check("E", int(r_stream["published"]) == 1,
			"the OPEN path routes to a Stream instead (skipped: %s)" % [r_stream["skipped"]])
	_check("E", stream.published_path != null and not stream.published_path.closed,
			"and the Stream holds it, open: %d point(s)"
			% [0 if stream.published_path == null else stream.published_path.points.size()])

	# And the mirror mismatch, so the discriminant is refused in BOTH directions rather than being a
	# rule about Pools that Streams happen to escape.
	var g_loop_stream := _graph(_loop(), _water_publish(skey))
	var r_ls := _run(g_loop_stream, stream, base)
	_check("E", int(r_ls["published"]) == 0,
			"CONTROL a CLOSED path to a Stream publishes nothing: %s" % [r_ls["skipped"]])

	pool.queue_free()
	stream.queue_free()


## [F] the Pool stays flat. §14.1 Q4: it receives an extent, not a level.
func _f_a_pool_fed_a_loop_is_still_flat() -> void:
	var pkey := _name("poolF")
	var pool := _pool(pkey)
	# A ramp, so the drape gives the loop genuinely different heights around its rim.
	var g := _graph(_loop(), _water_publish(pkey))
	var base := _ramp()
	_run(g, pool, base)

	var published := Pasture3DGraphRuntimeSinks.resolve_path(g, _sink_index(g), _ctx(base))
	var lo := INF
	var hi := -INF
	for h in published.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	# CONTROL: if the rim were level, "the Pool is flat" would be a fact about the fixture.
	_check("F", hi - lo > 1.0,
			"CONTROL the published rim varies by %.3f m" % (hi - lo))

	var ys := PackedFloat32Array()
	for i in range(published.points.size()):
		ys.append(pool._still_surface_y(published.points[i]))
	var spread := 0.0
	for y in ys:
		spread = maxf(spread, absf(y - ys[0]))
	_check("F", spread <= 1.0e-4,
			"the Pool's still surface is ONE level across %d rim point(s): spread %.6f m"
			% [ys.size(), spread])
	pool.queue_free()


## [G] terminality — the whole native story (§9.2's mechanism, reused).
func _g_the_sinks_are_terminal() -> void:
	# TERMINALITY ITSELF, first. The program comparison below cannot see this: a sink nothing wires FROM
	# leaves the program alone whether or not it declares an output, so a `has_output()` that flipped to
	# true would pass every other check here and only show up the day somebody wired one into an Output.
	# `has_output()` false is the whole native story (§9.2), so it is asserted rather than inferred.
	var sink := _path_publish("terminality")
	_check("G", not sink.has_output(), "a publish sink declares no output")
	# `output_count()` is deliberately NOT asserted: the base class still reports one, because the port
	# count is what the editor draws and `has_output()` is what decides whether anything may leave it.
	# Asserting the count would be asserting the wrong number and would pass with the mechanism removed.
	# CONTROL: an ordinary PATH filter declares an output, so the assertion above can tell the two apart.
	var filt := Pasture3DGraphNodePathSmooth.new()
	_check("G", filt.has_output(), "CONTROL an ordinary filter declares an output")

	var bare := _graph(_line(false, LINE_Z), null)
	var with_sink := _graph(_line(false, LINE_Z), _path_publish(_name("netG")))
	var a: PackedInt32Array = bare.compile_graph_program().get("ops", PackedInt32Array())
	var b: PackedInt32Array = with_sink.compile_graph_program().get("ops", PackedInt32Array())
	_check("G", not a.is_empty(), "the fixture compiles to %d op word(s)" % a.size())
	_check("G", a == b, "the program is byte-identical with the publish sink present: %d vs %d word(s)"
			% [a.size(), b.size()])

	# CONTROL: the comparison can see a change. A Path Smooth spliced INTO the chain is an ancestor of
	# the Output, so it moves the ops — which makes "identical" above a fact about terminality rather
	# than about a comparison that always agrees.
	var moved := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = _line(false, LINE_Z)
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), src, Pasture3DGraphNodePathDrape.new(),
		Pasture3DGraphNodePathCarve.new(), Pasture3DGraphNodeOutput.new(),
		Pasture3DGraphNodePathSmooth.new()]
	moved.nodes = ns
	moved.connections = [
		[0, 0, 2, 1], [1, 0, 2, 0],
		[2, 0, 5, 0],  # Drape  -> Smooth
		[5, 0, 3, 1],  # Smooth -> Carve.path
		[0, 0, 3, 0], [3, 0, 4, 0],
	]
	var c: PackedInt32Array = moved.compile_graph_program().get("ops", PackedInt32Array())
	_check("G", c != a, "CONTROL a node in the program DOES change it: %d vs %d word(s)"
			% [a.size(), c.size()])

	# And neither op is registered, because neither is ever emitted.
	var ids: Dictionary = Pasture3DUtil.graph_op_ids() if ClassDB.class_has_method(
			"Pasture3DUtil", "graph_op_ids") else {}
	_check("G", not ids.has("path_publish") and not ids.has("water_surface_publish"),
			"neither publish op is in graph_op_ids() (%d op(s) registered)" % ids.size())
	# CONTROL for that: an op the graph DOES emit is there, so the absence above is a fact about these
	# two and not about a lookup that returns nothing (`op-ids-omission-drops-graph-to-gdscript`).
	_check("G", ids.is_empty() or ids.has("path_carve"),
			"CONTROL an emitted op IS registered: path_carve %s"
			% ["present" if ids.has("path_carve") else "ABSENT"])


# ---- fixture --------------------------------------------------------------------------------------

## Input → Drape.surface, Source → Drape.path, Drape → Carve.path, Input → Carve.surface, Carve → Output,
## and (when given) Drape → sink.path.
##
## The Carve is not decorative: it is what makes the drape an ancestor of the Output, so the graph has a
## program at all — which is what [G] compares.
func _graph(p_path: Pasture3DGraphPath, p_sink) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = p_path
	var carve := Pasture3DGraphNodePathCarve.new()
	var ns: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), src, Pasture3DGraphNodePathDrape.new(), carve,
		Pasture3DGraphNodeOutput.new()]
	if p_sink != null:
		ns.append(p_sink)
	g.nodes = ns
	g.connections = [
		[0, 0, 2, 1],  # Input  -> Drape.surface
		[1, 0, 2, 0],  # Source -> Drape.path
		[2, 0, 3, 1],  # Drape  -> Carve.path
		[0, 0, 3, 0],  # Input  -> Carve.surface
		[3, 0, 4, 0],  # Carve  -> Output
	]
	if p_sink != null:
		# Assigned, not appended: `connections` is a setter and the topology caches clear on its signal.
		var cx: Array = g.connections
		cx.append([2, 0, 5, 0])  # Drape -> sink.path
		g.connections = cx
	return g


func _sink_index(p_graph) -> int:
	var idx := Pasture3DGraphRuntimeSinks.sinks_of(p_graph)
	return idx[0] if not idx.is_empty() else -1


func _path_publish(p_key: String) -> Pasture3DGraphNodePathPublish:
	var s := Pasture3DGraphNodePathPublish.new()
	s.consumer_key = p_key
	s.resource_name = "Publish " + p_key
	s.corridor_half_width = 8.0
	return s


func _water_publish(p_key: String) -> Pasture3DGraphNodeWaterSurfacePublish:
	var s := Pasture3DGraphNodeWaterSurfacePublish.new()
	s.consumer_key = p_key
	s.resource_name = "Water " + p_key
	return s


## An OPEN line along constant Z, or a CLOSED one when asked.
func _line(p_closed: bool, p_z: float) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for i in 17:
		pts.append(Vector2(-150.0 + 300.0 * (float(i) / 16.0), p_z))
		w.append(5.0)
		h.append(0.0)
	p.points = pts
	p.half_widths = w
	p.heights = h
	p.closed = p_closed
	return p


## A closed ring, for the Pool half.
func _loop() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for i in 24:
		var a: float = TAU * float(i) / 24.0
		pts.append(Vector2(cos(a) * 90.0, sin(a) * 90.0))
		w.append(4.0)
		h.append(0.0)
	p.points = pts
	p.half_widths = w
	p.heights = h
	p.closed = true
	return p


## A surface that slopes across Z, so a draped ring picks up genuinely different heights around its rim.
func _ramp() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in GH:
		var wz: float = RECT.position.y + (float(iz) + 0.5) * RECT.size.y / float(GH)
		for ix in GW:
			out[iz * GW + ix] = wz * 0.1
	return out


## `p_base` with a 40 m plateau centred on world Z `p_z`, 30 m tall in Z. Used for both halves of [B]:
## the same edit, in two places.
func _bump(p_base: PackedFloat32Array, p_z: float, p_height: float) -> PackedFloat32Array:
	var out := p_base.duplicate()
	for iz in GH:
		var wz: float = RECT.position.y + (float(iz) + 0.5) * RECT.size.y / float(GH)
		if absf(wz - p_z) > 30.0:
			continue
		for ix in GW:
			out[iz * GW + ix] += p_height
	return out


func _ctx(p_input: PackedFloat32Array) -> Dictionary:
	return {"gw": GW, "gh": GH, "rect": RECT, "input": p_input}


func _run(p_graph, p_host: Node, p_input: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var input := p_input if not p_input.is_empty() else _ramp()
	return Pasture3DGraphRuntimeSinks.run(p_graph, p_host, _ctx(input))


## Consumers are resolved BY NAME out of the whole scene, so every fixture needs its own. Two criteria
## that both called their network "net" would silently share the first one's — which is not a hypothetical:
## it is what this gate did on its first run, and [B] read a null runtime off a network that had never
## been published to while [A]'s got published to twice.
var _uniq: int = 0

func _name(p_stem: String) -> String:
	_uniq += 1
	return "%s%d" % [p_stem, _uniq]


func _network(p_name: String) -> Pasture3DRoadNetwork:
	var n := Pasture3DRoadNetwork.new()
	n.name = p_name
	add_child(n)
	return n


func _pool(p_name: String) -> Pasture3DPool:
	var p := Pasture3DPool.new()
	p.name = p_name
	add_child(p)
	return p


func _stream(p_name: String) -> Pasture3DStream:
	var s := Pasture3DStream.new()
	s.name = p_name
	add_child(s)
	return s
