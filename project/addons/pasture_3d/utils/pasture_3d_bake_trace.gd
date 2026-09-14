# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DBakeTrace — WHY a brush baked, not just that it did.
#
# ---- WHAT THIS EXISTS TO ANSWER ----
#
# "I moved a road point and three mountains re-solved their terrain graphs. What woke them?"
#
# That question could not be answered from the editor. `log_bake_timing` is per-brush opt-in, so you have
# to already know which brush to watch — and the whole problem is that you do not. It covers only the
# dirty-rect path. It records the COST of a bake and nothing about its CAUSE. And it prints to Output,
# where a real session buries it under hundreds of unrelated engine errors.
#
# So the chain of reasoning about a spurious bake was: read the code, form a hypothesis, ask the user to
# reproduce, guess again. Three hypotheses were wrong in a row that way — a Path node that was not in the
# graph, a GDScript fallback that was not being taken, a shared layer owner that turned out to be two
# separate owners. Each was plausible from the code and false in the scene. This records the answer
# instead.
#
# ---- WHY THE CAUSE IS CAPTURED AT ARM TIME ----
#
# Three schedulers can wake a brush — `_schedule_refresh` (a property or the whole layer),
# `_schedule_transform_refresh` (the node moved), `_schedule_spline_refresh` (one curve changed) — and all
# three funnel into `_arm_refresh_timer`. That is the ONE choke point where "something decided this brush
# is dirty" is true, and it is the only place the GDScript call stack still holds who decided it. By the
# time the timer fires, REFRESH_DELAY later, the stack is gone and every bake looks self-inflicted. That
# is exactly why the mountains looked spontaneous.
#
# `get_stack()` is only populated for @tool scripts running under the editor, which is the only place this
# is ever enabled, and it is the single most expensive call here — hence `capture_stacks`, on by default
# but separable from tracing itself when someone wants arm/bake pairs cheaply.
#
# ---- WHY EVENTS AND NOT PRINTS ----
#
# Ordering ACROSS brushes is the signal. "LakeRoad1 armed by a curve edit, then 40 ms later Mountain2
# armed with the terrain-changed rebind on its stack" is the finding; two independent per-brush prints
# interleaved with engine noise is not. So events land in one ordered buffer with a monotonic sequence
# number, and `report()` renders them after the fact. Nothing is formatted while the editor is busy.
#
# ---- COST WHEN OFF ----
#
# Every entry point returns on the first line when `enabled` is false, so a shipped scene pays one static
# bool read per arm and per bake. The buffer is capped and drops OLDEST first: a runaway feedback loop is
# the thing you most want to catch, and it must not exhaust memory while you catch it.
@tool
class_name Pasture3DBakeTrace
extends RefCounted

## Master switch. Nothing is recorded and nothing is allocated while this is false.
static var enabled: bool = false

## Record the GDScript call stack at arm time — the field that answers "what woke this brush". Costs a
## `get_stack()` per arm, so it is separable, but tracing without it usually cannot answer the question
## that made someone turn tracing on.
static var capture_stacks: bool = true

## Ring capacity. Oldest events are dropped first (see the header: a feedback loop must be catchable).
static var max_events: int = 4096

## Frames closest to the arm site are the informative ones; the editor's own dispatch above them is noise.
const STACK_DEPTH := 6

## Engine and trace-internal frames carry no information about who decided a brush was dirty.
const _STACK_SKIP := ["pasture_3d_bake_trace.gd"]

static var _events: Array[Dictionary] = []
static var _seq: int = 0
static var _t0: int = 0
static var _open_bakes: Dictionary = {}
static var _started_at: String = ""
static var _session_note: String = ""


## Begin a session, discarding anything already buffered. Timestamps are relative to this call, because an
## absolute µs clock makes the gaps between events — the part you read — harder to see than they need to be.
static func start(p_capture_stacks: bool = true) -> void:
	_events = []
	_seq = 0
	_open_bakes = {}
	_t0 = Time.get_ticks_usec()
	capture_stacks = p_capture_stacks
	enabled = true


static func stop() -> void:
	enabled = false


static func is_running() -> bool:
	return enabled


static func event_count() -> int:
	return _events.size()


## A brush was marked dirty. `p_kind` is which scheduler did it ("full", "transform", "spline").
##
## THE STACK IS THE POINT. Everything else here is recoverable later; the caller is not.
static func arm(p_brush: Node, p_kind: String) -> void:
	if not enabled:
		return
	_push({
		"type": "arm",
		"brush": _brush_name(p_brush),
		"owner": _layer_owner_of(p_brush),
		"kind": p_kind,
		"stack": _stack() if capture_stacks else [],
	})


## A bake started. Pair with `bake_end` using the returned token; nesting is not expected but interleaving
## across brushes is, so the token is per-call rather than a single "current bake" slot.
static func bake_begin(p_brush: Node, p_path: String) -> int:
	if not enabled:
		return -1
	var token := _push({
		"type": "bake_begin",
		"brush": _brush_name(p_brush),
		"owner": _layer_owner_of(p_brush),
		"path": p_path,
		# Spec §5: not every bake comes through a scheduler — refresh(), undo, force_bake_modifiers and the
		# deferred driver's later passes do not — so the arm stack alone left bakes with no recorded cause.
		"stack": _stack() if capture_stacks else [],
	})
	_open_bakes[token] = [Time.get_ticks_usec(), _brush_name(p_brush)]
	return token


## Close the bake opened as `p_token`. `p_tools` is how many layer-mates it repainted — the number that
## turns "one edit" into "twelve repaints" when a layer is shared.
static func bake_end(p_token: int, p_tools: int = -1) -> void:
	if not enabled or p_token < 0 or not _open_bakes.has(p_token):
		return
	var open: Array = _open_bakes[p_token]
	var us: int = Time.get_ticks_usec() - int(open[0])
	_open_bakes.erase(p_token)
	_push({
		"type": "bake_end",
		"of": p_token,
		# Carried on the event, not looked up from its begin: the journal writes one line per event as it
		# happens and cannot search back, and the begin may already have left the ring.
		"brush": open[1],
		"us": us,
		"tools": p_tools,
	})


## One graph modifier resolved during a bake. `p_result` is "HIT", "MISS", "STALE" or "DEFERRED".
##
## Recorded per bake rather than sampled after the fact, because the state that matters is what the cache
## did AT the bake — a diagnostic run afterwards sees a populated cache and reports health for a bake that
## missed. That is precisely the reading that sent this investigation down a wrong path once already.
static func graph(p_brush: Node, p_frozen: bool, p_extent: String, p_result: String, p_us: int = -1) -> void:
	if not enabled:
		return
	_push({
		"type": "graph",
		"brush": _brush_name(p_brush),
		"frozen": p_frozen,
		"extent": p_extent,
		"result": p_result,
		"us": p_us,
	})


## Free-form marker, so a caller can label a reproduction ("moved LakeRoad1 point 3") inside the stream.
static func mark(p_text: String) -> void:
	if not enabled:
		return
	_push({ "type": "mark", "text": p_text })


static func _push(p_ev: Dictionary) -> int:
	p_ev["seq"] = _seq
	p_ev["t_us"] = Time.get_ticks_usec() - _t0
	_events.append(p_ev)
	_seq += 1
	if _journal != null:
		_journal_write(p_ev)
	if _events.size() > max_events:
		_events = _events.slice(_events.size() - max_events)
	return p_ev["seq"]


static func _brush_name(p_brush: Node) -> String:
	return String(p_brush.name) if is_instance_valid(p_brush) else "<freed>"


static func _layer_owner_of(p_brush: Node) -> String:
	if not is_instance_valid(p_brush):
		return ""
	# `_layer_owner` is private to the brush, and this reaches across to it deliberately: a trace that
	# needed a public accessor would be a trace that changes the API it observes.
	return String(p_brush.get("_layer_owner")) if p_brush.get("_layer_owner") != null else ""


## The informative frames of the current GDScript stack, innermost first, as "file:line func()".
##
## Empty outside a debug/editor context, which `get_stack()` does not distinguish from "called from
## nowhere" — so the report says which of the two it is rather than showing a blank cause.
static func _stack() -> Array:
	var raw := get_stack()
	var out: Array = []
	for f in raw:
		var src := String(f.get("source", ""))
		var skip := false
		for s in _STACK_SKIP:
			if src.ends_with(s):
				skip = true
				break
		if skip:
			continue
		out.append("%s:%d %s()" % [src.get_file(), int(f.get("line", 0)), String(f.get("function", ""))])
		if out.size() >= STACK_DEPTH:
			break
	return out


## The events, oldest first, as plain dictionaries. For a gate that wants to assert on them rather than
## read them.
static func events() -> Array[Dictionary]:
	return _events.duplicate(true)


## Human-readable timeline plus a per-brush cost summary.
##
## The timeline is the part that answers the causality question and the summary is the part that answers
## "and what did it cost", in that order, because knowing the cost of a bake that should not have happened
## is the less useful half.
static func report() -> String:
	var lines := PackedStringArray()
	lines.append("=== Pasture3D bake trace — %d event(s) ===" % _events.size())
	if _session_note != "":
		lines.append(_session_note)
	if _events.is_empty():
		lines.append("  (nothing recorded — was Pasture3DBakeTrace.start() called before the edit?)")
		return "\n".join(lines)

	var totals := {}
	var counts := {}
	var arms := {}
	var graph_stats := {}

	lines.append("")
	lines.append("-- TIMELINE (ms from start) --")
	for ev in _events:
		lines.append_array(_event_lines(ev))
		match String(ev["type"]):
			"arm":
				var b := String(ev["brush"])
				arms[b] = int(arms.get(b, 0)) + 1
			"bake_end":
				var owner_name := String(ev.get("brush", "?"))
				totals[owner_name] = float(totals.get(owner_name, 0.0)) + float(ev["us"]) / 1000.0
				counts[owner_name] = int(counts.get(owner_name, 0)) + 1
			"graph":
				var key := "%s/%s" % [ev["brush"], ev["result"]]
				graph_stats[key] = int(graph_stats.get(key, 0)) + 1

	lines.append("")
	lines.append("-- PER-BRUSH SUMMARY --")
	var names := totals.keys()
	names.sort_custom(func(a, b): return float(totals[a]) > float(totals[b]))
	for nm in names:
		lines.append("  %-16s %8.1f ms over %d bake(s), armed %d time(s)" % [
				nm, totals[nm], counts[nm], int(arms.get(nm, 0))])
	for nm in arms:
		if not totals.has(nm):
			lines.append("  %-16s %8s    armed %d time(s), never baked" % [nm, "-", int(arms[nm])])

	if not graph_stats.is_empty():
		lines.append("")
		lines.append("-- GRAPH CACHE --")
		var gk := graph_stats.keys()
		gk.sort()
		for k in gk:
			lines.append("  %-32s %d" % [k, graph_stats[k]])

	return "\n".join(lines)


## One event as timeline text. Shared by `report()` and the journal so the two cannot drift apart.
static func _event_lines(p_ev: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var t: float = float(p_ev["t_us"]) / 1000.0
	match String(p_ev["type"]):
		"mark":
			lines.append("")
			lines.append("  %8.1f  ### %s" % [t, p_ev["text"]])
		"arm":
			lines.append("  %8.1f  ARM   %-16s owner=%-28s via %s" % [t, p_ev["brush"], p_ev["owner"], p_ev["kind"]])
			var st: Array = p_ev.get("stack", [])
			if st.is_empty():
				lines.append("            %-22s (no stack: capture_stacks off, or not an editor/tool context)" % "")
			else:
				for i in st.size():
					lines.append("            %s %s" % ["woken by" if i == 0 else "        ", st[i]])
		"bake_begin":
			lines.append("  %8.1f  BAKE  %-16s owner=%-28s path=%s" % [t, p_ev["brush"], p_ev["owner"], p_ev["path"]])
			var bst: Array = p_ev.get("stack", [])
			for i in bst.size():
				lines.append("            %s %s" % ["entered via" if i == 0 else "           ", bst[i]])
		"bake_end":
			var tools: int = int(p_ev.get("tools", -1))
			lines.append("  %8.1f  DONE  %-16s %8.1f ms%s" % [t, p_ev.get("brush", "?"), float(p_ev["us"]) / 1000.0,
					("  (%d tool(s) repainted)" % tools) if tools >= 0 else ""])
		"graph":
			var gms := ("  %.1f ms" % (float(p_ev["us"]) / 1000.0)) if int(p_ev["us"]) >= 0 else ""
			lines.append("  %8.1f  GRAPH %-16s %-8s %-5s extent=%s%s" % [
					t, p_ev["brush"], p_ev["result"], "frozen" if p_ev["frozen"] else "live", p_ev["extent"], gms])
	return lines


## Default report location. user:// survives the Output panel being flooded and the editor restarting.
const REPORT_PATH := "user://pasture3d_bake_trace.txt"

## ---- THE JOURNAL: WHAT SURVIVES A CRASH ----
##
## The ring buffer lives in memory and the report is written on untick, so an editor crash — the moment a
## trace matters most — left nothing (2026-09-13: a road moved on a mound took the editor down mid-trace).
## So a toggled session also appends every event to this file as it is recorded, flushed per event: a
## process crash loses nothing already recorded, and the LAST line is the last thing that happened. A
## machine-level crash (driver watchdog, power) can still lose what the OS had not written out.
##
## A clean stop ends the file with "STOPPED CLEANLY"; a journal without that line is from a session that died.
## Starting a session moves the previous journal to JOURNAL_PREV_PATH first, so relaunching after a crash and
## ticking the box again does not overwrite the only record of it.
##
## Only `set_session` journals. `start()` alone (gates) does not, and `journal_path` is a var so a gate that
## exercises the session can point it away from the user's crash record.
const JOURNAL_PATH := "user://pasture3d_bake_trace_journal.txt"
const JOURNAL_PREV_PATH := "user://pasture3d_bake_trace_journal_prev.txt"
static var journal_path: String = JOURNAL_PATH
static var journal_prev_path: String = JOURNAL_PREV_PATH
static var _journal: FileAccess = null


static func is_journaling() -> bool:
	return _journal != null


static func _journal_open() -> void:
	_journal_close("")
	if FileAccess.file_exists(journal_path):
		if FileAccess.file_exists(journal_prev_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_prev_path))
		DirAccess.rename_absolute(ProjectSettings.globalize_path(journal_path),
				ProjectSettings.globalize_path(journal_prev_path))
	_journal = FileAccess.open(journal_path, FileAccess.WRITE)
	if _journal == null:
		push_error("Pasture3DBakeTrace: cannot open journal %s (%d); a crash will lose this trace" % [
				journal_path, FileAccess.get_open_error()])
		return
	_journal.store_line("=== Pasture3D bake trace JOURNAL — started %s ===" % Time.get_datetime_string_from_system())
	_journal.store_line("One entry per event, flushed as recorded. No 'STOPPED CLEANLY' line at the end means the")
	_journal.store_line("session died (crash or kill): the last entry is the last thing recorded before it did.")
	_journal.store_line("")
	_journal.flush()


static func _journal_write(p_ev: Dictionary) -> void:
	for l in _event_lines(p_ev):
		_journal.store_line(l)
	_journal.flush()


## `p_end` is the closing line; "" closes without one (an interrupted journal is replaced, not ended).
static func _journal_close(p_end: String) -> void:
	if _journal == null:
		return
	if p_end != "":
		_journal.store_line("")
		_journal.store_line(p_end)
	_journal.close()
	_journal = null


## The whole in-editor session in one call, for the Pasture3D inspector toggle: `p_on` starts a trace
## (stacks on); off stops it and ALWAYS writes a report, returning its absolute path ("" only on start or a
## write failure).
##
## Off writes even when nothing was running, on purpose. The first real use of this toggle produced no
## report and no message, and "never unticked" could not be told apart from "the recorder's static state was
## reset mid-session" (a script reload clears static vars). A report stamped NOT RUNNING answers that; a
## silent return answered nothing.
##
## Lives here rather than in the inspector control because an EditorInspectorPlugin cannot be instantiated
## outside the editor, so logic inside one can never be gated.
static func set_session(p_on: bool, p_path: String = REPORT_PATH) -> String:
	if p_on:
		start(true)
		_started_at = Time.get_datetime_string_from_system()
		_journal_open()
		print("Pasture3DBakeTrace: STARTED. Reproduce the problem, then untick Bake Trace. Live journal: %s" %
				ProjectSettings.globalize_path(journal_path))
		return ""
	var was_running := enabled
	stop()
	_journal_close("=== STOPPED CLEANLY at %s, %d event(s) ===" % [Time.get_datetime_string_from_system(), _seq])
	_session_note = "session: started %s, stopped %s%s" % [
			_started_at if _started_at != "" else "<unknown>",
			Time.get_datetime_string_from_system(),
			"" if was_running else "  -- NOT RUNNING at stop: the trace was reset or never started, " 					+ "so the events below (if any) are incomplete"]
	var path := write_report(p_path)
	_session_note = ""
	if was_running:
		print("Pasture3DBakeTrace: stopped, %d event(s) -> %s" % [_events.size(), path])
	else:
		push_warning("Pasture3DBakeTrace: unticked but the trace was NOT running (state reset, e.g. a " 				+ "script reload). Wrote what was buffered (%d event(s)) -> %s" % [_events.size(), path])
	return path


## Write `report()` to `p_path` (default under user://, which survives the Output panel being flooded).
## Returns the absolute path written, or "" on failure.
static func write_report(p_path: String = REPORT_PATH) -> String:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		push_error("Pasture3DBakeTrace: cannot write %s (%d)" % [p_path, FileAccess.get_open_error()])
		return ""
	f.store_string(report())
	f.close()
	return ProjectSettings.globalize_path(p_path)
