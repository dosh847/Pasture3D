# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DOcean warns when its material will not draw its wave profile at all.
#
# Whether a material draws the profile used to be inferred from SUBSTRINGS OF THE SHADER'S FILE
# PATH, which was wrong for any shader an author renamed, in whichever direction the new name
# happened to fall. Both failures are silent, and both are the wrong kind: the warning exists to
# say "you will not see what get_water_height() is telling you", so a bad guess either invents
# that sentence or suppresses it.
#
# The answer now comes from _draws_wave_profile, a uniform water_common.gdshaderinc declares for
# the purpose: true on every variant that draws the FFT or the fBm, false on a stream variant,
# which replaces the wave model with its own channel model. This checks the warning that reads it.
# (Until Phase 6 of the FFT port it was _wave_variant_count, a Gerstner wave budget; the FFT and
# the fBm have no per-variant budget, so the counting criteria went with it.)
#
# WINDOWED, NOT HEADLESS. RenderingServer.shader_get_parameter_default() returns nil under the
# dummy renderer for every uniform however the shader is written, so headless every variant
# looks undeclared and every criterion here passes vacuously. Criterion D is the guard against
# that being missed.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterVariantWarningCheck.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const NEEDLE := "draws no wave profile"

var _fail := 0


func _ready() -> void:
	print("\n=== ocean stream-variant warning reads the shader, not the filename ===\n")
	# The header above says windowed, and criterion D exists to catch a headless run rather than let one
	# pass vacuously. It does its job — but a sweep reads red criteria as defects, when the only fact
	# established is that the renderer was never there. Refuse the run instead of failing it.
	if DisplayServer.get_name() == "headless":
		print("SKIPPED: needs a real renderer (shader_get_parameter_default is nil under the dummy one).")
		print("Run windowed: Godot_console.exe --path project res://bench/WaterVariantWarningCheck.tscn")
		print("")
		print("=== VARIANT WARNING CHECK SKIPPED (headless) ===")
		get_tree().quit(0)
		return
	_check_river()
	_check_matching()
	_check_renderer_is_real()

	print("")
	if _fail == 0:
		print("=== VARIANT WARNING CHECK PASS ===")
	else:
		print("=== VARIANT WARNING CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## A river material on an ocean: the profile describes a surface this material will not draw.
func _check_river() -> void:
	print("[B] a river material on an ocean:")
	var w := _warnings_for("M_water_river.tres")
	var hit := _first_containing(w, NEEDLE)
	print("    %s" % (hit if hit != "" else "<no stream-variant warning>"))
	if hit == "":
		_fail += 1
		print("    !! silent — the ocean's get_water_height() answers from a profile nothing draws")


## CONTROL. Every variant that draws the profile must say nothing, or the warning is noise and
## criterion B passes for the wrong reason.
func _check_matching() -> void:
	print("\n[C] CONTROL, the body and ocean presets on an ocean:")
	for preset in ["M_water_pond.tres", "M_water_lake.tres", "M_water_ocean.tres", "M_water_ocean_low.tres"]:
		var hit := _first_containing(_warnings_for(preset), NEEDLE)
		print("    %s: %s" % [preset, hit if hit != "" else "<none, as required>"])
		if hit != "":
			_fail += 1
			print("    !! warns about a material that draws the profile")


## CONTROL for the harness itself. Everything above reads the flag through
## shader_get_parameter_default(), which returns nil headless — where B would fail and C would
## pass by saying nothing. This fails in that case, so a vacuous run cannot look like a good one.
## Both values are read, so a flag stuck at either one is caught too.
func _check_renderer_is_real() -> void:
	print("\n[D] CONTROL, the flag is actually readable in this run:")
	for row in [["water_ocean.gdshader", true], ["water_river.gdshader", false]]:
		var sh: Shader = load(WATER_DIR + row[0])
		var declared: Variant = RenderingServer.shader_get_parameter_default(
			sh.get_rid(), &"_draws_wave_profile")
		print("    %s _draws_wave_profile = %s (must be %s)" % [row[0], str(declared), str(row[1])])
		if typeof(declared) != TYPE_BOOL:
			_fail += 1
			print("    !! not a bool — a headless run, or an undeclared flag, so B/C proved nothing")
		elif bool(declared) != row[1]:
			_fail += 1
			print("    !! wrong value")


# ---- fixtures ----------------------------------------------------------------

## An ocean carrying p_preset, on a manager with one profile.
func _warnings_for(p_preset: String) -> PackedStringArray:
	var root := Node3D.new()
	add_child(root)
	var m := Pasture3DPoolManager.new()
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = "test_profile"
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	m.profiles = profiles
	root.add_child(m)

	var ocean := Pasture3DOcean.new()
	ocean.material = load(WATER_DIR + p_preset)
	ocean.wave_profile = &"test_profile"
	root.add_child(ocean)

	var w: PackedStringArray = ocean.get_ocean_warnings()
	# free(), NOT queue_free(). Every criterion here runs synchronously inside _ready, and a
	# queue_free'd node stays in the tree until the frame ends — so the previous fixture's
	# manager was still registered when the next one asked, and Pasture3DPoolManager's
	# get_active_manager() hands back _managers[0], the FIRST one in.
	root.free()
	return w


func _first_containing(p_warnings: PackedStringArray, p_needle: String) -> String:
	for s in p_warnings:
		if s.contains(p_needle):
			return s
	return ""
