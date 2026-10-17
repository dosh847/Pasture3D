extends Node
## W3 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.2): the crest foam's per-resolution calibration.
##
## The crest is clamp(sum over the drawn cascades of foam_i + offset, 0, 1). The foam is read straight off
## the simulation's displacement texture (.a, mip 0), every texel of every drawn cascade, so each
## resolution is measured at its own texels -- a rendered readout at a fixed pixel size averages 1024's
## texels before the clamp and not 256's, which is the very bias W3 corrects at a distance. The cascades
## tile at incommensurate repeats, so over a sea the summed foam's distribution is the CONVOLUTION of the
## cascades' own; per sample, the histograms are convolved, then accumulated.
## Per preset and resolution: the simulation runs WARM_SECONDS per seed, then SAMPLES readouts
## SAMPLE_SECONDS apart, taken paused.
##   coverage = the fraction of the sea whose crest exceeds CREST_MIN; mean = the mean crest.
## The operating point is REF_N at the preset's bare offset sum plus P3D_LIFT (default 0.45, the ocean's
## look, chosen by eye at 256). Per resolution, the lift of the bare offset sum giving that mean crest:
##   foam_lift = 1024's lift; water_fft_foam_resolution_lift(N) = N's lift - 1024's.
##   Godot --path project --fixed-fps 60 res://bench/WaterFoamCoverageProbe.tscn
## A probe: it measures, it does not gate. P3D_RES="1024,256" and P3D_PRESETS="ocean_default" narrow it.

const RESOLUTIONS := [256, 1024, 512, 128]
const REF_N := 256
const PRESETS := ["ocean_default", "lake_calm", "pond_still", "river_flow"]
const SEEDS := [0, 101, 202, 303]
const WARM_SECONDS := 8.0
const SAMPLES := 8
const SAMPLE_SECONDS := 0.75
const CREST_MIN := 0.02
const BINS := 500
const BIN_MAX := 2.5
# Texels read per axis: every texel up to this, a regular subset above.
const MAX_READ := 256

var _manager: Pasture3DPoolManager


func _ready() -> void:
	print("=== WaterFoamCoverageProbe ===")
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	var res_list: Array = _env_list("P3D_RES", RESOLUTIONS).map(func(s): return int(s))
	var presets: Array = _env_list("P3D_PRESETS", PRESETS)
	var lift := float(OS.get_environment("P3D_LIFT")) if OS.get_environment("P3D_LIFT") != "" else 0.45
	print("  coverage = crest > %.2f; %d seeds x %d samples; texel foam, mip 0" % [
		CREST_MIN, SEEDS.size(), SAMPLES])
	for preset in presets:
		var prof := _manager.override_builtin(StringName(preset))
		# The bare offsets: the preset's own foam_lift is what this calibrates.
		prof.fft.foam_lift = 0.0
		var offset_sum := prof.fft.get_foam_offset_sum()
		# A material keeps the simulation live; nothing draws it.
		_manager.upload_profile_into(ShaderMaterial.new(), StringName(preset))
		print("  [%s] drawn %d, foam_bias %.3f, offset sum %.3f, add %.2f/s, decay %.2f/s; operating point N %d at %+.3f" % [
			preset, prof.fft.cascade_drawn, prof.fft.foam_bias, offset_sum, prof.fft.foam_add, prof.fft.foam_decay,
			REF_N, lift])
		var target_mean := -1.0
		var target_cov := 0.0
		var lifts := {}
		for n in res_list:
			_manager.fft_resolution = n
			var hist := await _histogram(prof)
			var at := offset_sum + lift
			var line := "    N %4d (effective %d): at the lift, coverage %6.3f%% mean %.4f" % [
				n, _manager.get_effective_fft_resolution(), 100.0 * _coverage(hist, at), _mean(hist, at)]
			if n == REF_N:
				target_mean = _mean(hist, at)
				target_cov = _coverage(hist, at)
				lifts[n] = lift
			elif target_mean >= 0.0:
				var l := _lift_for_mean(hist, offset_sum, target_mean)
				lifts[n] = l
				line += " | lift %+.3f gives mean %.4f, coverage %6.3f%% (%d: %6.3f%%)" % [
					l, _mean(hist, offset_sum + l), 100.0 * _coverage(hist, offset_sum + l), REF_N, 100.0 * target_cov]
			print(line + "  p99.9 raw %.3f" % _quantile(hist, 0.999))
		if lifts.has(1024):
			var parts := PackedStringArray()
			for n in lifts:
				parts.append("%d: %+.3f" % [n, lifts[n] - lifts[1024]])
			print("    -> foam_lift %.3f; resolution lifts %s" % [lifts[1024], ", ".join(parts)])
	get_tree().quit(0)


## A COPY, never the const itself: a `for` over a read-only const array, with awaits in its body, ended
## after its first element (the first run of this probe measured 1024 only, and quit cleanly).
func _env_list(p_name: String, p_default: Array) -> Array:
	var env := OS.get_environment(p_name)
	return p_default.duplicate() if env == "" else Array(env.split(","))


func _frames(p_n: int) -> void:
	for i in p_n:
		await RenderingServer.frame_post_draw


## The summed foam's distribution, accumulated over every sample of every seed.
func _histogram(p_prof: Pasture3DWaveProfile) -> PackedFloat64Array:
	var hist := PackedFloat64Array()
	hist.resize(BINS)
	var rd := RenderingServer.get_rendering_device()
	for seed in SEEDS:
		p_prof.fft.seed = seed
		_manager.paused = false
		await _frames(int(WARM_SECONDS * 60.0))
		for s in SAMPLES:
			await _frames(int(SAMPLE_SECONDS * 60.0))
			_manager.paused = true
			await _frames(1)
			var rid: RID = p_prof.fft.get_displacement_texture().texture_rd_rid
			var n := _manager.get_effective_fft_resolution()
			var sum := PackedFloat64Array()
			for c in 4:
				if not (p_prof.fft.cascade_drawn >> c) & 1:
					continue
				var one := _cascade_histogram(rd.texture_get_data(rid, c), n)
				sum = one if sum.is_empty() else _convolve(sum, one)
			for i in BINS:
				hist[i] += sum[i]
			_manager.paused = false
	return hist


## One cascade's foam (.a of RGBA16F, mip 0) as a normalised histogram.
func _cascade_histogram(p_bytes: PackedByteArray, p_n: int) -> PackedFloat64Array:
	var h := PackedFloat64Array()
	h.resize(BINS)
	var step := maxi(1, p_n / MAX_READ)
	var count := 0
	for y in range(0, p_n, step):
		for x in range(0, p_n, step):
			var f := p_bytes.decode_half((y * p_n + x) * 8 + 6)
			h[clampi(int(f / BIN_MAX * BINS), 0, BINS - 1)] += 1.0
			count += 1
	for i in BINS:
		h[i] /= count
	return h


## The distribution of the sum of two independent draws, on the same bins (bin centres add, so the
## half-bin offset is carried once and rounded).
func _convolve(p_a: PackedFloat64Array, p_b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(BINS)
	for i in BINS:
		if p_a[i] == 0.0:
			continue
		for j in BINS - i:
			if p_b[j] != 0.0:
				out[i + j] += p_a[i] * p_b[j]
	return out


func _bin_value(p_i: int) -> float:
	return (p_i + 0.5) * BIN_MAX / BINS


func _coverage(p_hist: PackedFloat64Array, p_offset: float) -> float:
	var on := 0.0
	var n := 0.0
	for i in BINS:
		n += p_hist[i]
		if _bin_value(i) + p_offset > CREST_MIN:
			on += p_hist[i]
	return on / maxf(n, 1e-12)


func _mean(p_hist: PackedFloat64Array, p_offset: float) -> float:
	var s := 0.0
	var n := 0.0
	for i in BINS:
		n += p_hist[i]
		s += p_hist[i] * clampf(_bin_value(i) + p_offset, 0.0, 1.0)
	return s / maxf(n, 1e-12)


func _quantile(p_hist: PackedFloat64Array, p_q: float) -> float:
	var n := 0.0
	for i in BINS:
		n += p_hist[i]
	var acc := 0.0
	for i in BINS:
		acc += p_hist[i]
		if acc >= p_q * n:
			return _bin_value(i)
	return BIN_MAX


## The lift of the offset whose mean crest reaches p_target (bisection; the mean rises with lift).
func _lift_for_mean(p_hist: PackedFloat64Array, p_offset: float, p_target: float) -> float:
	var lo := -1.0
	var hi := 2.0
	for i in 40:
		var mid := 0.5 * (lo + hi)
		if _mean(p_hist, p_offset + mid) < p_target:
			lo = mid
		else:
			hi = mid
	return hi
