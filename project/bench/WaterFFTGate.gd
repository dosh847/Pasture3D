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
#   [B] Band limit (spec §2.2.2). Height variance summed over cascades is NOT inflated by overlap: with
#       band_limited off, the same spectrum's variance must rise past x1.3. Band-limited, a second cascade
#       layout gives the same variance within +-20%, because it is one sea, not four. Averaged over
#       SEEDS seeds: one realisation of the spectral peak is a few dozen modes, about 15% noise.
#   [P] Physical scale (spec §2.2.6). At scale 1 the realised height variance (seed-averaged) equals the
#       integral of the spectrum, which the gate computes itself in 1D: S(w(k)) * TMA * fade(k) * dw/dk over
#       the k the grid holds, both spectra, within +-20%. The reference's normalisation reads x8 here.
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

const CRITERIA: PackedStringArray = ["A", "S", "D", "B", "P", "M"]
const N := 128
const PERIOD := 120.0
const T_A := 37.3
const G := 9.81
const SEEDS := 6

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


# --- [B] band limit -----------------------------------------------------------------------------------

## Height variance per cascade, averaged over SEEDS seeds.
func _total_variance(p_lengths: Vector4, p_banded: bool) -> Array:
	var fft := _make()
	fft.cascade_lengths = p_lengths
	fft.band_limited = p_banded
	var parts := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for i in SEEDS:
		fft.seed = 101 + i
		fft.update(0.0, 0.0)
		for c in 4:
			parts[c] += _variance_y(_disp(fft, c)) / float(SEEDS)
	var total := 0.0
	for v in parts:
		total += v
	return [total, parts]


## [B]'s banded default-layout result, reused by [P].
var _banded: Array = []


func _criterion_b() -> void:
	var la := Vector4(500.0, 85.0, 16.0, 4.0)
	var lb := Vector4(400.0, 70.0, 13.0, 3.3)
	_banded = _total_variance(la, true)
	var other: Array = _total_variance(lb, true)
	var overlapped: Array = _total_variance(la, false)
	var inflate: float = overlapped[0] / max(_banded[0], 1e-12)
	var layout: float = other[0] / max(_banded[0], 1e-12)
	var ok: bool = _banded[0] > 1e-8 and inflate > 1.3 and layout > 1.0 / 1.2 and layout < 1.2
	_check("B", ok, "%d seeds: variance banded %s m^2 %s; layout B %s %s (ratio %.3f, within 1.2x); unbanded %s %s (x%.2f, must exceed 1.3)" % [
			SEEDS, _g(_banded[0]), _banded[1], _g(other[0]), other[1], layout, _g(overlapped[0]), overlapped[1], inflate])


# --- [P] physical scale -------------------------------------------------------------------------------

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


## Variance of the sea the knobs describe: the integral of S(w(k)) * fade(k) * dw/dk over the k the grid
## realises. The directional spread integrates to 1 over the circle at spread_blend 1, so it drops out.
func _spectrum_integral(p_fft: Pasture3DWaterFFT) -> float:
	var lengths := p_fft.cascade_lengths
	var depth := p_fft.depth
	var k0 := 0.5 * TAU / lengths[0]
	var k1 := PI * float(N) / lengths[3]
	var steps := 20000
	var total := 0.0
	var prev_k := k0
	var prev_f := 0.0
	for i in steps + 1:
		var k := k0 * pow(k1 / k0, float(i) / float(steps))
		var kd: float = min(k * depth, 20.0)
		var th := tanh(kd)
		var omega := sqrt(G * k * th)
		var ch := cosh(kd)
		var domega := G * (depth * k / ch / ch + th) / omega / 2.0
		var f := 0.0
		for sidx in 2:
			var sp := p_fft.get_spectrum_params(sidx)
			if sidx == 1 and sp[0] <= 0.0:
				continue
			f += _jonswap(sp, omega, depth) * exp(-sp[7] * sp[7] * k * k) * domega
		if i > 0:
			total += 0.5 * (f + prev_f) * (k - prev_k)
		prev_k = k
		prev_f = f
	return total


func _criterion_p() -> void:
	var fft := _make()
	var blend_ok := fft.get_spectrum_knob(0, "spread_blend") == 1.0 and fft.get_spectrum_knob(1, "spread_blend") == 1.0
	var expected := _spectrum_integral(fft)
	var realised: float = _banded[0] if not _banded.is_empty() else 0.0
	var ratio: float = realised / max(expected, 1e-12)
	# Control: the same comparison must fail for a sea at 0.6x the energy, measured, not assumed.
	var quiet := _make()
	quiet.set_spectrum_knob(0, "scale", 0.6)
	quiet.set_spectrum_knob(1, "scale", 0.6 * fft.get_spectrum_knob(1, "scale"))
	var quiet_var := 0.0
	for i in SEEDS:
		quiet.seed = 101 + i
		quiet.update(0.0, 0.0)
		for c in 4:
			quiet_var += _variance_y(_disp(quiet, c)) / float(SEEDS)
	var control: float = quiet_var / max(expected, 1e-12)
	var ok: bool = blend_ok and expected > 1e-6 and realised > 1e-8 and ratio > 1.0 / 1.2 and ratio < 1.2 			and control < 1.0 / 1.2
	_check("P", ok, "realised variance %s m^2 (Hs %.2f m) vs spectrum integral %s m^2 (Hs %.2f m): ratio %.3f, within 1.2x; control at 0.6x energy %.3f (must fall below 0.833)%s" % [
			_g(realised), 4.0 * sqrt(realised), _g(expected), 4.0 * sqrt(expected), ratio, control,
			"" if blend_ok else " (spread_blend is not 1: the integral assumes a unit-mass spread)"])


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
