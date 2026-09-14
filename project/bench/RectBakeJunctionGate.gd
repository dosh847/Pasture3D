# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RectBakeJunctionGate — does a partial (rect) road bake leave another road's junction ground the way a full
# layer bake of the SAME edit would?
#
# Trace 2026-09-13: the ground at Road+Road1@96,-1 read 0.719, then -0.029 right after a Road2 rect bake
# that repainted 4 of 7 roads, then 0.718 after a full bake repainted all 7. Each flip re-armed two roads.
# That bake was the DEFERRED DRIVER's pass 2 (a frozen graph solved on a worker), with a graph extent far
# wider than any plain rect box.
#
#   [A] Direct rect path: for each control point of the moved road, every junction not involving that road
#       inside the cleared box has the same ground after the rect bake as after a full bake of the same
#       curve, within 5 cm. (Measured 2026-09-13: holds, but never reached @96,-1.)
#   [B] Deferred driver: the same edit run through `_bake_deferred`, with frames flowing so the network's
#       queued resolve runs where it does in the editor. The ground at every foreign junction is sampled
#       EVERY FRAME of the run, and compared to a full bake of the same curve — the flip in the trace was
#       transient, so an end-of-run comparison alone could miss it. Also records the ground the queued
#       resolve_junctions actually saw.
#
# The reference is a full bake at the same curve, not the pre-edit ground: moving a point may legitimately
# move nearby batters, but the partial and the full bake of one input must agree.
#
# Ways this could measure nothing, each reported as NOT COVERED and counted as a failure:
#   - the ground reads NaN (no terrain data loaded). The first version redirected data_directory to an
#     empty folder, every height came back NaN, NaN "matched" NaN, and it passed;
#   - [A] no foreign junction ever lies inside a cleared box;
#   - [B] no edit ever reached the driver's pass 2 (the graph was served from cache, or is not frozen), so
#     the path from the trace never ran.
#
# Uses the demo road network like RoadInteractivePerfGate and keeps the scene's own terrain data, which a
# headless run never saves — check `git status` after running anyway.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RectBakeJunctionGate.tscn
extends Node

const MOVER := "Road2"
const TOL := 0.05
const NUDGE := Vector3(0.5, 0.0, 0.5)

var _fail := 0
var _ran := 0

var _scene: Node
var _net: Pasture3DRoadNetwork
var _terrain: Pasture3D
var _mover: Pasture3DRoadBrush
var _owner: String
var _foreign: Array = []

# [B] per-frame sampler state
var _polling := false
var _poll_gen := 0
var _samples: Array = [] # [{ "frame": int, "phase": String, "h": PackedFloat64Array }]
var _resolve_seen: Array = [] # [{ "phase": String, "h": PackedFloat64Array }]


func _ready() -> void:
	print("=== RectBakeJunctionGate: partial vs full bake at foreign junctions ===\n")
	if await _setup():
		_a_rect_matches_full()
		await _b_deferred_matches_full()
	if is_instance_valid(_scene):
		_scene.queue_free()
	print("\n  criteria completed: %d (want 2)" % _ran)
	if _ran != 2:
		_fail += 1
	print("\n=== %s (%d failures) ===\n" % ["RECT BAKE JUNCTION PASS" if _fail == 0 else "RECT BAKE JUNCTION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _not_covered(p_why: String) -> void:
	_fail += 1
	print("    !! NOT COVERED: %s" % p_why)


func _setup() -> bool:
	var packed: PackedScene = load("res://demo_road_network.tscn")
	if packed == null:
		_not_covered("demo_road_network.tscn did not load")
		return false
	_scene = packed.instantiate()
	add_child(_scene)
	await get_tree().process_frame
	_net = _scene.find_child("Pasture3DRoadNetwork", true, false)
	_terrain = _scene.find_child("Pasture3D", true, false)
	if _net == null or _terrain == null:
		_not_covered("no road network or terrain in the demo scene")
		return false
	for b in _net.road_brushes():
		if b != null and b.name == MOVER:
			_mover = b
	if _mover == null or _mover._get_splines().is_empty():
		_not_covered("%s with a spline not found" % MOVER)
		return false
	_owner = _mover._layer_owner
	_settle()
	var key := _mover.road_key()
	for j in _net.junctions:
		if not j.road_keys.has(key):
			_foreign.append(j)
	if _foreign.is_empty():
		_not_covered("no junction without %s" % MOVER)
		return false
	var nan_count := 0
	for h in _heights():
		if is_nan(h):
			nan_count += 1
	print("%d foreign junction(s); ground readable at %d\n" % [_foreign.size(), _foreign.size() - nan_count])
	if nan_count == _foreign.size():
		_not_covered("ground is NaN at every foreign junction — no terrain data loaded")
		return false
	return true


## A settled layer: bake, resolve pins, bake again with them. Headless, the resolve's rebake requests are
## no-ops (the schedulers are editor-only), so the second bake is explicit.
func _settle() -> void:
	_mover._refresh_owner(_owner, false, [])
	_net.resolve_junctions()
	_mover._refresh_owner(_owner, false, [])


func _heights() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for j in _foreign:
		out.append(_terrain.data.get_height(Vector3(j.center.x, 0.0, j.center.y)))
	return out


func _in_box(p_c: Vector2, p_box: AABB) -> bool:
	return p_box.size != Vector3.ZERO and p_c.x >= p_box.position.x and p_c.x <= p_box.end.x 			and p_c.y >= p_box.position.z and p_c.y <= p_box.end.z


func _a_rect_matches_full() -> void:
	print("[A] rect bake leaves foreign junction ground equal to a full bake of the same edit")
	var sp: Path3D = _mover._get_splines()[0]
	var inside := 0
	var bad := 0
	for i in sp.curve.point_count:
		var orig := sp.curve.get_point_position(i)
		sp.curve.set_point_position(i, orig + NUDGE)
		Pasture3DBakeTrace.start(false)
		_mover._refresh_owner_rect(_owner, {sp.get_instance_id(): true})
		var mark := ""
		for ev in Pasture3DBakeTrace.events():
			if ev["type"] == "mark" and String(ev["text"]).contains("rect bake"):
				mark = String(ev["text"])
		Pasture3DBakeTrace.stop()
		var clip: AABB = _mover._last_rect_clip
		var after_rect := _heights()
		_mover._refresh_owner(_owner, false, [])
		var after_full := _heights()
		# Restore and re-settle, so the next point starts from the unedited layer.
		sp.curve.set_point_position(i, orig)
		_mover._refresh_owner(_owner, false, [])

		var rows := PackedStringArray()
		for k in _foreign.size():
			if not _in_box(_foreign[k].center, clip):
				continue
			var r: float = after_rect[k]
			var f: float = after_full[k]
			if is_nan(r) or is_nan(f):
				rows.append("       ?? %-24s rect %8.3f  full %8.3f  (NaN: not measured)" % [_foreign[k].id, r, f])
				continue
			inside += 1
			var off := absf(r - f) > TOL
			if off:
				bad += 1
			rows.append("       %s %-24s rect %8.3f  full %8.3f  |d| %.3f" % ["!!" if off else "  ",
					_foreign[k].id, r, f, absf(r - f)])
		print("    point %d: %s" % [i, mark.get_slice(": ", 1) if mark != "" else "(no rect bake mark)"])
		for row in rows:
			print(row)

	if inside == 0:
		_not_covered("no measurable foreign junction fell inside any cleared box")
	elif bad > 0:
		_fail += 1
		print("    !! %d of %d measured junction/edit pair(s) differ from the full bake by > %.2f m" % [bad, inside, TOL])
	else:
		print("    all %d measured junction/edit pair(s) match the full bake" % inside)
	_ran += 1


func _b_deferred_matches_full() -> void:
	print("\n[B] the deferred driver's rect bake, sampled every frame, against a full bake of the same edit")
	_mover.force_deferred_erosion = true
	# `_has_graph_modifier` skips a FROZEN graph that already holds a cache, and the settle bakes above fill
	# it — so without this the driver is never taken and [B] measured nothing (first run 2026-09-13). The
	# editor reached the driver with the cache empty, so each edit starts from that state.
	var graphs: Array = []
	for m in _mover.modifiers:
		if m is Pasture3DNodeGraph and m.is_active():
			graphs.append(m)
	print("    %s has %d active graph modifier(s)" % [MOVER, graphs.size()])
	var sp: Path3D = _mover._get_splines()[0]
	var reached_pass2 := 0
	var measured := 0
	var bad := 0
	for i in sp.curve.point_count:
		var orig := sp.curve.get_point_position(i)
		sp.curve.set_point_position(i, orig + NUDGE)
		for g in graphs:
			g.clear_cache()
		if not _mover._wants_deferred_bake():
			sp.curve.set_point_position(i, orig)
			print("    point %d: driver not taken even with the graph cache cleared" % i)
			continue

		Pasture3DBakeTrace.start(false)
		_samples = []
		_resolve_seen = []
		_polling = true
		_poll()
		var bake := _mover._refresh_owner_rect.bind(_owner, {sp.get_instance_id(): true}, false)
		await _mover._bake_deferred(bake, _owner, false)
		# Let the resolve the final pass queued run too, as it would in the editor.
		await get_tree().process_frame
		await get_tree().process_frame
		_polling = false
		var marks := PackedStringArray()
		var graph_results := PackedStringArray()
		for ev in Pasture3DBakeTrace.events():
			if ev["type"] == "mark":
				marks.append(String(ev["text"]).get_slice("\n", 0))
			elif ev["type"] == "graph":
				graph_results.append(String(ev["result"]))
		Pasture3DBakeTrace.stop()
		var hit_pass2 := false
		for m in marks:
			if m.contains("deferred driver pass 2"):
				hit_pass2 = true

		_mover._refresh_owner(_owner, false, [])
		var full := _heights()
		sp.curve.set_point_position(i, orig)
		_settle()

		print("    point %d: pass 2 %s; graph %s; %d frame sample(s); %d resolve(s) during the run" % [
				i, "REACHED" if hit_pass2 else "not reached", ",".join(graph_results), _samples.size(),
				_resolve_seen.size()])
		if not hit_pass2:
			continue
		reached_pass2 += 1
		for k in _foreign.size():
			var f: float = full[k]
			if is_nan(f):
				continue
			var worst := 0.0
			var worst_phase := ""
			var worst_h := f
			for s in _samples:
				var h: float = s["h"][k]
				if is_nan(h):
					continue
				if absf(h - f) > worst:
					worst = absf(h - f)
					worst_phase = s["phase"]
					worst_h = h
			var at_resolve := PackedStringArray()
			for r in _resolve_seen:
				at_resolve.append("%.3f (%s)" % [r["h"][k], r["phase"]])
			measured += 1
			var off := worst > TOL
			if off:
				bad += 1
			if off or not at_resolve.is_empty():
				print("       %s %-24s full %8.3f  worst in-run %8.3f (|d| %.3f, %s)  resolve saw [%s]" % [
						"!!" if off else "  ", _foreign[k].id, f, worst_h, worst, worst_phase, ", ".join(at_resolve)])
	_mover.force_deferred_erosion = false

	if reached_pass2 == 0:
		_not_covered("no edit reached the driver's pass 2, so the path from the trace never ran")
	elif bad > 0:
		_fail += 1
		print("    !! %d of %d junction/edit pair(s) left the full-bake ground by > %.2f m at some frame of the run" % [
				bad, measured, TOL])
	else:
		print("    all %d junction/edit pair(s) stayed within %.2f m of the full bake on every frame (%d edit(s) reached pass 2)" % [
				measured, TOL, reached_pass2])
	_ran += 1


## Samples foreign-junction ground once per frame while `_polling`, tagged with the driver phase the latest
## trace mark names. A resolve_junctions mark since the last frame records the ground it saw — this runs
## in the frame after the resolve, and nothing bakes between, so that is the ground it read.
##
## Each poller owns a generation. A bare `_polling` flag is not enough: the next edit sets it true again
## before the previous poller's pending frame resumes, so every earlier poller kept sampling into the new
## edit's arrays (first run: sample counts 3, 6, 9, … per edit).
func _poll() -> void:
	_poll_gen += 1
	var gen := _poll_gen
	var seen := 0
	while _polling and gen == _poll_gen:
		await get_tree().process_frame
		if not _polling or gen != _poll_gen:
			break
		var evs := Pasture3DBakeTrace.events()
		var phase := "before pass 1"
		for ev in evs:
			if ev["type"] == "mark":
				var t := String(ev["text"])
				if t.contains("deferred driver pass"):
					phase = t.get_slice(": ", 1)
		var h := _heights()
		for idx in range(seen, evs.size()):
			var ev: Dictionary = evs[idx]
			if ev["type"] == "mark" and String(ev["text"]).begins_with("resolve_junctions"):
				_resolve_seen.append({"phase": phase, "h": h})
		seen = evs.size()
		_samples.append({"frame": Engine.get_process_frames(), "phase": phase, "h": h})
