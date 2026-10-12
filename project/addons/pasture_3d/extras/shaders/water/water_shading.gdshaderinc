// Pasture3D Water — fragment stage.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §3.3-§3.7
//
// Budget (§5): zero sin/cos, zero integer multiplies, zero mat4 products, one
// normalize, four texture fetches. Everything expensive happens per vertex.
//
// The normal is assembled in the SLOPE domain, not by blending normal vectors:
// dh/dx and dh/dz add, so the wave slope and two scrolled detail layers
// combine with two adds and one normalize at the end. That is the entire reason
// the detail texture is a derivative map and not a normal map.

#ifndef WATER_SHADING_INC
#define WATER_SHADING_INC

#ifdef WATER_PBR
// The reference's Fresnel for eta 1.33, flattened with roughness: R = (0.33 / 2.33)^2. One definition for
// the sun term in light() and the environment reflection in fragment(), which the reference shares.
float water_ref_fresnel(float p_n_dot_v, float p_alpha) {
	float f = 0.020059 + 0.979941 * pow(max(1.0 - p_n_dot_v, 0.0), 5.0 * exp(-2.69 * p_alpha))
		/ (1.0 + 22.7 * pow(p_alpha, 1.5));
	return clamp(f, 0.0, 1.0);
}
#endif

void fragment() {
#ifdef WATER_DEBUG_GLOBALS
	// Diagnostic: writes the three plugin-driven globals straight to ALBEDO so
	// the global-uniform plumbing can be verified in isolation, at any phase,
	// without needing waves or textures to be implemented. Used by the Phase 1
	// gate (bench/WaterPhase1Gate.gd) and worth keeping for future regressions.
	//
	// This is an #else and not an early `return` because Godot's shader language
	// rejects `return` inside fragment()/vertex() outright.
	ALBEDO = vec3(
		clamp(water_time, 0.0, 1.0),
		clamp(water_sun_color.g, 0.0, 1.0),
		clamp(water_sun_direction.y * 0.5 + 0.5, 0.0, 1.0));
	ALPHA = 1.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
#elif defined(WATER_DEBUG_SURFACE)
	// Diagnostic: the wave function itself, with the shading taken out of the
	// way. EMISSION passes through the light loop untouched, and a black ALBEDO
	// with zero SPECULAR contributes nothing, so this is unshaded without
	// needing a render_mode the wrappers would have to opt into.
	//
	// This exists because a shaded diff is the wrong instrument for comparing
	// two tessellations of the same surface: water is near-mirror, so a normal
	// difference far too small to see becomes a saturated specular pixel, and
	// the metric ends up measuring highlight placement rather than geometry.
	ALBEDO = vec3(0.0);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	ALPHA = 1.0;
	vec3 dbg_n = normalize(v_wave_normal);
	EMISSION = vec3(
		dbg_n.x * 0.5 + 0.5,
		dbg_n.z * 0.5 + 0.5,
		clamp(v_world_pos.y * (1.0 / 8.0) + 0.5, 0.0, 1.0));
#else

	vec2 domain = v_world_pos.xz - _water_domain_origin.xz;

	// The vertex normal back into the slope domain. v_wave_normal always points up
	// -- the flip for the underwater view happens after detail is added, because
	// an inverted normal would put the divide below on the wrong side of zero.
	vec3 wave_normal = normalize(v_wave_normal);
	vec2 slope = -wave_normal.xz / max(wave_normal.y, 1e-3);

#ifdef WATER_FFT
	// Per-pixel slope and foam from the cascades, sampled at the REST position. Replaces the per-vertex
	// normal outright: the vertex stage filtered the short cascades out of the geometry, and this is where
	// they come back. Implicit-derivative sampling is valid here because _wave_model is uniform.
	bool fft = _wave_model == WATER_MODEL_FFT;
	float fft_foam = 0.0;
	float fft_height = 0.0;
	if (fft) {
		slope = vec2(0.0);
		for (int i = 0; i < 4; i++) {
			if (_fft_drawn[i] == 0.0) {
				continue;
			}
			vec3 uvw = vec3(v_fft_domain / _fft_repeat[i], float(i));
			slope += texture(_fft_slope, uvw).xy;
			vec4 disp = texture(_fft_displacement, uvw);
			fft_foam += disp.w;
			fft_height += disp.y;
		}
		fft_foam += _fft_foam_offset;
		// L8, then G5: scaled, then faded toward flat. The reference lerps the NORMAL toward up, not the
		// slope toward zero; the two differ wherever the slope is steep.
		slope *= fft_normal_strength;
		vec3 fft_n = normalize(mix(vec3(0.0, 1.0, 0.0), normalize(vec3(-slope.x, 1.0, -slope.y)),
				water_fft_fade(v_fft_depth, fft_normal_falloff)));
		slope = -fft_n.xz / fft_n.y;
	}
	// The fBm fallback's normals: the fragment set, summed per pixel at the rest position like the cascades,
	// down to the octave this pixel can still resolve (two samples a wavelength). Its height is light()'s
	// crest height. The footprint is taken outside the branch, where derivatives are always defined.
	// Any value but FFT draws the fBm (water_surface.gdshaderinc), so this is !fft and not == FBM.
	bool fbm = !fft;
	float fbm_footprint = max(length(dFdx(v_fft_domain)), length(dFdy(v_fft_domain)));
	float fbm_height = 0.0;
	if (fbm) {
		vec3 s = water_fbm(v_fft_domain, _fbm_f0, _fbm_f1, _fbm_f2, _fbm_f3, fbm_footprint, 2.0, true);
		slope = s.yz;
		fbm_height = s.x;
	}
#endif

	// Detail amplitude the distance fade removed. Fed to roughness below so the
	// energy is redistributed rather than thrown away (§3.4).
	float detail_lost = 0.0;

#ifdef WATER_DETAIL
	float detail_fade = 1.0 - clamp(
		(v_view_dist - detail_fade_start) / max(detail_fade_end - detail_fade_start, 1e-3),
		0.0, 1.0);

	// Two fetches from ONE texture: same mip chain, same cache lines, and the
	// second layer costs little more than the first. Mip filtering is the
	// anti-aliasing here -- hardware trilinear is a correct prefilter, which is
	// what the legacy shader's widened finite-difference stencil never was.
#ifdef WATER_FLOW
	// Advected along the per-vertex flow direction (spec §10), cross-faded between
	// two half-period-offset copies so the shear a varying direction produces is
	// reset before it becomes visible.
	//
	// The weight is triangular: |1 - 2*phase| is 1 when a copy has just been reset
	// (zero distortion) and 0 when it is half a cycle old (maximum distortion), so
	// each copy is at full weight exactly when it is freshest. The two copies are
	// half a period apart, so one is always near its reset.
	float flow_len = water_flow_period();
	float flow_phase = fract(water_time / flow_len);
	float flow_phase_b = fract(flow_phase + 0.5);
	float flow_blend = abs(1.0 - 2.0 * flow_phase);
	// Metres of travel, converted to UV by the same scale the layer is sampled at.
	vec2 flow_step = v_flow.xy * (v_flow.z * flow_speed_scale) * flow_len;

	vec2 uv0a = (domain - flow_step * flow_phase) * detail_scale0;
	vec2 uv0b = (domain - flow_step * flow_phase_b) * detail_scale0;
	vec2 detail = mix(texture(detail_deriv, uv0b).rg, texture(detail_deriv, uv0a).rg,
		flow_blend) * 2.0 - 1.0;
#if WATER_DETAIL_LAYERS > 1
	vec2 uv1a = (domain - flow_step * flow_phase) * detail_scale1;
	vec2 uv1b = (domain - flow_step * flow_phase_b) * detail_scale1;
	detail += mix(texture(detail_deriv, uv1b).rg, texture(detail_deriv, uv1a).rg,
		flow_blend) * 2.0 - 1.0;
#endif
#else
	vec2 uv0 = domain * detail_scale0 - water_scroll(detail_flow0 * detail_scale0);
	vec2 detail = texture(detail_deriv, uv0).rg * 2.0 - 1.0;
#if WATER_DETAIL_LAYERS > 1
	vec2 uv1 = domain * detail_scale1 - water_scroll(detail_flow1 * detail_scale1);
	detail += texture(detail_deriv, uv1).rg * 2.0 - 1.0;
#endif
#endif

	slope += detail * (detail_strength * detail_fade);
	detail_lost = detail_strength * (1.0 - detail_fade);
#endif

	vec3 world_normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	// Water is a two-sided sheet (render_mode cull_disabled): flip for the
	// underwater view. The legacy shader was cull_back and simply vanished from
	// below, while still testing for a submerged camera.
	//
	// Keyed on the CAMERA, not on FRONT_FACING, and the difference is visible.
	// depth_draw_never means the water does not occlude itself, so cull_disabled
	// rasterises the back side of every wave crest -- fragments that a solid
	// surface would have hidden behind the crest in front of them. Those are
	// !FRONT_FACING while the viewer is plainly above the water, and flipping them
	// pointed their normal at the ground: they shaded as dark dashes scattered
	// across the mid-distance at grazing pitches, which is what the Phase 5 A/B
	// captures showed (§8.6).
	//
	// Which side the viewer is on is a property of the camera and cannot be read
	// off one triangle. v_base_y is the undisplaced sheet -- sea_level, or the
	// mesh's own height -- so this stays correct for a plain MeshInstance3D that
	// has no sea_level uniform at all.
	if (CAMERA_POSITION_WORLD.y < v_base_y) {
		world_normal = -world_normal;
	}

	NORMAL = normalize(mat3(VIEW_MATRIX) * world_normal);

	float n_dot_v = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = water_fresnel(n_dot_v);

#ifdef WATER_PBR
	// L5: the body colour is the reference's scatter_color, lit in light().
	vec3 body_base = scatter_color;
#else
	vec3 body_base = deep_color;
#endif
	vec3 albedo = body_base;
	// Opacity from absorption alone, before fresnel. Opaque unless the depth
	// path says otherwise, which is the right default: with no way to know what
	// is behind, showing it would be a guess.
	float absorb_alpha = 1.0;
	float thickness = 0.0;

#ifdef WATER_DEPTH_FADE
	float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	// Scalar linear-depth reconstruction (§3.5). Only view-space z is wanted, and
	// four scalars of the inverse projection give it: 2 mul, 2 add, 1 divide
	// against the legacy shader's two full mat4 chains. Phase 2 gate G measured
	// this exactly equal to the mat4 path over 186k pixels under reversed-Z.
	float scene_vz = (INV_PROJECTION_MATRIX[2][2] * raw_depth + INV_PROJECTION_MATRIX[3][2])
		/ (INV_PROJECTION_MATRIX[2][3] * raw_depth + INV_PROJECTION_MATRIX[3][3]);
	// View space looks down -Z, so both are negative and the farther one is more
	// so. VERTEX is the water surface. No world-space reconstruction, and no
	// sea_level in sight -- the legacy shader added it twice (§9.1).
	thickness = max(0.0, VERTEX.z - scene_vz);

	// Beer-Lambert, per channel. This is the ocean/lake/pond knob (§3.5): the
	// three presets differ mainly in how fast and how selectively they absorb.
	vec3 transmit = exp(-absorption * thickness);

	// Fixed-function alpha blending has ONE scalar destination factor, so the
	// per-channel filtering of the background cannot be done without a backbuffer
	// copy -- and avoiding that copy is the whole point of WATER_REFRACTION being
	// off by default. What is done instead: pick the scalar alpha from luminance,
	// then solve for the albedo that makes the water's OWN contribution exact per
	// channel. Deep water lands on deep_color exactly, shallow water lands on the
	// background almost untinted, and the approximation is confined to mid
	// depths, where it shows as a colour blended toward the water rather than a
	// background filtered by it. Visually close; physically not the same thing,
	// so it is written down rather than glossed.
	absorb_alpha = 1.0 - dot(transmit, WATER_LUMA);
	albedo = min(body_base * (vec3(1.0) - transmit) / max(absorb_alpha, 1e-3), vec3(1.0));
#endif

	// Reflection replaces transmission: light bounced off the surface did not
	// come from behind it, so opacity has to rise with fresnel. This is the other
	// half of the Phase 1 horizon artefact -- alpha already rose at grazing
	// incidence, but with no reflection term to put in the sky's place the
	// brightest pixels on the surface went opaque and dark (§8.3).
	float alpha = absorb_alpha + (1.0 - absorb_alpha) * fresnel;

#ifdef WATER_DETAIL
	float roughness = clamp(base_roughness + detail_lost * variance_to_roughness, 0.02, 0.35);
#else
	float roughness = clamp(base_roughness, 0.02, 0.35);
#endif

#if defined(WATER_FOAM_CREST) || defined(WATER_FOAM_SHORE)
	float foam = 0.0;
#ifdef WATER_FOAM_CREST
#ifdef WATER_FFT
	// The simulation's foam is already coverage in [0, 1+]. The fBm has no breaking signal at all (the
	// reference draws no foam).
	float crest = fft ? clamp(fft_foam, 0.0, 1.0) * water_fft_fade(v_fft_depth, fft_foam_falloff) : 0.0;
#else
	// A stream's slope: whitecaps from threshold to threshold + softness.
	float crest = smoothstep(foam_crest_threshold,
		foam_crest_threshold + foam_crest_softness, v_jacobian);
	foam += crest * foam_crest_amount;
#endif
#endif
#if defined(WATER_FOAM_SHORE) && defined(WATER_DEPTH_FADE)
	// Also free: thickness came out of the depth fetch above.
	foam += (1.0 - smoothstep(0.0, foam_shore_depth, thickness)) * foam_shore_amount;
#endif
#ifdef WATER_FLOW
	// Shore foam on a river streaks downstream rather than sitting still, so it
	// rides the same advection the detail layers do -- one texture, one flow, one
	// cross-fade, sampled at the foam scale.
	vec2 foam_uv_a = (domain - flow_step * flow_phase) * foam_scale;
	vec2 foam_uv_b = (domain - flow_step * flow_phase_b) * foam_scale;
	foam = clamp(foam, 0.0, 1.0) * mix(texture(foam_tex, foam_uv_b).r,
		texture(foam_tex, foam_uv_a).r, flow_blend);
#else
	foam = clamp(foam, 0.0, 1.0) * texture(foam_tex,
		domain * foam_scale - water_scroll(foam_flow * foam_scale)).r;
#endif
#if defined(WATER_FOAM_CREST) && defined(WATER_FFT)
	// L2: the reference's crest foam is untextured. foam_tex breaks up the shore foam only.
	foam = clamp(foam + crest * foam_crest_amount, 0.0, 1.0);
#endif

#ifdef WATER_PBR
	// L1 is below, in the outputs: the foam is an unlit lerp. L3: roughness rises by the modifier.
	roughness = clamp(roughness + foam * foam_roughness_modifier, 0.02, 1.0);
#else
	albedo = mix(albedo, foam_color, foam);
	roughness = mix(roughness, foam_roughness, foam);
#endif
	alpha = mix(alpha, 1.0, foam);
#endif

#ifdef WATER_PBR
	// The reference's output is lerp(water, foam_color, foam), the foam an unlit constant (L1). Every lit
	// term below and in light() carries (1 - foam), and the foam colour is emitted. It glows in shadow,
	// as the reference's does. ALBEDO 0: the reference has no ambient term, and light() needs no ALBEDO.
	float lerp_foam = 0.0;
#if defined(WATER_FOAM_CREST) || defined(WATER_FOAM_SHORE)
	lerp_foam = foam;
	EMISSION = foam * foam_color;
#endif
	v_body_color = albedo;
	ALBEDO = vec3(0.0);
	if (use_environment_map) {
		// L4: F * env * strength, the reference's reflection, at the reference's roughness.
		float env_alpha = sun_roughness + lerp_foam * foam_roughness_modifier;
		float env_f = water_ref_fresnel(dot(NORMAL, VIEW), env_alpha);
		vec3 env_dir = mat3(INV_VIEW_MATRIX) * reflect(-VIEW, NORMAL);
		EMISSION += (1.0 - lerp_foam) * env_f * texture(environment_map, env_dir).rgb * environment_light_strength;
		SPECULAR = 0.0;
	} else {
		// Godot's sky. Its env BRDF is not linear in SPECULAR, so this (1 - foam) is the approximation.
		SPECULAR = specular_amount * (1.0 - lerp_foam);
	}
#else
	ALBEDO = albedo;
	SPECULAR = specular_amount;
#endif
	ROUGHNESS = roughness;
	ALPHA = alpha;

#ifdef WATER_DEBUG_FFT_SHADING
#ifndef WATER_FOAM_CREST
#error "WATER_DEBUG_FFT_SHADING reads the crest foam; it needs WATER_FOAM_CREST"
#endif
	// Diagnostic, unlit like WATER_DEBUG_SURFACE but at the END of the fragment stage: the per-pixel slope
	// after normal strength and the normal fade, and the crest foam after its fade. What WATER_DEBUG_SURFACE
	// encodes is the VERTEX normal, which neither touches (WaterFFTWiringGate [N]).
	ALBEDO = vec3(0.0);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	ALPHA = 1.0;
	EMISSION = vec3(slope.x * 0.125 + 0.5, slope.y * 0.125 + 0.5, crest);
#endif

#ifdef WATER_PBR
	// What light() needs that it cannot read itself. The crest height is the displaced surface above the
	// rest level: the per-pixel cascade sum under FFT (the reference's own H), the fragment set under the
	// fBm, and the vertex-stage height on a stream, where the vertex sum is the only one there is.
#ifdef WATER_FFT
	float crest_height = fft ? fft_height : fbm_height;
#else
	float crest_height = v_world_pos.y - v_base_y;
#endif
	float pbr_foam = 0.0;
#if defined(WATER_FOAM_CREST) || defined(WATER_FOAM_SHORE)
	pbr_foam = foam;
#endif
	v_pbr = vec2(pbr_foam, max(crest_height, 0.0));
#endif

#endif // WATER_DEBUG_GLOBALS

#ifdef WATER_SHORE_MASK
	// Outside every #if above, deliberately: the debug readouts are how the shore
	// is measured, and a mask that applied to the shipping path but not to the
	// readout would be measured as perfect by construction.
	//
	// Multiplied into whatever alpha the branch above arrived at, so shore foam
	// still raises it and then this takes it away again at the waterline -- foam
	// that fades out with the water it sits on rather than surviving it.
	ALPHA *= water_shore_alpha(v_shore_xz);
#endif
}

#ifdef WATER_PBR
// ---------------------------------------------------------------------------
// Sun lighting: GarrettGunnell/Water's NEW_LIGHTING, per light (FFT spec §3.1).
//
// The reference evaluates one hardcoded sun and writes the final colour. Godot calls this once per light,
// so the port is the reference's sun terms, all of them into SPECULAR_LIGHT (ALBEDO is 0):
//   - the environment reflection is the fragment stage's: environment_map into EMISSION, or Godot's sky
//     through SPECULAR when there is none (D3);
//   - there is no ambient term, as the reference has none;
//   - the foam is emitted unlit by the fragment stage, so every term here carries (1 - foam) (L1);
//   - shadows arrive through ATTENUATION, which every term here takes. The reference has no shadows, so
//     nothing in it says which terms a shadow should dim; all of them is the only answer that leaves a
//     shadowed patch of water lit by nothing but its reflection.
// ---------------------------------------------------------------------------

// Smith masking for a Beckmann distribution, Walter et al.'s rational fit. The reference's form,
// including its use of the HALF vector where the textbook has the normal. The sqrt argument is floored so
// a viewer exactly on the half vector reads "unmasked" (a -> inf, 0) and not NaN.
float water_smith_beckmann(vec3 p_h, vec3 p_s, float p_alpha) {
	float h_dot_s = max(0.001, clamp(dot(p_h, p_s), 0.0, 1.0));
	float a = h_dot_s / (p_alpha * sqrt(max(1.0 - h_dot_s * h_dot_s, 1e-12)));
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a * a) / (3.535 * a + 2.181 * a * a) : 0.0;
}

float water_beckmann(float p_n_dot_h, float p_alpha) {
	float n2 = p_n_dot_h * p_n_dot_h;
	float a2 = p_alpha * p_alpha;
	return exp((n2 - 1.0) / (a2 * n2)) / (PI * a2 * n2 * n2);
}

void light() {
	// The reference's _SunIrradiance, in the reference's units. Godot hands light() its colour times
	// energy times PI -- measured, not assumed: WaterPBRGate [E] renders a flat sheet against this
	// arithmetic, and the same prediction without the divide is its control. Getting it wrong is a silent
	// 3x on every term below.
	vec3 irr = LIGHT_COLOR * (ATTENUATION / PI);

	float foam = v_pbr.x;
	vec3 h = normalize(LIGHT + VIEW);
	float n_dot_l = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	// L3: the reference's a = roughness + foam * foamRoughnessModifier.
	float alpha = sun_roughness + foam * foam_roughness_modifier;
	float light_mask = water_smith_beckmann(h, LIGHT, alpha);
	float g = 1.0 / (1.0 + water_smith_beckmann(h, VIEW, alpha) + light_mask);
	float f = water_ref_fresnel(dot(NORMAL, VIEW), alpha);

	// The reference divides by the MACRO normal's incidence -- world up -- not the textbook 4 (n.l)(n.v).
	vec3 up = VIEW_MATRIX[1].xyz;
	float up_dot_l = max(0.001, clamp(dot(up, LIGHT), 0.0, 1.0));
	float d = water_beckmann(max(1e-4, dot(NORMAL, h)), alpha);

	vec3 specular = vec3(f * g * d / (4.0 * up_dot_l) * n_dot_l);

	float v_dot_n = clamp(dot(VIEW, NORMAL), 0.0, 1.0);
	float k = view_scatter * v_dot_n * v_dot_n;
#ifdef WATER_SCATTER
	float into_sun = clamp(dot(LIGHT, -VIEW), 0.0, 1.0);
	float away = 0.5 - 0.5 * dot(LIGHT, NORMAL);
	k += wave_peak_scatter * v_pbr.y * (into_sun * into_sun) * (into_sun * into_sun) * (away * away * away);
#endif
	float body = k / (1.0 + light_mask) + shadow_scatter * n_dot_l;

	// output = (1 - F) scatter + specular, lerped toward the (emitted) foam colour by foam.
	vec3 scatter = body * v_body_color + bubble_density * bubble_color;
	SPECULAR_LIGHT += irr * (1.0 - foam) * ((1.0 - f) * scatter + specular);
}
#endif

#endif // WATER_SHADING_INC
