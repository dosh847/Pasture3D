# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# WaterFFTGate — the FFT ocean's compute core (PASTURE3D_WATER_FFT_SPEC.md §6 Phase 1, 2026-10-09).
#
# Pasture3DWaterFFT runs four cascades of Tessendorf waves on the main RenderingDevice. These criteria judge
# what it PRODUCED, read back from the GPU, against references that do not share its code:
#
#   [A] Transform. At sample texels in every cascade, the displacement the GPU assembled equals a direct
#       O(N^2) DFT the gate computes itself, in float64, from the GPU's own initial spectrum h0. This covers
#       the dispersion, the two-signals-per-FFT packing, the Stockham butterflies, the (-1)^(x+y) permute,
#       and the choppiness. Control: the same oracle half a second later must disagree. Otherwise the
#       comparison cannot fail, and a static field would pass.
#   [S] Loop seam (spec G2). The surface at t = loop_period equals the surface at t = 0. Control: with
#       loop_period mismatched by x1.37, the two differ. This proves the quantisation is what closes the
#       loop, not a short period.
#   [D] Determinism. One seed twice is bit-identical; a second seed differs.
#   [H] The initial spectrum is the reference's (PASTURE3D_WATER_REFERENCE_SPEC.md S1, S3, S9, S10). On the
#       default sea -- the reference's scene, eight spectra -- the GPU's h0 matches, texel by texel, the
#       reference's CS_InitializeSpectrum re-evaluated here: its hash (constants as HLSL truncates them) and
#       seed chain, Box-Muller, cascade i on spectra 2i and 2i+1, the cos^2 spread at the UNROTATED angle,
#       and sqrt(2 Psi |dw/dk| / k dk^2). Controls, each of which must miss most texels: Elias' decimal hash
#       constants, the cos^2 rotated with the wind, and our former normalisation (variance / 8).
#   [B] Band limit (spec §2.2.2), on a fixture of ONE spectrum in every cascade, so that the cascades
#       describe one sea. band_limited is off by default (the reference overlaps). Turned on, height variance
#       summed over cascades is NOT inflated by overlap: with it off the same sea's variance rises past
#       x1.3. On, a second layout, and the first layout in a scrambled order (the band split walks the
#       cascades by length, not index), give the same variance within +-20%. Averaged over SEEDS seeds.
#   [P] Scale. The realised height variance (P_SEEDS-averaged, summed over cascades) of the default sea equals
#       its expectation within +-20%: 8 Psi(k) dk^2 per mode, summed over every mode the grids hold, from
#       [H]'s re-evaluation. get_height_sigma(), the CPU estimate the cull bounds and fit_sea use, squares
#       to that expectation within 5%. Control: a sea at 0.6x the energy, realised and estimated, must miss.
#   [M] Mip chain. Mip 1 is the 2x2 box average of mip 0, in every cascade, for both outputs.
#
# [A]'s tolerance carries an AMBIGUITY bound. A mode whose sqrt(g|k|)/w0 sits within float32 rounding of
# an integer floors differently on the GPU than in the float64 oracle; its phase then differs by a whole
# quantum, so the gate adds 2|htilde| per such mode rather than guessing which way it went. The count is
# printed. The first run failed cascade 3 at 18x tolerance with the phase computed as w*t: that was the
# GPU's large-argument sin/cos, now reduced to one cycle in the kernel, and the oracle reduces the same way.
#
# Every criterion first asserts that its field is not empty: an all-zero spectrum passes [A], [S] and [D]
# trivially.
#
# Needs a RenderingDevice, so it runs WINDOWED (Forward+); headless has none, and it says so and fails.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterFFTGate.tscn
extends Node

const CRITERIA: PackedStringArray = ["A", "S", "D", "H", "B", "P", "M"]
const N := 128
const PERIOD := 120.0
const T_A := 37.3
const G := 9.81
const SEEDS := 6
# The reference's sea peaks far below its tiles, so each cascade's variance sits in its first ring of about
# eight modes: ~35% scatter per seed. 6 seeds read cascade 1 at 0.64 of its expectation; 48 bring the
# total's scatter to ~5%. [H] pins h0 exactly; this is only the statistics of the realised sea.
const P_SEEDS := 48
const SEED_STRIDE := 100003

var _fail := 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== WaterFFTGate ===")
	if not Pasture3DWaterFFT.is_supported():
		print("  FAIL: no RenderingDevice. Run windowed under Forward+, not --headless.")
		get_tree().quit(1)
		return
	_run()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== WATER FFT %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


## GDScript's % has no %g or %e.
func _g(p_value: float) -> String:
	return String.num_scientific(p_value)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _make() -> Pasture3DWaterFFT:
	var fft := Pasture3DWaterFFT.new()
	fft.resolution = N
	fft.loop_period = PERIOD
	fft.seed = 1
	fft.choppiness = 0.8
	return fft


func _run() -> void:
	_criterion_a()
	_criterion_s()
	_criterion_d()
	_criterion_h()
	_criterion_b()
	_criterion_p()
	_criterion_m()


# --- readback helpers ---------------------------------------------------------------------------------

## Mip-0 displacement of one cascade as a PackedFloat32Array of xyzw per texel.
func _disp(p_fft: Pasture3DWaterFFT, p_cascade: int, p_mip: int = 0) -> PackedFloat32Array:
	return _halves(p_fft.read_layer(Pasture3DWaterFFT.OUTPUT_DISPLACEMENT, p_cascade, p_mip))


func _halves(p_bytes: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_bytes.size() / 2)
	for i in out.size():
		out[i] = p_bytes.decode_half(i * 2)
	return out


func _floats(p_bytes: PackedByteArray) -> PackedFloat32Array:
	return p_bytes.to_float32_array()


func _rms_y(p_disp: PackedFloat32Array) -> float:
	var s := 0.0
	var n := p_disp.size() / 4
	for i in n:
		s += p_disp[i * 4 + 1] * p_disp[i * 4 + 1]
	return sqrt(s / float(max(n, 1)))


func _variance_y(p_disp: PackedFloat32Array) -> float:
	var n := p_disp.size() / 4
	var s := 0.0
	var s2 := 0.0
	for i in n:
		var y := p_disp[i * 4 + 1]
		s += y
		s2 += y * y
	var mean: float = s / float(max(n, 1))
	return s2 / float(max(n, 1)) - mean * mean


func _max_abs_diff_xyz(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in p_a.size():
		if i % 4 == 3:
			continue
		m = max(m, abs(p_a[i] - p_b[i]))
	return m


func _max_abs_xyz(p_a: PackedFloat32Array) -> float:
	var m := 0.0
	for i in p_a.size():
		if i % 4 != 3:
			m = max(m, abs(p_a[i]))
	return m


# --- [A] transform against a direct DFT ---------------------------------------------------------------

## Displacement at texel (p_px, p_pz) by direct summation over the spectrum, float64, plus an upper bound
## on what quantisation-ambiguous modes can contribute: [Vector3, ambiguity_bound, ambiguous_count].
## Mirrors the kernel's definitions, not its arithmetic: htilde(k,t) = h0 e^{iwt} + conj(h0(-k)) e^{-iwt},
## with w quantised to the loop; Dy = sum htilde e^{ik.x}; Dx,z = sum i htilde k_x,z/|k| e^{ik.x}.
func _oracle(p_h0: PackedFloat32Array, p_length: float, p_t: float, p_px: int, p_pz: int,
		p_lambda: float, p_depth: float) -> Array:
	var w0 := TAU / PERIOD
	var dk := TAU / p_length
	var half := N / 2
	var dx := 0.0
	var dy := 0.0
	var dz := 0.0
	var ambiguity := 0.0
	var ambiguous := 0
	for n in N:
		var kz := float(n - half) * dk
		var phase_z := TAU * float((n - half) * p_pz) / float(N)
		for m in N:
			var o := (n * N + m) * 4
			var hr := p_h0[o]
			var hi := p_h0[o + 1]
			var cr := p_h0[o + 2]
			var ci := p_h0[o + 3]
			if hr == 0.0 and hi == 0.0 and cr == 0.0 and ci == 0.0:
				continue
			var kx := float(m - half) * dk
			var kmag := sqrt(kx * kx + kz * kz)
			var rcp := 1.0 if kmag < 0.0001 else 1.0 / kmag
			var x := sqrt(G * kmag * tanh(minf(kmag * p_depth, 20.0))) / w0
			var q := floorf(x)
			var near: float = minf(x - q, q + 1.0 - x)
			if near < max(1e-4, x * 1e-6):
				ambiguous += 1
				ambiguity += 2.0 * (sqrt(hr * hr + hi * hi) + sqrt(cr * cr + ci * ci)) * max(1.0, p_lambda) * sqrt(3.0)
			# Same reduction as the kernel: the phase of q quanta at t, taken to one cycle first.
			var phase := TAU * fposmod(q * p_t / PERIOD, 1.0)
			var ec := cos(phase)
			var es := sin(phase)
			# htilde = h0 * e + h0conj * conj(e)
			var tr := hr * ec - hi * es + cr * ec + ci * es
			var ti := hr * es + hi * ec - cr * es + ci * ec
			var th := TAU * float((m - half) * p_px) / float(N) + phase_z
			var bc := cos(th)
			var bs := sin(th)
			# Re(htilde e^{i th})
			dy += tr * bc - ti * bs
			# Re(i htilde e^{i th}) = -Im(htilde e^{i th})
			var im := tr * bs + ti * bc
			dx += -im * kx * rcp
			dz += -im * kz * rcp
	return [Vector3(p_lambda * dx, dy, p_lambda * dz), ambiguity, ambiguous]


func _criterion_a() -> void:
	var fft := _make()
	var lengths := fft.cascade_lengths
	fft.update(T_A, 0.0)
	var samples := [Vector2i(0, 0), Vector2i(17, 93), Vector2i(64, 5), Vector2i(101, 127)]
	var completed := 0
	var worst := 0.0
	var control_min := INF
	var empty := false
	var ambiguous_total := 0
	var detail := ""
	for c in 4:
		var h0 := _floats(fft.read_layer(Pasture3DWaterFFT.OUTPUT_INITIAL_SPECTRUM, c))
		var disp := _disp(fft, c)
		var peak := _max_abs_xyz(disp)
		if peak <= 1e-6:
			empty = true
		var base_tol := 2e-3 * peak + 1e-5
		var cascade_worst := 0.0
		var cascade_control := 0.0
		var cascade_ambiguous := 0
		for s in samples:
			var o: int = (s.y * N + s.x) * 4
			var gpu := Vector3(disp[o], disp[o + 1], disp[o + 2])
			var now: Array = _oracle(h0, lengths[c], T_A, s.x, s.y, fft.choppiness, fft.depth)
			var later: Array = _oracle(h0, lengths[c], T_A + 0.5, s.x, s.y, fft.choppiness, fft.depth)
			var tol: float = base_tol + now[1]
			cascade_ambiguous = now[2]
			cascade_worst = max(cascade_worst, (gpu - (now[0] as Vector3)).length() / tol)
			cascade_control = max(cascade_control, (gpu - (later[0] as Vector3)).length() / tol)
			completed += 1
		ambiguous_total += cascade_ambiguous
		worst = max(worst, cascade_worst)
		control_min = min(control_min, cascade_control)
		detail += " c%d[L=%.1f peak=%s err/tol=%.3f ctl/tol=%.1f ambiguous=%d]" % [
				c, lengths[c], _g(peak), cascade_worst, cascade_control, cascade_ambiguous]
	var ok := not empty and completed == 16 and worst <= 1.0 and control_min > 1.0
	_check("A", ok, "%d/16 samples, worst err/tol %.3f, control min %.1f (must exceed 1), %d ambiguous modes%s%s" % [
			completed, worst, control_min, ambiguous_total, " EMPTY FIELD" if empty else "", detail])


# --- [S] loop seam ------------------------------------------------------------------------------------

func _seam_diff(p_period: float) -> Array:
	var fft := _make()
	fft.loop_period = p_period
	var worst := 0.0
	var peak := 0.0
	fft.update(0.0, 0.0)
	var at0: Array = []
	for c in 4:
		at0.append(_disp(fft, c))
	fft.update(PERIOD, 0.0)
	for c in 4:
		var d := _disp(fft, c)
		var p := _max_abs_xyz(at0[c])
		peak = max(peak, p)
		worst = max(worst, _max_abs_diff_xyz(at0[c], d) / max(p, 1e-9))
	return [worst, peak]


func _criterion_s() -> void:
	var r: Array = _seam_diff(PERIOD)
	var ctl: Array = _seam_diff(PERIOD * 1.37)
	var ok: bool = r[1] > 1e-6 and r[0] < 2e-3 and ctl[0] > 0.05
	_check("S", ok, "t=0 vs t=%.0f s: worst relative diff %s (< 2e-3), peak %s m; control period x1.37: %.3f (> 0.05)" % [
			PERIOD, _g(r[0]), _g(r[1]), ctl[0]])


# --- [D] determinism ----------------------------------------------------------------------------------

func _criterion_d() -> void:
	var a := _make()
	a.update(T_A, 0.0)
	var b := _make()
	b.update(T_A, 0.0)
	var c := _make()
	c.seed = 2
	c.update(T_A, 0.0)
	var same := 0.0
	var differ := 0.0
	var peak := 0.0
	for k in 4:
		var da := _disp(a, k)
		peak = max(peak, _max_abs_xyz(da))
		same = max(same, _max_abs_diff_xyz(da, _disp(b, k)))
		differ = max(differ, _max_abs_diff_xyz(da, _disp(c, k)) / max(_max_abs_xyz(da), 1e-9))
	var ok := peak > 1e-6 and same == 0.0 and differ > 0.1
	_check("D", ok, "same seed max diff %s (must be 0), other seed relative diff %.3f (> 0.1), peak %s m" % [
			_g(same), differ, _g(peak)])


# --- [H] the reference's initial spectrum ------------------------------------------------------------

const MASK32 := 0xFFFFFFFF
var _f32_box := PackedFloat32Array([0.0])


## Rounds to float32, which the kernel's hash arithmetic runs in: the seed chain floors hash() * 10, and a
## float64 product can land on the other side of an integer.
func _f32(p_x: float) -> float:
	_f32_box[0] = p_x
	return _f32_box[0]


## a * b mod 2^32, without overflowing GDScript's int64.
func _mul32(p_a: int, p_b: int) -> int:
	return (p_a * (p_b & 0xFFFF) + (((p_a * (p_b >> 16)) & 0xFFFF) << 16)) & MASK32


## The kernel's hash(): Hugo Elias' integer hash, with the reference's constants (p_decimal: Elias' own).
func _hash(p_n: int, p_decimal: bool) -> float:
	var c1 := 789221 if p_decimal else 0x789221
	var c2 := 1376312589 if p_decimal else 0x76312589
	var n := p_n & MASK32
	n = ((n << 13) & MASK32) ^ n
	n = (_mul32(n, (_mul32(_mul32(n, n), 15731) + c1) & MASK32) + c2) & MASK32
	return _f32(_f32(float(n & 0x7FFFFFFF)) / _f32(float(0x7FFFFFFF)))


## The gaussian pair each texel of each cascade draws: [gauss1, gauss2] per cascade, as the kernel's seed
## chain produces them.
func _gaussians(p_x: int, p_y: int, p_seed: int, p_decimal: bool) -> Array:
	var seed := (p_x + N * p_y + N + p_seed) & MASK32
	var out := []
	for i in 4:
		seed = (seed + i + int(_f32(_hash(seed, p_decimal) * 10.0))) & MASK32
		var u := [_hash(seed, p_decimal), _hash(_mul32(seed, 2), p_decimal), _hash(_mul32(seed, 3), p_decimal),
				_hash(_mul32(seed, 4), p_decimal)]
		var r1 := sqrt(-2.0 * log(maxf(u[0], 1e-7)))
		var r2 := sqrt(-2.0 * log(maxf(u[2], 1e-7)))
		out.append([Vector2(r1 * cos(TAU * u[1]), r1 * sin(TAU * u[1])),
				Vector2(r2 * cos(TAU * u[3]), r2 * sin(TAU * u[3]))])
	return out


## The reference's DirectionSpectrum; p_rotated is the control that rotates the cos^2 half with the wind.
func _direction(p_sp: PackedFloat32Array, p_theta: float, p_omega: float, p_rotated: bool) -> float:
	var ratio := p_omega / p_sp[5]
	var sp := 9.77 * pow(ratio, -2.5) if ratio > 1.0 else 6.97 * pow(ratio, 5.0)
	sp += 16.0 * tanh(minf(ratio, 20.0)) * p_sp[3] * p_sp[3]
	var s2 := sp * sp
	var s3 := s2 * sp
	var s4 := s3 * sp
	var norm := (-0.000564 * s4 + 0.00776 * s3 - 0.044 * s2 + 0.192 * sp + 0.163) if sp < 5.0 \
			else (-4.80e-08 * s4 + 1.07e-05 * s3 - 9.53e-04 * s2 + 5.90e-02 * sp + 3.93e-01)
	var c2s := norm * pow(absf(cos(0.5 * (p_theta - p_sp[1]))), 2.0 * sp)
	var c := cos(p_theta - p_sp[1]) if p_rotated else cos(p_theta)
	return lerpf(2.0 / 3.1415 * c * c, c2s, p_sp[2])


## Psi(k) |dw/dk| / k for one cascade's pair of spectra at grid wavevector p_k: the sqrt argument's
## spectral part. [base, rotated-control].
func _psi(p_fft: Pasture3DWaterFFT, p_cascade: int, p_k: Vector2) -> Vector2:
	var depth := p_fft.depth
	var k := p_k.length()
	var kd := minf(k * depth, 20.0)
	var th := tanh(kd)
	var omega := sqrt(G * k * th)
	var ch := cosh(kd)
	var domega := G * (depth * k / ch / ch + th) / omega / 2.0
	var angle := atan2(p_k.y, p_k.x)
	var out := Vector2.ZERO
	for j in 2:
		var sp := p_fft.get_spectrum_params(2 * p_cascade + j)
		if j == 1 and sp[0] <= 0.0:
			continue
		var radial := _jonswap(sp, omega, depth) * exp(-sp[7] * sp[7] * k * k)
		out += Vector2(radial * _direction(sp, angle, omega, false), radial * _direction(sp, angle, omega, true))
	return out * absf(domega) / k


## [H]'s per-cascade expected height variance, 4 * sum of the sqrt argument over every mode: [P] reuses it.
var _expected := PackedFloat64Array()


func _criterion_h() -> void:
	var fft := _make()
	fft.update(0.0, 0.0)
	var lengths := fft.cascade_lengths
	var lo := fft.get_band_low()
	var hi := fft.get_band_high()
	var gpu: Array = []
	var peak := PackedFloat64Array([0, 0, 0, 0])
	for c in 4:
		var h0 := _floats(fft.read_layer(Pasture3DWaterFFT.OUTPUT_INITIAL_SPECTRUM, c))
		gpu.append(h0)
		for i in N * N:
			peak[c] = maxf(peak[c], Vector2(h0[i * 4], h0[i * 4 + 1]).length())
	_expected = PackedFloat64Array([0, 0, 0, 0])
	# [matched, decimal, rotated, normalisation] texels, of `counted` non-empty ones.
	var hits := PackedInt64Array([0, 0, 0, 0])
	var counted := 0
	var zero_mismatch := 0
	var worst := 0.0
	var half := N / 2
	for y in N:
		for x in N:
			var g: Array = _gaussians(x, y, fft.seed, false)
			var gd: Array = _gaussians(x, y, fft.seed, true)
			for c in 4:
				var dk := TAU / lengths[c]
				var k := Vector2(x - half, y - half) * dk
				var kl := k.length()
				var o := (y * N + x) * 4
				var got := Vector2(gpu[c][o], gpu[c][o + 1])
				if x == 0 or y == 0 or kl < lo[c] or kl >= hi[c]:
					if got != Vector2.ZERO:
						zero_mismatch += 1
					continue
				var psi := _psi(fft, c, k)
				var arg := 2.0 * psi.x * dk * dk
				_expected[c] += 4.0 * arg
				var want := Vector2(g[c][1].x, g[c][0].y) * sqrt(arg)
				var tol := 2e-3 * want.length() + 1e-6 * peak[c]
				var err := (got - want).length()
				counted += 1
				worst = maxf(worst, err / tol)
				if err <= tol:
					hits[0] += 1
				if (got - Vector2(gd[c][1].x, gd[c][0].y) * sqrt(arg)).length() <= tol:
					hits[1] += 1
				if (got - Vector2(g[c][1].x, g[c][0].y) * sqrt(2.0 * psi.y * dk * dk)).length() <= tol:
					hits[2] += 1
				if (got - want / sqrt(8.0)).length() <= tol:
					hits[3] += 1
	var frac := PackedFloat64Array()
	for i in 4:
		frac.append(float(hits[i]) / float(maxi(counted, 1)))
	var empty := peak[0] <= 0.0 or peak[1] <= 0.0 or peak[2] <= 0.0 or peak[3] <= 0.0
	var ok := not empty and counted > 0 and zero_mismatch == 0 and frac[0] >= 0.999 \
			and frac[1] < 0.5 and frac[2] < 0.5 and frac[3] < 0.5
	_check("H", ok, "%d texels: %.4f match the reference h0 (>= 0.999, worst err/tol %.2f), %d non-zero where it is zero; controls (each < 0.5): decimal hash %.4f, rotated cos^2 %.4f, variance/8 %.4f; peaks %s%s" % [
			counted, frac[0], worst, zero_mismatch, frac[1], frac[2], frac[3], peak, " EMPTY CASCADE" if empty else ""])


# --- [B] band limit -----------------------------------------------------------------------------------

## One spectrum in every cascade (the pair's second off), deep water: the cascades describe ONE sea, which
## is what a band split is for. The reference's scene is not that: each of its cascades is its own sea.
func _one_sea(p_fft: Pasture3DWaterFFT) -> void:
	p_fft.depth = 100.0
	for c in 4:
		var knobs := {"scale": 1.0, "wind_speed": 10.0, "direction_deg": 0.0, "fetch": 100000.0,
				"spread_blend": 1.0, "swell": 0.2, "peak_enhancement": 3.3, "short_waves_fade": 0.01}
		for key in knobs:
			p_fft.set_spectrum_knob(2 * c, key, knobs[key])
		p_fft.set_spectrum_knob(2 * c + 1, "scale", 0.0)


## Height variance per cascade, averaged over SEEDS seeds: [total, per cascade, the fft]. A zero p_lengths
## keeps the default layout; p_energy scales every spectrum.
func _total_variance(p_lengths: Vector4, p_banded: bool, p_one_sea: bool = true, p_energy: float = 1.0,
		p_seeds: int = SEEDS) -> Array:
	var fft := _make()
	if p_one_sea:
		_one_sea(fft)
	if p_energy != 1.0:
		for i in Pasture3DWaterFFT.SPECTRA:
			fft.set_spectrum_knob(i, "scale", fft.get_spectrum_knob(i, "scale") * p_energy)
	if p_lengths != Vector4.ZERO:
		fft.cascade_lengths = p_lengths
	fft.band_limited = p_banded
	var parts := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for i in p_seeds:
		# Spaced past N^2: the kernel adds the seed to x + N y + N, so consecutive seeds hand a texel its
		# neighbour's draws, and the +k and -k modes of the dominant ring repeat each other two seeds apart.
		fft.seed = 101 + i * SEED_STRIDE
		fft.update(0.0, 0.0)
		for c in 4:
			parts[c] += _variance_y(_disp(fft, c)) / float(p_seeds)
	var total := 0.0
	for v in parts:
		total += v
	return [total, parts, fft]


func _criterion_b() -> void:
	var default_off := not Pasture3DWaterFFT.new().band_limited
	var la := Vector4(500.0, 85.0, 16.0, 4.0)
	var lb := Vector4(400.0, 70.0, 13.0, 3.3)
	var lc := Vector4(85.0, 500.0, 4.0, 16.0)
	var banded: Array = _total_variance(la, true)
	var other: Array = _total_variance(lb, true)
	var scrambled: Array = _total_variance(lc, true)
	var overlapped: Array = _total_variance(la, false)
	var inflate: float = overlapped[0] / max(banded[0], 1e-12)
	var layout: float = other[0] / max(banded[0], 1e-12)
	var order: float = scrambled[0] / max(banded[0], 1e-12)
	var ok: bool = default_off and banded[0] > 1e-8 and inflate > 1.3 and layout > 1.0 / 1.2 and layout < 1.2 \
			and order > 1.0 / 1.2 and order < 1.2
	_check("B", ok, "band_limited off by default: %s; %d seeds, one sea: banded %s m^2 %s; layout B %s (ratio %.3f), scrambled order %s %s (ratio %.3f), both within 1.2x; unbanded %s %s (x%.2f, must exceed 1.3)" % [
			default_off, SEEDS, _g(banded[0]), banded[1], _g(other[0]), layout, _g(scrambled[0]), scrambled[1], order,
			_g(overlapped[0]), overlapped[1], inflate])


# --- [P] scale ----------------------------------------------------------------------------------------

## JONSWAP with the TMA depth correction, from the derived params the kernel receives:
## [scale, angle, spread_blend, swell, alpha, peak_omega, gamma, short_waves_fade].
func _jonswap(p_sp: PackedFloat32Array, p_omega: float, p_depth: float) -> float:
	var peak := p_sp[5]
	var sigma := 0.07 if p_omega <= peak else 0.09
	var r := exp(-(p_omega - peak) * (p_omega - peak) / 2.0 / sigma / sigma / peak / peak)
	var oh := p_omega * sqrt(p_depth / G)
	var tma := 1.0
	if oh <= 1.0:
		tma = 0.5 * oh * oh
	elif oh < 2.0:
		tma = 1.0 - 0.5 * (2.0 - oh) * (2.0 - oh)
	return p_sp[0] * tma * p_sp[4] * G * G / pow(p_omega, 5.0) * exp(-1.25 * pow(peak / p_omega, 4.0)) \
			* pow(absf(p_sp[6]), r)


func _criterion_p() -> void:
	var expected := 0.0
	for v in _expected:
		expected += v
	var real: Array = _total_variance(Vector4.ZERO, false, false, 1.0, P_SEEDS)
	var quiet: Array = _total_variance(Vector4.ZERO, false, false, 0.6, P_SEEDS)
	var sigma: float = (real[2] as Pasture3DWaterFFT).get_height_sigma()
	var quiet_sigma: float = (quiet[2] as Pasture3DWaterFFT).get_height_sigma()
	var ratio: float = real[0] / max(expected, 1e-12)
	var est: float = sigma * sigma / max(expected, 1e-12)
	var control: float = quiet[0] / max(expected, 1e-12)
	var est_control: float = quiet_sigma * quiet_sigma / max(expected, 1e-12)
	var per := PackedFloat64Array()
	for c in 4:
		per.append(real[1][c] / max(_expected[c], 1e-12) if _expected.size() == 4 else 0.0)
	var ok: bool = expected > 1e-8 and real[0] > 1e-8 and ratio > 1.0 / 1.2 and ratio < 1.2 \
			and est > 1.0 / 1.05 and est < 1.05 and control < 1.0 / 1.2 and est_control < 1.0 / 1.05
	_check("P", ok, "default sea, %d seeds: realised variance %s m^2 (Hs %.2f m) vs expected %s m^2 (Hs %.2f m): ratio %.3f (within 1.2x; per cascade %s); get_height_sigma^2 / expected %.4f (within 1.05x); controls at 0.6x energy: realised %.3f (< 0.833), estimate %.3f (< 0.952)" % [
			P_SEEDS, _g(real[0]), 4.0 * sqrt(real[0]), _g(expected), 4.0 * sqrt(expected), ratio, per, est, control, est_control])


# --- [M] mip chain ------------------------------------------------------------------------------------

func _criterion_m() -> void:
	var fft := _make()
	fft.update(T_A, 0.0)
	var worst := 0.0
	var peak := 0.0
	var checked := 0
	for output in [Pasture3DWaterFFT.OUTPUT_DISPLACEMENT, Pasture3DWaterFFT.OUTPUT_SLOPE]:
		for c in 4:
			var m0 := _halves(fft.read_layer(output, c, 0))
			var m1 := _halves(fft.read_layer(output, c, 1))
			if m1.size() * 4 != m0.size():
				worst = INF
				continue
			var h := N / 2
			for y in range(0, h, 7):
				for x in range(0, h, 5):
					for ch in 4:
						var a := m0[((2 * y) * N + 2 * x) * 4 + ch]
						var b := m0[((2 * y) * N + 2 * x + 1) * 4 + ch]
						var cc := m0[((2 * y + 1) * N + 2 * x) * 4 + ch]
						var d := m0[((2 * y + 1) * N + 2 * x + 1) * 4 + ch]
						var avg := (a + b + cc + d) * 0.25
						var got := m1[(y * h + x) * 4 + ch]
						peak = max(peak, abs(avg))
						# Half-float storage of an average of half floats: 1e-3 relative, plus a floor.
						worst = max(worst, abs(got - avg) / (abs(avg) * 2e-3 + 1e-4))
						checked += 1
	var ok := peak > 1e-6 and checked > 0 and worst <= 1.0
	_check("M", ok, "%d mip-1 texel channels vs 2x2 mip-0 average, worst err/tol %.3f, peak %s" % [
			checked, worst, _g(peak)])
