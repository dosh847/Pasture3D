// Pasture3D Water — wave evaluation.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §3.1, §3.2
//
// *** THIS FILE IS THE PARITY CONTRACT WITH C++. ***
// Pasture3D::get_water_height() is a transcription of water_eval_waves(). Any
// change here must be mirrored in pasture_3d.cpp, in the same operation order,
// using float (not double). See spec §4.3.
//
// Everything except the wave table is derived here rather than uploaded, for
// two reasons:
//   1. G6 -- drop water_body.gdshader on a bare MeshInstance3D and it must make
//      waves with no plugin, so the shader cannot depend on C++ having run.
//   2. Parity. The fewer numbers that cross the CPU/GPU boundary, the fewer
//      places the two evaluators can silently disagree. The only derivations
//      used are `/` and `sqrt`, both correctly-rounded and therefore bit-exact
//      under IEEE-754 on either side.
//
// The mesh must be dense enough to resolve the shortest wavelength in the
// table: waves are a VERTEX-stage effect, so a 10 m wave on a 12 m grid aliases
// into noise. Rule of thumb: vertex spacing <= L_min / 8.

#ifndef WATER_WAVES_INC
#define WATER_WAVES_INC

#define WATER_TAU 6.283185307179586
#define WATER_GRAVITY 9.81

struct WaveSample {
	vec3 position; // world-space position after displacement
	vec3 normal;   // world-space normal
	float jacobian; // sum(Q * w * A * sin(theta)); ~1.0 means the crest is breaking
};

// p_pos: undisplaced world-space position. Y is carried through; the wave
// domain is XZ.
WaveSample water_eval_waves(vec3 p_pos) {
	WaveSample o;
	o.position = p_pos;
	o.normal = vec3(0.0, 1.0, 0.0);
	o.jacobian = 0.0;

	vec2 domain = p_pos.xz - _water_domain_origin.xz;

	// Steepness budget, distributed across waves in proportion to amplitude.
	//
	// GPU Gems normalises Q_i = steepness / (w_i * A_i * N), which makes the
	// product Q_i*w_i*A_i the same constant for every wave. That satisfies the
	// non-self-intersection constraint sum(Q*w*A) <= 1, but it has a defect the
	// spec missed: the horizontal term Q_i*A_i = steepness/(w_i*N) then carries
	// no amplitude dependence at all. A zero-amplitude wave -- an unused table
	// slot -- still shears the surface horizontally and still tilts the normal,
	// producing motion with no visible wave to justify it.
	//
	// Weighting by amplitude instead keeps the same bound (the weights sum to 1
	// by construction) while making empty slots genuinely inert and giving the
	// larger waves the sharper crests, which is also what the ocean does.
#ifndef WATER_NO_DEFAULT_WAVES
	// Nothing uploaded a table -- fall back to the compile-time one so a raw
	// .gdshader on a bare mesh still makes waves (see water_common.gdshaderinc).
	//
	// The sentinel is the first WAVELENGTH, not the amplitude sum. An un-set
	// uniform array reads as all zeros, and no real table has a zero wavelength,
	// so this distinguishes the two cases exactly -- whereas an amplitude test
	// would read a deliberately calm body as "nothing uploaded" and override it
	// with waves, making flat water impossible to author.
	//
	// Branch-free: `use_defaults` is uniform across the draw, so it costs a
	// select per wave and causes no divergence.
	float use_defaults = (_waves[0].w <= 0.0) ? 1.0 : 0.0;
#endif

	float sum_amp = 0.0;
	for (int i = 0; i < WATER_WAVE_COUNT; i++) {
		sum_amp += _waves[i].z;
	}
#ifndef WATER_NO_DEFAULT_WAVES
	sum_amp = mix(sum_amp, float(WATER_DEFAULT_SUM_AMP), use_defaults);
#endif

	float steepness_per_amp = wave_steepness / max(sum_amp, 1e-6);

	for (int i = 0; i < WATER_WAVE_COUNT; i++) {
#ifdef WATER_NO_DEFAULT_WAVES
		vec4 wave = _waves[i];
#else
		vec4 wave = mix(_waves[i], _wave_defaults[i], use_defaults);
#endif
		vec2 dir = wave.xy;
		float amp = wave.z;
		float wavelength = max(wave.w, 1e-3);

		float w = WATER_TAU / wavelength;
		// Deep-water dispersion. speed = sqrt(g*L/TAU), phase rate = speed*w,
		// which collapses to sqrt(g*w) -- one sqrt instead of a sqrt and two
		// multiplies, and identical to the spec's formula in exact arithmetic.
		float omega = sqrt(WATER_GRAVITY * w);

		// Q*w*A and Q*A, without ever forming Q. Dividing by amplitude to get Q
		// and multiplying it straight back out would blow up on empty slots.
		float qwa = steepness_per_amp * amp;
		float qa = qwa / w;
		float wa = w * amp;

		float theta = w * dot(dir, domain) + omega * water_time;
		float s = sin(theta);
		float c = cos(theta); // one sincos with the line above on every GPU in scope

		o.position.xz += (qa * c) * dir;
		o.position.y += amp * s;

		o.normal.xz -= (wa * c) * dir;
		float qwa_s = qwa * s;
		o.normal.y -= qwa_s;
		o.jacobian += qwa_s;
	}

	o.normal = normalize(o.normal);
	return o;
}

#ifdef WATER_FFT
// ---------------------------------------------------------------------------
// The FFT surface (PASTURE3D_WATER_FFT_SPEC.md §3). NOT part of the parity
// contract above: its CPU answer is a readback (spec §5), not a transcription.
// ---------------------------------------------------------------------------

// Mip for cascade i when the samples are p_spacing metres apart: the level whose texel is twice the
// spacing, which removes everything shorter than four samples a wavelength.
// The mesh cannot draw those, and leaving them in is what makes a coarse ring crawl. Past the last level
// the sampler clamps to the 1x1 mean, which is zero: a cascade far finer than the mesh vanishes from the
// geometry, as it should, and stays in the fragment stage's slope.
float water_fft_lod(float p_spacing, float p_length, float p_texels) {
	return max(log2(2.0 * p_spacing * p_texels / p_length), 0.0);
}

// p_pos: undisplaced world-space position. p_spacing: vertex spacing in metres.
// jacobian carries the summed FOAM, in [0, 1+], not Gerstner's fold-limit signal: the simulation already
// turned the Jacobian into whitecaps with its own bias, decay and accumulation.
WaveSample water_eval_fft(vec3 p_pos, float p_spacing) {
	WaveSample o;
	vec2 domain = p_pos.xz - _water_domain_origin.xz;
	float texels = float(textureSize(_fft_displacement, 0).x);
	vec3 disp = vec3(0.0);
	vec2 slope = vec2(0.0);
	float foam = 0.0;
	for (int i = 0; i < 4; i++) {
		float len = _fft_lengths[i];
		vec3 uvw = vec3(domain / len, float(i));
		float lod = water_fft_lod(p_spacing, len, texels);
		vec4 d = textureLod(_fft_displacement, uvw, lod);
		disp += d.xyz;
		foam += d.w;
		slope += textureLod(_fft_slope, uvw, lod).xy;
	}
	o.position = p_pos + disp;
	o.normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	o.jacobian = foam;
	return o;
}

// ---------------------------------------------------------------------------
// The fBm fallback (FFT spec §3, Phase 4): GarrettGunnell/Water's vertexFBM / fragmentFBM. Also NOT part
// of the parity contract above; Phase 5 transcribes it for the buoys.
//
// Evaluated in a domain scaled by the set's `frequency`, so the first octave runs at 1 rad per unit and
// the drag displaces by the same fraction of a wavelength on a pond as on an ocean. At 1 rad/m this is
// the reference exactly. See Pasture3DWaterFBM for that and the two deviations below.
// ---------------------------------------------------------------------------

// Phase rate rounded to a whole number of cycles per water_time_period, so the clock's wrap is seamless.
float water_fbm_speed(float p_speed) {
	float period = max(water_time_period, 1e-3);
	return round(p_speed * period / WATER_TAU) * (WATER_TAU / period);
}

// One set's sum at p_domain. Returns (height in metres, dh/dx, dh/dz).
//
// p_spacing is the sample spacing in metres and p_min_samples how many samples an octave needs: each
// octave fades from full weight at 2 x p_min_samples samples a wavelength to nothing at p_min_samples,
// and the loop stops at the first octave with nothing left while the series is shortening. The weight
// takes the octave's mean and its drag with it, so a fading octave neither lifts the sea nor warps the
// ones after it.
//
// p_drag_by_frequency is the one difference between the reference's two functions: fragmentFBM's drag is
// its slope (which carries f), vertexFBM's is not.
vec3 water_fbm(vec2 p_domain, vec4 p0, vec4 p1, vec4 p2, vec4 p3, float p_spacing, float p_min_samples,
		bool p_drag_by_frequency) {
	float seed = p0.x;
	float k0 = max(p0.z, 1e-6);
	float f = 1.0;
	float a = p1.x;
	float speed = p1.z;
	vec2 q = p_domain * k0;
	float h = 0.0;
	vec2 n = vec2(0.0);
	int octaves = int(p3.z);
	float min_length = max(p_spacing, 1e-6) * p_min_samples;
	for (int i = 0; i < octaves; i++) {
		float w = clamp(WATER_TAU / (k0 * f * min_length) - 1.0, 0.0, 1.0);
		if (w <= 0.0 && p0.w >= 1.0) {
			break;
		}
		vec2 d = vec2(cos(seed), sin(seed));
		float x = dot(d, q) * f + water_time * water_fbm_speed(speed);
		// The DC offset is removed: exp(sin) averages p3.y per unit amplitude.
		float wave = a * exp(p2.z * sin(x) - p2.w);
		float dwave = p2.z * wave * cos(x); // d(wave)/dx
		h += w * (wave - a * p3.y);
		n += (w * f * dwave) * d;
		q -= d * (w * dwave * a * p2.x * (p_drag_by_frequency ? f : 1.0));
		f *= p0.w;
		a *= p1.y;
		speed *= p1.w;
		seed += p0.y;
	}
	float scale = p2.y / max(p3.x, 1e-6);
	return vec3(h * scale, n * (scale * k0));
}

// The geometry: the vertex set at the mesh spacing, four samples a wavelength as the FFT's mip rule.
WaveSample water_eval_fbm(vec3 p_pos, float p_spacing) {
	WaveSample o;
	vec2 domain = p_pos.xz - _water_domain_origin.xz;
	vec3 s = water_fbm(domain, _fbm_v0, _fbm_v1, _fbm_v2, _fbm_v3, p_spacing, 4.0, false);
	o.position = p_pos + vec3(0.0, s.x, 0.0);
	o.normal = normalize(vec3(-s.y, 1.0, -s.z));
	o.jacobian = 0.0;
	return o;
}
#endif

#endif // WATER_WAVES_INC
