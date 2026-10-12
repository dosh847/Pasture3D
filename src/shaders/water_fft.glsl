// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// GLSL compute kernels for the FFT ocean. Spec: PASTURE3D_WATER_FFT_SPEC.md §2.1.
// Ported from Garrett Gunnell's FFTWater.compute (github.com/GarrettGunnell/Water), which in turn credits
// gasgiant's FFT-Ocean for the JONSWAP/FFT implementation.
//
// One source, seven kernels: Pasture3DWaterFFT prepends "#version 450", N, LOG_N and exactly one KERNEL_*
// define per compiled variant. Each kernel declares only the bindings it uses, because Godot builds a
// uniform set from the shader's reflected layout and an unused binding is stripped by the compiler.
//
// The spectrum is the reference's, quirks included (PASTURE3D_WATER_REFERENCE_SPEC.md S1-S3, S9, S10): eight
// spectra, two per cascade; its h0 normalisation; the cos^2 half of the spread at the unrotated angle; its
// hash constants as HLSL truncates them. Band limits (k_lo/k_hi) are optional and default to the reference's
// full overlap. Deviations, each marked where it happens:
//   - foam decays and accumulates per SECOND (dt), not per dispatch;
//   - the dispersion phase is reduced to one cycle before cos/sin, and uses the finite-depth w(k) that
//     the spectrum was built with (the reference advances by deep-water sqrt(g k));
//   - the Nyquist row and column are empty: a mode at k = -N/2 is its own conjugate partner, so it
//     breaks the two-real-signals-per-FFT packing and leaks between the packed channels.
R"(
#define PI 3.14159265358979323846
#define TWO_PI 6.28318530717958647692

#if defined(KERNEL_FFT_H) || defined(KERNEL_FFT_V)
layout(local_size_x = N, local_size_y = 1, local_size_z = 1) in;
#else
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif

struct Spectrum {
	float scale;
	float angle;
	float spread_blend;
	float swell;
	float alpha;
	float peak_omega;
	float gamma;
	float short_waves_fade;
};

#if defined(KERNEL_INIT) || defined(KERNEL_UPDATE) || defined(KERNEL_ASSEMBLE)
// Rebuilt by the host when a knob changes; constant across frames otherwise. Layout mirrored by
// Pasture3DWaterFFT::_write_params() -- 88 floats, std430.
layout(set = 0, binding = 0, std430) restrict readonly buffer Params {
	Spectrum spectra[8];  // cascade i: [2i] and [2i+1]
	vec4 length_scales;   // metres per cascade tile
	vec4 k_lo;            // band limits per cascade, rad/m: k_lo <= |k| < k_hi
	vec4 k_hi;
	vec2 lambda;          // choppiness (horizontal displacement scale)
	float gravity;
	float depth;
	float repeat_time;    // == water_time_period: dispersion is quantised to it (spec G2)
	float foam_bias;
	float foam_threshold;
	float foam_add;       // per second
	float foam_decay;     // per second
	uint seed;
	float pad0;
	float pad1;
} params;
#endif

#if defined(KERNEL_INIT) || defined(KERNEL_PACK) || defined(KERNEL_UPDATE)
// xy = h0(k), zw = conj(h0(-k)) after PACK. 4 layers, one per cascade.
layout(rgba32f, set = 0, binding = 1) restrict uniform image2DArray initial_spectrum;
#endif

#if defined(KERNEL_UPDATE) || defined(KERNEL_FFT_H) || defined(KERNEL_FFT_V) || defined(KERNEL_ASSEMBLE)
// 8 layers: [2i] = (Dx + i*Dz, Dy + i*Dzx), [2i+1] = (Dyx + i*Dyz, Dxx + i*Dzz). Transformed in place.
layout(rgba32f, set = 0, binding = 2) restrict uniform image2DArray spectrum;
#endif

#ifdef KERNEL_ASSEMBLE
// One 2D view per cascade: the outputs carry mip chains, and a storage binding has to name a single
// level, which this godot-cpp can only express as a per-layer 2D slice.
layout(rgba16f, set = 0, binding = 3) restrict uniform image2D displacement[4]; // xyz metres, a foam
layout(rgba16f, set = 0, binding = 4) restrict writeonly uniform image2D slope[4]; // xy slope, z jacobian
#endif

#ifdef KERNEL_DOWNSAMPLE
layout(rgba16f, set = 0, binding = 5) restrict readonly uniform image2D disp_src[4];
layout(rgba16f, set = 0, binding = 6) restrict writeonly uniform image2D disp_dst[4];
layout(rgba16f, set = 0, binding = 7) restrict readonly uniform image2D slope_src[4];
layout(rgba16f, set = 0, binding = 8) restrict writeonly uniform image2D slope_dst[4];
layout(push_constant, std430) uniform Push {
	uint dst_size;
	uint pad0;
	uint pad1;
	uint pad2;
} pc;
#endif

#if defined(KERNEL_UPDATE) || defined(KERNEL_ASSEMBLE)
layout(push_constant, std430) uniform Push {
	float time;
	float dt;
	float pad0;
	float pad1;
} pc;
#endif

vec2 complex_mult(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

#if defined(KERNEL_INIT) || defined(KERNEL_UPDATE)
// Finite-depth dispersion. INIT weights the spectrum by it and UPDATE advances the phase by it: the
// reference advances by the deep-water sqrt(g k), so at a pond's depth the two disagreed.
float dispersion(float k) {
	return sqrt(params.gravity * k * tanh(min(k * params.depth, 20.0)));
}

#endif

#ifdef KERNEL_INIT
float hash(uint n) {
	// Integer hash, Hugo Elias, with the reference's constants: it writes them as hex, 0x789221U and
	// 0x1376312589U, and HLSL truncates the 36-bit second one to its low 32 bits. Elias' decimal 789221 and
	// 1376312589 draw a different sea from the same seed.
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 0x789221u) + 0x76312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

vec2 uniform_to_gaussian(float u1, float u2) {
	// Box-Muller. hash() can return exactly 0, and log(0) is -inf.
	float r = sqrt(-2.0 * log(max(u1, 1e-7)));
	float theta = TWO_PI * u2;
	return vec2(r * cos(theta), r * sin(theta));
}

float dispersion_derivative(float k) {
	float kd = min(k * params.depth, 20.0);
	float th = tanh(kd);
	float ch = cosh(kd);
	return params.gravity * (params.depth * k / ch / ch + th) / dispersion(k) / 2.0;
}

float normalization_factor(float s) {
	float s2 = s * s;
	float s3 = s2 * s;
	float s4 = s3 * s;
	if (s < 5.0) {
		return -0.000564 * s4 + 0.00776 * s3 - 0.044 * s2 + 0.192 * s + 0.163;
	}
	return -4.80e-08 * s4 + 1.07e-05 * s3 - 9.53e-04 * s2 + 5.90e-02 * s + 3.93e-01;
}

float cosine_2s(float theta, float s) {
	return normalization_factor(s) * pow(abs(cos(0.5 * theta)), 2.0 * s);
}

float spread_power(float omega, float peak_omega) {
	if (omega > peak_omega) {
		return 9.77 * pow(abs(omega / peak_omega), -2.5);
	}
	return 6.97 * pow(abs(omega / peak_omega), 5.0);
}

float direction_spectrum(float theta, float omega, Spectrum sp) {
	float s = spread_power(omega, sp.peak_omega) +
			16.0 * tanh(min(omega / sp.peak_omega, 20.0)) * sp.swell * sp.swell;
	// As the reference: the cos^2 half at the UNROTATED angle, so with spread_blend < 1 part of the energy
	// travels along +-X whatever the wind direction (S9), and its 3.1415 for pi.
	return mix(2.0 / 3.1415 * cos(theta) * cos(theta), cosine_2s(theta - sp.angle, s), sp.spread_blend);
}

float tma_correction(float omega) {
	float omega_h = omega * sqrt(params.depth / params.gravity);
	if (omega_h <= 1.0) {
		return 0.5 * omega_h * omega_h;
	}
	if (omega_h < 2.0) {
		return 1.0 - 0.5 * (2.0 - omega_h) * (2.0 - omega_h);
	}
	return 1.0;
}

float jonswap(float omega, Spectrum sp) {
	float sigma = (omega <= sp.peak_omega) ? 0.07 : 0.09;
	float r = exp(-(omega - sp.peak_omega) * (omega - sp.peak_omega) / 2.0 / sigma / sigma / sp.peak_omega /
			sp.peak_omega);
	float inv = 1.0 / omega;
	float peak_over = sp.peak_omega / omega;
	return sp.scale * tma_correction(omega) * sp.alpha * params.gravity * params.gravity * inv * inv * inv *
			inv * inv * exp(-1.25 * peak_over * peak_over * peak_over * peak_over) * pow(abs(sp.gamma), r);
}

float short_waves_fade(float k, Spectrum sp) {
	return exp(-sp.short_waves_fade * sp.short_waves_fade * k * k);
}

void main() {
	uvec2 id = gl_GlobalInvocationID.xy;
	if (id.x >= uint(N) || id.y >= uint(N)) {
		return;
	}
	uint seed = id.x + uint(N) * id.y + uint(N);
	seed += params.seed;
	float half_n = float(N) / 2.0;
	for (int i = 0; i < 4; i++) {
		float delta_k = TWO_PI / params.length_scales[i];
		vec2 k = (vec2(id) - half_n) * delta_k;
		float k_len = length(k);

		seed += uint(i) + uint(hash(seed) * 10.0);
		vec4 u = vec4(hash(seed), hash(seed * 2u), hash(seed * 3u), hash(seed * 4u));
		vec2 gauss1 = uniform_to_gaussian(u.x, u.y);
		vec2 gauss2 = uniform_to_gaussian(u.z, u.w);

		vec4 h0 = vec4(0.0);
		// Nyquist row/column (id 0): no conjugate partner on the grid, see the header.
		if (id.x != 0u && id.y != 0u && params.k_lo[i] <= k_len && k_len < params.k_hi[i]) {
			float k_angle = atan(k.y, k.x);
			float omega = dispersion(k_len);
			float d_omega_dk = dispersion_derivative(k_len);
			Spectrum a = params.spectra[i * 2];
			Spectrum b = params.spectra[i * 2 + 1];
			float s = jonswap(omega, a) * direction_spectrum(k_angle, omega, a) * short_waves_fade(k_len, a);
			if (b.scale > 0.0) {
				s += jonswap(omega, b) * direction_spectrum(k_angle, omega, b) * short_waves_fade(k_len, b);
			}
			// The reference's normalisation: E|h0|^2 = 4 Psi(k) dk^2, so the realised height variance is
			// eight times the spectrum's integral (Pasture3DWaterFFT::get_height_sigma). Its scene's scales
			// of 0.1-0.25 are tuned against that.
			h0.xy = vec2(gauss2.x, gauss1.y) * sqrt(2.0 * s * abs(d_omega_dk) / k_len * delta_k * delta_k);
		}
		imageStore(initial_spectrum, ivec3(ivec2(id), i), h0);
	}
}
#endif // KERNEL_INIT

#ifdef KERNEL_PACK
void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= N || id.y >= N) {
		return;
	}
	ivec2 mirror = ivec2((N - id.x) % N, (N - id.y) % N);
	for (int i = 0; i < 4; i++) {
		// Concurrent threads read .xy of the texel this one rewrites, but the rewrite stores the same .xy,
		// so the read is the same value either side of it.
		vec2 h0 = imageLoad(initial_spectrum, ivec3(id, i)).xy;
		vec2 h0_conj = imageLoad(initial_spectrum, ivec3(mirror, i)).xy;
		imageStore(initial_spectrum, ivec3(id, i), vec4(h0, h0_conj.x, -h0_conj.y));
	}
}
#endif // KERNEL_PACK

#ifdef KERNEL_UPDATE
void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= N || id.y >= N) {
		return;
	}
	float half_n = float(N) / 2.0;
	float w_0 = TWO_PI / params.repeat_time;
	for (int i = 0; i < 4; i++) {
		vec4 initial = imageLoad(initial_spectrum, ivec3(id, i));
		vec2 h0 = initial.xy;
		vec2 h0_conj = initial.zw;

		vec2 k = (vec2(id) - half_n) * TWO_PI / params.length_scales[i];
		float k_mag = length(k);
		float k_mag_rcp = (k_mag < 0.0001) ? 1.0 : 1.0 / k_mag;

		// Quantised to whole cycles per repeat_time, so the surface at t = repeat_time is the surface at
		// t = 0 and the water_time wrap is seamless (spec G2).
		//
		// Reduced to one cycle BEFORE cos/sin. The short cascades run hundreds of cycles per loop, and GPU
		// sin/cos lose accuracy on arguments in the thousands of radians; q * (t / T) is exact in the
		// integer q, so fract() costs only the rounding of t / T.
		float cycles = floor(dispersion(k_mag) / w_0);
		float phase = TWO_PI * fract(cycles * (pc.time / params.repeat_time));
		vec2 e = vec2(cos(phase), sin(phase));

		vec2 htilde = complex_mult(h0, e) + complex_mult(h0_conj, vec2(e.x, -e.y));
		vec2 ih = vec2(-htilde.y, htilde.x);

		vec2 disp_x = ih * k.x * k_mag_rcp;
		vec2 disp_y = htilde;
		vec2 disp_z = ih * k.y * k_mag_rcp;

		vec2 disp_x_dx = -htilde * k.x * k.x * k_mag_rcp;
		vec2 disp_y_dx = ih * k.x;
		vec2 disp_z_dx = -htilde * k.x * k.y * k_mag_rcp;

		vec2 disp_y_dz = ih * k.y;
		vec2 disp_z_dz = -htilde * k.y * k.y * k_mag_rcp;

		// Two real signals per complex FFT: A + iB. Both are Hermitian, so after the inverse transform A
		// lands in the real part and B in the imaginary part.
		vec2 packed_xz = vec2(disp_x.x - disp_z.y, disp_x.y + disp_z.x);
		vec2 packed_y_zx = vec2(disp_y.x - disp_z_dx.y, disp_y.y + disp_z_dx.x);
		vec2 packed_slope = vec2(disp_y_dx.x - disp_y_dz.y, disp_y_dx.y + disp_y_dz.x);
		vec2 packed_xx_zz = vec2(disp_x_dx.x - disp_z_dz.y, disp_x_dx.y + disp_z_dz.x);

		imageStore(spectrum, ivec3(id, i * 2), vec4(packed_xz, packed_y_zx));
		imageStore(spectrum, ivec3(id, i * 2 + 1), vec4(packed_slope, packed_xx_zz));
	}
}
#endif // KERNEL_UPDATE

#if defined(KERNEL_FFT_H) || defined(KERNEL_FFT_V)
// Stockham radix-2, one workgroup per row, N threads, ping-pong in shared memory. No bit reversal: the
// butterfly indexing below is self-sorting.
shared vec4 fft_buffer[2][N];

void butterfly(uint step, uint index, out uvec2 indices, out vec2 twiddle) {
	uint b = uint(N) >> (step + 1u);
	uint w = b * (index / b);
	uint i = (w + index) % uint(N);
	float a = -TWO_PI / float(N) * float(w);
	// Conjugated twiddle: this is what makes it the INVERSE transform.
	twiddle = vec2(cos(a), -sin(a));
	indices = uvec2(i, i + b);
}

vec4 fft(uint t, vec4 value) {
	fft_buffer[0][t] = value;
	memoryBarrierShared();
	barrier();
	uint ping = 0u;
	for (uint step = 0u; step < uint(LOG_N); step++) {
		uvec2 idx;
		vec2 tw;
		butterfly(step, t, idx, tw);
		vec4 v = fft_buffer[ping][idx.y];
		fft_buffer[1u - ping][t] = fft_buffer[ping][idx.x] + vec4(complex_mult(tw, v.xy), complex_mult(tw, v.zw));
		ping = 1u - ping;
		memoryBarrierShared();
		barrier();
	}
	return fft_buffer[ping][t];
}

void main() {
	uint t = gl_LocalInvocationID.x;
	uint row = gl_WorkGroupID.y;
#ifdef KERNEL_FFT_H
	ivec2 texel = ivec2(int(t), int(row));
#else
	ivec2 texel = ivec2(int(row), int(t));
#endif
	for (int i = 0; i < 8; i++) {
		vec4 result = fft(t, imageLoad(spectrum, ivec3(texel, i)));
		imageStore(spectrum, ivec3(texel, i), result);
	}
}
#endif // KERNEL_FFT_H || KERNEL_FFT_V

#ifdef KERNEL_ASSEMBLE
vec4 permute(vec4 data, ivec2 id) {
	// The spectrum is indexed from -N/2; (-1)^(x+y) undoes that shift in the spatial domain.
	return data * (1.0 - 2.0 * float((id.x + id.y) % 2));
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= N || id.y >= N) {
		return;
	}
	vec2 lambda = params.lambda;
	for (int i = 0; i < 4; i++) {
		vec4 hd = permute(imageLoad(spectrum, ivec3(id, i * 2)), id);
		vec4 hs = permute(imageLoad(spectrum, ivec3(id, i * 2 + 1)), id);

		vec2 dx_dz = hd.xy;
		vec2 dy_dzx = hd.zw;
		vec2 dyx_dyz = hs.xy;
		vec2 dxx_dzz = hs.zw;

		float jacobian = (1.0 + lambda.x * dxx_dzz.x) * (1.0 + lambda.y * dxx_dzz.y) -
				lambda.x * lambda.y * dy_dzx.y * dy_dzx.y;

		vec3 disp = vec3(lambda.x * dx_dz.x, dy_dzx.x, lambda.y * dx_dz.y);
		vec2 slopes = dyx_dyz / (1.0 + abs(dxx_dzz * lambda));

		// Per SECOND, not per dispatch: the reference's exp(-decay) per frame makes foam last twice as
		// long at 30 fps as at 60.
		float foam = imageLoad(displacement[i], id).a;
		foam = clamp(foam * exp(-params.foam_decay * pc.dt), 0.0, 1.0);
		float biased = max(0.0, -(jacobian - params.foam_bias));
		if (biased > params.foam_threshold) {
			foam += params.foam_add * biased * pc.dt;
		}

		imageStore(displacement[i], id, vec4(disp, foam));
		imageStore(slope[i], id, vec4(slopes, jacobian, 0.0));
	}
}
#endif // KERNEL_ASSEMBLE

#ifdef KERNEL_DOWNSAMPLE
void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(pc.dst_size) || id.y >= int(pc.dst_size)) {
		return;
	}
	ivec2 s = id * 2;
	for (int i = 0; i < 4; i++) {
		vec4 d = imageLoad(disp_src[i], s) + imageLoad(disp_src[i], s + ivec2(1, 0)) +
				imageLoad(disp_src[i], s + ivec2(0, 1)) + imageLoad(disp_src[i], s + ivec2(1, 1));
		vec4 g = imageLoad(slope_src[i], s) + imageLoad(slope_src[i], s + ivec2(1, 0)) +
				imageLoad(slope_src[i], s + ivec2(0, 1)) + imageLoad(slope_src[i], s + ivec2(1, 1));
		imageStore(disp_dst[i], id, d * 0.25);
		imageStore(slope_dst[i], id, g * 0.25);
	}
}
#endif // KERNEL_DOWNSAMPLE
)"
