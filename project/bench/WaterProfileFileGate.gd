extends Node
## Wave profiles tuned in the editor and saved for reuse (wave_profile_row.gd, the Wave Profiles row on a
## Pasture3DPoolManager's Inspector).
##
## Criteria, each with a control that must fail:
##   [K] "Edit a copy" sticks: an override_builtin() copy, untouched, survives an array reassignment and a
##       pack/instantiate. Control: the same copy without its mark is dropped, as a stale copy.
##   [F] A file round-trips: a tuned override saved with save_to_file() loads into a fresh manager, answers
##       its name with the tuned knobs, and carries its FFT and fBm in the file. A file equal to the
##       built-in is kept too. Control: that profile's pathless, unmarked duplicate is dropped.
##   [P] A scene references the file: packing a manager that holds it stores an ext_resource, not a copy.
##       Control: an embedded override packs as a sub_resource.
##   [H] The row's helpers: source_of() names each source; profiles_with() replaces by name in place;
##       profiles_without() removes by name.
##   [B] The line under a body's `wave_profile`: manager_for() takes a pool's explicit manager over the
##       scene's, and the scene's for an ocean; the buttons follow the profile's source; the line rebuilds
##       when the source or the name changes. Controls: before the poll runs, the line still shows the
##       old buttons; with no manager in the tree it offers none.
## Runs headless:
##   Godot --headless --path project res://bench/WaterProfileFileGate.tscn

const Row = preload("res://addons/pasture_3d/src/wave_profile_row.gd")
const DIR := "user://wave_profile_gate/"
const CRITERIA := 5

var _failures := 0
var _completed := 0


func _ready() -> void:
	print("=== WaterProfileFileGate ===")
	DirAccess.make_dir_recursive_absolute(DIR)
	_criterion_k()
	_criterion_f()
	_criterion_p()
	_criterion_h()
	_criterion_b()
	if _completed != CRITERIA:
		_fail("only %d of %d criteria ran to the end" % [_completed, CRITERIA])
	print("=== WAVE PROFILE FILES %s (%d failures, %d/%d criteria) ===" % [
		"PASS" if _failures == 0 else "FAIL", _failures, _completed, CRITERIA])
	get_tree().quit(0 if _failures == 0 else 1)


func _fail(p_msg: String) -> void:
	_failures += 1
	printerr("  FAIL ", p_msg)


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["ok  " if p_ok else "FAIL", p_msg])
	if not p_ok:
		_failures += 1


func _builtin(p_m: Pasture3DPoolManager, p_name: String) -> Pasture3DWaveProfile:
	for p in p_m.get_builtin_profiles():
		if p.profile_name == StringName(p_name):
			return p
	return null


func _criterion_k() -> void:
	print("[K] an untouched copy from Edit a copy sticks")
	var m := Pasture3DPoolManager.new()
	var o := m.override_builtin(&"ocean_default")
	_check(o != null and Pasture3DPoolManager.profiles_store_same_knobs(o, _builtin(m, "ocean_default")),
		"WITNESS the copy equals the built-in")
	m.profiles = m.profiles.duplicate()
	_check(m.profiles.size() == 1 and m.get_profile(&"ocean_default") == o, "survives an array reassignment")
	var ps := PackedScene.new()
	ps.pack(m)
	var back := ps.instantiate() as Pasture3DPoolManager
	_check(back.profiles.size() == 1 and back.get_profile(&"ocean_default") != _builtin(back, "ocean_default"),
		"survives pack and instantiate as the scene's own")
	back.free()
	# Control: without the mark it is a stale copy.
	var bare := o.duplicate(true) as Pasture3DWaveProfile
	bare.remove_meta(&"pasture3d_override")
	var arr: Array[Pasture3DWaveProfile] = [bare]
	m.profiles = arr
	_check(m.profiles.is_empty(), "CONTROL the same copy unmarked is dropped")
	m.free()
	_completed += 1


func _criterion_f() -> void:
	print("[F] a tuned profile round-trips through a file")
	var m := Pasture3DPoolManager.new()
	var o := m.override_builtin(&"lake_calm")
	o.fft.foam_bias = 0.33
	o.fft.set("spectrum_1/wind_speed", 4.25)
	o.min_wavelength += 0.5
	var path := DIR + "my_lake.tres"
	_check(Row.save_to_file(o, path) == OK, "saved to %s" % path)
	_check(o.resource_path == path and Row.is_file_backed(o), "the profile IS the file now (%s)" % o.resource_path)
	var text := FileAccess.get_file_as_string(path)
	_check(text.contains("Pasture3DWaterFFT") and text.contains("Pasture3DWaterFBM"),
		"the file embeds its FFT and fBm")
	m.free()

	var fresh := Pasture3DPoolManager.new()
	var loaded := Row.load_profile(path)
	_check(loaded != null, "loads as a Pasture3DWaveProfile")
	fresh.profiles = Row.profiles_with(fresh, loaded)
	var got := fresh.get_profile(&"lake_calm")
	_check(got == loaded, "a fresh manager answers lake_calm from the file")
	_check(got != null and is_equal_approx(got.fft.foam_bias, 0.33)
			and is_equal_approx(got.fft.get("spectrum_1/wind_speed"), 4.25),
		"tuned knobs come back (foam_bias %s, wind %s)" % [
			got.fft.foam_bias if got else "-", got.fft.get("spectrum_1/wind_speed") if got else "-"])
	fresh.free()

	# A file equal to the built-in, unmarked: kept, because it is a file.
	var plain := _builtin(Pasture3DPoolManager.new(), "pond_still").duplicate(true) as Pasture3DWaveProfile
	var plain_path := DIR + "plain_pond.tres"
	Row.save_to_file(plain, plain_path)
	var m2 := Pasture3DPoolManager.new()
	var plain_loaded := Row.load_profile(plain_path)
	m2.profiles = Row.profiles_with(m2, plain_loaded)
	_check(Pasture3DPoolManager.profiles_store_same_knobs(plain_loaded, _builtin(m2, "pond_still")),
		"WITNESS the plain file equals the built-in")
	_check(m2.profiles.size() == 1 and m2.get_profile(&"pond_still") == plain_loaded, "a file equal to the built-in is kept")
	# Control: its pathless duplicate is a stale copy.
	var arr: Array[Pasture3DWaveProfile] = [plain_loaded.duplicate(true)]
	m2.profiles = arr
	_check(m2.profiles.is_empty(), "CONTROL its pathless duplicate is dropped")
	m2.free()
	_completed += 1


func _criterion_p() -> void:
	print("[P] a scene references the file")
	var m := Pasture3DPoolManager.new()
	m.name = "M"
	var o := m.override_builtin(&"river_flow")
	o.fft.foam_bias = 0.21
	var scene_path := DIR + "embedded.tscn"
	var ps := PackedScene.new()
	ps.pack(m)
	ResourceSaver.save(ps, scene_path)
	var embedded := FileAccess.get_file_as_string(scene_path)
	_check(embedded.contains('type="Pasture3DWaveProfile"') and embedded.contains("[sub_resource type=\"Pasture3DWaveProfile\""),
		"CONTROL an embedded override packs as a sub_resource")
	var path := DIR + "my_river.tres"
	Row.save_to_file(o, path)
	ps = PackedScene.new()
	ps.pack(m)
	scene_path = DIR + "referenced.tscn"
	ResourceSaver.save(ps, scene_path)
	var referenced := FileAccess.get_file_as_string(scene_path)
	_check(referenced.contains('[ext_resource type="Resource"') or referenced.contains('type="Pasture3DWaveProfile" path="%s"' % path),
		"the saved scene has an ext_resource")
	_check(referenced.contains(path), "it names %s" % path)
	_check(not referenced.contains("[sub_resource type=\"Pasture3DWaveProfile\""), "and no embedded profile")
	m.free()
	_completed += 1


func _criterion_h() -> void:
	print("[H] the row's helpers")
	var m := Pasture3DPoolManager.new()
	_check(Row.source_of(m, &"ocean_default") == Row.SOURCE_BUILTIN, "an untouched name is built-in")
	var o := m.override_builtin(&"ocean_default")
	_check(Row.source_of(m, &"ocean_default") == Row.SOURCE_SCENE, "an override is this scene's")
	var mine := Pasture3DWaveProfile.new()
	mine.profile_name = &"stormy"
	m.profiles = Row.profiles_with(m, mine)
	_check(m.profiles.size() == 2 and m.get_profile(&"stormy") == mine, "profiles_with appends a new name")
	var path := DIR + "stormy.tres"
	Row.save_to_file(mine, path)
	_check(Row.source_of(m, &"stormy") == path, "a saved profile's source is its file")
	var other := Pasture3DWaveProfile.new()
	other.profile_name = &"ocean_default"
	other.set_meta(&"pasture3d_override", true)
	m.profiles = Row.profiles_with(m, other)
	_check(m.profiles.size() == 2 and m.profiles[0] == other and m.get_profile(&"ocean_default") == other,
		"profiles_with replaces a same-named profile in place")
	m.profiles = Row.profiles_without(m, &"ocean_default")
	_check(m.profiles.size() == 1 and Row.source_of(m, &"ocean_default") == Row.SOURCE_BUILTIN,
		"profiles_without reverts the name to the built-in")
	# Control: removing a name that is not there changes nothing.
	m.profiles = Row.profiles_without(m, &"nope")
	_check(m.profiles.size() == 1, "CONTROL removing an absent name keeps the rest")
	m.free()
	_completed += 1


## The button texts on a body line, in order.
func _buttons(p_row: Control) -> Array:
	var out := []
	for line in p_row.get_children():
		for c in line.get_children():
			if c is Button:
				out.append(c.text)
	return out


func _criterion_b() -> void:
	print("[B] the line under a body's wave_profile")
	var none := Pasture3DOcean.new()
	add_child(none)
	var bare := Row.new().setup_for_body(none, null)
	_check(Row.manager_for(none) == null and _buttons(bare).is_empty(),
		"CONTROL with no manager the line offers nothing")
	bare.free()
	none.free()

	var m := Pasture3DPoolManager.new()
	add_child(m)
	var ocean := Pasture3DOcean.new()
	ocean.wave_profile = &"ocean_choppy"
	add_child(ocean)
	var pool := Pasture3DPool.new()
	var other := Pasture3DPoolManager.new()
	pool.manager = other
	add_child(pool)
	_check(Row.manager_for(ocean) == m, "an ocean uses the scene's manager")
	_check(Row.manager_for(pool) == other, "a pool's explicit manager wins over the scene's")

	var row := Row.new().setup_for_body(ocean, null)
	add_child(row)
	_check(_buttons(row) == ["Edit a copy"], "a built-in offers Edit a copy (%s)" % [_buttons(row)])
	var copy := m.override_builtin(&"ocean_choppy")
	_check(_buttons(row) == ["Edit a copy"], "CONTROL before the poll the line is unchanged")
	row._process(1.0)
	_check(_buttons(row) == ["Open", "Save to file...", "Revert"], "the scene's copy offers %s" % [_buttons(row)])
	Row.save_to_file(copy, DIR + "choppy_body.tres")
	row._process(1.0)
	_check(_buttons(row) == ["Open", "Revert"], "a file-backed copy offers %s" % [_buttons(row)])
	ocean.wave_profile = &"lake_calm"
	row._process(1.0)
	_check(_buttons(row) == ["Edit a copy"], "renaming the body's profile rebuilds the line")
	for n in [row, pool, ocean, m]:
		n.free()
	other.free()
	_completed += 1
