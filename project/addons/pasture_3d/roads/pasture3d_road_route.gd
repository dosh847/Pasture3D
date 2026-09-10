# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadRoute — a stage: an ordered walk through the network (§9.2, P6a).
#
# ---- WHY THERE IS NO TRACK ASSET ----
#
# The world is open-world-first and a stage is a SECTION OF IT — point to point, with checkpoints, never
# a closed circuit (§9). So there is no separate track authoring path and nothing here is geometry: a
# route is an ordered list of runs that already exist for open-world reasons, plus a few numbers. Every
# quantity a stage needs is derived from the alignment §7 already solved.
#
# That is a simplification rather than an extra requirement, and it is what makes checkpoints parametric:
# a gate is an arc length, so MOVING THE ROAD MOVES ITS CHECKPOINTS and a stage cannot silently develop a
# gate floating beside the new alignment.
@tool
class_name Pasture3DRoadRoute
extends Resource

## The walk, start to finish: `[{run_id: int, reversed: bool}, ...]`.
enum RouteTopology {
	POINT_TO_POINT, ## Rally stage: starts at s=0, ends at s=total, no loop wrapping.
	CLOSED_CIRCUIT, ## Track racing: loop wraps s=total back to s=0 with lap counters.
}

## The walk, start to finish: `[{run_id: int, reversed: bool}, ...]`.
##
## Runs are named by STABLE ID, not by index into the runtime's array (§9.2), so a route survives edits
## elsewhere in the network. An index would break every route the moment a road was deleted from the
## middle of the network — and break it silently, by pointing at whichever road moved into that slot.
@export var entries: Array = []

## Route topology: point-to-point stage or closed racing circuit (P9h).
@export var topology: RouteTopology = RouteTopology.POINT_TO_POINT

## Number of laps in closed circuit mode (P9h).
@export var lap_count: int = 3

## Split timing sector gates along track arc length in metres (P9h).
@export var sector_gates: PackedFloat32Array = PackedFloat32Array()

## Gates, as arc length along the ROUTE in metres — not along any one run, and not placed objects. A
## gate is derived: a plane perpendicular to the centreline at `s`, as wide as the corridor.
@export var checkpoints: PackedFloat32Array = PackedFloat32Array()

## Off-course threshold, metres either side of the centreline (§9.3). Cutting onto the verge is
## legitimate rally driving; leaving the corridor is not. So the test is against this, not against the
## carriageway edge, and the band between them is the verge you are allowed to use.
@export var corridor_width: float = 8.0

## How tall a derived checkpoint gate is, metres.
@export var gate_height: float = 6.0


## Create a tracking session for a race or run along this route (P9h).
## Maintains continuous distance across laps, lap completion, and sector timing splits.
func create_session(p_start_time: float = 0.0) -> Dictionary:
	return {
		"lap_index": 0,
		"accum_distance": 0.0,
		"lap_distance": 0.0,
		"last_s": -1.0,
		"last_time": p_start_time,
		"completed_laps": 0,
		"finished": false,
		"sector_index": 0,
		"current_lap_start_time": p_start_time,
		"sector_crossings": [],
		"lap_times": [],
	}


## Total route length, metres. Cached is not worth it: this is a sum over a handful of entries.
func length(p_runtime: Pasture3DRoadRuntime) -> float:
	var total := 0.0
	for e: Dictionary in entries:
		var r := p_runtime.run_by_id(int(e["run_id"])) if p_runtime != null else null
		if r != null:
			total += r.length()
	return total


## Which entry contains route arc length `p_s`, as `{index, run_id, reversed, local_s, entry_start}`,
## or {} past the end.
##
## The route's `s` and a run's `s` are different coordinates and are kept visibly so. Conflating them is
## the mistake this whole function exists to prevent: a checkpoint at 4 km means 4 km into the STAGE,
## which may be 300 m into the third run, and a system that used the run's own arc length would put the
## gate 4 km along a road that is 900 m long — clamped to its end, silently, at the wrong place.
func entry_at(p_runtime: Pasture3DRoadRuntime, p_s: float) -> Dictionary:
	if p_runtime == null:
		return {}
	var s := p_s
	var total_len := length(p_runtime)
	if topology == RouteTopology.CLOSED_CIRCUIT and total_len > 0.0:
		s = fposmod(p_s, total_len)
	var walked := 0.0
	for i in entries.size():
		var e: Dictionary = entries[i]
		var r := p_runtime.run_by_id(int(e["run_id"]))
		if r == null:
			continue
		var l := r.length()
		if s < walked + l or i == entries.size() - 1:
			return { "index": i, "run_id": r.id, "reversed": bool(e.get("reversed", false)),
					"local_s": clampf(s - walked, 0.0, l), "entry_start": walked }
		walked += l
	return {}


## Position, tangent and banked up at route arc length `p_s` — the centreline a game follows.
func sample(p_runtime: Pasture3DRoadRuntime, p_s: float) -> Dictionary:
	var e := entry_at(p_runtime, p_s)
	if e.is_empty():
		return {}
	var r := p_runtime.run_by_id(int(e["run_id"]))
	if r == null:
		return {}
	var out := r.sample(float(e["local_s"]), bool(e["reversed"]))
	if not out.is_empty():
		out["run_id"] = r.id
		out["surface"] = r.surface_at(float(e["local_s"]), bool(e["reversed"]))
	return out


## Route-relative progress for a world position (§9.2):
## `{distance_from_start, lateral, next_checkpoint, next_checkpoint_distance, on_corridor, run_id}`.
## In CLOSED_CIRCUIT with session: tracks monotonic distance, lap counters, split sector timing.
func progress(p_runtime: Pasture3DRoadRuntime, p_world: Vector3,
		p_session: Dictionary = {}, p_time: float = 0.0) -> Dictionary:
	if p_runtime == null or entries.is_empty():
		return {}
	var best := {}
	var best_d := INF
	var walked := 0.0
	for e: Dictionary in entries:
		var r := p_runtime.run_by_id(int(e["run_id"]))
		if r == null:
			continue
		var rev := bool(e.get("reversed", false))
		var hit := r.locate(p_world, rev)
		if not hit.is_empty() and float(hit["distance"]) < best_d:
			best_d = float(hit["distance"])
			best = { "distance_from_start": walked + float(hit["s"]), "lateral": float(hit["t"]),
					"on_corridor": absf(float(hit["t"])) <= corridor_width, "run_id": r.id }
		walked += r.length()
	if best.is_empty():
		return {}

	var total_len := walked
	var raw_s := float(best["distance_from_start"])

	if topology == RouteTopology.POINT_TO_POINT:
		best["next_checkpoint"] = -1
		best["next_checkpoint_distance"] = INF
		for i in checkpoints.size():
			if checkpoints[i] >= raw_s:
				best["next_checkpoint"] = i
				best["next_checkpoint_distance"] = checkpoints[i] - raw_s
				break
		return best

	# CLOSED_CIRCUIT
	var loop_s := fposmod(raw_s, total_len) if total_len > 0.0 else raw_s
	var lap_idx := int(floor(raw_s / total_len)) if total_len > 0.0 else 0

	best["lap_index"] = lap_idx
	best["lap_distance"] = loop_s
	best["accum_distance"] = raw_s
	best["completed_laps"] = 0
	best["finished"] = false
	best["sector_index"] = 0
	best["lap_completed"] = false
	best["sector_completed"] = false

	if p_session.is_empty():
		best["next_checkpoint"] = -1
		best["next_checkpoint_distance"] = INF
		for i in checkpoints.size():
			if checkpoints[i] >= loop_s:
				best["next_checkpoint"] = i
				best["next_checkpoint_distance"] = checkpoints[i] - loop_s
				break
		return best

	# Stateful Session Tracking
	var last_s: float = float(p_session.get("last_s", -1.0))
	var last_time: float = float(p_session.get("last_time", p_time))
	var cur_accum: float = float(p_session.get("accum_distance", 0.0))
	var cur_lap: int = int(p_session.get("lap_index", 0))
	var cur_sector: int = int(p_session.get("sector_index", 0))
	var lap_start_time: float = float(p_session.get("current_lap_start_time", p_time))
	var completed_laps: int = int(p_session.get("completed_laps", 0))
	var finished: bool = bool(p_session.get("finished", false))

	if last_s < 0.0:
		cur_accum = loop_s
		last_s = loop_s
		cur_lap = 0
		completed_laps = 0
		cur_sector = 0
		for i in sector_gates.size():
			if loop_s >= sector_gates[i]:
				cur_sector = i + 1
	else:
		var ds: float = loop_s - last_s
		var seam_crossed := false
		if total_len > 0.0:
			if ds < -0.5 * total_len:
				ds += total_len
				seam_crossed = true
			elif ds > 0.5 * total_len:
				ds -= total_len

		cur_accum += ds

		# Check sector gate crossings during this step
		for i in sector_gates.size():
			var gate_s := sector_gates[i]
			var crossed := false
			if not seam_crossed:
				crossed = (last_s < gate_s and loop_s >= gate_s)
			else:
				crossed = (last_s < gate_s) or (loop_s >= gate_s)
			if crossed and cur_sector == i:
				var interp_frac := 0.0
				var step_len := (loop_s + total_len - last_s) if seam_crossed else (loop_s - last_s)
				if step_len > 1e-6:
					var dist_to_gate := (gate_s + total_len - last_s) if (seam_crossed and gate_s < last_s) else (gate_s - last_s)
					interp_frac = clampf(dist_to_gate / step_len, 0.0, 1.0)
				var cross_time := last_time + (p_time - last_time) * interp_frac
				var split_time := cross_time - lap_start_time
				var crossing := {
					"sector": i,
					"lap": cur_lap,
					"time": cross_time,
					"split": split_time,
					"s": gate_s
				}
				if not p_session.has("sector_crossings"):
					p_session["sector_crossings"] = []
				p_session["sector_crossings"].append(crossing)
				cur_sector = i + 1
				best["sector_completed"] = true

		# Check lap completion (crossing start/finish forward)
		if seam_crossed and ds > 0.0:
			var step_len := loop_s + total_len - last_s
			var dist_to_finish := total_len - last_s
			var interp_frac := clampf(dist_to_finish / step_len, 0.0, 1.0) if step_len > 1e-6 else 1.0
			var finish_time := last_time + (p_time - last_time) * interp_frac
			var lap_duration := finish_time - lap_start_time
			if not p_session.has("lap_times"):
				p_session["lap_times"] = []
			p_session["lap_times"].append(lap_duration)
			cur_lap += 1
			completed_laps += 1
			cur_sector = 0
			lap_start_time = finish_time
			best["lap_completed"] = true
			if completed_laps >= lap_count:
				finished = true

		last_s = loop_s

	p_session["accum_distance"] = cur_accum
	p_session["lap_index"] = cur_lap
	p_session["lap_distance"] = loop_s
	p_session["last_s"] = last_s
	p_session["last_time"] = p_time
	p_session["completed_laps"] = completed_laps
	p_session["finished"] = finished
	p_session["sector_index"] = cur_sector
	p_session["current_lap_start_time"] = lap_start_time

	best["distance_from_start"] = cur_accum
	best["accum_distance"] = cur_accum
	best["lap_index"] = cur_lap
	best["lap_distance"] = loop_s
	best["completed_laps"] = completed_laps
	best["finished"] = finished
	best["sector_index"] = cur_sector

	best["next_checkpoint"] = -1
	best["next_checkpoint_distance"] = INF
	for i in checkpoints.size():
		if checkpoints[i] >= loop_s:
			best["next_checkpoint"] = i
			best["next_checkpoint_distance"] = checkpoints[i] - loop_s
			break

	return best


## A checkpoint gate as `{position, normal, half_width, height}` — derived, never stored.
##
## This is the payoff of routes being parametric: nothing here is authored geometry, so a road that moves
## takes its gates with it. An authored gate node would stay where it was put, and a stage would develop
## a checkpoint floating beside the new alignment with nothing to flag it.
func gate(p_runtime: Pasture3DRoadRuntime, p_index: int) -> Dictionary:
	if p_index < 0 or p_index >= checkpoints.size():
		return {}
	var at := sample(p_runtime, checkpoints[p_index])
	if at.is_empty():
		return {}
	return { "position": at["position"], "normal": (at["tangent"] as Vector3).normalized(),
			"half_width": corridor_width, "height": gate_height, "up": at["up"] }


## Start/finish gate derived at s = 0 as {position, normal, half_width, height, up} (P9h).
func start_finish_gate(p_runtime: Pasture3DRoadRuntime) -> Dictionary:
	var at := sample(p_runtime, 0.0)
	if at.is_empty():
		return {}
	return {
		"position": at["position"],
		"normal": (at["tangent"] as Vector3).normalized(),
		"half_width": corridor_width,
		"height": gate_height,
		"up": at["up"]
	}


## Derived sector split gate at sector_gates[p_index] as {position, normal, half_width, height, up} (P9h).
func sector_gate(p_runtime: Pasture3DRoadRuntime, p_index: int) -> Dictionary:
	if p_index < 0 or p_index >= sector_gates.size():
		return {}
	var at := sample(p_runtime, sector_gates[p_index])
	if at.is_empty():
		return {}
	return {
		"position": at["position"],
		"normal": (at["tangent"] as Vector3).normalized(),
		"half_width": corridor_width,
		"height": gate_height,
		"up": at["up"]
	}


## The surface under route arc length `p_s`, blended across transitions (§9.1).
func sample_surface(p_runtime: Pasture3DRoadRuntime, p_s: float) -> Dictionary:
	var e := entry_at(p_runtime, p_s)
	if e.is_empty():
		return { "primary": &"", "secondary": &"", "blend": 0.0 }
	var r := p_runtime.run_by_id(int(e["run_id"]))
	if r == null:
		return { "primary": &"", "secondary": &"", "blend": 0.0 }
	return r.sample_surface(float(e["local_s"]), bool(e["reversed"]))


## The co-driver's calls for the whole stage, in route arc length (§9.4).
##
## Generated per entry and shifted into route coordinates, because a run's notes are a property of the
## run and the direction it is driven — the same run used twice by one route, or used the other way on the
## reverse stage, produces different calls from the same data.
func generate_pace_notes(p_runtime: Pasture3DRoadRuntime) -> Array:
	var out: Array = []
	if p_runtime == null:
		return out
	var walked := 0.0
	for e: Dictionary in entries:
		var r := p_runtime.run_by_id(int(e["run_id"]))
		if r == null:
			continue
		for c: Dictionary in Pasture3DRoadPaceNotes.generate(r, bool(e.get("reversed", false))):
			var call := c.duplicate()
			call["s"] = walked + float(c["s"])
			out.append(call)
		walked += r.length()
	out.sort_custom(func(a, b): return float(a["s"]) < float(b["s"]))
	# Distance to the NEXT call, which is what actually gets read out: "200, left 4" is the gap, not the
	# absolute position. Computed here rather than by the audio system so every consumer agrees.
	for i in out.size():
		out[i]["distance_to_next"] = (float(out[i + 1]["s"]) - float(out[i]["s"])) 				if i + 1 < out.size() else INF
	return out


## Run ids the game should have loaded, given where the player is and how fast (§10).
##
## ---- WHY A ROUTE IS THE BEST STREAMING HINT IN THE PROJECT ----
##
## Rally's hard streaming problem is speed: at stage pace, a radius-around-the-player policy loads chunks
## roughly when you arrive at them. An active route is a KNOWN CORRIDOR — the game knows the next 800 m of
## road before the player does — so this returns what lies ahead along the route rather than what is
## near. It costs nothing to compute, and it turns the worst streaming case in the project into the
## best-informed one.
##
## The lookahead is biased by speed because distance is not what runs out, TIME is: 400 m is generous at
## 60 km/h and about four seconds at stage pace.
func lookahead(p_runtime: Pasture3DRoadRuntime, p_distance_from_start: float,
		p_speed: float = 0.0, p_base: float = 400.0, p_seconds: float = 8.0) -> PackedInt32Array:
	var out := PackedInt32Array()
	if p_runtime == null:
		return out
	var ahead := maxf(p_base, absf(p_speed) * p_seconds)
	var walked := 0.0
	for e: Dictionary in entries:
		var r := p_runtime.run_by_id(int(e["run_id"]))
		if r == null:
			continue
		var start := walked
		var end := walked + r.length()
		walked = end
		# Overlap with [position, position + ahead]. The run the player is ON is included by the same
		# test, so there is no special case for it.
		if end >= p_distance_from_start and start <= p_distance_from_start + ahead:
			if not out.has(r.id):
				out.append(r.id)
	return out


## The corridor ahead of the player, as `{from_s, to_s, run_ids}` — the hook a project's traffic system
## uses to clear the stage.
##
## THIS CLEARS NOTHING. It reports which stretch of which runs is about to be driven; despawning traffic,
## pulling cars over or suppressing spawns is the project's own logic, and deliberately so — Pasture3D
## publishes road and lane data and does not implement traffic. What it can do is answer the question
## precisely, so a traffic system does not have to re-derive the route's geometry to ask it.
func corridor_ahead(p_runtime: Pasture3DRoadRuntime, p_distance_from_start: float,
		p_ahead: float = 600.0) -> Dictionary:
	return {
		"from_s": p_distance_from_start,
		"to_s": p_distance_from_start + p_ahead,
		"half_width": corridor_width,
		"run_ids": lookahead(p_runtime, p_distance_from_start, 0.0, p_ahead, 0.0),
	}


## Edit-time validation (§9.2). Returns one line per problem, empty when the route is sound.
##
## ---- THE VALIDATOR REPORTS THE GAP, NOT JUST THE FAILURE ----
##
## "no junction between run 12 and run 13" is a rejection; "nearest connection is via run 41" is a fix.
## The difference matters more than it looks: a later "pick start and finish, auto-path" tool is a solver
## over the same junction graph this walk already visits, so naming the missing hop now is both the
## better message AND the shape that tool will need. A validator that only said yes or no would have to
## be rewritten to become one.
func validate(p_runtime: Pasture3DRoadRuntime) -> PackedStringArray:
	var out := PackedStringArray()
	if p_runtime == null:
		out.append("No runtime to validate against — bake the network first.")
		return out
	if entries.is_empty():
		out.append("The route is empty: add the road runs it follows, in order.")
		return out
	for i in entries.size():
		var e: Dictionary = entries[i]
		var id := int(e.get("run_id", -1))
		if p_runtime.run_by_id(id) == null:
			out.append("Entry %d names run %d, which is not in the baked network." % [i, id])
	if out.size() > 0:
		return out
	for i in range(entries.size() - 1):
		var a := int(entries[i]["run_id"])
		var b := int(entries[i + 1]["run_id"])
		if p_runtime.connected(a, b):
			continue
		out.append("Entries %d and %d (runs %s and %s) do not meet at a junction%s"
				% [i, i + 1, _name_of(p_runtime, a), _name_of(p_runtime, b), _suggest(p_runtime, a, b)])
	for s in checkpoints:
		if s < 0.0 or s > length(p_runtime):
			out.append("Checkpoint at %.1f m is off the route, which is %.1f m long."
					% [s, length(p_runtime)])
	if topology == RouteTopology.CLOSED_CIRCUIT:
		if lap_count < 1:
			out.append("Closed circuit requires lap_count >= 1 (got %d)." % lap_count)
		if entries.is_empty():
			out.append("Closed circuit requires at least one entry.")
		else:
			var first_id := int(entries[0]["run_id"])
			var last_id := int(entries[entries.size() - 1]["run_id"])
			var closed_ok := false
			if entries.size() == 1:
				var r := p_runtime.run_by_id(first_id)
				if r != null and r.plan.size() >= 2:
					closed_ok = r.plan[0].distance_to(r.plan[r.plan.size() - 1]) < 0.5
			else:
				if p_runtime.connected(last_id, first_id):
					closed_ok = true
				else:
					var r_first := p_runtime.run_by_id(first_id)
					var r_last := p_runtime.run_by_id(last_id)
					if r_first != null and r_last != null and r_first.plan.size() >= 2 and r_last.plan.size() >= 2:
						var p_end := r_last.plan[0 if bool(entries[entries.size() - 1].get("reversed", false)) else (r_last.plan.size() - 1)]
						var p_start := r_first.plan[(r_first.plan.size() - 1) if bool(entries[0].get("reversed", false)) else 0]
						closed_ok = p_end.distance_to(p_start) < 0.5
			if not closed_ok:
				out.append("Closed circuit seam does not meet: last entry %d (run %s) does not connect back to entry 0 (run %s)%s"
						% [entries.size() - 1, _name_of(p_runtime, last_id), _name_of(p_runtime, first_id), _suggest(p_runtime, last_id, first_id)])
		var total_len := length(p_runtime)
		for s in sector_gates:
			if s <= 0.0 or s >= total_len:
				out.append("Sector gate at %.1f m is outside the circuit bounds (0.0 to %.1f m)."
						% [s, total_len])
	return out


## The one-hop connection between two runs, phrased as a suggestion, or a full stop when there is none.
## One hop only: past that the message stops being a fix and becomes a route of its own, which is the
## auto-pathing tool's job rather than the validator's.
func _suggest(p_runtime: Pasture3DRoadRuntime, p_a: int, p_b: int) -> String:
	for n: Dictionary in p_runtime.neighbours(p_a):
		if p_runtime.connected(int(n["run_id"]), p_b):
			return " — nearest connection is via run %s." % _name_of(p_runtime, int(n["run_id"]))
	return " — and no single run joins them; they may be in separate parts of the network."


func _name_of(p_runtime: Pasture3DRoadRuntime, p_id: int) -> String:
	var r := p_runtime.run_by_id(p_id)
	if r == null or r.label == "":
		return str(p_id)
	return "%d (%s)" % [p_id, r.label]
