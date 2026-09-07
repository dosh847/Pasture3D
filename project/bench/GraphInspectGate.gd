extends Node

# GraphInspectGate — THE INSPECTOR DOCK (PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §7, phase V4)
#
# §2.3's second conclusion: every comparable tool has a quantitative surface and we have none. A thumbnail
# says "there is a channel network here"; it cannot say "the flow at this confluence is 4 200 m²". This
# phase adds the probe, the histogram, the statistics, the PATH profiles, the pin — and, decided
# 2026-09-07 and recorded in §7, the CHANNEL SELECTOR that finally makes V2's mechanism reachable.
#
# ---- WHAT MAKES THIS GATE HARD TO WRITE HONESTLY ----
#
# Every number here is derived from a field, and the field is derived from a graph. So a check that
# compares a derived number to the number it came from proves only that the derivation is a function —
# `check-derived-values-outside-the-chain`, and the failure mode this whole file is arranged against. The
# probe is therefore checked against a field read OUTSIDE the inspector's path, by a separate
# `graph_eval_grid_taps` call the gate makes for itself; the histogram is checked against the DECLARED
# range's arithmetic, not against the binner's own idea of the range; the channel reading is checked
# against an independent tap of the same channel.
#
#   [A]  the probe reports the field's value at a cell, checked against an independent tap.
#        Control: a neighbouring cell differs, so a constant fixture cannot pass.
#   [A2] the inspector's field was tapped at the INSPECTOR's resolution, not upsampled from the thumbnail.
#        Asserted on the tap's requested grid size. Control: the thumbnail pass in the same refresh
#        requested 128, so a single shared tap cannot satisfy both.
#   [A3] no inspector tap is dispatched while the dock is CLOSED — counted. Control: opening it dispatches.
#   [B]  the histogram bins over the DECLARED range, not the data's. A mask spanning 0.28–0.32 fills bins
#        near the left of a 0..1 axis and leaves the rest empty. Control: the same data on a HEIGHT port
#        with an AUTO range does fill the axis — so the criterion measures the type RULE, not the binner.
#   [C]  the width profile equals `half_width_at(s)` sampled independently.
#        Control: a constant-width path is flat and a tapered one is not.
#   [D]  a heightless path's profile draws a GAP, asserted as absent-data (NAN) rather than as zeros.
#        Control: a path carrying heights draws no gap.
#   [E]  pinning holds the node across a selection change. Control: unpinned follows it.
#   [F]  the channel selector moves the probe, the histogram AND the statistics together to that channel's
#        field, compared against a tap made outside the dock. Controls: channel 0 and channel 1 differ, and
#        an UNRESERVED channel reports NO_DATA with no statistics rather than zeros — the distinction V2's
#        `reserved` key was added to make observable.
#
# Headless. Needs the freshly built DLL for `graph_eval_grid_taps`, and says so rather than passing.

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")
const Inspector = preload("res://addons/pasture_3d/src/graph_inspector.gd")

var _fail := 0
var _checks := 0


func _ready() -> void:
	print("=== GraphInspectGate: the inspector dock (spec V4 §7) ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		print("!! Pasture3DUtil.graph_eval_grid_taps is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return

	_a_the_probe_reads_the_field()
	_a3_a_closed_dock_dispatches_nothing()
	_b_the_histogram_bins_over_the_declared_range()
	_c_the_width_profile_follows_the_path()
	_d_a_heightless_profile_is_a_gap()
	_e_pinning_holds_the_node()
	_f_the_channel_selector_moves_everything()

	if _checks < 43:
		print("\n    VACUOUS: only %d checks completed; the gate did not measure what it claims to."
				% _checks)
		_fail += 1
	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["GRAPH INSPECT PASS" if _fail == 0 else "GRAPH INSPECT FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


# ---- fixtures -----------------------------------------------------------------------------------------


## A Noise -> Output graph with a real, VARIED noise field.
##
## The seed and frequency are explicit because a Noise node with no `noise` resource assigned is a defined
## flat 0 — and on a flat field every check in this gate passes for the wrong reason. That exact fixture
## bug cost three false failures in V1 [F]; it is not repeated here.
func _noise_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeRegistry.create(&"noise")
	var out := Pasture3DGraphNodeRegistry.create(&"output")
	if n == null or out == null:
		return null
	var fnl := FastNoiseLite.new()
	fnl.seed = 12345
	fnl.frequency = 0.05
	n.noise = fnl
	n.amplitude = 20.0
	g.add_node(n, Vector2.ZERO)
	g.add_node(out, Vector2(300, 0))
	g.output_node = 1
	g.connect_ports(0, 0, 1, 0)
	n.preview_on = true
	return g


## Input -> Erosion -> Output. LIVE, not the node's FROZEN default: a frozen solver serves its own cache,
## which only the GDScript evaluator can do, so the whole graph would answer `native_supported()` false and
## every criterion would pass while measuring an evaluator this phase does not touch (the V2 gate's lesson).
func _erosion_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeRegistry.create(&"input")
	var er := Pasture3DGraphNodeRegistry.create(&"erosion")
	var out := Pasture3DGraphNodeRegistry.create(&"output")
	if inp == null or er == null or out == null:
		return null
	er.evaluation = Pasture3DGraphSolverNode.Evaluation.LIVE
	g.add_node(inp, Vector2.ZERO)
	g.add_node(er, Vector2(200, 0))
	g.add_node(out, Vector2(400, 0))
	g.output_node = 2
	g.connect_ports(0, 0, 1, 0)
	g.connect_ports(1, 0, 2, 0)
	er.preview_on = true
	return g


func _panel(p_graph: Pasture3DTerrainGraph):
	var ed = GraphEditorScript.new()
	add_child(ed)
	ed.initialize(null) # `_build_ui` hangs off `initialize`; without it the panel builds no TextureRects
	ed.edit_graph(p_graph, null, null)
	return ed


## A dock bound to a panel, OPEN. `dock_open` is set explicitly rather than left to `visible`, because a
## Control outside a tree reports visible and the closed case ([A3]) would then be unmeasurable.
func _dock(p_editor, p_node: int = 0):
	var d = Inspector.new()
	add_child(d)
	d.editor = p_editor
	d.dock_open = true
	d.node_index = p_node
	# The panel -> dock link the plugin makes. Set HERE rather than left out, because §7 has the two
	# passes riding one debounce: without it `_refresh_previews` would drive only the thumbnails and
	# [A2]'s control — "the thumbnail pass in the SAME refresh asked for 128" — would be comparing two
	# unrelated dispatches.
	p_editor.inspect_dock = d
	return d


## Tap a graph OUTSIDE the inspector, so a comparison against the dock's reading is between two
## independent readings rather than between a number and itself.
func _independent_tap(p_g: Pasture3DTerrainGraph, p_node: int, p_channel: int, p_px: int,
		p_rect: Rect2, p_input: PackedFloat32Array) -> Dictionary:
	var compiled: Dictionary = p_g.compile_graph_program_multi([p_node])
	if compiled.is_empty():
		return {}
	var slot: int = int((compiled["slot_of"] as Dictionary)[p_node])
	return Pasture3DUtil.graph_eval_grid_taps(compiled["program"], p_px, p_px, p_rect, p_input,
			PackedInt32Array([slot]), PackedInt32Array([p_channel]))


# --- A / A2 ---------------------------------------------------------------------------------------------
#
# §7's first content line, and the cheapest useful thing in the whole document: hover reports
# `(x, z) world -> value`, in the field's own units, unnormalised.
#
# THE COMPARISON IS AGAINST AN INDEPENDENT TAP. Reading the dock's own `last_reading.field` and then
# indexing it here would assert that `probe_at` indexes an array, which is true of any implementation
# including one reading the wrong grid entirely.
#
# [A2] rides along because it is about the same field: the value must come from a 512 px pass of the
# inspector's own, not from the 128 px thumbnail upsampled. That is §7's central decision and the one a
# later "optimisation" would undo, since sharing one tap looks like pure savings.
func _a_the_probe_reads_the_field() -> void:
	print("\n[A] the probe reports the field's value at a cell, at the INSPECTOR's own resolution (§7)")

	var g := _noise_graph()
	var ed = _panel(g)
	var d = _dock(ed, 0)
	ed._refresh_previews() # drives the thumbnail pass AND, through the panel, the inspector's second pass

	_check(not bool(d.last_reading.get("no_data", true)),
			"control: the dock produced a reading at all, so the checks below are about its CONTENT")
	if bool(d.last_reading.get("no_data", true)):
		ed.queue_free()
		d.queue_free()
		return

	var rect: Rect2 = d.last_reading["rect"]
	var px: int = int(d.last_reading["gw"])
	var input_data: Dictionary = ed._get_preview_input_data(px)
	var input: PackedFloat32Array = input_data["grid"]
	if int(input_data["gw"]) != px or int(input_data["gh"]) != px:
		input = Pasture3DUtil.resample_grid(input, int(input_data["gw"]), int(input_data["gh"]), px, px)
	var indep: Dictionary = _independent_tap(g, 0, 0, px, rect, input)
	var ref: PackedFloat32Array = (indep.get("fields", []) as Array)[0]

	# A point a third of the way in, so the cell chosen is not an edge or a centre — both of which are
	# where an off-by-one in the world->cell mapping happens to still land on a plausible value.
	var wx: float = rect.position.x + rect.size.x * 0.37
	var wz: float = rect.position.y + rect.size.y * 0.61
	var got: float = d.probe(wx, wz)
	var want: float = Inspector.probe_at(ref, px, px, rect, wx, wz)
	_check(is_finite(got) and is_finite(want) and absf(got - want) < 1e-5,
			"[A] the probe at (%.1f, %.1f) reads %.4f, and an INDEPENDENT tap of the same graph reads "
			% [wx, wz, got] + "%.4f" % want)

	# The control: a neighbouring cell differs. Without it the criterion passes on a constant field, where
	# every probe agrees with every other probe and the mapping is never exercised.
	var step: float = rect.size.x / float(px)
	var other: float = d.probe(wx + step * 4.0, wz)
	_check(is_finite(other) and absf(other - got) > 1e-6,
			"control: a neighbouring cell reads a DIFFERENT value (%.4f vs %.4f), so the fixture is not "
			% [other, got] + "constant and the probe's cell mapping is actually being exercised")

	# Outside the domain there is no value. Zero there would put a hard floor of sea level around the field.
	_check(is_nan(d.probe(rect.position.x - 10.0, wz)),
			"[A] a point OUTSIDE the domain probes NAN rather than 0.0 — outside the rect there is no "
			+ "value, and a zero would read as sea level")

	# ---- [A2] the resolution ----
	_check(int(d.last_inspect_dispatch.get("gw", -1)) == Inspector.INSPECT_SIZE,
			"[A2] the inspector's tap requested %d px — its OWN resolution, not the thumbnail's"
			% int(d.last_inspect_dispatch.get("gw", -1)))
	_check(int(ed.last_preview_dispatch.get("px", -1)) == GraphEditorScript.PREVIEW_SIZE,
			"control: the THUMBNAIL pass in the same refresh requested %d px, so a single shared tap "
			% int(ed.last_preview_dispatch.get("px", -1)) + "could not have satisfied both — this is what "
			+ "tells a second pass from an upsample")
	_check(int(d.last_inspect_dispatch.get("gw", -1)) > int(ed.last_preview_dispatch.get("px", -1)),
			"[A2] and the inspector's grid is the LARGER of the two (%d > %d), which is the direction §7 "
			% [int(d.last_inspect_dispatch.get("gw", -1)), int(ed.last_preview_dispatch.get("px", -1))]
			+ "requires — a histogram binning 16 384 samples of a million-cell field is quantitatively "
			+ "wrong while looking quantitative")
	_check(ref.size() == px * px and _varied(ref),
			"control: the reference field is a real, VARIED %d-cell grid, so [A] compared two measurements "
			% ref.size() + "rather than two flat fields agreeing vacuously")

	ed.queue_free()
	d.queue_free()


# --- A3 -------------------------------------------------------------------------------------------------
#
# §7: the second pass is dispatched ONLY while the dock is open. A closed dock that kept tapping would
# spend up to 27% of the 120 ms debounce (measured 2026-09-06) on a picture nobody is looking at, and that
# arrives as "the editor got slower" with no commit to bisect.
#
# COUNTED at the tap call, not reasoned about from the dock's state — the same reason V1 [G] counts
# `evaluate_count` rather than arguing that no evaluation could occur.
func _a3_a_closed_dock_dispatches_nothing() -> void:
	print("\n[A3] a CLOSED dock dispatches no tap; opening it dispatches one (§7)")

	var g := _noise_graph()
	var ed = _panel(g)
	var d = _dock(ed, 0)
	d.dock_open = false

	var before: int = d.inspect_dispatch_count
	ed._refresh_previews()
	ed._refresh_previews()
	d.refresh()
	_check(d.inspect_dispatch_count == before,
			"[A3] two full preview refreshes and a direct refresh() with the dock CLOSED dispatched %d "
			% (d.inspect_dispatch_count - before) + "inspector taps (expected 0)")
	_check(bool(d.last_reading.get("no_data", true)),
			"control: and it holds no reading, so [A3] measured a dock that did nothing rather than one "
			+ "serving a cached answer it would have had to tap for")

	# THE CONTROL. Without it every check above passes on a counter that never moves.
	d.dock_open = true
	var dispatched: bool = d.refresh()
	_check(dispatched and d.inspect_dispatch_count == before + 1,
			"control: OPENING the dock dispatches exactly one tap (%d -> %d), so the zero above is a "
			% [before, d.inspect_dispatch_count] + "measurement and not a dead counter")
	_check(not bool(d.last_reading.get("no_data", true)),
			"control: and that tap produced a real reading, so the counter is not incremented by a call "
			+ "that failed immediately")

	ed.queue_free()
	d.queue_free()


# --- B --------------------------------------------------------------------------------------------------
#
# THE CRITERION §7 SAYS IS THE WHOLE REASON THE HISTOGRAM IS WORTH BUILDING.
#
# §5.2 Rule 1: the range is chosen by the TYPE, not by the data. A MASK is absolute 0..1 and never
# rescaled. So a mask spanning 0.28–0.32 must fill a narrow group of bins near the left of a 0..1 axis and
# leave the rest EMPTY — which is the true picture, and which Hesiod's histogram cannot show because it
# fits its axis to the data.
#
# The control is the same data on a HEIGHT port, where the range is AUTO: there it DOES fill the axis. That
# pairing is what makes this a measurement of the type rule rather than of the binner. A binner that always
# auto-fits passes the control and fails the criterion; a binner that always uses 0..1 passes the criterion
# and fails the control.
func _b_the_histogram_bins_over_the_declared_range() -> void:
	print("\n[B] the histogram bins over the DECLARED range, not the data's (§5.2 Rule 1)")

	# Built here rather than tapped, because the claim is about the BINNING rule and a field with a known,
	# stated span is what makes "near the left, and the rest empty" checkable arithmetic.
	var field := PackedFloat32Array()
	field.resize(4096)
	for i in range(4096):
		field[i] = 0.28 + 0.04 * (float(i % 64) / 63.0)

	var mask_range: Dictionary = GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_MASK_ALPHA, field, false, 0.0, 0.0)
	_check(is_equal_approx(float(mask_range["min"]), 0.0) and is_equal_approx(float(mask_range["max"]), 1.0),
			"control: a MASK's declared range is the absolute 0..1 (%.2f..%.2f) regardless of the data, "
			% [float(mask_range["min"]), float(mask_range["max"])] + "which is the rule [B] rests on")

	var h: Dictionary = Inspector.histogram_bins(field, float(mask_range["min"]), float(mask_range["max"]))
	var bins: PackedInt32Array = h["bins"]
	var occupied := 0
	var first := -1
	var last := -1
	for i in range(bins.size()):
		if bins[i] > 0:
			occupied += 1
			if first < 0:
				first = i
			last = i
	_check(int(h["counted"]) == 4096,
			"control: every one of the %d samples was binned (out_low %d, out_high %d), so the emptiness "
			% [int(h["counted"]), int(h["out_low"]), int(h["out_high"])] + "below is bins being unfilled "
			+ "rather than samples being dropped")
	# 0.28..0.32 of a 0..1 axis is 4% of it — at 64 bins that is bins 17..20 inclusive, so at most 4 or 5.
	_check(occupied <= 5 and occupied > 0,
			"[B] a 0.28–0.32 mask occupies %d of %d bins on the absolute axis — a narrow group, which is "
			% [occupied, bins.size()] + "the true picture of a mask that barely varies")
	_check(first >= 15 and last <= 22,
			"[B] and that group sits where the arithmetic puts it, near the LEFT (bins %d..%d of %d), not "
			% [first, last, bins.size()] + "spread across an axis fitted to the data")

	# THE CONTROL: the same data on a HEIGHT port, where the range is AUTO.
	var auto_range: Dictionary = GraphEditorScript.resolve_preview_range(
			Pasture3DUtil.PREVIEW_HILLSHADE, field, false, 0.0, 0.0)
	var h2: Dictionary = Inspector.histogram_bins(field, float(auto_range["min"]), float(auto_range["max"]))
	var bins2: PackedInt32Array = h2["bins"]
	var occupied2 := 0
	for b in bins2:
		if b > 0:
			occupied2 += 1
	_check(occupied2 > occupied * 4,
			"control: the SAME data on a HEIGHT port with an AUTO range fills %d of %d bins, so [B] "
			% [occupied2, bins2.size()] + "measured the type RULE and not a binner that is simply narrow")

	# Out-of-range samples are counted apart, never folded into the end bins — §5.2 Rule 4's marking would
	# otherwise contradict a tidy in-range histogram sitting directly beneath the marked picture.
	var over := PackedFloat32Array([-0.5, 0.5, 1.5])
	var h3: Dictionary = Inspector.histogram_bins(over, 0.0, 1.0)
	_check(int(h3["out_low"]) == 1 and int(h3["out_high"]) == 1 and int(h3["counted"]) == 1,
			"[B] out-of-range samples are counted SEPARATELY (%d low, %d high, %d binned) rather than "
			% [int(h3["out_low"]), int(h3["out_high"]), int(h3["counted"])] + "piled into the end bins, "
			+ "where they would contradict the marked overflow in the picture above")
	# And a NaN is an absence, not a population.
	var withnan := PackedFloat32Array([NAN, 0.5])
	var h4: Dictionary = Inspector.histogram_bins(withnan, 0.0, 1.0)
	_check(int(h4["counted"]) == 1 and int(h4["out_low"]) == 0 and int(h4["out_high"]) == 0,
			"[B] a NaN is counted in neither the bins nor the overflows, so a hole in the data cannot "
			+ "look like a population")

	# The statistics obey the same rule about absence.
	var st: Dictionary = Inspector.field_stats(PackedFloat32Array([NAN, NAN]))
	_check(int(st["count"]) == 0 and is_nan(float(st["mean"])),
			"[B] an all-NaN field reports count 0 and a NaN mean, never 0.0 — which would read as a "
			+ "measurement of a flat field")


# --- C --------------------------------------------------------------------------------------------------
#
# §7's PATH contents: a taper reads as a slope, a Path Width driven by a flow field reads as a step at each
# confluence. Both are invisible in a thumbnail, where a 2 m and a 6 m road are the same few pixels.
#
# Checked against `half_width_at(s)` sampled independently HERE, so the criterion is that the profile is
# the path's own width function and not merely a smooth curve of the right length.
func _c_the_width_profile_follows_the_path() -> void:
	print("\n[C] the width profile is `half_width_at(s)` along arc length (§7)")

	var tapered := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var hw := PackedFloat32Array()
	for i in range(9):
		pts.append(Vector2(float(i) * 10.0, 0.0))
		hw.append(1.0 + float(i) * 0.5) # 1.0 -> 5.0
	tapered.points = pts
	tapered.half_widths = hw

	var prof: PackedFloat32Array = Inspector.width_profile(tapered, 33)
	_check(prof.size() == 33,
			"control: the profile has the %d samples asked for, so the comparison below is over a real "
			% prof.size() + "series")
	var worst := 0.0
	var total: float = tapered.length()
	for i in range(prof.size()):
		var s: float = total * float(i) / float(prof.size() - 1)
		worst = maxf(worst, absf(prof[i] - tapered.half_width_at(s)))
	_check(worst < 1e-4,
			"[C] every sample equals `half_width_at(s)` computed independently (worst %.6f m)" % worst)
	_check(absf(prof[0] - 1.0) < 1e-4 and absf(prof[prof.size() - 1] - 5.0) < 1e-4,
			"[C] and it spans the declared taper end to end (%.2f m -> %.2f m), so the profile is the "
			% [prof[0], prof[prof.size() - 1]] + "author's widths and not a normalised shape")

	# THE CONTROL: a constant-width path is flat. Without it, a profile that returned `s` itself — or any
	# monotone curve — would pass the taper check by coincidence of direction.
	var flat := Pasture3DGraphPath.new()
	flat.points = pts
	var hw2 := PackedFloat32Array()
	hw2.resize(9)
	hw2.fill(3.0)
	flat.half_widths = hw2
	var prof2: PackedFloat32Array = Inspector.width_profile(flat, 33)
	var span2 := 0.0
	for v in prof2:
		span2 = maxf(span2, absf(v - 3.0))
	_check(span2 < 1e-4,
			"control: a CONSTANT-width path profiles flat (deviation %.6f m), so [C] measured the widths "
			% span2 + "and not a plot that always slopes")
	var span1 := 0.0
	for v in prof:
		span1 = maxf(span1, absf(v - prof[0]))
	_check(span1 > 3.0,
			"control: and the tapered one is NOT flat (%.2f m of variation), so the two fixtures are "
			% span1 + "distinguishable and the flatness above is a finding")


# --- D --------------------------------------------------------------------------------------------------
#
# §7, stated there in as many words: a NAN — a heightless path — draws as a GAP, never as 0. A heightless
# path plotted at zero is a path at sea level, and it looks like a bug in the drape rather than an absence
# of data. This is the §6.3 trap in profile form: the confident wrong answer, one panel over.
func _d_a_heightless_profile_is_a_gap() -> void:
	print("\n[D] a heightless path profiles as absent data, not as zeros (§7)")

	var pts := PackedVector2Array()
	for i in range(9):
		pts.append(Vector2(float(i) * 10.0, 0.0))

	var bare := Pasture3DGraphPath.new()
	bare.points = pts
	bare.heights = PackedFloat32Array()
	var prof: PackedFloat32Array = Inspector.height_profile(bare, 17)
	var nans := 0
	var zeros := 0
	for v in prof:
		if is_nan(v):
			nans += 1
		elif absf(v) < 1e-9:
			zeros += 1
	_check(prof.size() == 17 and nans == 17,
			"[D] every sample of a heightless path is NAN (%d of %d), so the plot lifts the pen" % [nans, prof.size()])
	_check(zeros == 0,
			"[D] and NOT ONE of them is 0.0 — a heightless path drawn at zero is a path at sea level, "
			+ "which reads as a broken drape rather than as absent data")

	# THE CONTROL: a path that carries heights has no gap at all. Without it, a `height_profile` that
	# returned NAN unconditionally would pass everything above.
	var carried := Pasture3DGraphPath.new()
	carried.points = pts
	var hs := PackedFloat32Array()
	for i in range(9):
		hs.append(10.0 + float(i))
	carried.heights = hs
	var prof2: PackedFloat32Array = Inspector.height_profile(carried, 17)
	var nans2 := 0
	for v in prof2:
		if is_nan(v):
			nans2 += 1
	_check(nans2 == 0 and prof2.size() == 17,
			"control: a path CARRYING heights profiles with no gaps at all (%d NANs), so [D] measured the "
			% nans2 + "absence rule and not a profile that is NAN unconditionally")
	_check(absf(prof2[0] - 10.0) < 1e-4 and absf(prof2[prof2.size() - 1] - 18.0) < 1e-4,
			"control: and those heights are the path's own (%.2f -> %.2f), so the non-NAN case is a real "
			% [prof2[0], prof2[prof2.size() - 1]] + "reading")


# --- E --------------------------------------------------------------------------------------------------
#
# §7's pin: the dock follows the graph editor's selection by default, and a pin freezes it on one node so
# the author can change selection without losing the reading. (Hesiod has exactly this, `is_node_pinned`.)
func _e_pinning_holds_the_node() -> void:
	print("\n[E] a pinned dock holds its node across a selection change (§7)")

	var g := _noise_graph()
	var ed = _panel(g)
	var d = _dock(ed, 0)

	# The control FIRST, so "pinning held it" cannot pass on a dock that never follows anything.
	d.set_target(1)
	_check(d.node_index == 1,
			"control: an UNPINNED dock follows the selection (now node %d), so the pin below is holding "
			% d.node_index + "against something that would otherwise move")
	d.pinned = true
	d.set_target(0)
	_check(d.node_index == 1,
			"[E] with the pin on, selecting another node leaves the dock on node %d" % d.node_index)
	d.pinned = false
	d.set_target(0)
	_check(d.node_index == 0,
			"control: releasing the pin lets it follow again (now node %d), so [E] measured the pin and "
			% d.node_index + "not a dock that had simply stopped updating")

	ed.queue_free()
	d.queue_free()


# --- F --------------------------------------------------------------------------------------------------
#
# THE CHANNEL SELECTOR — assigned to this phase by §7 on 2026-09-07, and the reason V2's mechanism is
# finally reachable by a person. Until now `flow`, `ero`, `dep` and `wet` were addressable by the evaluator
# and by nothing else.
#
# One selection drives the probe, the histogram AND the statistics together, or the numbers beneath the
# picture stop describing the picture. So this criterion asserts all three moved, against a tap made
# outside the dock.
#
# The second half is the one carried over from V2: an UNRESERVED channel must report NO_DATA with no
# statistics. An unreserved channel and a genuinely calm one are the same bytes, and reporting
# `min 0, max 0, mean 0` about a channel the compiler never allocated is a confident wrong answer with an
# axis under it.
func _f_the_channel_selector_moves_everything() -> void:
	print("\n[F] the channel selector moves the probe, the histogram and the statistics together (§7)")

	var g := _erosion_graph()
	var ed = _panel(g)
	var d = _dock(ed, 1) # the Erosion node

	var opts: Array = Inspector.channel_options(g.nodes[1])
	_check(opts.size() == 5,
			"control: the selector offers this node's %d declared channels, read from its own "
			% opts.size() + "`output_names()` / `output_port_types()` rather than a table keyed by op")
	_check(String(opts[1]["name"]) == "flow" and bool(opts[1]["reserved"]),
			"control: channel 1 is `%s` and the kernel reserves it, so [F] is about a channel that "
			% String(opts[1]["name"]) + "genuinely exists")

	d.channel = 0
	d.refresh()
	if bool(d.last_reading.get("no_data", true)):
		_check(false, "[F] the dock produced no reading on channel 0; nothing below was measured")
		ed.queue_free()
		d.queue_free()
		return
	var rect: Rect2 = d.last_reading["rect"]
	var px: int = int(d.last_reading["gw"])
	var stats0: Dictionary = d.last_reading["stats"]
	var hist0: Dictionary = d.last_reading["histogram"]
	var wx: float = rect.position.x + rect.size.x * 0.42
	var wz: float = rect.position.y + rect.size.y * 0.55
	var probe0: float = d.probe(wx, wz)

	d.channel = 1
	d.refresh()
	_check(not bool(d.last_reading.get("no_data", true)),
			"control: channel 1 produced a reading, so the comparison below is between two real fields")
	var stats1: Dictionary = d.last_reading["stats"]
	var probe1: float = d.probe(wx, wz)
	var hist1: Dictionary = d.last_reading["histogram"]

	# Against an INDEPENDENT tap of the same channel, not against the dock's own field re-indexed.
	var input_data: Dictionary = ed._get_preview_input_data(px)
	var input: PackedFloat32Array = input_data["grid"]
	if int(input_data["gw"]) != px or int(input_data["gh"]) != px:
		input = Pasture3DUtil.resample_grid(input, int(input_data["gw"]), int(input_data["gh"]), px, px)
	var indep: Dictionary = _independent_tap(g, 1, 1, px, rect, input)
	var ref: PackedFloat32Array = (indep.get("fields", []) as Array)[0]
	var want: float = Inspector.probe_at(ref, px, px, rect, wx, wz)
	_check(is_finite(probe1) and is_finite(want) and absf(probe1 - want) < 1e-4,
			"[F] with `flow` selected the probe reads %.4f, matching an INDEPENDENT tap of channel 1 "
			% probe1 + "(%.4f)" % want)
	var ref_stats: Dictionary = Inspector.field_stats(ref)
	_check(absf(float(stats1["max"]) - float(ref_stats["max"])) < 1e-3,
			"[F] and the STATISTICS moved with it (max %.3f, independent tap %.3f), so the numbers "
			% [float(stats1["max"]), float(ref_stats["max"])] + "describe the field the picture shows")
	_check(int(hist1["counted"]) > 0 and hist1["bins"] != hist0["bins"],
			"[F] and the HISTOGRAM moved too (%d samples binned), so one selection drives all three"
			% int(hist1["counted"]))

	# THE CONTROL that stops [F] passing by reading one buffer twice.
	_check(absf(probe1 - probe0) > 1e-6 or absf(float(stats1["max"]) - float(stats0["max"])) > 1e-6,
			"control: channel 0 and channel 1 genuinely DIFFER (probe %.4f vs %.4f, max %.3f vs %.3f), so "
			% [probe0, probe1, float(stats0["max"]), float(stats1["max"])]
			+ "the criterion cannot pass by reading one buffer twice")

	# ---- the unreserved channel: NO_DATA, and no statistics ----
	# Channel 5 is past this node's `native_out_count()`, so the compiler never allocated it. V2 [D] proved
	# the tap reports it `unserved`; this proves the DOCK refuses to put numbers under it.
	d.channel = 5
	d.refresh()
	_check(bool(d.last_reading.get("no_data", true)),
			"[F] a channel past the kernel's out_count reports NO_DATA rather than a field of zeros")
	_check(not d.last_reading.has("stats") and not d.last_reading.has("histogram"),
			"[F] and it publishes NO statistics and NO histogram — `min 0, max 0, mean 0` about a channel "
			+ "the compiler never allocated is a confident wrong answer with an axis under it")
	_check(is_nan(d.probe(wx, wz)),
			"[F] and the probe reads NAN there, so an unreserved channel and a genuinely calm one stay "
			+ "distinguishable — which is what V2's `reserved` key was added for")
	_check(d.inspect_dispatch_count > 0,
			"control: the dock did dispatch (%d taps), so the NO_DATA above is a refusal to report and "
			% d.inspect_dispatch_count + "not a dock that never ran")

	ed.queue_free()
	d.queue_free()


func _varied(p_field: PackedFloat32Array) -> bool:
	if p_field.is_empty():
		return false
	var lo := INF
	var hi := -INF
	for v in p_field:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return hi - lo > 1e-6
