# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDLANativeParityGate — the C++ DLA growth (Pasture3DUtil.dla_grow_field) reproduces the GDScript
# growth (Pasture3DReliefDLA.grow_into) exactly.
#
# The growth history is six bugs that each produced a plausible mountain, so "looks like a massif" is not
# evidence of anything. The port is held to the script bit for bit instead:
#   [R] the port's random stream equals the engine's RandomNumberGenerator, draw for draw (randi, randf,
#       randfn) over several seeds. Control: the next seed's stream differs.
#   [G] the grown field, its grid size and its crop dims are identical across configurations that walk
#       every branch: small and default grids, a non-square loop, zero wander, a profile power, and ridge
#       seeding from a surface. Control: the next seed's field differs by far more than the parity bound.
extends Node

const ReliefDLA = preload("res://addons/pasture_3d/connectors/pasture3d_relief_dla.gd")

var _fail := 0
var _done := 0


func _ready() -> void:
	print("=== GraphDLANativeParityGate: C++ DLA growth equals the GDScript growth ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "dla_grow_field"):
		print("!! Pasture3DUtil.dla_grow_field is not bound; rebuild the extension")
		get_tree().quit(1)
		return
	# `-- --only=R` or `--only=G` runs one criterion; the completion count only binds a full run.
	var only := "RG"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	if only.contains("R"):
		_r_rng_stream()
	if only.contains("G"):
		_g_growth_parity()
	if only == "RG" and _done != 2:
		_fail += 1
		print("\n!! only %d of 2 criteria reached their assertion" % _done)
	print("\n=== %s (%d failures) ===\n" % ["GRAPH DLA NATIVE PARITY PASS" if _fail == 0 else "GRAPH DLA NATIVE PARITY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_msg: String) -> void:
	_done += 1
	if not p_ok:
		_fail += 1
		print("    !! " + p_msg)


# ---- [R] ---------------------------------------------------------------------------------------------

func _r_rng_stream() -> void:
	print("[R] the port's PCG stream equals RandomNumberGenerator, draw for draw")
	const ROUNDS := 4000
	const DEV := 0.24
	var all_ok := true
	var control_differs := true
	for s in [0, 1, -7, 123456789012]:
		var port: PackedFloat64Array = Pasture3DUtil.dla_rng_probe(s, ROUNDS, DEV)
		var eng := _engine_stream(s, ROUNDS, DEV)
		var bad := [0, 0, 0]
		var first := -1
		for i in range(ROUNDS * 3):
			if port[i] != eng[i]:
				bad[i % 3] += 1
				if first < 0:
					first = i
		var ctrl := _engine_stream(s + 1, ROUNDS, DEV)
		var same_as_next := 0
		for i in range(ROUNDS * 3):
			if port[i] == ctrl[i]:
				same_as_next += 1
		print("    seed %-13d mismatches randi=%d randf=%d randfn=%d (first at %d) | control: %d of %d equal to seed+1"
			% [s, bad[0], bad[1], bad[2], first, same_as_next, ROUNDS * 3])
		if first >= 0:
			all_ok = false
			print("      first mismatch at %d: port=%.12f engine=%.12f" % [first, port[first], eng[first]])
		if same_as_next > ROUNDS: # a third would already be suspicious; any real stream shares ~none
			control_differs = false
	_check(all_ok and control_differs, "the port's random stream does not reproduce RandomNumberGenerator")



func _engine_stream(p_seed: int, p_rounds: int, p_dev: float) -> PackedFloat64Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var out := PackedFloat64Array()
	out.resize(p_rounds * 3)
	for i in range(p_rounds):
		out[i * 3] = float(rng.randi())
		out[i * 3 + 1] = rng.randf()
		out[i * 3 + 2] = rng.randfn(0.0, p_dev)
	return out


# ---- [G] ---------------------------------------------------------------------------------------------

func _g_growth_parity() -> void:
	print("\n[G] the grown field is identical, config by config")
	var configs := [
		{"name": "small 64/3", "resolution": 64, "hierarchy_levels": 3, "blur_levels": 4, "coverage": 0.9},
		{"name": "default 256/4", "resolution": 256},
		{"name": "non-square 3:1", "resolution": 128, "hierarchy_levels": 3, "host_ex": 150.0, "host_ez": 50.0},
		{"name": "no wander, power 2", "resolution": 128, "hierarchy_levels": 3, "wander": 0.0, "profile_power": 2.0, "seed": 17},
		{"name": "coarse detail 0.4", "resolution": 128, "detail_size": 0.4, "blur_growth": 0.8, "seed": -3},
		{"name": "ridge seeded", "resolution": 128, "hierarchy_levels": 3, "ridge_seeding": true, "ridge_amount": 0.1, "seeded": true},
	]
	var all_ok := true
	for cfg in configs:
		var eng := _engine_for(cfg)
		var st := {}
		eng.grow_into(st)
		var native: Dictionary = Pasture3DUtil.dla_grow_field(_params_for(cfg))
		var ef: PackedFloat32Array = st["field"]
		var nf: PackedFloat32Array = native["field"]
		var diff := _diff(ef, nf)
		var shape_ok: bool = int(native["n"]) == int(st["n"]) and Vector2i(native["dims"]) == Vector2i(st["dims"]) and ef.size() == nf.size()
		var grew := _max(ef) > 0.5
		var ok: bool = shape_ok and grew and diff[1] == 0
		print("    %-20s n=%d dims=%s | cells differing=%d max diff=%.6f | grew=%s%s"
			% [cfg["name"], int(st["n"]), st["dims"], diff[1], diff[0], grew, "" if ok else "  <-- MISMATCH"])
		if not ok:
			all_ok = false
		# CONTROL: the same config at the next seed must differ, or equality above could mean the field is
		# insensitive to the stream (for instance, an empty growth).
		var cfg2: Dictionary = cfg.duplicate()
		cfg2["seed"] = int(cfg.get("seed", 0)) + 1
		var other: Dictionary = Pasture3DUtil.dla_grow_field(_params_for(cfg2))
		var cd := _diff(ef, other["field"])
		print("      control: seed+1 differs in %d cells, max %.3f" % [cd[1], cd[0]])
		if cd[0] < 0.05:
			all_ok = false
			print("      !! the next seed grew (nearly) the same field; parity above proves nothing")
	_check(all_ok, "the native growth diverged from the GDScript growth")


func _engine_for(p_cfg: Dictionary) -> Object:
	var e = ReliefDLA.new()
	var pp := _params_for(p_cfg)
	for k in ["coverage", "resolution", "hierarchy_levels", "detail_size", "wander", "seed", "blur_levels",
			"blur_growth", "profile_power", "ridge_seeding", "ridge_amount"]:
		e.set(k, pp[k])
	e._host_ex = pp["host_ex"]
	e._host_ez = pp["host_ez"]
	if pp.has("seed_surface"):
		e._seed = {"surface": pp["seed_surface"], "gw": pp["seed_gw"], "gh": pp["seed_gh"], "frame": pp["frame"]}
		e._seed_hash = hash(pp["seed_surface"])
	return e


## One place builds the parameter set, so the engine and the port cannot be handed different values.
func _params_for(p_cfg: Dictionary) -> Dictionary:
	var pp := {
		"seed": int(p_cfg.get("seed", 0)),
		"resolution": int(p_cfg.get("resolution", 256)),
		"hierarchy_levels": int(p_cfg.get("hierarchy_levels", 4)),
		"detail_size": float(p_cfg.get("detail_size", 0.12)),
		"wander": float(p_cfg.get("wander", 0.32)),
		"blur_levels": int(p_cfg.get("blur_levels", 5)),
		"blur_growth": float(p_cfg.get("blur_growth", 1.6)),
		"profile_power": float(p_cfg.get("profile_power", 1.0)),
		"coverage": float(p_cfg.get("coverage", 0.95)),
		"ridge_seeding": bool(p_cfg.get("ridge_seeding", false)),
		"ridge_amount": float(p_cfg.get("ridge_amount", 0.05)),
		"host_ex": float(p_cfg.get("host_ex", 100.0)),
		"host_ez": float(p_cfg.get("host_ez", 100.0)),
	}
	if bool(p_cfg.get("seeded", false)):
		const GW := 64
		const GH := 64
		var rect := Rect2(-100.0, -100.0, 200.0, 200.0)
		var s := PackedFloat32Array()
		s.resize(GW * GH)
		for iz in range(GH):
			for ix in range(GW):
				s[iz * GW + ix] = 20.0 * absf(sin(float(ix) / float(GW - 1) * TAU * 1.5)) + 3.0 * cos(float(iz) * 0.3)
		var dx := rect.size.x / float(GW)
		var dz := rect.size.y / float(GH)
		var ex := rect.size.x * 0.5
		var ez := rect.size.y * 0.5
		pp["seed_surface"] = s
		pp["seed_gw"] = GW
		pp["seed_gh"] = GH
		pp["frame"] = [rect.position.x + ex, rect.position.y + ez, 1.0, 0.0, ex, ez,
				rect.position.x + 0.5 * dx, rect.position.y + 0.5 * dz, dx]
	return pp


## [max abs diff, cells differing]. A NaN on either side counts as differing.
func _diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> Array:
	if p_a.size() != p_b.size():
		return [INF, maxi(p_a.size(), p_b.size())]
	var m := 0.0
	var c := 0
	for i in range(p_a.size()):
		if p_a[i] != p_b[i]:
			c += 1
			var d := absf(p_a[i] - p_b[i])
			m = maxf(m, d if is_finite(d) else INF)
	return [m, c]


func _max(p_a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_a:
		m = maxf(m, v)
	return m
