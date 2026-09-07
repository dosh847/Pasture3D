# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphExportSinks — the file-writing half of the B2 export sinks.
# PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.2. The node classes declare what a sink IS; this runs them.
#
# ---- THE EVALUATOR HAS NO PATH TO THIS FILE ----
#
# That sentence is the whole design. §9.2 rejected Hesiod's `auto_export` flag, its button that flips and
# restores it, and its JSON pre-pass that rewrites it for batch runs — three mechanisms for one problem we
# do not have. An export sink is terminal, so no compiler pass ever visits it, so `evaluate()` and every
# preview refresh are structurally incapable of writing a file. Criterion [B] asserts the file's absence
# across a parameter sweep, and it is true by construction rather than by care: there is no branch here
# that a preview could take, because nothing in the preview path calls into this class at all.
#
# `write_count` is incremented AT the file write for the same reason `Pasture3DGraphChannelSinks` counts
# there — a counter on `export_graph_outputs()` would tick on a run that resolved nothing and wrote
# nothing, and [B]'s control needs to distinguish those.
#
# ---- WHAT IS TAPPED IS THE SINK'S INPUT ----
#
# A sink has no slot of its own, so the mechanism is V2's: compile with the sink's SOURCE nodes as roots,
# ask `graph_eval_grid_taps` for those slots, write what comes back. Criterion [E] tests exactly this by
# muting the upstream node and asserting the file changes — if the writer read the graph's output instead,
# muting a node the output does not depend on would change nothing.
#
# ---- BATCH IS A PARAMETER OF THE ACTION ----
#
# `Export All` takes a base path; each sink carries a relative filename; they are joined here. Nothing in
# the graph is rewritten, nothing is flipped and restored, and a cancelled run leaves the graph untouched
# — because the run never touched it. The begin/step/finish shape is `bake_all_brushes()`'s
# (`pasture3d_sim_manager.gd:1525`) and is split the same way for the same reason: the scripted entry
# point must return a finished report rather than a coroutine, or a gate cannot assert on it.
@tool
class_name Pasture3DGraphExportSinks
extends RefCounted

## Files actually written since the counter was last reset. Counted at the write — see the header.
static var write_count: int = 0
## Taps dispatched. Separately counted so a gate can tell "it tapped and wrote nothing" from "it never
## ran", which is `gate-pass-can-mean-nothing-ran` applied to an exporter.
static var tap_count: int = 0

## Suffix of the calibration record written beside every image. A record, never a print: a normalised
## raster without its divisor is not a heightmap, it is a picture of one.
const SIDECAR_SUFFIX := ".range.json"


## Node indices of every export sink in `p_graph`, in graph order.
static func sinks_of(p_graph) -> PackedInt32Array:
	var out := PackedInt32Array()
	if p_graph == null:
		return out
	for i in range(p_graph.nodes.size()):
		var n = p_graph.nodes[i]
		if n != null and n is Pasture3DGraphNodeExportSink:
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


## Export every sink in `p_graph` under `p_base_path`. The one-call form; `Export All` in the editor and
## every scripted caller land here.
##
## Returns {"ok", "reason", "total", "written", "cancelled", "files": PackedStringArray,
## "skipped": Array[String]}.
static func export_graph_outputs(p_graph, p_base_path: String, p_terrain = null) -> Dictionary:
	var ctx := export_begin(p_graph, p_base_path, p_terrain)
	if not bool(ctx["ok"]):
		return ctx["report"]
	for i in range(int(ctx["plan"].size())):
		export_step(ctx, i)
	return export_finish(ctx)


## Validate and plan. `ok` false means nothing was done and `report.reason` says why. Split out so a
## caller that needs cancellation drives the steps itself and stops — which is what cancellation IS here.
static func export_begin(p_graph, p_base_path: String, p_terrain = null) -> Dictionary:
	var report := {"ok": false, "reason": "", "total": 0, "written": 0, "cancelled": false,
			"files": PackedStringArray(), "skipped": []}
	var fail := {"ok": false, "report": report}
	var idx := sinks_of(p_graph)
	if idx.is_empty():
		report["reason"] = "this graph contains no export sinks"
		return fail
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		report["reason"] = "this build has no graph_eval_grid_taps"
		return fail
	if p_base_path.strip_edges().is_empty():
		report["reason"] = "no base path was given"
		return fail
	report["total"] = idx.size()
	report["ok"] = true
	return {"ok": true, "report": report, "plan": idx, "graph": p_graph, "terrain": p_terrain,
			"base": p_base_path}


## Export one sink. Never throws on a bad sink: it is named in `skipped` and the run continues, because a
## batch that aborted on the first misconfigured node would make the other four unreachable.
static func export_step(p_ctx: Dictionary, p_index: int) -> void:
	var report: Dictionary = p_ctx["report"]
	var graph = p_ctx["graph"]
	var ni: int = int(p_ctx["plan"][p_index])
	var sink: Pasture3DGraphNodeExportSink = graph.nodes[ni]
	var label := _label_of(sink, ni)

	var warn := sink.sink_warnings()
	if not warn.is_empty():
		for w in warn:
			report["skipped"].append("%s: %s" % [label, w])
		return

	# The `normal` port's refusal (§9.2). Checked here rather than in `sink_warnings` because it is a
	# fact about the GRAPH — whether a wire exists — and a node cannot see its own connections.
	if sink is Pasture3DGraphNodeExportNormalMap and not source_of(graph, ni, 1).is_empty():
		report["skipped"].append(("%s: the `normal` port is wired, and the program cannot carry a vector "
				+ "grid yet. Refused rather than deriving from `height` and calling it yours — unwire it "
				+ "to export the derived map.") % label)
		return

	var tapped := _tap(graph, sink, ni, p_ctx["terrain"])
	if tapped.has("error"):
		report["skipped"].append("%s: %s" % [label, tapped["error"]])
		return

	var path: String = _join(String(p_ctx["base"]), sink.filename)
	var wrote := _write(sink, path, tapped["fields"])
	if wrote.has("error"):
		report["skipped"].append("%s: %s" % [label, wrote["error"]])
		return
	var files: PackedStringArray = report["files"]
	files.append(path)
	report["files"] = files
	report["written"] = int(report["written"]) + 1


## Mark a run cancelled. The remaining sinks are simply not stepped — §9.2's "a cancelled export leaves
## the graph untouched" is free, because no step ever touched it. Criterion [D] asserts the remainder are
## unwritten AND that the report says so, which is why this sets a flag rather than just returning.
static func export_cancel(p_ctx: Dictionary) -> void:
	p_ctx["report"]["cancelled"] = true


## Close the run and return the report.
static func export_finish(p_ctx: Dictionary) -> Dictionary:
	var report: Dictionary = p_ctx["report"]
	var files: PackedStringArray = report["files"]
	print("Pasture3D graph export %s — %d of %d sink(s): %s"
			% ["CANCELLED" if bool(report["cancelled"]) else "done", int(report["written"]),
				int(report["total"]), ", ".join(files) if files.size() > 0 else "(nothing written)"])
	for msg in report["skipped"]:
		push_warning("Pasture3D graph export: %s" % msg)
	return report


static func _label_of(p_sink, p_index: int) -> String:
	var nm: String = p_sink.resource_name
	return nm if nm != "" else "%s #%d" % [p_sink.op(), p_index]


static func _join(p_base: String, p_leaf: String) -> String:
	if p_base.ends_with("/"):
		return p_base + p_leaf
	return p_base + "/" + p_leaf


## Tap every source port of one sink in a SINGLE multi-root pass. Returns {"fields": Array} — one entry
## per `source_ports()` position, each a PackedFloat32Array of `res*res` cells or an empty array for an
## unwired channel — or {"error": String}.
static func _tap(p_graph, p_sink, p_index: int, p_terrain) -> Dictionary:
	var res: int = p_sink.resolution
	var rect: Rect2 = p_sink.world_rect
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return {"error": "the world rect is %s, which has no area" % rect}

	var ports: PackedInt32Array = p_sink.source_ports()
	var roots: Array = []
	var src_of := {} # port -> {"node","port"}
	for port in ports:
		var src := source_of(p_graph, p_index, port)
		if src.is_empty():
			continue
		src_of[port] = src
		if not roots.has(int(src["node"])):
			roots.append(int(src["node"]))
	if roots.is_empty():
		# Every source port unwired. Refused rather than writing a black image: a file full of zeros is
		# indistinguishable from a field that happens to be zero, which is §4.4 exactly.
		return {"error": "no source port is wired, so there is nothing to write"}

	var compiled: Dictionary = p_graph.compile_graph_program_multi(roots)
	if compiled.is_empty():
		return {"error": "the graph does not lower, so its slots cannot be tapped"}
	var slot_of: Dictionary = compiled["slot_of"]
	var slots := PackedInt32Array()
	var chans := PackedInt32Array()
	var order: Array = [] # request index -> position within source_ports()
	for i in range(ports.size()):
		var port: int = ports[i]
		if not src_of.has(port):
			continue
		var src: Dictionary = src_of[port]
		if not slot_of.has(int(src["node"])):
			continue
		order.append(i)
		slots.append(int(slot_of[int(src["node"])]))
		chans.append(int(src["port"]))
	if order.is_empty():
		return {"error": "no wired port compiled to a slot"}

	var input := _input_surface(p_terrain, res, rect)
	var result: Dictionary = Pasture3DUtil.graph_eval_grid_taps(compiled["program"], res, res, rect,
			input, slots, chans)
	tap_count += 1
	var unserved: PackedInt32Array = result.get("unserved", PackedInt32Array())
	var got: Array = result.get("fields", [])

	var fields: Array = []
	for _i in range(ports.size()):
		fields.append(PackedFloat32Array())
	for r in range(order.size()):
		if unserved.has(r) or r >= got.size() or not (got[r] is PackedFloat32Array):
			# §4.4: an unserved channel is not zeros. A sink whose ONLY port went unserved is refused
			# below; a splat channel that did is left empty, which reads as "none of this layer" — and
			# `sink_warnings` has already named it.
			continue
		var f: PackedFloat32Array = got[r]
		if f.size() == res * res:
			fields[int(order[r])] = f
	var any := false
	for f in fields:
		if (f as PackedFloat32Array).size() > 0:
			any = true
			break
	if not any:
		return {"error": "no wired channel was served by this graph"}
	return {"fields": fields}


## The absolute surface the graph reads. The terrain's current heights where there is a terrain, zeros
## otherwise — an export is not a bake, so there is no in-flight field to inherit.
static func _input_surface(p_terrain, p_res: int, p_rect: Rect2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_res * p_res)
	if p_terrain == null or p_terrain.data == null:
		return out
	var data = p_terrain.data
	for iz in range(p_res):
		var wz: float = p_rect.position.y + (float(iz) + 0.5) * p_rect.size.y / float(p_res)
		var row := iz * p_res
		for ix in range(p_res):
			var wx: float = p_rect.position.x + (float(ix) + 0.5) * p_rect.size.x / float(p_res)
			var h: float = data.get_height(Vector3(wx, 0.0, wz))
			out[row + ix] = 0.0 if is_nan(h) else h
	return out


## Write one sink's tapped fields. Returns {"path", "range_min", "range_max"} or {"error": String}.
static func _write(p_sink, p_path: String, p_fields: Array) -> Dictionary:
	var res: int = p_sink.resolution
	var fmt: String = p_sink.format
	var primary: PackedFloat32Array = p_fields[0]

	var dir := p_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	# The calibration pair, decided ONCE here and recorded verbatim in the sidecar. Everything below
	# quantises against these numbers; nothing recomputes them.
	var lo: float = p_sink.range_min
	var hi: float = p_sink.range_max
	if p_sink.range_mode == Pasture3DGraphNodeExportSink.RangeMode.AUTO and primary.size() > 0:
		lo = primary[0]
		hi = primary[0]
		for v in primary:
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if hi <= lo:
		hi = lo + 1.0 # A constant field is legal; a zero divisor is not.

	var extra := {}
	var err := OK
	match fmt:
		"exr":
			err = _write_exr(p_path, res, p_fields, p_sink.channels())
		"r16":
			err = _write_r16(p_path, res, primary, lo, hi)
		"png8", "png16":
			var depth: int = 8 if fmt == "png8" else 16
			var samples: PackedFloat32Array
			if p_sink is Pasture3DGraphNodeExportNormalMap:
				samples = _derive_normals(primary, res, p_sink.world_rect, p_sink.normal_strength)
				extra["metres_per_cell"] = p_sink.world_rect.size.x / float(res)
				extra["encoding"] = "tangent-space XYZ mapped by v * 0.5 + 0.5; A unused"
			elif p_sink.is_index_map():
				# Never scaled. See the node's header — index 7 must come back as index 7.
				samples = PackedFloat32Array()
				samples.resize(res * res)
				var top: float = 255.0 if depth == 8 else 65535.0
				for i in range(res * res):
					samples[i] = clampf(round(primary[i]), 0.0, top) / top
				lo = 0.0
				hi = top
				extra["nearest_only"] = ("These are indices, not quantities. Read this file with NEAREST "
						+ "sampling and no mipmaps: an interpolated index map produces materials that "
						+ "exist nowhere in the graph, at every boundary between two that do.")
			elif p_sink.channels() == 4:
				samples = _pack_rgba(p_fields, res, lo, hi)
			else:
				samples = _normalise(primary, lo, hi)
			var bytes := Pasture3DGraphPng.encode(samples, res, res, p_sink.channels(), depth)
			if bytes.is_empty():
				return {"error": "the PNG encoder refused %dx%d at %d channels" % [res, res, p_sink.channels()]}
			err = _store(p_path, bytes)
		_:
			return {"error": "format '%s' has no writer" % fmt}
	if err != OK:
		return {"error": "the writer returned error %d for '%s'" % [err, p_path]}

	var sidecar := {"file": p_path.get_file(), "format": fmt, "resolution": res,
			"world_rect": [p_sink.world_rect.position.x, p_sink.world_rect.position.y,
				p_sink.world_rect.size.x, p_sink.world_rect.size.y],
			"range_min": lo, "range_max": hi,
			"range_mode": "auto" if p_sink.range_mode == Pasture3DGraphNodeExportSink.RangeMode.AUTO \
					else "explicit",
			"decode": "value = range_min + sample * (range_max - range_min)"}
	sidecar.merge(extra)
	_store(p_path + SIDECAR_SUFFIX, JSON.stringify(sidecar, "\t").to_utf8_buffer())
	write_count += 1
	return {"path": p_path, "range_min": lo, "range_max": hi}


static func _store(p_path: String, p_bytes: PackedByteArray) -> int:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(p_bytes)
	f.close()
	return OK


static func _normalise(p_field: PackedFloat32Array, p_lo: float, p_hi: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_field.size())
	var inv: float = 1.0 / (p_hi - p_lo)
	for i in range(p_field.size()):
		out[i] = clampf((p_field[i] - p_lo) * inv, 0.0, 1.0)
	return out


## Interleave up to four fields into RGBA. An unwired channel contributes zero — see the Splat node's
## header for why that is the declared answer here and an impostor everywhere else.
static func _pack_rgba(p_fields: Array, p_res: int, p_lo: float, p_hi: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_res * p_res * 4)
	var inv: float = 1.0 / (p_hi - p_lo)
	for c in range(4):
		var f: PackedFloat32Array = p_fields[c] if c < p_fields.size() else PackedFloat32Array()
		if f.size() != p_res * p_res:
			continue
		for i in range(p_res * p_res):
			out[i * 4 + c] = clampf((f[i] - p_lo) * inv, 0.0, 1.0)
	return out


## Central-difference normals in metres, encoded XYZ -> RGB by v * 0.5 + 0.5. The A channel is written
## opaque; a normal map's alpha carries nothing here and leaving it zero makes the file look empty in
## every viewer that respects it.
static func _derive_normals(p_height: PackedFloat32Array, p_res: int, p_rect: Rect2,
		p_strength: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_res * p_res * 4)
	var dx: float = p_rect.size.x / float(p_res)
	var dz: float = p_rect.size.y / float(p_res)
	for z in range(p_res):
		for x in range(p_res):
			var xm: int = maxi(x - 1, 0)
			var xp: int = mini(x + 1, p_res - 1)
			var zm: int = maxi(z - 1, 0)
			var zp: int = mini(z + 1, p_res - 1)
			# Divided by the ACTUAL span, so an edge cell (where one neighbour is itself) is a one-sided
			# difference and not a halved gradient.
			var gx: float = (p_height[z * p_res + xp] - p_height[z * p_res + xm]) / (float(xp - xm) * dx)
			var gz: float = (p_height[zp * p_res + x] - p_height[zm * p_res + x]) / (float(zp - zm) * dz)
			var n := Vector3(-gx * p_strength, 1.0, -gz * p_strength).normalized()
			var o := (z * p_res + x) * 4
			out[o] = n.x * 0.5 + 0.5
			out[o + 1] = n.z * 0.5 + 0.5
			out[o + 2] = n.y * 0.5 + 0.5
			out[o + 3] = 1.0
	return out


## EXR carries floats, so the field goes in unscaled and the sidecar's range is a readout rather than a
## divisor. That asymmetry is the reason the sidecar is written for every format including this one: a
## consumer reading it mechanically must not have to know which formats quantise.
static func _write_exr(p_path: String, p_res: int, p_fields: Array, p_channels: int) -> int:
	var img: Image
	if p_channels == 4:
		img = Image.create_empty(p_res, p_res, false, Image.FORMAT_RGBAF)
		for z in range(p_res):
			for x in range(p_res):
				var c := Color(0, 0, 0, 1)
				for ch in range(4):
					var f: PackedFloat32Array = p_fields[ch] if ch < p_fields.size() \
							else PackedFloat32Array()
					if f.size() == p_res * p_res:
						c[ch] = f[z * p_res + x]
				img.set_pixel(x, z, c)
	else:
		img = Image.create_empty(p_res, p_res, false, Image.FORMAT_RF)
		var f: PackedFloat32Array = p_fields[0]
		for z in range(p_res):
			for x in range(p_res):
				img.set_pixel(x, z, Color(f[z * p_res + x], 0, 0, 1))
	return img.save_exr(p_path, p_channels != 4)


## 16-bit little-endian raw, the shape `Pasture3DData::_save_export_image` writes for r16/raw. The range
## goes to the sidecar rather than to the console, which is the one thing that function does not do and
## the reason `calibration-constants-must-be-stored-not-printed` exists.
static func _write_r16(p_path: String, p_res: int, p_field: PackedFloat32Array, p_lo: float,
		p_hi: float) -> int:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var scale: float = 65535.0 / (p_hi - p_lo)
	for i in range(p_res * p_res):
		f.store_16(clampi(int((p_field[i] - p_lo) * scale), 0, 65535))
	f.close()
	return OK
