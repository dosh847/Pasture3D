# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphInspector — the quantitative surface
# (PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §7, phase V4).
#
# §2.3's second conclusion: every comparable tool has an inspector, we have none, and it is the half of
# visualization a thumbnail structurally cannot do. A 128 px picture can say "there is a channel network
# here". It cannot say "the flow at this confluence is 4 200 m²", and that number is what an author tuning
# a solver is actually after.
#
# ---- THE THREE THINGS THIS FILE IS CAREFUL ABOUT ----
#
# 1. IT RE-TAPS AT ITS OWN RESOLUTION (§7). It does not upsample the thumbnail's 128 px field. A probe
#    reading an interpolated value, and a histogram binning 16 384 samples of a million-cell field, are
#    both *quantitatively wrong while looking quantitative* — the §4.2 category of defect, and worse here
#    because an axis lends it authority. Measured 2026-09-06: a 512 px second pass costs 8–33 ms, at worst
#    27% of the 120 ms debounce, off the main thread.
#
# 2. IT BINS OVER THE DECLARED RANGE, NEVER THE DATA'S (§5.2 Rule 1). A mask spanning 0.28–0.32 must fill
#    four bins near the left of a 0..1 axis and leave the rest empty, because that IS the true picture. A
#    histogram that auto-fits its own axis says every field is equally spread and is the exact lie §4.2
#    opens with, drawn at higher resolution.
#
# 3. AN UNSERVED CHANNEL REPORTS `NO_DATA`, NOT ZEROS. `unserved` and `reserved` come back from
#    `graph_eval_grid_taps` for this reason: an unreserved channel and a genuinely calm one are the same
#    bytes. Reporting `min 0, max 0, mean 0` about a channel the compiler never allocated is a confident
#    wrong answer with statistics attached, which is worse than silence.
#
# ---- WHY THE MEASUREMENTS ARE STATIC AND PURE ----
#
# Everything that computes a number is a `static func` over plain arrays, so a gate can assert on the
# number without instantiating a dock, and so the probe's value can be checked against a field read
# OUTSIDE the preview path (`check-derived-values-outside-the-chain`). The instance half below only
# decides WHEN to tap and what to put on screen.
@tool
class_name Pasture3DGraphInspector
extends VBoxContainer

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")

## The inspector's own grid resolution — the "re-taps at its own" of §7, and the number the 2026-09-06
## measurement licensed. Not derived from `PREVIEW_SIZE`: they are different passes for different
## questions, and tying them together is how the upsample gets reintroduced by accident.
const INSPECT_SIZE: int = 512

## Bins in the histogram. Enough that a 0.28–0.32 mask occupies a visibly narrow group on a 0..1 axis
## rather than a single fat bar that could be read as "spread across the low end".
const HISTOGRAM_BINS: int = 64

## Samples along a path profile. Arc-length parametrised, so a resampled path and its source are plotted
## on the same axis and the difference between them is the resample.
const PROFILE_SAMPLES: int = 128


# =========================================================================================================
# THE MEASUREMENTS. Static, pure, and assertable without a dock.
# =========================================================================================================


## Bin `p_field` over the range `p_lo..p_hi` — the DECLARED range, per §5.2 Rule 1.
##
## Returns `{"bins": PackedInt32Array, "out_low": int, "out_high": int, "counted": int, "lo", "hi"}`.
##
## Out-of-range samples are counted SEPARATELY rather than folded into the end bins. Under a lock (§5.2
## Rule 4) out-of-range values are marked rather than clamped, and a histogram that quietly piled them
## into bin 0 would contradict the picture sitting directly above it — the author would see a marked
## overflow in the image and a tidy in-range histogram beneath it, and would have no way to tell which
## was lying.
##
## Non-finite samples are skipped and counted in neither, because a NaN is an absence and adding it to a
## tally would make a hole in the data look like a population.
static func histogram_bins(p_field: PackedFloat32Array, p_lo: float, p_hi: float,
		p_bins: int = HISTOGRAM_BINS) -> Dictionary:
	var n := maxi(p_bins, 1)
	var bins := PackedInt32Array()
	bins.resize(n)
	bins.fill(0)
	var out := {"bins": bins, "out_low": 0, "out_high": 0, "counted": 0, "lo": p_lo, "hi": p_hi}
	if not (p_hi > p_lo):
		# A degenerate range cannot bin anything. Reported as zero counted rather than as one full bin,
		# so a caller can tell "nothing to show" from "everything at one value".
		return out
	var span := p_hi - p_lo
	var low := 0
	var high := 0
	var counted := 0
	for v in p_field:
		if not is_finite(v):
			continue
		if v < p_lo:
			low += 1
			continue
		if v > p_hi:
			high += 1
			continue
		var b := int((v - p_lo) / span * float(n))
		bins[clampi(b, 0, n - 1)] += 1 # the top edge lands in the last bin rather than one past it
		counted += 1
	out["bins"] = bins
	out["out_low"] = low
	out["out_high"] = high
	out["counted"] = counted
	return out


## `{"min", "max", "mean", "count"}` over the finite samples of `p_field`.
##
## `count` is the number of FINITE samples, not the array size, and it is returned so a caller can say
## "12 of 262 144 cells are NaN" instead of quietly reporting statistics over a field that is mostly
## absent. An all-NaN or empty field reports `count == 0` and NaN for the three numbers — never 0.0,
## which would read as a measurement of a flat field.
static func field_stats(p_field: PackedFloat32Array) -> Dictionary:
	var lo := INF
	var hi := -INF
	var sum := 0.0
	var n := 0
	for v in p_field:
		if not is_finite(v):
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
		sum += v
		n += 1
	if n == 0:
		return {"min": NAN, "max": NAN, "mean": NAN, "count": 0}
	return {"min": lo, "max": hi, "mean": sum / float(n), "count": n}


## The field's value at the cell containing world point `(p_wx, p_wz)`, in the field's OWN units.
##
## NEAREST CELL, not bilinear. The probe answers "what does this cell hold", and an interpolated reading
## is a number that exists nowhere in the data — which is the same objection §7 raises against upsampling,
## one scale down. NAN when the point is outside `p_rect` or the grid is malformed: outside the domain
## there is no value, and returning 0.0 there would put a hard floor of sea level around every field.
static func probe_at(p_field: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2,
		p_wx: float, p_wz: float) -> float:
	if p_gw <= 0 or p_gh <= 0 or p_field.size() < p_gw * p_gh:
		return NAN
	if p_rect.size.x <= 0.0 or p_rect.size.y <= 0.0:
		return NAN
	var u := (p_wx - p_rect.position.x) / p_rect.size.x
	var v := (p_wz - p_rect.position.y) / p_rect.size.y
	if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
		return NAN
	var cx := clampi(int(u * float(p_gw)), 0, p_gw - 1)
	var cy := clampi(int(v * float(p_gh)), 0, p_gh - 1)
	return p_field[cy * p_gw + cx]


## `half_width_at(s)` sampled at `p_samples` points along the path's arc length.
##
## A taper reads as a slope; a Path Width driven by a flow field reads as a step at each confluence. Both
## are invisible in a thumbnail, where a 2 m and a 6 m road are the same handful of pixels.
static func width_profile(p_path: Pasture3DGraphPath, p_samples: int = PROFILE_SAMPLES) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if p_path == null or p_path.points.size() < 2:
		return out
	var n := maxi(p_samples, 2)
	var total := p_path.length()
	out.resize(n)
	for i in range(n):
		out[i] = p_path.half_width_at(total * float(i) / float(n - 1))
	return out


## `height_at(s)` sampled the same way — with NANs left in.
##
## THE NAN IS THE POINT (§7). A heightless path plotted at zero is a path at sea level, and it looks like
## a bug in the drape rather than an absence of data. `height_at` already returns NAN for a path carrying
## no heights; this function's whole job is to not helpfully clean that up. The plot draws a gap.
static func height_profile(p_path: Pasture3DGraphPath, p_samples: int = PROFILE_SAMPLES) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if p_path == null or p_path.points.size() < 2:
		return out
	var n := maxi(p_samples, 2)
	var total := p_path.length()
	out.resize(n)
	for i in range(n):
		out[i] = p_path.height_at(total * float(i) / float(n - 1))
	return out


## The world XZ of each profile sample, so the terrain profile can be read beneath the path's own heights
## on the same axis. The difference between those two curves IS the carve depth, plotted.
static func profile_points(p_path: Pasture3DGraphPath, p_samples: int = PROFILE_SAMPLES) -> PackedVector2Array:
	var out := PackedVector2Array()
	if p_path == null or p_path.points.size() < 2:
		return out
	var n := maxi(p_samples, 2)
	var total := p_path.length()
	out.resize(n)
	for i in range(n):
		var s := total * float(i) / float(n - 1)
		out[i] = _point_at(p_path, s)
	return out


## Position at arc length `p_s`, by the same vertex-lerp rule the path's own accessors use, so a profile
## sample and a `half_width_at` at the same `s` describe the same place.
static func _point_at(p_path: Pasture3DGraphPath, p_s: float) -> Vector2:
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var pts: PackedVector2Array = p_path.points
	xs.resize(pts.size())
	ys.resize(pts.size())
	for i in range(pts.size()):
		xs[i] = pts[i].x
		ys[i] = pts[i].y
	return Vector2(p_path.lerp_vertex(xs, p_s), p_path.lerp_vertex(ys, p_s))


## The channels an author may ask for on `p_node`, as `[{"chan", "name", "type", "reserved"}]`.
##
## Built from the node's OWN `output_names()` / `output_port_types()` declarations, like every other
## consumer of them (§7's read-first) — never from a table keyed by op string, which is the shape that
## produced four shipped bugs (`native_lower`'s header has the list).
##
## `reserved` is `chan < native_out_count()`: the kernel's number, not `output_count()`. A node may offer
## five ports in the editor and implement one in C++, and the two disagreeing is precisely the case where
## a tap comes back as plausible zeros. The selector still LISTS the channel — hiding it would leave the
## author wondering where `wetness` went — and the reading reports `NO_DATA` when it is picked.
static func channel_options(p_node: Pasture3DGraphNode) -> Array:
	var out: Array = []
	if p_node == null:
		return out
	var names: PackedStringArray = p_node.output_names()
	var types: PackedInt32Array = p_node.output_port_types()
	var served: int = p_node.native_out_count()
	for i in range(p_node.output_count()):
		out.append({
			"chan": i,
			"name": String(names[i]) if i < names.size() else "out %d" % i,
			"type": int(types[i]) if i < types.size() else int(Pasture3DGraphNode.PortType.HEIGHT),
			"reserved": i < served,
		})
	return out


# =========================================================================================================
# THE DOCK. Decides WHEN to tap and what to show; computes nothing itself.
# =========================================================================================================

## The panel this inspector reads its graph and its preview domain from. Assigned by the plugin.
var editor = null

## The node being inspected, and the channel of it. `channel` is the selection §7 assigns to this dock
## (decided 2026-09-07): one selection drives the probe, the histogram and the statistics together, or the
## numbers stop describing the picture.
var node_index: int = -1
var channel: int = 0

## Pinned, per §7 — the dock follows the graph editor's selection by default, and a pin freezes it on one
## node so the author can change selection without losing the reading. (Hesiod has exactly this,
## `is_node_pinned` in `viewers/viewer.cpp`.)
var pinned: bool = false

## Whether the dock is on screen. §7: the second pass is dispatched ONLY while the dock is open. A closed
## dock that kept taping would spend a third of the debounce on a picture nobody is looking at, which is
## how "the editor got slower" arrives without a bisectable commit.
##
## Set by the plugin from the dock's visibility rather than read from `visible` here, because a Control
## that is not in a tree reports `visible == true` and a headless gate would then be unable to measure the
## closed case at all.
var dock_open: bool = false

## What the last tap asked for and got. `gw` is the assertable half of §7's "at its own resolution": the
## thumbnail pass in the same refresh requested 128, so a single shared tap cannot satisfy it.
var last_inspect_dispatch: Dictionary = {}

## Bumped once per DISPATCHED tap, at the tap call. A refresh that returns early increments nothing, which
## is what lets a gate tell "the dock is closed" from "the dock tapped and found nothing".
var inspect_dispatch_count: int = 0

## The last reading, all of it, so the UI and a gate read the same numbers.
##   field / gw / rect  : what came back
##   range              : §5.2's declared range, via the editor's own resolver
##   stats / histogram  : the two derived views
##   no_data            : the channel was not served (§8's `unserved`) — NOT "the field was zero"
##   reserved           : whether the compiler actually allocated the channel (V2's third return key)
var last_reading: Dictionary = {}

var _value_label: Label
var _stats_label: Label
var _channel_picker: OptionButton
var _pin_button: Button
var _histogram: Control
var _profile: Control
var _title: Label


func _init() -> void:
	name = "Pasture3D Inspect"
	_build_ui()


func _build_ui() -> void:
	_title = Label.new()
	_title.text = "(no node)"
	add_child(_title)

	var row := HBoxContainer.new()
	add_child(row)
	_pin_button = Button.new()
	_pin_button.text = "Pin"
	_pin_button.toggle_mode = true
	_pin_button.tooltip_text = ("Freeze the inspector on this node so the reading survives a selection "
			+ "change (§7).")
	_pin_button.toggled.connect(_on_pin_toggled)
	row.add_child(_pin_button)
	_channel_picker = OptionButton.new()
	_channel_picker.tooltip_text = ("Which channel of this node to read. Drives the probe, the histogram "
			+ "and the statistics together.")
	_channel_picker.item_selected.connect(_on_channel_picked)
	row.add_child(_channel_picker)

	_value_label = Label.new()
	_value_label.text = "probe: —"
	add_child(_value_label)
	_stats_label = Label.new()
	_stats_label.text = "min — max — mean —"
	add_child(_stats_label)

	_histogram = Control.new()
	_histogram.custom_minimum_size = Vector2(0, 96)
	_histogram.draw.connect(_draw_histogram)
	add_child(_histogram)

	_profile = Control.new()
	_profile.custom_minimum_size = Vector2(0, 96)
	_profile.draw.connect(_draw_profile)
	add_child(_profile)


## Follow the editor's selection — unless pinned, which is the whole point of the pin.
func set_target(p_index: int) -> void:
	if pinned:
		return
	if node_index == p_index:
		return
	node_index = p_index
	channel = 0 # a new node's channels are its own; carrying an index across would read `wetness` as `flow`
	_sync_channel_picker()
	refresh()


func _on_pin_toggled(p_on: bool) -> void:
	pinned = p_on


func _on_channel_picked(p_i: int) -> void:
	if p_i < 0 or p_i >= _channel_picker.item_count:
		return
	channel = int(_channel_picker.get_item_metadata(p_i))
	refresh()


func _sync_channel_picker() -> void:
	if _channel_picker == null:
		return
	_channel_picker.clear()
	var node := _node()
	if node == null:
		return
	for opt in channel_options(node):
		# The unreserved ones are listed too, marked. Hiding them would leave the author hunting for a
		# channel the node's own face advertises; marking them says the kernel does not produce it.
		var label: String = opt["name"] if bool(opt["reserved"]) else "%s (no data)" % opt["name"]
		_channel_picker.add_item(label)
		_channel_picker.set_item_metadata(_channel_picker.item_count - 1, int(opt["chan"]))
	_channel_picker.visible = _channel_picker.item_count > 1


func _node() -> Pasture3DGraphNode:
	if editor == null or editor.graph == null:
		return null
	if node_index < 0 or node_index >= editor.graph.nodes.size():
		return null
	return editor.graph.nodes[node_index]


## The second pass (§7). Synchronous and single-tap: this is one slot at 512 px, where the thumbnail pass
## is every previewed slot and needed a thread.
##
## Returns true when a tap was actually dispatched.
func refresh() -> bool:
	if not dock_open:
		return false # §7: not while closed. Counted by its absence — see `inspect_dispatch_count`.
	var node := _node()
	if node == null or editor == null or editor.graph == null:
		return false
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		return false
	var graph: Pasture3DTerrainGraph = editor.graph

	# A PATH output has no grid to tap — its slot is zeros by construction (standing constraint 3). The
	# profiles below are read from the resolved path instead, and NO tap is requested, for the same reason
	# §6.1 diverts the thumbnail: tapping would spend the evaluator's time fetching the zeros.
	if node.output_port_type() == Pasture3DGraphNode.PortType.PATH:
		var path: Pasture3DGraphPath = graph.resolved_path_of(node_index)
		last_reading = {
			"path": path,
			"widths": width_profile(path),
			"heights": height_profile(path),
			"no_data": path == null,
		}
		_refresh_labels()
		return false

	# A TERMINAL node — a sink — has no output, so there is nothing to tap and never will be, however it
	# is wired. Named here rather than falling through, because the generic branch below reports "the
	# graph does not lower", which is the wording for the graph-wide native bail (§10) and sends an author
	# hunting for a missing kernel. Selecting a sink is a completely ordinary thing to do; it is not a
	# fault, and it must not read as one.
	if not node.has_output():
		last_reading = {
			"no_data": true,
			"terminal": true,
			"reason": _terminal_reason(graph, node),
		}
		_refresh_labels()
		return false

	var compiled: Dictionary = graph.compile_graph_program_multi([node_index])
	if compiled.is_empty():
		last_reading = {"no_data": true, "reason": "the graph does not lower"}
		_refresh_labels()
		return false
	var slot_of: Dictionary = compiled["slot_of"]
	if not slot_of.has(node_index):
		last_reading = {"no_data": true, "reason": "the node has no slot in the compiled program"}
		_refresh_labels()
		return false
	var slot: int = int(slot_of[node_index])

	var input_data: Dictionary = editor._get_preview_input_data(INSPECT_SIZE)
	var input: PackedFloat32Array = input_data["grid"]
	var in_gw: int = int(input_data["gw"])
	var in_gh: int = int(input_data["gh"])
	var rect: Rect2 = input_data["rect"]
	if in_gw != INSPECT_SIZE or in_gh != INSPECT_SIZE:
		input = Pasture3DUtil.resample_grid(input, in_gw, in_gh, INSPECT_SIZE, INSPECT_SIZE)

	# THE DISPATCH. Counted here, at the call, so a gate counts what the evaluator was asked for rather
	# than inferring it from a picture that could have come from anywhere.
	inspect_dispatch_count += 1
	last_inspect_dispatch = {"gw": INSPECT_SIZE, "gh": INSPECT_SIZE, "rect": rect,
			"slot": slot, "channel": channel, "node": node_index}
	var result: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"],
			INSPECT_SIZE, INSPECT_SIZE, rect, input,
			PackedInt32Array([slot]), PackedInt32Array([channel]))

	var unserved: PackedInt32Array = result.get("unserved", PackedInt32Array())
	var reserved: PackedInt32Array = result.get("reserved", PackedInt32Array())
	if unserved.has(0):
		# §8's distinction, and the reason V2 added `reserved`: an unreserved channel and a genuinely calm
		# one are the same bytes. Statistics are withheld rather than computed over zeros.
		last_reading = {"no_data": true, "reserved": false, "gw": INSPECT_SIZE, "rect": rect,
				"reason": "channel %d is not served by this graph" % channel}
		_refresh_labels()
		return true
	var fields: Array = result.get("fields", [])
	if fields.is_empty() or not (fields[0] is PackedFloat32Array):
		last_reading = {"no_data": true, "reason": "the tap returned no field"}
		_refresh_labels()
		return true
	var field: PackedFloat32Array = fields[0]

	# The range comes from the editor's OWN resolver, not a second implementation of §5.2. Two copies of
	# the range rule would drift, and the histogram's axis disagreeing with the thumbnail's ramp is the
	# defect §5 exists to remove, not a cosmetic mismatch.
	var repr_id: int = node.preview_repr
	if repr_id < 0:
		var types: PackedInt32Array = node.output_port_types()
		var chan_type: int = int(types[channel]) if channel < types.size() else node.output_port_type()
		repr_id = GraphEditorScript.preview_repr_for_type(chan_type)
	var rng: Dictionary = GraphEditorScript.resolve_preview_range(repr_id, field,
			node.preview_range_locked, node.preview_range_min, node.preview_range_max)

	last_reading = {
		"field": field, "gw": INSPECT_SIZE, "gh": INSPECT_SIZE, "rect": rect,
		"range": rng, "repr": repr_id,
		"stats": field_stats(field),
		"histogram": histogram_bins(field, float(rng["min"]), float(rng["max"])),
		"no_data": false,
		"reserved": reserved.size() > 0 or channel == 0,
	}
	_refresh_labels()
	return true


## Read the field at a world point — the probe (§7).
##
## Reads the LAST reading rather than re-tapping: hovering must not dispatch, or a mouse moved across the
## dock would queue one 512 px pass per frame.
func probe(p_wx: float, p_wz: float) -> float:
	if last_reading.is_empty() or bool(last_reading.get("no_data", true)):
		return NAN
	return probe_at(last_reading["field"], int(last_reading["gw"]), int(last_reading["gh"]),
			last_reading["rect"], p_wx, p_wz)


## What to say about a sink, and where to look instead.
##
## The dock reads a node's OUTPUT, so it can say nothing about a node that has none — but the field the
## author actually wants to see is on the node wired INTO the sink, and naming it is the difference
## between a dead end and a redirect. Falls back to the plain statement when nothing is wired yet.
func _terminal_reason(p_graph, p_node) -> String:
	var here := "this is a sink — it writes, and has no output to inspect"
	var types: PackedInt32Array = p_node.input_port_types()
	var names: PackedStringArray = p_node.input_names()
	for port in range(p_node.input_count()):
		if port >= types.size() or not Pasture3DGraphNode.is_field_type(int(types[port])):
			continue
		for c in p_graph.connections:
			if c.size() >= 4 and int(c[2]) == node_index and int(c[3]) == port:
				var src = p_graph.nodes[int(c[0])]
				if src == null:
					continue
				return "%s. Select '%s' to read what reaches its `%s`." 						% [here, src.display_name(), String(names[port]) if port < names.size() else "input"]
	return "%s. Wire a field into it, then select that node to read it." % here


func _refresh_labels() -> void:
	if _title == null:
		return
	var node := _node()
	_title.text = "(no node)" if node == null else node.display_name()
	if bool(last_reading.get("no_data", true)):
		# NO_DATA, and it says which kind. "no data" with a reason is a different statement from a row of
		# zeros, and this is the only place the difference is visible to the author.
		_stats_label.text = "NO DATA — %s" % String(last_reading.get("reason", "nothing to read"))
		_value_label.text = "probe: —"
	else:
		var st: Dictionary = last_reading.get("stats", {})
		var rng: Dictionary = last_reading.get("range", {})
		_stats_label.text = "min %.3f   max %.3f   mean %.3f   (%d cells)   %s" % [
				float(st.get("min", NAN)), float(st.get("max", NAN)), float(st.get("mean", NAN)),
				int(st.get("count", 0)), GraphEditorScript.range_chip_text(rng)]
	if _histogram != null:
		_histogram.queue_redraw()
	if _profile != null:
		_profile.queue_redraw()


## The histogram, on the DECLARED range's axis (§5.2 Rule 1 — see this file's header, point 2).
func _draw_histogram() -> void:
	var h: Dictionary = last_reading.get("histogram", {})
	if h.is_empty():
		return
	var bins: PackedInt32Array = h["bins"]
	if bins.is_empty():
		return
	var size := _histogram.size
	var peak := 1
	for b in bins:
		peak = maxi(peak, b)
	var bw := size.x / float(bins.size())
	for i in range(bins.size()):
		var frac := float(bins[i]) / float(peak)
		var bh := frac * (size.y - 14.0)
		_histogram.draw_rect(Rect2(float(i) * bw, size.y - 14.0 - bh, maxf(bw - 1.0, 1.0), bh),
				Color(0.55, 0.75, 1.0))
	# The axis carries the range's OWN endpoints, because a histogram without them is a shape and the
	# whole claim of this panel is that it is a measurement.
	var rng: Dictionary = last_reading.get("range", {})
	var font := get_theme_default_font()
	if font != null:
		_histogram.draw_string(font, Vector2(0.0, size.y - 1.0), "%.2f" % float(rng.get("min", 0.0)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.7, 0.7, 0.7))
		_histogram.draw_string(font, Vector2(size.x - 40.0, size.y - 1.0),
				"%.2f" % float(rng.get("max", 1.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				Color(0.7, 0.7, 0.7))


## The width and height profiles against arc length (§7's PATH contents).
##
## A NAN in the height profile draws a GAP — the pen lifts. Never a zero: a heightless path plotted at
## zero is a path at sea level, and it reads as a broken drape rather than as absent data.
func _draw_profile() -> void:
	var widths: PackedFloat32Array = last_reading.get("widths", PackedFloat32Array())
	var heights: PackedFloat32Array = last_reading.get("heights", PackedFloat32Array())
	if widths.is_empty() and heights.is_empty():
		return
	var size := _profile.size
	_draw_series(widths, size, Color(0.9, 0.8, 0.4), 0.0, size.y * 0.5)
	_draw_series(heights, size, Color(0.5, 0.9, 0.6), size.y * 0.5, size.y * 0.5)


func _draw_series(p_vals: PackedFloat32Array, p_size: Vector2, p_col: Color, p_top: float,
		p_height: float) -> void:
	if p_vals.size() < 2:
		return
	var lo := INF
	var hi := -INF
	for v in p_vals:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if not (hi > lo):
		hi = lo + 1.0
	var prev := Vector2.INF
	for i in range(p_vals.size()):
		var v := p_vals[i]
		if not is_finite(v):
			prev = Vector2.INF # THE GAP. The pen lifts and the next finite sample starts a new run.
			continue
		var pt := Vector2(p_size.x * float(i) / float(p_vals.size() - 1),
				p_top + p_height - (v - lo) / (hi - lo) * p_height)
		if prev != Vector2.INF:
			_profile.draw_line(prev, pt, p_col, 1.0)
		prev = pt
