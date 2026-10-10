extends Node
# Phase 6 of PASTURE3D_WATER_FFT_SPEC.md: Gerstner retired.
#
# Headless is enough, and is how CI runs it:
#   Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/WaterRetireGerstnerGate.tscn
#
#   [G] Gone. Every deleted symbol is absent from the code: addons, bench, demo (not its data) and ../src,
#       in .gd/.gdshader/.gdshaderinc/.tres/.tscn/.cpp/.h. Comment lines are skipped -- history may name
#       what was removed -- and so is this file, which has to name them to look for them. Legacy KEYS are
#       not symbols: `ocean_wave_steepness` and the profile's `wave_count` are what old scenes carry, and
#       the migration has to spell them. Controls: the same matcher on three fixture lines must hit the
#       live one and skip the comment and the legacy key; and the scan must have read at least
#       G_MIN_RES files under res:// and G_MIN_SRC under src/, so "clean" cannot mean "read nothing".
#   [L] Presets load. Every M_water_*.tres loads as a ShaderMaterial on a shader that parses, and every
#       shader_parameter/ it stores is a uniform its shader declares -- a stale stored parameter (the
#       retired _waves, wave_steepness, the ocean's detail_*) loads without complaint and is dropped,
#       which is how a preset rots. Controls: each preset must store at least one parameter (so the
#       comparison ran), and the retired `_waves` checked against the ocean's list must be undeclared.
#   [P] Presets are migrations. Each of the four shipped profiles equals a fresh profile handed its old
#       Gerstner knobs as legacy keys: the fBm and FFT knobs and min_wavelength, to P_TOL relative (the
#       presets are spelled to six figures). Control: each preset against the NEXT preset's migration
#       must miss by over P_CTRL, or the comparison cannot tell the presets apart.
#   [M] Migration on load. Legacy profiles written as .tres and loaded from disk: one with only the old
#       keys re-fits to the same knobs as [P]'s path; two that also carry an authored fbm -- before the
#       keys and after them, since load order is file order -- keep that fbm exactly while the FFT
#       re-fits. Control: a profile file with no legacy keys loads as the unmigrated default, which
#       must differ from the migrated one by over P_CTRL.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const CRITERIA: PackedStringArray = ["G", "L", "P", "M"]
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const SELF := "res://bench/WaterRetireGerstnerGate.gd"
const SCAN_ROOTS := ["res://addons", "res://bench", "res://demo"]
const SCAN_SKIP := ["res://demo/data", "res://addons/pasture_3d/bin"]
const SCAN_EXT := ["gd", "gdshader", "gdshaderinc", "tres", "tscn", "cpp", "h"]
const G_MIN_RES := 200
const G_MIN_SRC := 50
const P_TOL := 1e-4
const P_CTRL := 0.05
const AUTHORED_HEIGHT := 3.25

# Every symbol Phase 6 deleted, as a regex. Lookbehinds keep the legacy keys out.
const SYMBOLS := [
	"WAVE_MODEL_GERSTNER", "MODEL_GERSTNER", "get_shader_table", "(?<![A-Za-z_])wave_steepness",
	"WATER_WAVE_COUNT", "WATER_MAX_WAVES", "_wave_variant_count", "\"_waves\"", "\\b_waves\\[",
	"WATER_NO_FFT", "WATER_PLAIN_DOMAIN_ORIGIN", "\\bWaterWaves\\b", "water_waves\\.h", "_wave_defaults",
	"\\bget_waves\\(", "set_wave_count", "set_spread_deg", "set_steepness", "test_water_waves",
	"WaterPhase[2-5]Gate", "WavePresetTables", "water_parity_probe", "water_depth_probe",
]

# The shipped presets as they were until Phase 6: count, direction, spread, amplitude, length_max, steepness.
const LEGACY_PRESETS := {
	"ocean_default": [8, 20.0, 28.0, 1.6, 137.0, 0.35],
	"lake_calm": [4, 35.0, 40.0, 0.25, 25.0, 0.25],
	"pond_still": [2, 55.0, 50.0, 0.05, 12.0, 0.15],
	"river_flow": [3, 0.0, 10.0, 0.06, 10.0, 0.12],
}
const LEGACY_KEYS := ["wave_count", "direction_deg", "spread_deg", "amplitude", "length_max", "steepness"]

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== WaterRetireGerstnerGate ===")
	_criterion_g()
	_criterion_l()
	_criterion_p()
	_criterion_m()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== WATER RETIRE GERSTNER %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


# --- [G] ---------------------------------------------------------------------------------------------

func _compiled() -> Array:
	var out := []
	for s in SYMBOLS:
		var re := RegEx.create_from_string(s)
		assert(re.is_valid(), s)
		out.append(re)
	return out


func _is_comment(p_line: String) -> bool:
	var t := p_line.strip_edges()
	return t.begins_with("#") or t.begins_with("//") or t.begins_with("*") or t.begins_with("/*")


# The symbols p_line uses, outside comments.
func _hits(p_res: Array, p_line: String) -> PackedStringArray:
	var out := PackedStringArray()
	if _is_comment(p_line):
		return out
	for i in p_res.size():
		if (p_res[i] as RegEx).search(p_line) != null:
			out.append(SYMBOLS[i])
	return out


func _collect(p_dir: String, p_out: PackedStringArray) -> void:
	for skip in SCAN_SKIP:
		if p_dir.begins_with(skip):
			return
	var d := DirAccess.open(p_dir)
	if d == null:
		return
	for f in d.get_files():
		if SCAN_EXT.has(f.get_extension()):
			p_out.append(p_dir.path_join(f))
	for sub in d.get_directories():
		if not sub.begins_with("."):
			_collect(p_dir.path_join(sub), p_out)


func _criterion_g() -> void:
	var res := _compiled()
	var found := PackedStringArray()

	var files := PackedStringArray()
	for root in SCAN_ROOTS:
		_collect(root, files)
	var res_count := files.size()
	var src := ProjectSettings.globalize_path("res://").path_join("../src").simplify_path()
	var src_files := PackedStringArray()
	_collect(src, src_files)
	files.append_array(src_files)

	for path in files:
		if path == SELF:
			continue
		var text := FileAccess.get_file_as_string(path)
		var n := 0
		for line in text.split("\n"):
			n += 1
			var h := _hits(res, line)
			if not h.is_empty():
				found.append("%s:%d %s" % [path, n, ", ".join(h)])

	var live := _hits(res, "\tmat.set_shader_parameter(\"_waves\", table)")
	var comment := _hits(res, "\t# until Phase 6 this wrote \"_waves\" and wave_steepness")
	var key := _hits(res, "ocean_wave_steepness = 0.42")
	var controls := live.size() == 1 and comment.is_empty() and key.is_empty()
	var read_enough := res_count >= G_MIN_RES and src_files.size() >= G_MIN_SRC
	var detail := "%d files under res://, %d under src/ (need %d/%d); %d live uses of deleted symbols" % [
			res_count, src_files.size(), G_MIN_RES, G_MIN_SRC, found.size()]
	detail += " | controls: live line hits %s, comment hits %s, legacy key hits %s" % [live, comment, key]
	for f in found.slice(0, 20):
		detail += "\n      " + f
	_check("G", found.is_empty() and controls and read_enough, detail)


# --- [L] ---------------------------------------------------------------------------------------------

func _stored_params(p_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in FileAccess.get_file_as_string(p_path).split("\n"):
		if line.begins_with("shader_parameter/"):
			out.append(line.substr(17).split(" ")[0])
	return out


func _declared(p_shader: Shader) -> PackedStringArray:
	var out := PackedStringArray()
	for u in p_shader.get_shader_uniform_list(true):
		out.append(u["name"])
	return out


func _criterion_l() -> void:
	var details := PackedStringArray()
	var ok := true
	var presets := 0
	var ocean_declared := PackedStringArray()
	for f in DirAccess.get_files_at(WATER_DIR):
		if not (f.begins_with("M_water_") and f.ends_with(".tres")):
			continue
		presets += 1
		var mat := load(WATER_DIR + f) as ShaderMaterial
		if mat == null or mat.shader == null:
			ok = false
			details.append("%s: did not load as a ShaderMaterial with a shader" % f)
			continue
		var declared := _declared(mat.shader)
		if f == "M_water_ocean.tres":
			ocean_declared = declared
		var stored := _stored_params(WATER_DIR + f)
		var stale := PackedStringArray()
		for s in stored:
			if not declared.has(s):
				stale.append(s)
		var row_ok := not declared.is_empty() and not stored.is_empty() and stale.is_empty()
		ok = ok and row_ok
		details.append("%s on %s: %d stored, %d declared, undeclared %s -> %s" % [
				f, mat.shader.resource_path.get_file(), stored.size(), declared.size(), stale,
				"ok" if row_ok else "WRONG"])
	var ctrl := not ocean_declared.is_empty() and not ocean_declared.has("_waves")
	details.append("CONTROL: the retired _waves against the ocean's uniforms is undeclared: %s" % ctrl)
	_check("L", ok and ctrl and presets >= 5, "%d presets\n      %s" % [presets, "\n      ".join(details)])


# --- [P] / [M] ---------------------------------------------------------------------------------------

func _migrated(p_knobs: Array) -> Pasture3DWaveProfile:
	var p := Pasture3DWaveProfile.new()
	for i in LEGACY_KEYS.size():
		p.set(LEGACY_KEYS[i], p_knobs[i])
	return p


# Everything the fit writes, plus min_wavelength.
func _knobs(p: Pasture3DWaveProfile) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for s in 2:
		for k in [&"seed", &"frequency", &"speed", &"height"]:
			out.append(p.fbm.get_knob(s, k))
	var l: Vector4 = p.fft.cascade_lengths
	out.append_array([l.x, l.y, l.z, l.w])
	for s in 2:
		for k in [&"scale", &"fetch"]:
			out.append(p.fft.get_spectrum_knob(s, k))
	out.append(p.min_wavelength)
	return out


func _e(p_x: float) -> String:
	return String.num_scientific(p_x) if p_x != 0.0 else "0"


# Worst relative difference, each entry against the larger magnitude of the pair.
func _rel(p_a: PackedFloat64Array, p_b: PackedFloat64Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var worst := 0.0
	for i in p_a.size():
		var m := maxf(maxf(absf(p_a[i]), absf(p_b[i])), 1e-9)
		worst = maxf(worst, absf(p_a[i] - p_b[i]) / m)
	return worst


func _criterion_p() -> void:
	var m := Pasture3DPoolManager.new()
	var names: Array = LEGACY_PRESETS.keys()
	var details := PackedStringArray()
	var ok := true
	for i in names.size():
		var name: String = names[i]
		var next: String = names[(i + 1) % names.size()]
		var shipped: Pasture3DWaveProfile = m.get_profile(name)
		if shipped == null:
			ok = false
			details.append("%s: the manager ships no such profile" % name)
			continue
		var err := _rel(_knobs(shipped), _knobs(_migrated(LEGACY_PRESETS[name])))
		var ctrl := _rel(_knobs(shipped), _knobs(_migrated(LEGACY_PRESETS[next])))
		var row_ok := err < P_TOL and ctrl > P_CTRL
		ok = ok and row_ok
		details.append("%s: vs its migration %s (tol %s) | CONTROL vs %s's %.3f (need > %.2f) -> %s" % [
				name, _e(err), _e(P_TOL), next, ctrl, P_CTRL, "ok" if row_ok else "WRONG"])
	m.free()
	_check("P", ok and details.size() == names.size(), "\n      " + "\n      ".join(details))


func _write_profile(p_path: String, p_lines: PackedStringArray, p_fbm_path := "") -> void:
	var text := "[gd_resource type=\"Pasture3DWaveProfile\" load_steps=%d format=3]\n\n" % (2 if p_fbm_path != "" else 1)
	if p_fbm_path != "":
		text += "[ext_resource type=\"Pasture3DWaterFBM\" path=\"%s\" id=\"1_fbm\"]\n\n" % p_fbm_path
	text += "[resource]\n" + "\n".join(p_lines) + "\n"
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _criterion_m() -> void:
	var knobs: Array = LEGACY_PRESETS["lake_calm"]
	var legacy := PackedStringArray(["profile_name = &\"legacy\""])
	for i in LEGACY_KEYS.size():
		legacy.append("%s = %s" % [LEGACY_KEYS[i], var_to_str(knobs[i])])

	# An authored fbm, saved on its own so the profile files can point at it.
	var fbm := Pasture3DWaterFBM.new()
	fbm.set_knob(Pasture3DWaterFBM.SET_VERTEX, &"height", AUTHORED_HEIGHT)
	var fbm_path := "user://retire_gerstner_fbm.tres"
	ResourceSaver.save(fbm, fbm_path)

	var fbm_line := "fbm = ExtResource(\"1_fbm\")"
	var before := PackedStringArray([fbm_line])
	before.append_array(legacy)
	var after := legacy.duplicate()
	after.append(fbm_line)
	_write_profile("user://retire_gerstner_legacy.tres", legacy)
	_write_profile("user://retire_gerstner_fbm_before.tres", before, fbm_path)
	_write_profile("user://retire_gerstner_fbm_after.tres", after, fbm_path)
	_write_profile("user://retire_gerstner_plain.tres", PackedStringArray(["profile_name = &\"plain\""]))

	var flags := ResourceLoader.CACHE_MODE_IGNORE
	var loaded := ResourceLoader.load("user://retire_gerstner_legacy.tres", "", flags) as Pasture3DWaveProfile
	var fb := ResourceLoader.load("user://retire_gerstner_fbm_before.tres", "", flags) as Pasture3DWaveProfile
	var fa := ResourceLoader.load("user://retire_gerstner_fbm_after.tres", "", flags) as Pasture3DWaveProfile
	var plain := ResourceLoader.load("user://retire_gerstner_plain.tres", "", flags) as Pasture3DWaveProfile
	if loaded == null or fb == null or fa == null or plain == null:
		_check("M", false, "a profile file did not load: legacy %s, fbm before %s, fbm after %s, plain %s" % [
				loaded != null, fb != null, fa != null, plain != null])
		return

	var want := _knobs(_migrated(knobs))
	var refit := _rel(_knobs(loaded), want)
	var details := PackedStringArray()
	details.append("legacy keys only: vs the migration %s (tol %s)" % [_e(refit), _e(P_TOL)])
	var ok := refit < P_TOL
	var want_fft := want.slice(8, 12 + 4)
	for row in [["fbm before the keys", fb], ["fbm after the keys", fa]]:
		var p: Pasture3DWaveProfile = row[1]
		var height: float = p.fbm.get_knob(Pasture3DWaterFBM.SET_VERTEX, &"height")
		var fft_err := _rel(_knobs(p).slice(8, 12 + 4), want_fft)
		var row_ok := height == AUTHORED_HEIGHT and fft_err < P_TOL and p.is_fbm_authored()
		ok = ok and row_ok
		details.append("%s: fbm height %.4f (authored %.4f), FFT vs the migration %s -> %s" % [
				row[0], height, AUTHORED_HEIGHT, _e(fft_err), "ok" if row_ok else "WRONG"])
	var ctrl := _rel(_knobs(plain), want)
	details.append("CONTROL, no legacy keys vs the migration: %.3f (need > %.2f)" % [ctrl, P_CTRL])
	_check("M", ok and ctrl > P_CTRL, "\n      " + "\n      ".join(details))
