extends Node
## W1 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.1): the shipped sea states are built-ins, not saved copies.
##
## Criteria, each with a control that must fail:
##   [S] A fresh manager saves no profiles. Control: a tuned override IS saved, and reloads tuned.
##   [M] sculpting_2's stale copies (bench/fixtures/stale_water_presets.tscn) load as the built-ins.
##       Control: the fixture's tuned pond_still and its own my_sea survive the load.
##       Witness: the stale lake's stored cascades differ from the built-in's, so [M] can see a swap.
##   [C] A saved copy of the CURRENT built-in is dropped. Control: the same copy with one knob moved is kept.
##   [O] override_builtin() copies deeply: tuning the copy leaves the built-in alone; a non-built-in is null.
##   [L] A pre-Phase-6 copy (only the Gerstner keys, at the retired preset's values, as big_regions.tscn
##       holds) is dropped. Control: the same keys with the amplitude moved are an artist's, and kept.
## Runs headless or windowed:
##   Godot --headless --path project res://bench/WaterBuiltinPresetsGate.tscn

const FIXTURE := "res://bench/fixtures/stale_water_presets.tscn"
const STOCK := ["ocean_default", "ocean_choppy", "lake_calm", "pond_still", "river_flow"]
const CRITERIA := 5

var _failures := 0
var _completed := 0


func _ready() -> void:
	print("=== WaterBuiltinPresetsGate ===")
	_criterion_s()
	_criterion_m()
	_criterion_c()
	_criterion_o()
	_criterion_l()
	if _completed != CRITERIA:
		_fail("only %d of %d criteria ran to the end" % [_completed, CRITERIA])
	print("=== BUILT-IN PRESETS %s (%d failures, %d/%d criteria) ===" % [
		"PASS" if _failures == 0 else "FAIL", _failures, _completed, CRITERIA])
	get_tree().quit(0 if _failures == 0 else 1)


func _fail(p_msg: String) -> void:
	_failures += 1
	printerr("  FAIL ", p_msg)


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["ok  " if p_ok else "FAIL", p_msg])
	if not p_ok:
		_failures += 1


## The names a packed scene stores for its root node.
func _stored_names(p_node: Node) -> PackedStringArray:
	var ps := PackedScene.new()
	ps.pack(p_node)
	var st := ps.get_state()
	var names := PackedStringArray()
	for i in st.get_node_property_count(0):
		names.append(st.get_node_property_name(0, i))
	return names


func _builtin(p_m: Pasture3DPoolManager, p_name: String) -> Pasture3DWaveProfile:
	for p in p_m.get_builtin_profiles():
		if p.profile_name == StringName(p_name):
			return p
	return null


func _criterion_s() -> void:
	print("[S] a fresh manager saves no profiles")
	var m := Pasture3DPoolManager.new()
	var names := m.get_profile_names()
	for n in STOCK:
		_check(names.has(n), "fresh manager answers '%s'" % n)
	_check(m.profiles.is_empty(), "fresh manager's own profiles are empty (%d)" % m.profiles.size())
	var stored := _stored_names(m)
	_check(not stored.has("profiles"), "packed fresh manager stores: %s" % [stored])

	# Control: a tuned override is saved, and comes back tuned.
	var o := m.override_builtin(&"lake_calm")
	o.fft.foam_bias = 0.37
	stored = _stored_names(m)
	_check(stored.has("profiles"), "CONTROL packed manager with a tuned override stores profiles")
	var ps := PackedScene.new()
	ps.pack(m)
	var back := ps.instantiate() as Pasture3DPoolManager
	var lake := back.get_profile(&"lake_calm")
	_check(back.profiles.size() == 1 and lake != _builtin(back, "lake_calm"),
		"CONTROL reloaded override is the scene's own, not the built-in")
	_check(lake != null and is_equal_approx(lake.fft.foam_bias, 0.37),
		"CONTROL reloaded override keeps foam_bias 0.37 (%s)" % [lake.fft.foam_bias if lake else "null"])
	back.free()
	m.free()
	_completed += 1


func _criterion_m() -> void:
	print("[M] sculpting_2's stale copies load as the built-ins")
	# The witness first, from the file itself, before any manager filters it.
	var raw_lake_lengths := Vector4.ZERO
	var text := FileAccess.get_file_as_string(FIXTURE)
	var at := text.find("cascade_lengths = Vector4(91.")
	_check(at >= 0, "WITNESS fixture stores the stale lake's 91 m cascade")
	var fresh := Pasture3DPoolManager.new()
	var built_lake := _builtin(fresh, "lake_calm").fft.cascade_lengths
	raw_lake_lengths = Vector4(91.240875, 15.510949, 2.919708, 0.729927)
	_check(not built_lake.is_equal_approx(raw_lake_lengths),
		"WITNESS built-in lake cascades %s differ from the stale %s" % [built_lake, raw_lake_lengths])
	fresh.free()

	var m := (load(FIXTURE) as PackedScene).instantiate() as Pasture3DPoolManager
	var own := PackedStringArray()
	for p in m.profiles:
		own.append(p.profile_name)
	print("  own profiles after load: ", own)
	for n in ["ocean_default", "lake_calm", "river_flow"]:
		_check(not own.has(n), "stale '%s' dropped from the scene's profiles" % n)
		_check(m.get_profile(StringName(n)) == _builtin(m, n), "'%s' resolves to the built-in" % n)
	_check(m.get_profile(&"lake_calm").fft.cascade_lengths.is_equal_approx(built_lake),
		"lake_calm draws the built-in's cascades %s" % [m.get_profile(&"lake_calm").fft.cascade_lengths])

	# Control: a tuned stock name and the scene's own profile survive.
	var pond := m.get_profile(&"pond_still")
	_check(own.has("pond_still") and pond != _builtin(m, "pond_still"), "CONTROL tuned pond_still kept as an override")
	_check(pond != null and is_equal_approx(pond.fft.get("spectrum_1/wind_speed"), 3.5),
		"CONTROL override's wind 3.5 m/s (%s)" % [pond.fft.get("spectrum_1/wind_speed") if pond else "null"])
	_check(own.has("my_sea") and m.get_profile(&"my_sea") != null, "CONTROL the scene's own my_sea kept")
	# Every built-in plus the fixture's my_sea; the stock names it overrides are not extra.
	var want := m.get_builtin_profile_names().size() + 1
	_check(m.get_profile_names().size() == want, "%d names answer (%s)" % [want, m.get_profile_names()])
	m.free()
	_completed += 1


func _criterion_c() -> void:
	print("[C] a saved copy of the current built-in is dropped")
	var m := Pasture3DPoolManager.new()
	for n in STOCK:
		var copy := _builtin(m, n).duplicate(true) as Pasture3DWaveProfile
		var arr: Array[Pasture3DWaveProfile] = [copy]
		m.profiles = arr
		_check(m.profiles.is_empty(), "exact copy of '%s' dropped" % n)
		_check(m.get_profile(StringName(n)) == _builtin(m, n), "'%s' answers the built-in" % n)
	# Control: one knob moved makes it an override.
	var tuned := _builtin(m, "lake_calm").duplicate(true) as Pasture3DWaveProfile
	tuned.fft.choppiness += 0.25
	var arr2: Array[Pasture3DWaveProfile] = [tuned]
	m.profiles = arr2
	_check(m.profiles.size() == 1 and m.get_profile(&"lake_calm") == tuned,
		"CONTROL copy with choppiness moved is kept and answers")
	# Control: the fBm alone moved is also a deliberate edit.
	var tuned_fbm := _builtin(m, "pond_still").duplicate(true) as Pasture3DWaveProfile
	tuned_fbm.min_wavelength += 1.0
	var arr3: Array[Pasture3DWaveProfile] = [tuned_fbm]
	m.profiles = arr3
	_check(m.profiles.size() == 1, "CONTROL copy with min_wavelength moved is kept")
	m.free()
	_completed += 1


func _criterion_o() -> void:
	print("[O] override_builtin copies deeply")
	var m := Pasture3DPoolManager.new()
	var b := _builtin(m, "river_flow")
	var before := b.fft.foam_bias
	var o := m.override_builtin(&"river_flow")
	_check(o != null and o != b and o.fft != b.fft and o.fbm != b.fbm, "override has its own FFT and fBm")
	_check(Pasture3DPoolManager.profiles_store_same_knobs(o, b), "override starts equal to the built-in")
	_check(m.override_builtin(&"river_flow") == o, "a second call returns the same override")
	o.fft.foam_bias = before + 0.5
	_check(is_equal_approx(b.fft.foam_bias, before), "tuning the override leaves the built-in's foam_bias")
	_check(m.get_profile(&"river_flow") == o, "the name answers the override")
	# Control: the comparison can tell them apart once tuned.
	_check(not Pasture3DPoolManager.profiles_store_same_knobs(o, b), "CONTROL tuned override no longer equals the built-in")
	_check(m.override_builtin(&"not_a_preset") == null, "a name that is not a built-in gives null")
	m.free()
	_completed += 1


# The retired Gerstner presets, as _seed_default_profiles() seeded them until Phase 6 (f47e8f3e).
const RETIRED := {
	"ocean_default": {"direction_deg": 20.0, "spread_deg": 28.0},
	"lake_calm": {"wave_count": 4, "direction_deg": 35.0, "spread_deg": 40.0, "amplitude": 0.25, "length_max": 25.0, "steepness": 0.25},
	"pond_still": {"wave_count": 2, "direction_deg": 55.0, "spread_deg": 50.0, "amplitude": 0.05, "length_max": 12.0, "steepness": 0.15},
	"river_flow": {"wave_count": 3, "spread_deg": 10.0, "amplitude": 0.06, "length_max": 10.0, "steepness": 0.12},
}


## A profile as a scene saved before Phase 6 loads it: the name, then only the keys the scene stored.
func _legacy(p_name: String, p_keys: Dictionary) -> Pasture3DWaveProfile:
	var p := Pasture3DWaveProfile.new()
	p.profile_name = StringName(p_name)
	for k in p_keys:
		p.set(k, p_keys[k])
	return p


func _criterion_l() -> void:
	print("[L] pre-Phase-6 copies of the retired Gerstner presets are dropped")
	var m := Pasture3DPoolManager.new()
	var arr: Array[Pasture3DWaveProfile] = []
	for n in RETIRED:
		var p := _legacy(n, RETIRED[n])
		# Witness: the legacy fit gave it a spectrum, so only the legacy test can recognise it.
		_check(not p.is_fft_authored() and not Pasture3DPoolManager.profiles_store_same_knobs(p, _builtin(m, n)),
			"WITNESS legacy '%s' is unauthored and differs from the built-in" % n)
		arr.append(p)
	m.profiles = arr
	_check(m.profiles.is_empty(), "all four retired copies dropped (%d left)" % m.profiles.size())
	for n in RETIRED:
		_check(m.get_profile(StringName(n)) == _builtin(m, n), "'%s' answers the built-in" % n)
	# Control: an artist's Gerstner lake, amplitude moved.
	var keys: Dictionary = RETIRED["lake_calm"].duplicate()
	keys["amplitude"] = 0.4
	var tuned := _legacy("lake_calm", keys)
	var arr2: Array[Pasture3DWaveProfile] = [tuned]
	m.profiles = arr2
	_check(m.profiles.size() == 1 and m.get_profile(&"lake_calm") == tuned, "CONTROL tuned Gerstner lake kept")
	# Control: the retired ocean's keys under a name that is not a built-in are the scene's own.
	var mine := _legacy("my_old_sea", RETIRED["ocean_default"])
	var arr3: Array[Pasture3DWaveProfile] = [mine]
	m.profiles = arr3
	_check(m.profiles.size() == 1, "CONTROL retired keys under another name kept")
	m.free()
	_completed += 1
