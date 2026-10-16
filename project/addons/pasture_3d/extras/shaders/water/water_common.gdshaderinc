// Pasture3D Water — shared declarations.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §2.1
//
// Included first by every water .gdshader wrapper. Owns feature defaults, the
// plugin-driven globals, all artist uniforms, and the vertex->fragment varyings.
// Contains no entry points.

#ifndef WATER_COMMON_INC
#define WATER_COMMON_INC

// ---------------------------------------------------------------------------
// Feature defaults. Wrappers override by #define-ing before the include.
// ---------------------------------------------------------------------------
// The wave model (PASTURE3D_WATER_FFT_SPEC.md §3): the FFT, and the fBm fallback, which shares its vertex
// spacing and rest-domain varying. Every surface variant draws it except a river, which replaces the wave
// model outright with its channel model (water_stream.gdshaderinc).
#ifndef WATER_STREAM_WAVES
#define WATER_FFT
#endif
// Values of _wave_model. 0 was the Gerstner table, retired in Phase 6 of the FFT port; it now draws the
// fBm, like any value but FFT.
#define WATER_MODEL_FFT 1
#define WATER_MODEL_FBM 2

// Garrett's lighting in light() (FFT spec §3.1). Every lit surface variant except rivers, which keep
// Godot's built-in lambert/GGX and the look they were tuned under. Off for the debug readouts, which write
// EMISSION with zero SPECULAR and rely on the light loop contributing nothing -- a custom light() adds
// SPECULAR_LIGHT whatever SPECULAR says.
#if !defined(WATER_STREAM_WAVES) && !defined(WATER_DEBUG_SURFACE) && !defined(WATER_DEBUG_GLOBALS) && !defined(WATER_NO_PBR) 		&& !defined(WATER_DEBUG_FFT_SHADING)
#define WATER_PBR
#endif

// The detail texture stood in for wavelengths a wave table could not reach. The FFT's short cascades and
// the fBm's fragment octaves reach them, so it is a river feature only (FFT spec §6.6).
#if defined(WATER_DETAIL) && defined(WATER_FFT)
#error "WATER_DETAIL is for stream variants: the FFT and the fBm draw the short waves it stood in for"
#endif

// ---------------------------------------------------------------------------
// Globals, owned by the plugin (spec §2.3).
//
// These MUST exist in the RenderingServer global table before any water
// material is loaded, or Godot warns "used global parameter ... was removed at
// some point" and the material renders black until it recompiles.
//
// Declared in project.godot [shader_globals] by the editor plugin (persisted,
// takes effect at startup), with a runtime global_shader_parameter_add()
// fallback for projects where the settings were never written. Phase 1 probes
// proved a runtime-only ProjectSettings.set_setting() does NOT register them.
// ---------------------------------------------------------------------------
global uniform float water_time;
// Points FROM the surface TOWARD the sun (the light's +Z basis column), so
// water_sun_direction.y > 0 means daytime. Matches the legacy shader's
// _light_direction convention.
global uniform vec3 water_sun_direction;
global uniform vec3 water_sun_color;
// The period water_time wraps at. The clock alone is not enough: anything that
// advances with it has to land on a whole number of its own cycles at the wrap
// or the seam the waves do not have is one the detail texture does. See
// water_scroll() below.
global uniform float water_time_period;

// ---------------------------------------------------------------------------
// Artist uniforms
// ---------------------------------------------------------------------------
group_uniforms body;
// Absorption coefficient per metre, per channel. This is the knob that turns an
// ocean into a lake into a pond (spec §3.5).
uniform vec3 absorption = vec3(0.35, 0.08, 0.05);
uniform vec3 deep_color : source_color = vec3(0.015, 0.05, 0.08);
#ifdef WATER_CLIPMAP
uniform float sea_level : hint_range(-500.0, 500.0, 0.01) = 0.0;
#endif
group_uniforms;

group_uniforms waves;
// Whether this variant draws the manager's wave profile at all. Nothing in the shader reads it; it is
// read back from C++ (Pasture3DOcean's configuration warning), so the shader that compiles the model is
// the thing that reports it instead of a guess from the file name. False on a stream variant, which
// replaces the wave model with its own channel model.
#ifdef WATER_FFT
uniform bool _draws_wave_profile = true;
#else
uniform bool _draws_wave_profile = false;
#endif

#ifdef WATER_FFT
// Which model this material draws, written by Pasture3DPoolManager per profile. A UNIFORM BRANCH rather
// than a variant, so the fallback can switch at runtime without swapping the shader on every cached
// material; uniform across a draw, so it costs a branch and no divergence (FFT spec §3). The default is
// the fBm, whose uniform defaults below are the reference's waves: a material dropped on a bare mesh, with
// no manager to upload anything, still makes waves (spec G6).
#ifdef WATER_STATIC_MODEL
// Measurement only: the branch folded at compile time, which is what the twin-variant alternative would
// ship. WaterModelBranchTiming times the uniform branch against it (FFT spec §6.4).
const int _wave_model = WATER_STATIC_MODEL;
#else
uniform int _wave_model = WATER_MODEL_FBM;
#endif
// The profile's Pasture3DWaterFFT outputs: 4 layers, one per cascade, full mip chains.
//   _fft_displacement  xyz = displacement in metres, a = foam
//   _fft_slope         xy  = dh/dx, dh/dz;  z = the cascade's own Jacobian
// Cascade i repeats every _fft_repeat[i] metres of DOMAIN space: the reference's per-cascade _Tile, which
// need not be the length it was simulated at (PASTURE3D_WATER_REFERENCE_SPEC.md G1). The mips are the
// simulation's own 2x2 box chain (WaterFFTGate [M]); the sampler's job is only to pick and blend them.
// Per cascade, 0 or 1 (G2-G4): _fft_drawn, the reference's visualizeLayer, gates everything the cascade
// contributes; _fft_displaces, its contributeDisplacement already ANDed with drawn, gates the geometry.
// _fft_foam_offset is every cascade's foamSubtract summed, hidden ones included, as the reference adds them.
// Defaults are the reference's scene, so a material bound by hand draws what it drew.
uniform sampler2DArray _fft_displacement : filter_linear_mipmap, repeat_enable, hint_default_black;
uniform sampler2DArray _fft_slope : filter_linear_mipmap_anisotropic, repeat_enable, hint_default_black;
uniform vec4 _fft_repeat = vec4(100.0, 0.33333334, 0.33333334, 7.6923075);
uniform vec4 _fft_drawn = vec4(1.0, 0.0, 0.0, 1.0);
uniform vec4 _fft_displaces = vec4(1.0, 0.0, 0.0, 0.0);
uniform float _fft_foam_offset = -0.84;
// The reference's _NormalStrength (PASTURE3D_WATER_REFERENCE_SPEC.md L8): the drawn cascades' summed slope
// is scaled by it before the normal is built. Geometry and foam are untouched.
uniform float fft_normal_strength : hint_range(0.0, 4.0, 0.01) = 1.0;
// Distance fades (G5), the reference's *DepthAttenuation. Displacement, normal and crest foam are each
// scaled toward nothing by pow(1 - depth / fft_fade_distance, falloff): depth is the REST vertex's linear
// view depth. 0 turns a fade off. FFT only: the fBm has its own octave fade.
// The reference divides by the camera's FAR PLANE, so its look changes with every camera (the editor's
// default far of 4000 m fades the normals half as fast as its 2000 m scene). A distance in metres keeps
// the look under any camera (P-D4 of PASTURE3D_WATER_PRODUCTION_SPEC.md); 2000 m is the reference's look at
// its own far plane. fft_fade_distance = 0 restores the reference: the far plane of whatever view draws
// it, which for a shadow pass would be the LIGHT's; water casts no shadows by default.
uniform float fft_fade_distance : hint_range(0.0, 20000.0, 1.0) = 2000.0;
uniform float fft_displacement_falloff : hint_range(0.0, 8.0, 0.01) = 1.0;
uniform float fft_normal_falloff : hint_range(0.0, 8.0, 0.01) = 1.0;
uniform float fft_foam_falloff : hint_range(0.0, 8.0, 0.01) = 1.0;
// The profile's Pasture3DWaterFBM, one set for the geometry (_fbm_v*) and one for the normals (_fbm_f*),
// packed as Pasture3DWaterFBM::get_shader_pack() documents:
//   0 = (seed, seed_iter, frequency, frequency_mult)   1 = (amplitude, amplitude_mult, speed, speed_ramp)
//   2 = (drag, height, max_peak, peak_offset)           3 = (amplitude_sum, unit_mean, octaves, 0)
// Defaults are GarrettGunnell/Water's, so a material switched to fBm by hand still makes waves.
uniform vec4 _fbm_v0 = vec4(0.0, 1253.2131, 1.0, 1.18);
uniform vec4 _fbm_v1 = vec4(1.0, 0.82, 2.0, 1.07);
uniform vec4 _fbm_v2 = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 _fbm_v3 = vec4(4.4199217, 0.4657596, 8.0, 0.0);
uniform vec4 _fbm_f0 = vec4(0.0, 1253.2131, 1.0, 1.18);
uniform vec4 _fbm_f1 = vec4(1.0, 0.82, 2.0, 1.07);
uniform vec4 _fbm_f2 = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 _fbm_f3 = vec4(5.5535727, 0.4657596, 40.0, 0.0);
#ifndef WATER_CLIPMAP
// The mesh's vertex spacing in metres, which picks the vertex stage's mip per cascade. A clipmap knows its
// own (the ring scale); a plain mesh cannot, so its body writes this. PER INSTANCE because ten ponds on
// one material are meshed at ten spacings. Left at 1 m, a mesh finer than that aliases nothing and a
// coarser one aliases the short cascades in its geometry -- the slope maps still draw them correctly.
instance uniform float _fft_vertex_spacing = 1.0;
#endif
#endif

// Keeps phase arguments small and precise for bodies far from the origin (§3.1).
//
// PER INSTANCE, not per material (WATER_BODIES_SPEC §5.4). Pasture3DPoolManager hands the
// same material to every body sharing a (base material, wave profile) pair, so ten
// ponds cost one material and one profile upload -- but each of those ponds sits
// somewhere different, and a domain origin stored on the material would force them
// all to share one. An instance uniform is the only per-body channel Godot offers
// that a shared material survives; samplers cannot be one, which is why the
// material cache is keyed on the profile at all.
//
// Written with MeshInstance3D.set_instance_shader_parameter(), or
// RenderingServer.instance_geometry_set_shader_parameter() for the ocean clipmap's
// instances. material.set_shader_parameter() no longer reaches it -- anything that
// used to set it that way now sets nothing and silently gets vec3(0).
instance uniform vec3 _water_domain_origin = vec3(0.0, 0.0, 0.0);
group_uniforms;

group_uniforms surface;
uniform float base_roughness : hint_range(0.0, 1.0, 0.001) = 0.06;
uniform float specular_amount : hint_range(0.0, 1.0, 0.01) = 0.5;
// The lowest elevation, in degrees, a reflection may point at (production spec §2.4, H1). At grazing
// views a facet tilted away from the camera reflects DOWN, and Godot's sky below the horizon is its
// ground colour: a fifth of the sea drew dark, jagged streaks in a band at mid distance. A real ray
// there hits the back of the next wave. The normal of such a facet is bent just far enough that its
// reflection grazes the horizon instead. -90 turns it off (the reference does not do this).
uniform float reflection_min_elevation : hint_range(-90.0, 10.0, 0.1) = 3.0;
#ifdef WATER_DETAIL
// Toksvig in spirit (§3.4): normal detail the distance fade removed is converted
// into roughness rather than discarded, so the specular lobe widens by exactly
// as much as the geometry it stood for was smoothed away. Lowering roughness to
// make distant water look sharper is what CAUSES the shimmer, not what fixes it.
// With the detail texture, river-only (FFT spec §6.6); the FFT's mips and the
// fBm's octave fade filter their own slope.
uniform float variance_to_roughness : hint_range(0.0, 2.0, 0.01) = 0.55;
#endif
group_uniforms;

#ifdef WATER_DETAIL
group_uniforms detail;
// (dh/dx, dh/dz) in RG, NOT a normal map -- derivatives compose by addition, so
// two scrolled layers and the wave slope combine with two adds and need no
// TBN, no whiteout blend and no cross products (§3.3).
//
// hint_normal is a lie about the content and deliberate: it is the only hint
// whose fallback texture is (0.5, 0.5, ...), which is the neutral value here.
// hint_default_white would tilt every pixel by a full unit of slope on a
// material that had not been given a texture, which is exactly the bare
// MeshInstance3D case G6 promises works.
// Number of scrolled detail layers. Two is what breaks up the tile; one is the
// low-end escape hatch. Priced in §8.4.
#ifndef WATER_DETAIL_LAYERS
#define WATER_DETAIL_LAYERS 2
#endif

#ifdef WATER_DETAIL_TRILINEAR
// Plain trilinear instead of anisotropic. Anisotropy is what keeps a grazing
// water plane sharp into the distance, and the footprint is at its most elongated
// exactly where the most pixels are, so this is where it should cost the most.
//
// On an RTX 3070 it measured EXACTLY the same either way (§8.4), so this is not
// the desktop win it looks like. Kept as a knob rather than deleted because
// anisotropy on an RDNA2 iGPU is not the same instruction it is here, and Phase 5
// has a Steam Deck to measure it on.
uniform sampler2D detail_deriv : hint_normal, filter_linear_mipmap, repeat_enable;
#else
uniform sampler2D detail_deriv : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
#endif
// Slope multiplier, in units of the texture's FULL SCALE -- not in m/m, and not
// "the texture as authored", which is what this comment used to claim and what
// the 1.0 default was chosen to mean.
//
// The generator computes a real derivative in m/m and then normalises it by its
// own 99.5th percentile before quantising, and that divisor is printed and thrown
// away (tools/gen_water_textures.py). So the stored value is a FRACTION of full
// scale, and reproducing the authored slope needs the divisor back:
//
//   full scale        0.422 m/m     <- authored, from the generator
//   stored rms        0.277         <- per layer, measured off the shipped PNG
//   authored rms      0.117 m/m     <- 0.277 * 0.422
//
// At the old default of 1.0 the two summed layers reached an rms slope of 0.39
// with excursions past 2.0: normals tilted far enough to point the reflection
// vector BELOW the horizon, which is why the ocean picked up the sky's brown
// ground hemisphere as rust-coloured speckle. The same number also feeds
// variance_to_roughness, so distant water was getting +0.55 roughness and going
// out as flat grey slabs. One uniform, wrong at both ends of the distance range.
//
// 0.25 gives ~0.10 rms slope over both layers, which is the right order for
// wind-ruffled water at the sub-10 m scale a river's channel model does not cover.
// Pinned by Phase 5 gate E, which asserts the composed
// slope numerically and uses 1.0 as the control that must fail.
uniform float detail_strength : hint_range(0.0, 4.0, 0.01) = 0.25;
// Tiles per metre. The two are deliberately non-harmonic: at a simple ratio the
// layers re-align at a fixed period and the eye finds the tile immediately.
uniform float detail_scale0 : hint_range(0.001, 1.0, 0.001) = 0.1;
uniform float detail_scale1 : hint_range(0.001, 1.0, 0.001) = 0.0345;
// Advection in metres per second, world space.
uniform vec2 detail_flow0 = vec2(0.32, 0.11);
uniform vec2 detail_flow1 = vec2(-0.17, 0.26);
// Detail amplitude ramps to zero across this range, so distant water settles
// onto the smooth swell normal. A distance ramp rather than fwidth: cheaper, and
// unlike fwidth it does not misbehave across the clipmap's LOD seams.
uniform float detail_fade_start : hint_range(0.0, 2000.0, 1.0) = 200.0;
uniform float detail_fade_end : hint_range(0.0, 4000.0, 1.0) = 800.0;
group_uniforms;
#endif

#ifdef WATER_FLOW
// ---------------------------------------------------------------------------
// Flow (spec §10). River variant only.
// ---------------------------------------------------------------------------
//
// The detail layers advect along a PER-VERTEX direction carried in ARRAY_COLOR
// instead of the fixed detail_flow0/1 vectors, so the surface texture runs with
// the channel through every bend.
//
// A plain scroll along a direction that varies per vertex shears the texture at
// every bend and keeps shearing, without bound. The fix is the standard flow-map
// scheme: two copies of the layer, offset by half a period each and cross-faded
// on the same period, so the distortion is reset before it becomes visible. Two
// extra fetches from a texture already in cache.
group_uniforms flow;
// Seconds per advection cycle. Distortion grows for this long, then the
// cross-fade hands over to a fresh copy. Longer = more coherent motion but more
// visible smearing at the end of each cycle.
uniform float flow_period : hint_range(0.5, 20.0, 0.1) = 4.0;
// Metres per second at ARRAY_COLOR.b == 1. The mesh writes a NORMALISED speed, so
// this is the reference the normalisation was against and the two must agree --
// Pasture3DPool writes b = speed / FLOW_SPEED_REF with the same 8.0.
uniform float flow_speed_scale : hint_range(0.0, 20.0, 0.1) = 8.0;
// Quantise flow_period so a whole number of cycles fits in water_time_period.
//
// Without this the cross-fade is mid-hand-over when water_time wraps and the
// surface visibly jumps, exactly as an unquantised scroll rate does -- the same
// constraint water_scroll() documents, applied to a second clock. Exposed rather
// than hardcoded so the seam can be demonstrated: the Phase 7 gate turns it off
// as its control and requires the seam to appear.
uniform bool flow_quantise = true;
group_uniforms;
#endif

#ifdef WATER_STREAM_WAVES
// ---------------------------------------------------------------------------
// Stream ripples (spec §10.2). Replace the wave model on a river.
//
// See water_stream.gdshaderinc for why a river cannot use a sea's waves at all. These
// four are the whole surface: everything that varies BETWEEN reaches -- how fast
// the water is running, how steep, how near the bank -- is already per-vertex in
// the mesh, so the material only has to say how much ripple a given speed earns.
// That is why they are material uniforms and not a per-river profile.
// ---------------------------------------------------------------------------
group_uniforms ripples;
// Crest-to-trough amplitude at full speed, in metres, before the bank fade.
// Centimetres, not metres: this is chop on a channel, not swell on a sea.
uniform float ripple_amplitude : hint_range(0.0, 1.0, 0.005) = 0.06;
// Cycles per second the surface bobs at a fixed point. NOT a wavelength -- the
// wavelength is a consequence, and varies along the river, because frequency is
// what steady flow conserves. Quantised against water_time_period at evaluation.
//
// LOW ON PURPOSE. At the shipped 1.5 m/s this is a 5 m undulation, and raising it
// is expensive in a way the number does not show: wavelength is speed/frequency,
// the mesh has to resolve it, so doubling this halves the vertex spacing a stream
// chooses and quadruples its vertex count. The first draft shipped 0.9 and turned
// a 200 m river into 33k vertices for chop nobody could see.
//
// The fine detail is NOT missing from the surface -- it is in the detail normal
// map, which already advects along the same per-vertex flow (WATER_FLOW above).
// This is the part that has to be geometry because it moves the silhouette and
// floats boats; anything smaller is the texture's job and costs nothing.
uniform float ripple_frequency : hint_range(0.05, 2.0, 0.01) = 0.3;
// Flow speed (m/s) at which ripples reach full amplitude. Below it they scale
// down linearly, so a river slowing into a pool goes glassy on its own.
uniform float ripple_speed_ref : hint_range(0.1, 10.0, 0.1) = 2.0;
// Fraction of the half-width at which the bank fade starts. 1 = no fade, and a
// rim of crests standing over the dry bank; lower pulls the calm margin inward.
uniform float ripple_bank_fade : hint_range(0.0, 1.0, 0.01) = 0.55;
group_uniforms;

// ---------------------------------------------------------------------------
// Cross-channel chop (spec §10.3).
//
// The ripples above are a function of travel time ALONE, so every point on a
// cross-section is at the same height and the river reads as a rolling carpet.
// These are the term that varies ACROSS the channel: two oblique octaves whose
// crests meet at an angle and interfere into the diamond lattice moving water
// actually shows.
//
// COSTS COLUMNS, NOT ROWS. Its along-flow structure is deliberately no finer
// than the ripples already carry, so the only thing it makes the mesher spend
// more of is samples ACROSS the strip -- which is the cheap axis, because a
// river is long and narrow. Set chop_amplitude to 0 and the stream stops asking
// for them entirely and goes back to the column count it had before.
// ---------------------------------------------------------------------------
group_uniforms chop;
// Crest-to-trough amplitude in metres, at full speed, mid-channel. Gated by the
// same speed and bank fades as the ripples, so chop dies in a pool and at the
// waterline without a second set of knobs.
//
// ZERO IS A SUPPORTED SETTING and not merely a quiet one: it is what tells
// Pasture3DStream it may drop back to square cells. See _column_spacing().
uniform float chop_amplitude : hint_range(0.0, 1.0, 0.005) = 0.03;
// Distance between chop crests measured ACROSS the channel, in metres. This is
// the number that sets the mesh's column spacing -- a stream samples it about
// six times per wavelength -- so halving it roughly doubles the vertex count.
uniform float chop_wavelength : hint_range(0.25, 20.0, 0.05) = 2.5;
group_uniforms;

// ---------------------------------------------------------------------------
// Standing waves at shallows (spec §10.4).
//
// The stationary undulations downstream of a ford or a chute. Unlike everything
// else on this surface they DO NOT MOVE: their phase is a function of position
// along the channel and of nothing else, so they sit still in the world while
// the water runs through them. That is what a standing wave is.
//
// They appear on their own, wherever the flow goes supercritical -- Froude
// number v / sqrt(g*d) above 1 -- and the mesh already carries per-row depth and
// speed, so nobody authors where. Raise the bed toward the surface and the reach
// grows rapids; deepen it and they go away.
// ---------------------------------------------------------------------------
group_uniforms standing;
// Crest-to-trough amplitude in metres at standing_depth_ref of water. Scaled
// down in shallower water, because a wave taller than the river is not a wave.
uniform float standing_amplitude : hint_range(0.0, 2.0, 0.005) = 0.12;
// Froude number the undulations start at. 1.0 is the physical critical point --
// below it a disturbance can travel back upstream and no standing pattern can
// hold. Shipped slightly under, because a river at Fr 0.95 is already ruffled
// and the transition looks abrupt if it begins exactly at the textbook value.
uniform float standing_froude_onset : hint_range(0.4, 2.5, 0.01) = 0.9;
// Depth in metres at which standing waves reach standing_amplitude. Also the
// scale over which they fade out as a reach dries: at zero depth there is no
// water to stand up, whatever the Froude number says.
uniform float standing_depth_ref : hint_range(0.05, 5.0, 0.01) = 1.0;
group_uniforms;
#endif

#ifdef WATER_DEPTH_FADE
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
#endif

#if defined(WATER_FOAM_CREST) || defined(WATER_FOAM_SHORE)
group_uniforms foam;
uniform sampler2D foam_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 foam_color : source_color = vec3(0.85, 0.89, 0.92);
uniform float foam_scale : hint_range(0.001, 1.0, 0.001) = 0.07;
#ifndef WATER_FLOW
// Foam drift in metres per second, world space. Until Phase 6 of the FFT port the foam rode
// detail_flow0, which went river-only with WATER_DETAIL; a river's foam rides its flow instead.
uniform vec2 foam_flow = vec2(0.32, 0.11);
#endif
#ifndef WATER_PBR
// Foam is a scattering layer sitting on the water, so it must raise roughness.
// The legacy shader tinted albedo only, which gives you mirror-smooth foam. The lit variants take the
// reference's foam_roughness_modifier instead (sun group).
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.8;
#endif
#ifdef WATER_FOAM_CREST
#ifndef WATER_FFT
// A stream's crest signal is its surface slope, ~1 where the channel model is as steep as it gets
// (water_stream.gdshaderinc). Whitecaps start at this slope and reach full cover `softness` above it.
// The FFT needs neither: its simulation's foam is already coverage.
uniform float foam_crest_threshold : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float foam_crest_softness : hint_range(0.01, 1.0, 0.01) = 0.1;
#endif
uniform float foam_crest_amount : hint_range(0.0, 2.0, 0.01) = 1.0;
#endif
#ifdef WATER_FOAM_SHORE
// Metres of water below which shore foam appears.
uniform float foam_shore_depth : hint_range(0.0, 20.0, 0.05) = 1.2;
uniform float foam_shore_amount : hint_range(0.0, 2.0, 0.01) = 0.8;
#endif
group_uniforms;
#endif

#ifdef WATER_PBR
// ---------------------------------------------------------------------------
// Sun lighting (FFT spec §3.1), Garrett's NEW_LIGHTING terms evaluated per light in light().
//
// Lit the reference's way, end to end (PASTURE3D_WATER_REFERENCE_SPEC.md R4): ALBEDO is 0, so Godot's
// ambient light adds nothing the reference does not have, and light() writes every sun term to
// SPECULAR_LIGHT, which Godot does not multiply by ALBEDO. The defaults are the reference's SampleScene
// values.
// ---------------------------------------------------------------------------
group_uniforms sun;
// The reference's _ScatterColor (L5): the colour every body term is lit in. deep_color no longer draws on
// these variants; the absorption solve now tints THIS colour, and only where the water is thin enough to
// see through (the shore fade, §3.4) -- in deep water it is scatter_color exactly.
// The default is the reference's (0.016, 0.0736, 0.16) sRGB-encoded: FFTWater.cs passes its colours with
// SetVector, which does not linearise, so those numbers ARE linear; source_color linearises what it is
// given, and these values land on them exactly (WaterReferenceABGate's "colours" control).
uniform vec3 scatter_color : source_color = vec3(0.133352, 0.300728, 0.436627);
// Beckmann alpha (rms microfacet slope) of the SUN lobe. Not the perceptual ROUGHNESS Godot squares for
// its environment reflection: that one is still base_roughness above.
uniform float sun_roughness : hint_range(0.01, 0.5, 0.001) = 0.075;
// The reference's foamRoughnessModifier (PASTURE3D_WATER_REFERENCE_SPEC.md L3): added to the roughness, sun
// lobe and reflection alike, per unit of foam. Its scene sets 0 -- the foam is an unlit lerp (L1) and needs
// no roughness to look matte.
uniform float foam_roughness_modifier : hint_range(0.0, 1.0, 0.001) = 0.0;
// k2: light scattered back out of the body toward a viewer looking into the water.
uniform float view_scatter : hint_range(0.0, 4.0, 0.01) = 1.0;
// k3: body scatter that follows the sun's incidence on the surface.
uniform float shadow_scatter : hint_range(0.0, 4.0, 0.01) = 0.5;
// k4: a constant in-scatter from bubbles, in its own colour.
// The reference's (0, 0.02, 0.016), sRGB-encoded like scatter_color.
uniform vec3 bubble_color : source_color = vec3(0.0, 0.151704, 0.133352);
uniform float bubble_density : hint_range(0.0, 4.0, 0.01) = 1.0;
#ifdef WATER_SCATTER
// k1: sun shining THROUGH a crest toward the viewer, per metre of crest height above the rest level. The
// reference's _WavePeakScatterStrength times its _HeightModifier, which only ever appear as a product.
uniform float wave_peak_scatter : hint_range(0.0, 8.0, 0.01) = 1.0;
#endif
group_uniforms;

group_uniforms environment;
// The reference's environment reflection (L4, decision D3): F * texture(environment_map, reflect) *
// environment_light_strength, with the reference's own rough Fresnel, written to EMISSION. Exact, but it
// replaces Godot's sky reflection, reflection probes and SSR outright (SPECULAR goes to 0). Off, the sky
// reflects through Godot's own path, at SPECULAR = specular_amount, which the reference's F and strength
// cannot reach.
uniform bool use_environment_map = false;
uniform samplerCube environment_map : source_color, filter_linear_mipmap, hint_default_black;
uniform float environment_light_strength : hint_range(0.0, 4.0, 0.01) = 0.5;
group_uniforms;
#endif

#ifdef WATER_SHORE_MASK
// ---------------------------------------------------------------------------
// Shore mask (PROTOTYPE — shore-edge question, water LOD work).
//
// The alternative to meshing a body's outline: draw a sheet that does not know
// where the shore is, and cut it with a signed distance field baked from the
// same polygon the mesher would have clipped against. That is what makes a
// camera-centred clipmap usable for a finite body, because the clipmap's grid
// cannot be made to land on an arbitrary loop.
//
// Two stages, and they do different jobs:
//
//   VERTEX  kills whole triangles that are entirely outside, by writing NaN
//           into the position -- the same trick the terrain uses for holes
//           (src/shaders/main.glsl). Geometry, so far-outside area costs no
//           fragments at all. It is a CONSERVATIVE cut: the margin has to be
//           wide enough that every triangle touching the true shore survives,
//           or the feather below would be carving a hole that is already there.
//
//   FRAGMENT feathers the surviving band to the exact shore. Per-pixel, from
//           the texture, so its accuracy is set by the SDF's resolution and NOT
//           by the mesh's -- which is the whole hypothesis: the same rim at
//           LOD0 spacing and at LOD3 spacing.
//
// Stored NORMALISED to [0,1] over +-_shore_range and LINEARLY, so the sampler's
// bilinear filter interpolates distance itself. R16F at 1.5 m texels is 1.8 MB for a
// 1.4 km lake against 17 MB of the vertices it replaces; R8 halves that again and
// costs accuracy. WATER_SHORE_SQRT selects a cleverer encoding that measured worse --
// see water_shore_distance().
// ---------------------------------------------------------------------------
group_uniforms shore;
// Signed distance to the outline in the red channel, negative INSIDE the water.
// repeat_disable so a sheet extending past the baked rect clamps to the border
// texel, which is why the bake pads its bounds past the polygon by _shore_range:
// the clamped value then reads as "well outside" and the sheet ends.
uniform sampler2D _shore_sdf : filter_linear, repeat_disable, hint_default_black;
// xy = the baked rect's min corner in world XZ, zw = its size in metres.
uniform vec4 _shore_rect = vec4(0.0, 0.0, 1.0, 1.0);
// Texel counts, for the hard-cut control below. Nothing else reads it.
uniform vec2 _shore_texels = vec2(1.0, 1.0);
// Metres encoded at the ends of the range. Distances beyond it are clamped, and
// that is fine: everything past a few metres from the shore is either water or
// not, and no term here is sensitive to how far past.
uniform float _shore_range = 8.0;
// Width of the alpha ramp, in metres, CENTRED on the shore -- so alpha 0.5 lands
// on the outline itself and the surface does not sit systematically inside or
// outside of it. Half of it hangs over the bank, where edge_offset means there
// is bank under it.
uniform float _shore_feather : hint_range(0.0, 4.0, 0.01) = 0.5;
// Metres to grow the water past the baked outline. The geometric edge_offset,
// moved into the shader: with an SDF the rim no longer has to be baked in, and
// the same field serves any offset.
uniform float _shore_offset : hint_range(-8.0, 8.0, 0.05) = 0.0;
// How far outside a vertex may be before its triangles are killed. Must exceed
// the cell diagonal plus half the feather, or the cut eats into the band the
// fragment stage is supposed to be resolving. Written by the host, which is the
// only thing that knows the spacing.
uniform float _shore_kill_margin = 4.0;
// THE TILED FIELD, for a body too large for one image (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §I).
// One texture cannot hold a 25 km lake at 1.5 m texels, and its memory grows with the area. Tiled, only
// tiles the shore passes near carry a field; the rest are a constant, so memory follows the shore length,
// and a tile over a region that is not loaded is not baked at all.
//   _shore_tile_map   one texel per tile: 0 outside (or not baked), -1 inside, k + 1 = layer k of _shore_tiles
//   _shore_tiles      (n + 2)^2 texels per layer: n over the tile plus a one-texel apron on each side, baked at
//                     the neighbours' texel centres, so bilinear filtering across a tile edge is seamless
//   _shore_tile_grid  xy = the grid's min corner in world XZ, z = tile size in metres, w = n
// Chosen per material by _shore_tiled, a uniform branch, so one shader serves both.
uniform bool _shore_tiled = false;
uniform highp sampler2D _shore_tile_map : filter_nearest, repeat_disable;
uniform sampler2DArray _shore_tiles : filter_linear, repeat_disable;
uniform vec4 _shore_tile_grid = vec4(0.0, 0.0, 256.0, 170.0);
group_uniforms;
#endif

// Clipmap plumbing, written by Pasture3DMesher. Only exists for the ocean.
#ifdef WATER_CLIPMAP
group_uniforms private_set_by_terrain;
uniform float _mesh_size = 32.0;
uniform float _subdiv = 1.0;
uniform float _vertex_spacing = 1.0;
// PER INSTANCE, so each split-screen view geomorphs to its OWN camera.
//
// The clipmap's rings are shared geometry drawn once per view on that view's render layer, so a
// material-wide target would centre every view's morph on whichever camera wrote last -- two players
// and one of them gets a surface morphing toward the other. Pasture3DMesher writes this through
// RS.instance_geometry_set_shader_parameter() when its host asks for per-instance targets, which is
// what the terrain has always done (src/shaders/main.glsl declares it the same way).
//
// _water_domain_origin above is already an instance uniform and arrives by the same route, so this
// is not a new mechanism -- it is the same one, applied to the value that turned out to need it.
instance uniform vec3 _target_pos = vec3(0.0, 0.0, 0.0);
group_uniforms;
#endif

// ---------------------------------------------------------------------------
// Varyings
// ---------------------------------------------------------------------------
varying vec3 v_world_pos;
varying vec3 v_wave_normal; // world space, from the vertex stage's wave model
varying float v_jacobian;   // crest signal: FFT foam, or a stream's slope; drives whitecaps
varying float v_view_dist;
// The UNDISPLACED height of the sheet: sea_level for the clipmap, the mesh's own
// y for a plain MeshInstance3D. Carried so the fragment stage can ask "is the
// camera under the water" without knowing which of those two it is.
//
// Needed because the two-sided flip cannot be decided from FRONT_FACING alone.
// Water is depth_draw_never, so it does not occlude itself, and cull_disabled
// therefore rasterises the far side of every wave crest -- fragments a solid
// surface would have hidden. Flipping those gave them a downward normal and they
// shaded as dark dashes across the mid-distance (§8.6). The flip is only ever
// right when the VIEWER is underneath, which is a property of the camera, not of
// the triangle.
varying float v_base_y;

#ifdef WATER_FFT
// The REST domain position, before the FFT displaced it. The cascades are textures over the undisplaced
// sheet, so the fragment stage samples slope and foam where this vertex CAME FROM; sampling at the
// displaced position would shear every crest sideways by the choppiness.
varying vec2 v_fft_domain;
// 1 - depth / far at the rest vertex, in [0, 1]: the reference's per-vertex `depth`, interpolated as its is.
varying float v_fft_depth;
#endif

#ifdef WATER_PBR
// Fragment -> light(): x = foam coverage, y = crest height above the rest level in metres (k1's H).
varying vec2 v_pbr;
// Fragment -> light(): the body colour the sun terms are lit in, scatter_color through the absorption solve.
varying vec3 v_body_color;
#endif

#ifdef WATER_SHORE_MASK
// The sheet's REST xz, before the waves displace it. The shore is a fixed line in
// the world, but the question the mask answers is Lagrangian -- water whose rest
// position is inside the lake is lake water even when a crest has swept it a few
// centimetres over the bank -- and answering it from the displaced position instead
// makes the waterline crawl back and forth with every wave.
//
// Also what keeps the fragment feather and the vertex kill agreeing. They are
// different stages testing the same threshold, and if one used the displaced xz the
// kill margin would have to absorb the difference.
varying vec2 v_shore_xz;
#endif

#ifdef WATER_FLOW
// Per-vertex flow, decoded from ARRAY_COLOR in the vertex stage: xy is the
// normalised XZ direction the water runs, z is speed normalised against
// flow_speed_scale. A loop pool writes a neutral colour, so its flow is a zero
// vector and the river shader degrades to a still surface rather than misbehaving.
varying vec3 v_flow;
#endif

#ifdef WATER_STREAM_WAVES
// Distance from the centreline as a fraction of this row's half-width: 0 mid
// channel, 1 on the waterline. Carried in ARRAY_COLOR.a, which the flow encoding
// left unused. Interpolated, so the bank fade is smooth across the strip rather
// than stepping per column.
varying float v_shore;
#endif

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Rec.709 luminance. Used to collapse the per-channel transmittance into the one
// scalar alpha the blend hardware has (§3.5).
const vec3 WATER_LUMA = vec3(0.2126, 0.7152, 0.0722);

// Schlick fresnel for water (F0 = 0.02), unrolled -- never pow().
float water_fresnel(float n_dot_v) {
	float m = clamp(1.0 - n_dot_v, 0.0, 1.0);
	float m2 = m * m;
	return 0.02 + 0.98 * (m2 * m2 * m);
}

/**
 * UV offset for something scrolling at p_uv_per_second, snapped to the clock loop.
 *
 * water_time wraps at water_time_period, and §3.2 makes that seamless for the
 * waves by quantising their frequencies. A scrolling texture needs the same
 * treatment or it teleports at the wrap: the offset has to be a whole number of
 * tiles when t reaches the period. Rounding the CYCLE COUNT and dividing back out
 * is what does it -- the rate moves by at most half a tile per loop, which at the
 * default 120 s is under half a percent.
 *
 * A rate slow enough that it completes less than half a tile per loop rounds to
 * zero and stops. That is the honest outcome: such a layer cannot both scroll and
 * loop, and a frozen layer is less wrong than a jumping one.
 */
vec2 water_scroll(vec2 p_uv_per_second) {
	float period = max(water_time_period, 1e-3);
	return round(p_uv_per_second * period) * (water_time / period);
}

#ifdef WATER_SHORE_MASK
/**
 * Signed distance from a world XZ to the shore, in metres. Negative is water.
 *
 * The UV is clamped rather than left to the sampler because a sheet is expected
 * to extend past the baked rect -- that is the point of a clipmap -- and the
 * border texel is the honest answer out there only because the bake pads its
 * bounds. Clamping here makes that explicit instead of leaning on the sampler's
 * repeat mode to be set right.
 */
// The tiled field's normalised value at a world XZ, in [-1, 1] like one sample of _shore_sdf.
float water_shore_tiled(vec2 p_world_xz) {
	vec2 g = (p_world_xz - _shore_tile_grid.xy) / _shore_tile_grid.z;
	ivec2 ti = ivec2(floor(g));
	ivec2 count = textureSize(_shore_tile_map, 0);
	if (ti.x < 0 || ti.y < 0 || ti.x >= count.x || ti.y >= count.y) {
		return 1.0;
	}
	float e = texelFetch(_shore_tile_map, ti, 0).r;
	if (e < -0.5) {
		return -1.0;
	}
	if (e < 0.5) {
		return 1.0;
	}
	float n = _shore_tile_grid.w;
	vec2 uv = ((g - vec2(ti)) * n + 1.0) / (n + 2.0);
	return texture(_shore_tiles, vec3(uv, e - 1.0)).r * 2.0 - 1.0;
}

float water_shore_distance(vec2 p_world_xz) {
	if (_shore_tiled) {
		return water_shore_tiled(p_world_xz) * _shore_range - _shore_offset;
	}
	vec2 uv = (p_world_xz - _shore_rect.xy) / _shore_rect.zw;
#ifdef WATER_SHORE_HARD
	// The control: snap to texel centres, which is what sampling this field
	// without interpolation looks like. Nearest is emulated rather than declared
	// so both paths share one sampler and differ only in how they read it.
	uv = (floor(uv * _shore_texels) + 0.5) / _shore_texels;
#endif
	float t = texture(_shore_sdf, clamp(uv, 0.0, 1.0)).r * 2.0 - 1.0;
#ifdef WATER_SHORE_SQRT
	// The control, and a mistake worth keeping the evidence of.
	//
	// Storing sign(d) * sqrt(|d| / range) and squaring back looks like free precision: it
	// spends the byte near the shore, where the ramp reads, instead of spreading it over a
	// range only the vertex kill cares about. Measured, it is nearly TWICE AS BAD as the
	// linear encoding -- and the float-format case is just as bad, so this is not about
	// quantisation at all.
	//
	// The sampler interpolates the STORED value, and squaring afterwards is not the same as
	// interpolating the distance. Between texels at -0.2 m and +1.8 m the true crossing is
	// 10% into the cell; in sqrt space the interpolant reaches zero at 25%. Linear
	// interpolation of a distance field is an approximation of distance, which is the entire
	// reason an SDF texture works, and a nonlinear encoding throws that away.
	return t * abs(t) * _shore_range - _shore_offset;
#else
	// Linear, so the hardware's bilinear filter is interpolating distance itself. The
	// precision comes from the FORMAT instead: R16F resolves better than a millimetre near
	// the shore at any usable range, and R8 lands at 0.249 m against a 0.25 m budget, which
	// is why the byte is the cheap option and not the default.
	return t * _shore_range - _shore_offset;
#endif
}

/**
 * Surface coverage at a world XZ: 1 well inside the water, 0 past the shore.
 *
 * Multiplied into ALPHA rather than driving a discard. Water is already a
 * transparent, depth_draw_never surface, so there is no early-Z for a discard to
 * cost -- and a ramp is the only thing that can put the edge somewhere other
 * than a texel boundary.
 */
float water_shore_alpha(vec2 p_world_xz) {
	float d = water_shore_distance(p_world_xz);
#ifdef WATER_SHORE_HARD
	return d > 0.0 ? 0.0 : 1.0;
#else
	return 1.0 - smoothstep(-_shore_feather * 0.5, _shore_feather * 0.5, d);
#endif
}
#endif

#ifdef WATER_FLOW
/**
 * The flow cycle length actually used, snapped so a whole number of cycles fits
 * in water_time_period.
 *
 * Same problem and same fix as water_scroll() above, one clock down: the flow
 * cross-fade has its own period, and if that period does not divide the wave
 * clock's then the hand-over is caught mid-way when water_time wraps and the
 * whole surface jumps. Rounding the CYCLE COUNT and dividing back out moves the
 * period by at most half a cycle -- at the default 4 s in 120 s, under 2%.
 *
 * Clamped to at least one cycle: a flow period longer than the whole loop cannot
 * both advect and loop, and freezing is less wrong than jumping.
 */
float water_flow_period() {
	if (!flow_quantise) {
		return max(flow_period, 1e-3);
	}
	float clock = max(water_time_period, 1e-3);
	float cycles = max(round(clock / max(flow_period, 1e-3)), 1.0);
	return clock / cycles;
}
#endif

#endif // WATER_COMMON_INC
