# Pasture3D Water — FFT Ocean, fBm Fallback, Microfacet Lighting

Status: **spec written 2026-10-09. Phase 1 built, gated (`WaterFFTGate` 6/6, §6.1) and committed
(52212cbc). Phase 2 built, gated (`WaterFFTWiringGate` 4/4, §6.2) and committed (84923526). Phase 3
built, gated and committed (47a3b43e, `WaterPBRGate` 3/3, §6.3). Phase 4 built, gated and committed
(11a9a069, `WaterFBMGate`, §6.4); its uniform-branch timing was measured after Phase 6 (§6.4). Phase 5 built and gated
2026-10-09 (`WaterBuoyGate` on Forward+, headless and Compatibility, §6.5) and committed (70647d40).
Phase 6 built and gated 2026-10-09 (`WaterRetireGerstnerGate` 4/4, §6.6), not committed. Gerstner is
gone.**

Ports Garrett Gunnell's water (https://github.com/GarrettGunnell/Water, MIT-style reference code, last
commit 2023-12-30) onto Pasture3D's ocean, lake and pond. The reference is a Unity project. Two parts of it
are taken:

- **`FFTWater.compute` + `FFTWater.shader`:** a Tessendorf ocean. Four cascades, each with two JONSWAP
  spectra and a TMA shallow-water correction. It runs as an inverse FFT on the GPU, gets foam from the
  wave Jacobian, and lights with a Beckmann microfacet model plus a subsurface-scatter approximation.
- **`Water.shader`, `USE_FBM`:** an "Euler wave" fBm. It sums `exp(sin)` octaves with domain drag, in a
  cheap vertex set and a finer fragment set.

Rivers are out of scope. `water_river.gdshader` keeps its stream evaluator (`water_stream.gdshaderinc`)
untouched.

## Decisions (the user, 2026-10-09)

| Question | Decision | Consequence |
|---|---|---|
| Wave model | **FFT everywhere by default**, with a setting to fall back to fBm "for users that don't have the GPU performance to spare" | Ocean, lake and pond all sample FFT cascades. fBm is a runtime-selectable fallback, not a per-body art choice. |
| Lighting | **Port Garrett's PBR**, inside `light()` | Beckmann NDF, Smith-Beckmann masking, the roughness-aware Fresnel, and the k1–k4 scatter/bubble terms. Godot's lights and shadows still apply. Our depth fade, shore foam, shore mask and terrain check are kept. |

**This overturns a decision in [PASTURE3D_WATER_SHADER_SPEC.md](PASTURE3D_WATER_SHADER_SPEC.md).**
That spec's decision table reads "CPU height queries **required** … rules out texture-driven vertex
displacement". FFT displacement *is* texture-driven. The CPU height query stays required (buoys,
`contains_point`), but it can no longer be a bit-exact transcription. §5 replaces it with a GPU readback,
and the parity contract becomes a measured tolerance plus a known latency.

## 1. Goals / non-goals

- **G1. One wave source per profile, shared by every body on it.** Ten ponds on one profile cost one FFT,
  as they cost one material today.
- **G2. The clock loop stays seamless.** `water_time` wraps at `water_time_period` (water spec §3.2). FFT
  phases are quantised to that period, which is Garrett's own `_RepeatTime` trick. A displacement
  snapshot at t=0 and one at t=period must be identical.
- **G3. The fallback is always reachable.** With no `RenderingDevice` (the Compatibility renderer, or
  headless) the manager selects fBm automatically and says so once. It never draws flat water silently.
- **G4. Buoys keep floating.** `get_water_height()` answers on every model, within a stated tolerance and
  latency (§5).
- **G5. No silent cost.** Every perf claim gets measured, but only with the user's go-ahead
  (memory: ask before perf tests).
- **Non-goal:** tessellation. Godot has no hull/domain stages; the Pasture3D clipmap already provides the
  density near the camera that Garrett's tessellator did.
- **Non-goal:** bit-exact CPU/GPU parity for FFT. It is unattainable through a half-float readback, and §5
  says what it costs.

## 2. Architecture

```
Pasture3DPoolManager  (owns clock, sun, material cache — unchanged role)
  ├─ wave_model: FFT | FBM          (project-wide; auto-FBM when no RenderingDevice)
  ├─ fft_resolution: 128|256|512    (texels per cascade side)
  └─ per active profile ──► Pasture3DWaterFFT  (RefCounted, owned by the profile)
                              ├─ initial spectrum   rgba32f  N×N×4  (rebuilt on profile change)
                              ├─ spectrum ping       rgba32f  N×N×8  (per frame)
                              ├─ displacement        rgba16f  N×N×4 + mips  ──► Texture2DArrayRD
                              │                       xyz = displacement (m), a = foam
                              └─ slope               rg16f/rgba16f N×N×4 + mips ──► Texture2DArrayRD
cached material (base × profile) ◄── _fft_displacement, _fft_slope, _fft_cascade_scales, …
```

- **The profile owns the simulation**, because the profile is what bodies share and what the material
  cache is keyed on. The manager ticks every live simulation once per frame after `_update_clock()`, so
  all of them see the same `water_time`.
- **Main `RenderingDevice`, render thread.** The textures must be sampled by spatial materials, so they
  cannot live on a local device as the graph GPU's do. All `RenderingDevice` work goes through
  `RenderingServer::call_on_render_thread`.
- **`Texture2DArrayRD`** wraps the RIDs. Materials hold the Texture resources, and the RIDs never change
  after creation (only on a resolution change), so no per-frame `material_set_param`.

### 2.1 Compute passes (per profile, per frame)

Ported from `FFTWater.compute`. Kernels are numbered as in the reference.

| # | Kernel | When | Notes |
|---|---|---|---|
| 0 | InitializeSpectrum | profile change | JONSWAP × directional spread × short-wave fade × TMA. Gaussian draws from Hugo Elias' hash, seeded. |
| 1 | PackSpectrumConjugate | profile change | stores h0(k) and conj(h0(−k)) |
| 2 | UpdateSpectrumForFFT | every frame | dispersion **quantised to `2π / water_time_period`** (G2) |
| 3 | HorizontalFFT | every frame | one workgroup per row, N threads, shared memory ping-pong |
| 4 | VerticalFFT | every frame | |
| 5 | AssembleMaps | every frame | Permute, Jacobian, foam accumulate/decay, write displacement + slope |
| 6 | Downsample | every frame | mip chain (Unity's `GenerateMips()` has no Godot equivalent for storage textures) |

`SIZE`/`LOG_SIZE` become specialisation constants, not 1024. Shared memory is `2·N·16 B` = 16 KB at
N=512, which is inside Vulkan's guaranteed 16 KB minimum. N=1024 (32 KB) is offered since the reference
spec's R7, on devices whose limits allow it, with a fallback (`resolution_for_limits`).

### 2.2 Deliberate deviations from the reference

> **Superseded in part (2026-10-11).** The user chose full fidelity to the reference, so several of these
> deviations are being reverted: see PASTURE3D_WATER_REFERENCE_SPEC.md. As of R1, items 2 (band limits)
> and 6 (normalisation) now follow the reference, as do the two shared spectra (now eight, a pair per
> cascade), the rotated cos² and the hash constants. The rest stand until their phases.

1. **Cascade tiling is physical.** The reference samples cascade *i* at `worldPos.xz * _Tile_i` with
   hand-set tiles. Its own scene has a 32 m spectrum sampled at a 7.7 m repeat, which plays the waves at
   the wrong speed for their size. Here the UV is `xz / length_scale_i`, always.
2. **Cascades are band-limited, not overlapped.** The reference sums four cascades whose spectra all cover
   the whole wavenumber range, so energy near shared wavenumbers is counted up to four times. Each cascade
   here keeps `k ∈ [k_lo_i, k_hi_i)`, with boundaries between the cascades' Nyquist and fundamental
   (gasgiant's FFT-Ocean scheme, which the reference credits). One pair of spectra (wind sea + swell) is
   shared by all cascades, not eight independent ones. That is 16 knobs instead of 64, and a sum that is
   physically one sea.
3. **Foam decay is per second, not per frame.** `foam *= exp(-decay)` per dispatch makes foam life depend
   on frame rate. Here it is `exp(-decay · dt)`.
4. **The domain origin is honoured.** Sampling uses `xz − _water_domain_origin.xz`, as every water path
   does today (precision far from the origin).
5. **Distance attenuation uses metres, not `Linear01Depth`.** The reference fades displacement, normal and
   foam by normalised depth, which shifts with the camera's far plane. Here they fade by view distance,
   between `fft_fade_start` and `fft_fade_end`.
6. **h0 is physically normalised.** `E|h0|² = Ψ(k)·Δk²/2`, so the realised height variance is the
   integral of the spectrum and `scale = 1` *is* the sea the wind and fetch describe (gate [P]: ratio
   1.026). The reference's `sqrt(2·Ψ·Δk²)` gives 8× that variance, which is why its scene runs scale
   0.1–0.25. Reference presets therefore port with `scale × √8 ≈ 2.8` on amplitude, i.e. ×8 on scale.
7. **The phase uses finite-depth dispersion and is reduced to one cycle before `cos`/`sin`.** The
   reference builds the spectrum with `ω = √(gk·tanh kd)` but advances the phase with deep-water `√(gk)`,
   so ponds (small `depth`) moved at the wrong speed for the waves they drew. And the short cascades turn
   hundreds of cycles per loop: `ω·t` in the thousands of radians lost enough GPU `sin` accuracy to fail
   the 4 m cascade. Phase is `2π·fract(q·t/T)`, exact in the integer `q`.
8. **The Nyquist row and column are empty.** A mode at `k = −N/2` is its own conjugate partner, so it
   breaks the two-real-signals-per-complex-FFT packing and leaks between the packed channels. Only the
   last cascade carries energy there (the others are band-limited below it); it was the 4 m cascade's
   remaining 2.9× error, and 0.007× once removed.
9. **Defaults are sized to the spectrum.** `cascade_lengths = (500, 85, 16, 4)` m and `depth = 100` m. A
   256 m longest tile could not hold the default swell's peak (~340 m before, ~130 m now), so the peak fell
   below the grid's fundamental and a few dozen modes carried the whole sea.

**Known, not changed:** the reference's `cos²` half of the directional spread (`2/π·cos²θ`) integrates to
2 over the circle, not 1. At `spread_blend < 1` the sea gains up to 2× energy. Gate [P] asserts the
defaults' `spread_blend = 1`; normalising it is a one-line change to make when presets need it.

## 3. Shader

`water_waves.gdshaderinc` keeps its entry point and its `WaveSample` return (`position`, `normal`,
`jacobian`), so `water_surface.gdshaderinc`'s geomorph, shore mask and terrain check are untouched. Its
body selects the model:

- **FFT:** sum four `textureLod(_fft_displacement, vec3(uv_i, i), lod)` taps. The LOD comes from the
  clipmap ring's cell size against the cascade texel size, so coarse rings do not alias 12 cm waves.
  `jacobian` comes from the foam channel. The normal is left to the fragment stage (slope maps), as in the
  reference.
- **fBm:** `vertexFBM` in the vertex stage. `fragmentFBM` normals in the fragment stage, with a uniform
  octave count.

**Model selection is a uniform branch (`_wave_model`), not a static variant.** It is uniform across a
draw, so it costs a branch rather than divergence, and it lets the fallback toggle at runtime without
swapping shaders on every cached material. This trades against the water spec's "static variants"
principle (§6), and Phase 4 measures it, with the user's go-ahead. If it costs, the twin-variant route
is: the manager swaps `shader` on the cached duplicate.

The **detail derivative texture** (`WATER_DETAIL`) existed to break up analytic waves at 10 m and finer.
FFT cascades down to ~12 cm make it redundant on the FFT path, and the fBm's 40 fragment octaves reach
the same scale. **Decided in Phase 6: it is a river feature only.** `water_river` defines it; every
variant that defines `WATER_FFT` (all but `WATER_STREAM_WAVES`) refuses it with an `#error`.

**As built (Phase 2).**

- `WATER_FFT` is defined by `water_common.gdshaderinc` for every variant except rivers
  (`WATER_STREAM_WAVES`). Until Phase 6 the canvas_item parity probe (`WATER_PLAIN_DOMAIN_ORIGIN`) and
  `WATER_NO_FFT` also opted out; both went with Gerstner.
- `_wave_model` 0 was GERSTNER, because 0 is what an unset uniform reads. Since Phase 6 every value but
  FFT draws the fBm, and the uniform defaults to FBM, so a bare mesh draws the fBm at its default knobs.
- The vertex stage computes the mip per cascade as `max(log2(2 · spacing · N / L), 0)`: the texel is twice
  the vertex spacing, so nothing shorter than four samples a wavelength reaches the geometry.
  - On a clipmap, the spacing is the ring scale.
  - On a plain sheet, it is the per-instance `_fft_vertex_spacing`. `Pasture3DWaterBody` writes it from
    `_effective_spacing()`.
- The vertex normal comes from the filtered slope taps. The fragment stage then REPLACES it: it samples
  slope and foam at the rest position (`v_fft_domain`), not the displaced one. Sampling at the displaced
  position would shear every crest sideways by the choppiness.
- In FFT mode the detail texture's gain was zeroed; since Phase 6 these variants do not compile it.
- Crest foam and the scatter gate read the simulation's foam channel directly. The Gerstner
  `foam_crest_threshold` was in fold-limit units and means nothing here; only streams keep it.
- **Texel convention.** The shader samples cascade `i` at continuous texel `domain · N / L_i − 0.5`, so
  texel `j` sits at `(j + 0.5) · L / N`. That is half a texel from the oracle's `j · L / N` grid. The CPU
  readback (Phase 5) must use the shader's convention. `WaterFFTWiringGate` [R] does.

### 3.1 Lighting (Phase 3)

The reference's `NEW_LIGHTING` block, split across Godot's stages:

- `fragment()`: mesoscale normal from the slope sum (× `normal_strength`, faded by distance). Foam →
  roughness (`roughness + foam · foam_roughness_modifier`). `ALBEDO` is the foam/scatter base. Depth
  fade, shore foam and alpha are as today.
- `light()`: per light, Beckmann D, Smith-Beckmann G (view and light), and the roughness-dependent
  Fresnel `F = R + (1−R)·(1−n·v)^(5·e^(−2.69a)) / (1 + 22.7·a^1.5)`. Specular goes to `SPECULAR_LIGHT`.
  k1 (wave-peak scatter, using the height channel), k2 (view scatter), k3 (shadowed scatter, ×
  `ATTENUATION`) and k4 (bubbles) go to `DIFFUSE_LIGHT`, weighted by (1−F).
- Environment reflection: Godot's radiance, through `ROUGHNESS`/`SPECULAR`. The reference's cubemap
  sample stands in for exactly that. `environment_light_strength` scales `SPECULAR`.
- Godot's `LIGHT_COLOR` already carries energy·π. The reference's `_SunIrradiance` is folded into it and
  the π is divided back out once. A test pins this, because getting it wrong is a silent 3× brightness
  error.

`water_sun_direction`/`water_sun_color` stay. The fragment stage still needs the sun for k1 when the
scene has no light in range (unshaded previews).

**As built (Phase 3).** Where it departs from the plan above, the plan was wrong or untested:

- **The engine contract, measured.** `bench/WaterPBRGate` [E] pins it on Godot 4.7 Forward+:
  - `LIGHT_COLOR` is colour × energy × π.
  - `DIFFUSE_LIGHT` is multiplied by `ALBEDO` after the loop.
  - `SPECULAR_LIGHT` is added untouched, whatever `SPECULAR` says.
  - So the reference's irradiance is `LIGHT_COLOR · ATTENUATION / π`. Godot decodes the light's colour
    from sRGB, so a `DirectionalLight3D` at energy 1 coloured (1, 0.851, 0.601), the sRGB encoding of
    (1, 0.694, 0.32), is the reference's `_SunIrradiance` (corrected in the reference spec, R6).
- **`WATER_PBR`** is defined in `water_common.gdshaderinc` for every lit variant except rivers
  (`WATER_STREAM_WAVES`), the canvas_item probe and the two debug readouts. Rivers keep Godot's built-in
  lights and the look they were tuned under. `WATER_NO_PBR` opts a custom variant out, which is also how
  the A/B captures make their "before".
- **There is no separate scatter colour.** The water's own `ALBEDO` (`deep_color` through the absorption
  solve) is the reference's `_ScatterColor`.
  - `light()` assembles its target per colour: the body terms on the water's share of `ALBEDO`, bubbles
    in `bubble_color`, foam as Lambert on `foam_color`. It then divides by `ALBEDO` so that Godot's
    multiply lands it exactly.
  - The water's share needs no varying: it is `ALBEDO − foam · foam_color`.
- **Every term takes `ATTENUATION`**, not only k3. The reference has no shadows, so it cannot say which
  terms a shadow dims. Dimming them all is the only answer that leaves a shadowed patch lit by the sky
  alone. `WaterPBRGate` [A] checks it.
- **Foam** scales the specular by (1 − foam) and the body terms by (1 − foam), which reproduces the
  reference's lerp. The foam itself is LIT (Lambert × `foam_color`), not the reference's constant colour,
  so foam in shadow takes only the sky's light.
- **The environment reflection and alpha are unchanged.**
  - The reflection is Godot's sky radiance through `ROUGHNESS` = `base_roughness` and `SPECULAR` =
    `specular_amount`. The reference's cubemap is sampled at mip 0, so a near-mirror is the faithful
    reading. `environment_light_strength` was not ported: a `SPECULAR` scale cannot reach Godot's
    grazing term, and the knob would have claimed more than it did.
  - Alpha still uses `water_fresnel()`, which goes to 1 at grazing like Godot's environment Fresnel. The
    reference's roughness-flattened F tops out near 0.69 at a = 0.075, and putting that in alpha would
    let the horizon go translucent again (shader spec §8.3).
- **Two roughnesses.** `sun_roughness` (0.075) is the Beckmann α of the sun lobe. `base_roughness` is
  still the perceptual roughness Godot squares for the sky. The reference's `_FoamRoughnessModifier`
  defaults to 0 and was not ported.
- **k1's crest height H.** Under FFT it is the per-pixel cascade sum of displacement y (the reference's
  own H, from the taps the fragment already makes). Under Gerstner it is the vertex height above
  `v_base_y`. `wave_peak_scatter` is the product of the reference's `_WavePeakScatterStrength` and
  `_HeightModifier`, which only ever appear multiplied. k1 is compiled only under `WATER_SCATTER`, so the
  low tiers skip it, as they skipped the old backlight.
- **Deleted:** `scatter_color`, `scatter_strength` and the `BACKLIGHT` term they drove. k1 replaces them.
  The ocean and lake presets now set `wave_peak_scatter`.
- The reference's normal depth attenuation and `_NormalStrength` were not ported. The slope taps are
  mip-filtered (Phase 2), which is the job the depth fade did.

**As built (Phase 4).**

- `_wave_model` 2 is fBm (`WATER_MODEL_FBM`). It rides the same `WATER_FFT` define as the FFT, because it
  shares the FFT's vertex spacing (`_fft_vertex_spacing`, or the clipmap ring scale) and its rest-domain
  varying (`v_fft_domain`). Rivers and the canvas probe have neither.
- `water_fbm()` in `water_waves.gdshaderinc` is the reference's `vertexFBM` and `fragmentFBM` in one
  function. The flag `p_drag_by_frequency` is their only difference: the fragment's drag carries `f`, the
  vertex's does not.
- **The domain is scaled by `frequency` first.** The first octave runs at 1 rad per unit, and every other
  knob, drag included, is relative to it.
  - At 1 rad/m this is the reference exactly.
  - Elsewhere, the reference's drag is a displacement in absolute metres. It would vanish on an ocean and
    dominate on a pond.
- **The DC offset is removed.** `exp(sin)` averages e^(−offset)·I0(max_peak) per unit amplitude, which
  is 0.466 at the defaults. The reference's surface floats that fraction of `height` above its rest level.
  - The mean is subtracted per octave, so a fading octave takes its mean with it.
  - `WaterFBMGate` [D]: the corrected mean is −0.002 m and the uncorrected one is 0.93 m.
- **Each octave's speed is quantised** to `water_time_period` in the shader, as `water_scroll()` does, so
  the clock's wrap is seamless (`WaterFBMGate` [L]).
- **Per-octave fades.**
  - The vertex set fades from full weight at 8 samples per wavelength to nothing at 4. That is the FFT's
    mip rule, applied to the mesh spacing.
  - The fragment set fades from 4 samples to 2 over the pixel footprint, `max(|dFdx|, |dFdy|)` of the rest
    domain. Its loop stops at the first octave with nothing left, so distant pixels run few of the 40
    octaves.
- **The fragment stage.** The fragment set's slope REPLACES the vertex normal, as the FFT's cascades do.
  Its height is `light()`'s crest height. The detail texture's gain is zeroed, and crest foam is 0, because
  the reference has no breaking signal and draws no foam.

## 4. Settings and profiles

`Pasture3DWaveProfile` gains an FFT group and an fBm group. The Gerstner knobs (`wave_count`,
`direction_deg`, `spread_deg`, `amplitude`, `length_max`, `steepness`) are deleted in Phase 6, per the
standing rule that superseded code is removed rather than shimmed. The one exception, chosen by the user:
a scene that still stores them is migrated on load (§6.6).

- **FFT:** `seed`, `depth`, `choppiness` (λ), four `cascade_length` values, and per spectrum (`wind`,
  `swell`): `scale`, `wind_speed`, `wind_direction_deg`, `fetch`, `spread_blend`, `swell`,
  `peak_enhancement`, `short_waves_fade`. Foam: `foam_bias`, `foam_threshold`, `foam_add`,
  `foam_decay` (per second).
- **fBm:** the reference's vertex and fragment sets: `seed`, `seed_iter`, `frequency`, `frequency_mult`,
  `amplitude`, `amplitude_mult`, `speed`, `speed_ramp`, `drag`, `height`, `max_peak`, `peak_offset`,
  `octaves`.
- **Manager:** `wave_model` (FFT, fBm) and `fft_resolution` (128/256/512, default 256). Also project
  settings `pasture3d/water/wave_model` and `pasture3d/water/fft_resolution`, so a game's options menu can
  set them without a scene reference.

**As built (Phase 2).**

- Each `Pasture3DWaveProfile` owns a `Pasture3DWaterFFT` sub-resource (`fft`).
  - Until it is AUTHORED, it is DERIVED from the profile's Gerstner knobs, so scenes saved before the port
    keep their character: a pond does not load as an ocean.
  - The cascade lengths scale with `length_max / 137`, the fetch by that ratio to the 1/0.66 power, and
    the spectrum scale so that the height σ is 0.176 × the Gerstner amplitude sum. 0.176 is
    `ocean_default`'s ratio.
  - Any edit to the `fft` resource marks it authored.
- The manager writes `resolution` and `loop_period` into each simulation. Those two setters do not emit
  `changed`, so they neither mark the profile authored nor re-upload every material.
- `get_amplitude_sum()` returns 6σ of the FFT (`get_displacement_bound()`) while the FFT draws.
- `get_min_wavelength()` STAYS Gerstner. Its only consumer is mesh spacing, which is a cost knob for the
  FFT (the vertex mip adapts to it). Since Phase 6 it is a stored `min_wavelength` property, seeded from
  the retired table's shortest wave.
  - An FFT answer (¼ of cascade 1) meshed `lake_calm` at 0.48 m instead of 1.27 m.
  - The clipmap's reach shrank 2.6×, and the lake stopped covering its own outline (`WaterTwoLakesGate`
    [B] 0.72).
- The manager has `wave_model` (FFT, GERSTNER) and `fft_resolution`.
  - `is_fft_effective()` is FFT plus a RenderingDevice.
  - The project settings above are not built yet.
- The simulations tick from `NOTIFICATION_PROCESS`, once per rendered frame, and only the ones some
  material has been given. While the manager is paused, `dt` is 0.
- **Rebinding after a texture build.** A material DRAWN before a simulation's first build holds the
  shader's default black array.
  - `Texture2DArrayRD::get_rid()` lazily makes a plain 2D placeholder. The `sampler2DArray` refuses that
    type and binds its default, and the later `texture_replace()` never reaches that binding.
  - The simulation therefore counts its builds (`get_texture_generation()`). On a change the manager
    re-uploads its cache and emits `wave_textures_changed`, and the ocean and masked pools re-upload into
    their private duplicates.
  - The signal is not `profiles_changed`, because water bodies with auto spacing re-mesh on that.
  - Masked pools now also re-upload on `profiles_changed`. Their duplicate used to snapshot the plugin
    uniforms once, so a knob edit or a model switch never reached it.

**As built (Phase 4).**

- **`Pasture3DWaterFBM`** (`src/pasture_3d_water_fbm.h/.cpp`) is the profile's `fbm` sub-resource. It holds
  two knob sets as `vertex/<knob>` and `fragment/<knob>`, the FFT spectrum's dynamic-property pattern.
  - Defaults are the reference's, with 8 vertex octaves and 40 fragment octaves.
  - `get_shader_pack(set)` is the four vec4s `_fbm_v0..3` / `_fbm_f0..3` take. The fourth carries the
    amplitude sum, the unit mean and the octave count, so the shader needs no pre-pass.
  - Closed forms: `get_unit_sigma()` = e^(−o)·√(I0(2m) − I0(m)²)·√Σa²/Σa, treating the octaves as
    independent and ignoring drag. `get_displacement_bound()` is the vertex set at its all-crest or
    all-trough extreme about the corrected mean. It is a true bound: the fBm has no rare-crest tail.
- **Derived until authored**, like `fft`.
  - `seed` is `direction_deg` and `frequency` is 2π / `length_max`.
  - `speed` is 2·√k, the reference's 0.64 of deep-water dispersion.
  - The vertex `height` gives σ = 0.176 × the Gerstner amplitude sum, the FFT's target.
  - The fragment `height` is that × Σa_frag / Σa_vert, so both sets' first octaves are the same metres.
    The reference normalises each set by its own sum, so equal `height` knobs draw normals for a sea 25%
    shallower than the geometry.
  - For the default profile: k 0.0459 rad/m, speed 0.428 rad/s, height 7.34 m, σ 0.859 m, bound 3.92 m.
- **The profile's model is now `set_active_model()`.** It takes `MODEL_GERSTNER` / `MODEL_FFT` /
  `MODEL_FBM`, which are the shader's values. It replaces `set_fft_active()`. `is_fbm_active()` sits beside
  `is_fft_active()`, and `get_amplitude_sum()` answers the fBm's bound under fBm.
- **The manager.**
  - `wave_model` is FFT, GERSTNER, FBM or PROJECT, and PROJECT is the default. GERSTNER keeps its value 1
    until Phase 6.
  - `fft_resolution` 0 means the project setting, and 0 is the default.
  - `get_effective_wave_model()` resolves PROJECT and then falls back from FFT to FBM where
    `Pasture3DWaterFFT.is_supported()` is false. It warns once per process.
  - `is_wave_model_fallback()` is true only for that fallback.
  - `is_fft_effective()` is now `get_effective_wave_model() == FFT`.
- **Project settings.** `pasture_3d/water/wave_model` (FFT, fBm) and `pasture_3d/water/fft_resolution`
  (128/256/512, default 256).
  - Spelled `pasture_3d/`, not the spec's `pasture3d/`, to match the existing `pasture_3d/performance/*`.
  - Registered with their initial values on the manager's ENTER_TREE, so project.godot stores them only
    once moved.
  - The manager listens to `ProjectSettings.settings_changed` and re-applies only when the effective
    answer moved. A runtime `set_setting()` reaches it, measured by `WaterFBMGate` [P], so a game's options
    menu needs no node reference. `refresh_project_settings()` is bound for a game that wants the switch
    in the same frame.
- **CPU queries** answer from the model drawn since Phase 5 (§5).

Presets (Phase 6) give ocean, lake and pond profiles. Pond defaults to N=128-equivalent cascades
(short lengths).

## 5. CPU height (buoys)

- **FFT:** after `AssembleMaps`, `texture_get_data_async` reads mip 0 of the displacement array back.
  This is ~2 MB at N=256 in rgba16f; a later phase may read a smaller mip if that measures as too much.
  The profile keeps the latest frame's four layers on the CPU. `get_height_at(domain_xz, t)` sums
  bilinear taps. `solve_domain()` keeps its fixed-point inversion of the horizontal displacement, which is
  what it already does for Gerstner. **Latency: 1–3 frames.** The answer describes the surface as of the
  readback, not as of `t`, and the API documents it.
- **fBm:** a C++ transcription of `vertexFBM` in `water_waves.cpp`. Parity is a tolerance, not bit
  equality, because `exp`/`sin` are not correctly rounded. The gate states the bound and has a control
  that breaks it.
- **Headless / no device:** fBm is selected (G3), so gates and dedicated servers get a deterministic
  surface.

**As built (Phase 5).**

- **The profile's four queries** (`get_height_at`, `get_surface_point`, `get_normal_at`, `solve_domain`)
  branch on the active model. Everything above them is unchanged: the manager's `evaluate_*` and
  `solve_domain`, the ocean's and the GDScript body's `get_water_height`, and `Pasture3DBuoy`.
- **FFT readback.** `Pasture3DWaterFFT` queues `texture_get_data_async` for the four displacement layers
  right after the mips are built, in the same render-thread update.
  - It keeps mip 0 of each layer as raw rgba16f, about 0.5 MB at N=256, and decodes only the taps it reads.
  - A frame is published only when all four layers of one dispatch have arrived. A newer complete frame
    drops any older one still pending, and at most 8 can be in flight.
  - `CpuSurface::sample()` is the vertex shader's convention: uv = domain / length, repeat-wrapped,
    bilinear between texel centres, summed over the cascades. The texel coordinate is formed in double.
- **On demand.** Every FFT query calls `request_cpu_surface()`, and the readback runs for
  `READBACK_KEEPALIVE` (120) updates after the last one. A sea nobody floats anything on reads nothing
  back. The cost: the first query on a quiet sea answers flat (height 0, normal up) until a frame lands.
- **`p_time` is ignored under the FFT.** The answer is the surface as of `get_readback_time()`.
  `get_readback_update()` against `get_update_count()` is the lag in updates.
- **One copy per query.** A query takes one copy of the surface (the arrays are copy-on-write) and reads
  it for every tap, so a 16-iteration solve cannot straddle two frames.
- **The FFT normal** comes from central differences of the displaced point, 0.25 m either side. The slope
  output is not read back, so the cost stays at one output.
- **fBm.** `Pasture3DWaterFBM::evaluate()` is `water_fbm()` transcribed in float, reading the same pack the
  shader gets.
  - The profile evaluates the vertex set with spacing 0, so every octave runs at full weight. That is what
    the mesh draws wherever it is finer than about λ0 / 25 at the default eight octaves.
  - The speeds quantise to the profile's loop period, which the manager pushes and which is
    `water_time_period`.
  - The fBm is vertical only, so `solve_domain()` is the identity.
- **Gerstner** was deleted in Phase 6. A profile with no model answers flat.

## 6. Phases

| Phase | Scope | Gate |
|---|---|---|
| **1. FFT core** | `src/shaders/water_fft.glsl` (kernels 0–6), `Pasture3DWaterFFT` (RD resources, render-thread dispatch, Texture2DArrayRD), profile FFT knobs | `WaterFFTGate`: (a) an energy-conservation check on the spectrum, with a control where the band limit is removed and the double-count must show; (b) a loop seam — a readback at t=0 equals one at t=period, with a control where quantisation is off and must fail; (c) seed determinism; (d) the imaginary residual of the IFFT is ~0 |
| **2. Shader + wiring** | manager ticks the simulations; cached materials get the textures; FFT path in `water_waves.gdshaderinc`; LOD-aware vertex taps | windowed visual check on the ocean, a lake and a pond; existing water gates still pass, or are rescoped with a reason |
| **3. Lighting** | Garrett PBR in `light()` | energy pin (the π fold); A/B screenshots against the reference look |
| **4. fBm fallback** | fBm shader path, `wave_model` setting, auto-fallback with no device | the fallback is reached headless; parse/compile on the Compatibility renderer; uniform-branch cost (**asks first**) |
| **5. Buoys** | readback, CPU sampler, fBm CPU mirror | buoy rides within the stated tolerance and latency on both models; a control with a stale buffer fails |
| **6. Retire Gerstner** | delete the Gerstner table/knobs/tests; presets; guide update; decide `WATER_DETAIL` | grep for every deleted symbol is clean; presets load |

### 6.1 Phase 1 result (2026-10-09, `WaterFFTGate`, N=128, windowed Forward+)

The criteria replaced the plan in the table; each has a control that fails.

| | Criterion | Result | Control |
|---|---|---|---|
| A | GPU displacement = float64 direct DFT of the GPU's own h0, 4 texels × 4 cascades | worst err/tol 0.191 | oracle at t+0.5 s: ≥ 25.7× tol. The pre-fix deep-water kernel failed the depth-aware oracle at 43× on the 500 m cascade. |
| S | t=0 equals t=period | relative diff 0 | period ×1.37: 1.39 |
| D | same seed bit-identical | 0 | seed 2 differs, 1.38 |
| B | band-limited variance is layout-independent (6 seeds) | ratio 0.950 | unbanded inflates ×1.40 |
| P | realised variance = spectrum integral (6 seeds) | 1.026 (Hs 3.70 vs 3.65 m) | 0.6× energy reads 0.615 |
| M | mip 1 = 2×2 mean of mip 0, both outputs | worst err/tol 0.406 | — |

[A]'s tolerance adds `2|h̃|` for each mode whose `√(gk)/ω₀` sits within float32 rounding of an integer
(8 such modes, all in the 4 m cascade). Those floor differently on the GPU and in float64, and the gate
bounds rather than guesses them.

### 6.2 Phase 2 result (2026-10-09, `WaterFFTWiringGate`, N=128, windowed Forward+)

| | Criterion | Result | Control |
|---|---|---|---|
| B | material drawn before the first build renders the FFT after the manager's rebind | generation 1, rebind 1, correlation 0.989 | a private material drawn early and never re-uploaded: sd 0 m (flat) |
| W | FFT model writes `_wave_model` 1, the sim's own texture wrappers and lengths; resolution reaches the sim | all as expected | GERSTNER: `_wave_model` 0, profile inactive |
| T | one dispatch per rendered frame | 10 ticks / 10 updates in 10 frames | GERSTNER: 0 ticks |
| R | unlit top-down render (EMISSION.b = h/8 + ½) vs the readback rebuilt at the shader's texel convention | correlation 0.989, slope 0.987, sd 0.886 vs 0.887 m | GERSTNER branch on the same prediction: −0.18 |

Existing gates, run windowed after the change:

- **Pass:** `WaterFFTGate`, `WaterPhase1Gate`, `WaterBodiesPhase1/3/4/5/7Gate`, `WaterPresetCheck`,
  `WaterVariantWarningCheck`, `WaterBodyLateManagerCheck`, `GraphWaterNodesGate` and
  `WaterTwoLakesGate`.
  - TwoLakes went red twice before this. First on the min-wavelength rule above.
  - Then on [G]'s anti-null: its two cameras were congruent, centred on identical lakes with identical
    body-relative waves. Gerstner's 0.00093 there was float rounding at x = ±400 m, and the FFT's texture
    lookup has none. Camera 1 is now 40 m off its lake's centre (anti-null now 0.0218).
  - Once the rebind made the pools' FFT live, [G] and [H] read about 0.0004 between captures. The gate
    froze the clock by disabling the manager's physics process, but the FFT's foam still integrates the
    frame `dt`. The gate now also sets `paused`, which zeroes it. The same holds for any capture
    comparison: freezing water_time alone no longer freezes the surface.
- **Already red, unchanged:** `WaterPhase2–5Gate` and `WaterBodiesPhase0Baseline`, which carry the STALE
  FIXTURE header (8c538e51).
- **Red by design:** `WaterBodiesPhase2Gate` compares the extracted ocean against a Gerstner-era image
  (`bench/baselines/phase1_ref`). The ocean is now FFT, so its pixel criterion cannot pass until that
  baseline is re-taken. That gate also takes timings, and it ran once before this was noticed.
- **Not run:** `WaterBodiesPhase6Gate`, because it times a query.

Visual check (ocean / lake / pond on a plain sheet, FFT vs Gerstner): all three draw a broadband sea with
per-pixel slope detail. The thin dark streaks on back slopes near the horizon are the same in the
Gerstner shots. They come from the empty fixture, which has nothing under the sheet.

### 6.3 Phase 3 result (2026-10-09, `WaterPBRGate`, windowed Forward+)

The fixture is a flat sheet of `water_body.gdshader` under one white sun. The world is black: no sky, no
ambient, no reflections. The tonemap is linear and the readback is float. `_predict()` is `light()`'s
arithmetic in GDScript.

| | Criterion | Result | Control |
|---|---|---|---|
| E | sun lobe (sun and camera overhead) and body terms (sun 35°, camera 60° opposite) match the prediction | rel. error 0.0008 and 0.0005; 2× energy gives 2.0000× | the prediction without the π divide misses by 0.682 (= 1 − 1/π) |
| K | k1 at a Gerstner crest of known height (2 m, normal exactly up): `wave_peak_scatter` 0 and 8 each match | 0.0004 and 0.0002 | the k1-free prediction misses the k = 8 render by 0.832 |
| A | a box's shadow on the body geometry | shadowed pixel 0.0000 of predicted | the same frame with the light's shadows off matches to 0.0005 |

[K]'s first geometry sat near the mirror direction. The glint swamped k1 and its control margin was 0.06,
so the geometry moved off the lobe.

Existing gates, run windowed after the change, all pass: `WaterFFTGate`, `WaterFFTWiringGate`,
`WaterPhase1Gate`, `WaterBodiesPhase1/3/4/5/7Gate`, `WaterPresetCheck`, `WaterVariantWarningCheck`,
`WaterTwoLakesGate`, `WaterBodyLateManagerCheck` and `GraphWaterNodesGate`. The timing gates were not
run. The status of §6.2's red gates is unchanged.

A/B captures (ocean, a backlit ocean, lake and pond, against a `WATER_NO_PBR` build of the same
material):

- The body colour is close to the "before".
- The sun path is broader and brighter, because the lobe is Beckmann α 0.075 rather than Godot's GGX at
  `base_roughness`².
- On the pond, that width spreads into one large blown-out streak. The reference's 0.075 is an ocean
  value, and still water wants a smaller `sun_roughness`. That is a preset decision, left for Phase 6.
- k1 is hard to see by eye at the ocean's very dark `deep_color`, because it rides on `ALBEDO`. [K] is
  what shows it is there.

### 6.4 Phase 4 result (2026-10-09, `WaterFBMGate`)

The gate runs three ways, and each mode runs what its renderer can see:

- windowed Forward+: F, D, L, N, P
- headless: H
- windowed `--rendering-method gl_compatibility`: H, F, N

The shape fixture is a sheet meshed every 0.25 m, seen straight down through `WATER_DEBUG_SURFACE`, with
every pixel centre on a vertex. The material is filled by the manager's own `upload_profile_into()`.
`_fbm()` is `water_fbm()`'s arithmetic in GDScript.

| | Criterion | Forward+ | Compatibility / headless | Control |
|---|---|---|---|---|
| H | default manager (PROJECT asks FFT) with no device draws fBm: effective FBM, fallback flag, `_wave_model` 2 and the pack in the material | — | pass, both | explicit GERSTNER and explicit FBM managers are not fallbacks (0 and 2 uploaded) |
| F | per-pixel height and vertex normal match the prediction (rel. RMS) | 0.0099 and 0.0064 (tol 0.03) | 0.029 and 0.015 (tol 0.12) | prediction without drag misses by 0.361; without speed quantisation by 0.782 |
| D | mean height over the frame and four instants | −0.0024 m (tol 0.16) | — | the pack's mean zeroed (the reference) sits at 0.929 m; closed form 0.932 |
| L | t = 0 and t = period render the same surface | rel. RMS 0.0005 | — | the same instants with `water_time_period` 97 s differ by 1.47 |
| N | the lit shipped shader: luminance spread, fBm over a flat table | 35.9× | 25.0× (the lit variant compiles on GL) | the flat table's own spread |
| P | a manager on PROJECT follows a runtime write of `pasture_3d/water/wave_model`, 0 → 1 → 0 | FFT → fBm → FFT in the effective model, the profile and a cached material | — | the first state (FFT) is the control the switch must leave |

No shader errors were logged on Forward+ or Compatibility.

N's first framing tilted the orthographic camera 60°. That ran the view off the sheet, and both arms
measured the background edge (ratio 1.0). The camera now stays straight down.

**Uniform-branch cost, measured 2026-10-09 with the user's go-ahead** (`WaterModelBranchTiming`, RTX 3070,
1280×800, windowed Forward+). The shipped material is timed against the same shader with
`WATER_STATIC_MODEL` defined: `_wave_model` becomes a const, the compiler folds the branch, and that is
the code the twin-variant route would ship. Interleaved, five passes after a discarded warm-up, worst
pass-to-pass spread 1.5%.

| Body | Model | Uniform | Folded | Branch cost |
|---|---|---|---|---|
| ocean (clipmap) | FFT | 0.216 ms | 0.206 ms | +0.010 ms, +5.7% of the water |
| ocean | fBm | 0.388 ms | 0.384 ms | +0.004 ms, +1.1% |
| lake (meshed) | FFT | 0.216 ms | 0.204 ms | +0.012 ms, +6.9% |
| lake | fBm | 0.347 ms | 0.340 ms | +0.007 ms, +2.3% |

The water-hidden frame is 0.030 ms. Instrument checks: the folded and uniform variants draw identical
frames (mean abs diff 0.00000), while folded FFT and folded fBm differ (0.034 / 0.027). Every arm costs
more than the hidden frame.

- The branch costs the **FFT** path, which is the default, 6–7% of the water's draw. The likely cause is
  the untaken fBm code's register pressure on the shared program; the fBm path pays 1–2%.
- **The fBm fallback draws ~1.7× the FFT's fragment cost** (0.38 vs 0.21 ms on the ocean): its 40
  fragment octaves near the camera. Not counted here: the FFT's compute. It is dispatched outside the
  viewport's render timer, so these figures compare draws only. The fBm is the "no compute" fallback,
  not a cheaper draw.
- Decided 2026-10-09: **keep the uniform branch.** Its ~10 µs does not justify making the manager swap
  `shader` on its cached duplicates.

**Full cost, FFT compute included** (`WaterModelCostTiming`, same machine and frame, user's go-ahead). The
FFT's compute is bracketed by GPU timestamps queued from nodes that process before and after the manager.
Checks: compute scales with N (0.058 < 0.163 < 0.605 ms); fBm arms read 0.0001 ms between the stamps;
every arm draws more than the hidden frame. Draw spread 0.9%.

| Arm | Draw | Compute | Total (ocean) | Total (lake) |
|---|---|---|---|---|
| FFT N=128 | 0.208 | 0.058 | 0.266 | 0.265 |
| **FFT N=256 (shipped)** | 0.217 | 0.163 | **0.380** | **0.374** |
| FFT N=512 | 0.223 | 0.605 | 0.828 | 0.794 |
| **fBm 40 fragment octaves (shipped)** | 0.393 | — | **0.393** | **0.348** |
| fBm 16 octaves | 0.276 | — | 0.276 | 0.278 |
| fBm 12 octaves | 0.253 | — | 0.253 | 0.257 |

- At the shipped settings the two models cost the **same** in total (0.38 vs 0.39 ms on the ocean). The
  draw-only comparison above, which made the fBm look 1.7× dearer, left out 0.16 ms of compute.
- fBm at 16 fragment octaves is 27% cheaper than the shipped FFT and level with FFT N=128.
- The FFT's compute is per **profile**, whatever the water covers on screen; it ran even with the ocean
  hidden (0.163 ms). An ocean, a lake and a pond on three profiles pay it three times, about 0.5 ms here.
  The fBm's cost is per pixel.

**Octave count, visually** (`WaterFBMOctaveCompare`, six views, 40 against 16). Plain 16 octaves cuts
the series' short waves: the water goes glassy close up and the sun glint becomes a blob. 16 octaves
respaced over the same wavelength range (frequency, amplitude and speed ratios raised to 39/15, height
rescaled by the amplitude-sum ratio) keeps the detail but shows parallel streaking. Neither ships.

**Decided 2026-10-09: the fBm is the compatibility model, not a performance option.** It stays at 40
fragment octaves. Its value is that it needs no RenderingDevice (Compatibility, headless) and that
CPU height queries are exact and same-frame, with no readback lag. The performance lever is
`fft_resolution` 128. Choosing fBm where the FFT can run raises a configuration warning on the manager
and a once-per-run log (`is_fbm_by_choice()`, `WaterFBMGate` [W] on all three renderers). It stays
selectable for testing; hiding it from Forward+ is a possible later step.

Existing gates, run windowed after the change, all pass: `WaterPBRGate`, `WaterFFTGate`,
`WaterFFTWiringGate`, `WaterPhase1Gate`, `WaterBodiesPhase1/3/4/5/7Gate`, `WaterPresetCheck`,
`WaterVariantWarningCheck`, `WaterTwoLakesGate`, `WaterBodyLateManagerCheck` and `GraphWaterNodesGate`.

- `GraphWaterNodesGate` printed PASS every time. It exited 127 on two of three runs, each time after a
  Vulkan `vkEndCommandBuffer: Invalid commandBuffer` at quit, and 0 on the third. It creates no water
  manager or profile, so this is a teardown flake and not this phase.
- The timing gates were not run.

### 6.5 Phase 5 result (2026-10-09, `WaterBuoyGate`)

Run three ways, as `WaterFBMGate`: headless runs H; Compatibility runs H and B; Forward+ runs H, B, R, S
and A. The drawn surface is the same debug sheet as §6.4: WATER_DEBUG_SURFACE, straight down, with every
pixel centre on a rest vertex. Under the FFT the sheet's `_fft_vertex_spacing` is 0.001, so every cascade
samples mip 0. The CPU side is always the bodies' call path: the manager's
`evaluate_height(solve_domain(xz))`.

| | Criterion | Result | Control |
|---|---|---|---|
| H | `evaluate()` against water_fbm() in GDScript double, 200 points within 10 m and 10 s | 5.6e-4 m (tol 2e-3) | the oracle without drag misses by 0.547 m |
| H | loop: t = 0 against t = period | 1e-5 m (tol 0.02) | t = 97 s misses by 0.646 m |
| H | routing: an FBM profile answers `evaluate()` exactly, and `solve_domain` is the identity | pass | the same profile on GERSTNER answers 0.903 against −0.085 |
| B | fBm buoy against the drawn surface, rel. RMS | 0.0091 Forward+, 0.028 Compatibility (tol 0.03 / 0.12) | the CPU 0.25 s early: 0.68 |
| R | readback on demand; lag after warm-up | first frame after 1 update; lag 1 on 119 of 119 frames (bound 3); 119 readbacks in 120 frames | a profile never queried read back 0; after the keepalive the count stopped (240 then 240) |
| S | the readback against a synchronous `read_layer()` of the same frame, decoded independently, at 64 points | 0.0 m (tol 1e-5) | the kept answers of one second earlier miss by 3.6 m |
| A | FFT buoy against the drawn surface, rel. RMS (surface RMS 1.16 m, σ 0.91 m, N=128) | 0.0050 (tol 0.02) | the stale buffer of one second earlier: 0.91 |

Reported, not asserted:

- Without the horizontal solve, the FFT buoy misses by 0.175. The inverse is what puts a buoy on the drawn
  surface.
- Float32 phase precision. `evaluate()` moves away from the double oracle as the phase grows: 1e-4 m
  within ±1 m, 1.2e-2 m over ±300 m and the whole period. The shader has the same float32 limit, so H
  asserts on the small domain, and B is the parity that counts.
- The lag of 1 was measured with uncapped frames. At a capped frame rate the GPU can be two or three frames
  behind; the API says one to three.

**Gates rescoped, with reasons.** These three gates now pin their manager's model. The cause: CPU queries
answer from the model drawn, and on Forward+ the default draws FFT.

- `WaterBodiesPhase1Gate` is pinned to GERSTNER. Its G4 is the Gerstner parity contract, probed by a
  canvas_item shader that can only draw Gerstner. Phase 6 deletes or rewrites it with the rest of
  Gerstner.
- `WaterBodiesPhase5Gate` is pinned to fBm. Its probes ask once, and the FFT answers a first query flat.
- `WaterBodiesPhase6Gate` (bodies) is pinned to fBm. Its fixtures are amplitude-tuned analytic seas, and
  [H]'s control moves the ocean and asks again within the frame.

Existing gates, run windowed after the change, all pass: `WaterFBMGate`, `WaterPBRGate`, `WaterFFTGate`,
`WaterFFTWiringGate`, `WaterPhase1Gate`, `WaterBodiesPhase1Gate`, `WaterBodiesPhase3Gate`,
`WaterBodiesPhase4Gate`, `WaterBodiesPhase5Gate`, `WaterBodiesPhase6Gate`, `WaterBodiesPhase7Gate`,
`WaterPresetCheck`, `WaterVariantWarningCheck`, `WaterTwoLakesGate`, `WaterBodyLateManagerCheck` and
`GraphWaterNodesGate`. `StreamRippleCheck` passes headless.

**Correction to §6.3 and §6.4's "the timing gates were not run".** The runner behind those phases did not set
`SKIP_TIMING`. `WaterBodiesPhase3Gate` therefore ran its timing criterion A (a 500 m lake rebuilds in
≤ 500 ms) each time, and it passed. The runner now exports `SKIP_TIMING=1`, so Phase 5's runs are
correctness only.

### 6.6 Phase 6 result (2026-10-09, `WaterRetireGerstnerGate`)

**Deleted.**

- `src/water_waves.h/.cpp` (the table and its CPU mirror) and its unit tests in `unit_testing.cpp`.
- The profile's Gerstner knobs and `get_shader_table()`, `get_steepness()`, `_wave_defaults`.
- The manager's `WAVE_MODEL_GERSTNER` (1) and the profile's `MODEL_GERSTNER` (0). A stored manager
  `wave_model` of 1 reads as PROJECT.
- In the shaders: the table uniform `_waves`, `wave_steepness`, `WATER_WAVE_COUNT`, `WATER_MAX_WAVES`,
  `WATER_NO_FFT`, `WATER_PLAIN_DOMAIN_ORIGIN`, and the Gerstner branch of `water_waves.gdshaderinc`.
  `_wave_variant_count` went from the pool and stream warnings, which now ask `_draws_wave_profile`.
- Bench: `WaterPhase2Gate`..`WaterPhase5Gate` (already red, building no ocean, and measuring Gerstner),
  `WavePresetTables`, `water_parity_probe.gdshader`, `water_depth_probe.gdshader`.

**Migration** (the user's choice). `Pasture3DWaveProfile::_set` takes the six legacy keys, and
`_apply_legacy()` fits whichever model the scene did not also store: `fit_sea(direction_deg, length_max,
0.176 × Σa)` over the retired series at the default 120 s period, and `min_wavelength` = the series'
shortest wave. `set_fft` / `set_fbm` mark a model authored, so a stored `fbm` survives keys loaded before
or after it. A new profile runs the same fit from the retired defaults: one path for both.

**Presets.** `_seed_default_profiles()` is a table of `fit_sea` arguments (direction, length, σ,
min_wavelength) equal to the migration of the old presets, so a shipped lake and a migrated lake are the
same lake. The `M_water_*.tres` presets lost their `_waves` and `wave_steepness`. **Taste call:** the pond
ships `sun_roughness` 0.035, not the ocean's 0.075, which smeared a millpond's highlight; the user has not
looked at it yet.

**Bug the new gate found.** `water_shading.gdshaderinc` scrolled foam by `detail_flow0`, which is declared
only under `WATER_DETAIL`. Making that river-only broke compilation of every other variant. Foam now
scrolls by a new `foam_flow` uniform (m/s, default the ocean's old `detail_flow0`, 0.32/0.11; the lake
preset stores its own 0.14/0.05). Rivers' foam still rides their flow.

| | Criterion | Result | Control |
|---|---|---|---|
| G | no deleted symbol in addons, bench, demo (data excluded) or src, comments excluded | 0 hits over 1034 res files, 151 src files | a fixture line holding a symbol matches; file-count floors (200 / 50) |
| L | every `M_water_*.tres` stores only parameters its shader declares | 5 presets ok | `_waves` on the ocean is undeclared |
| P | each shipped profile equals a migration of its old Gerstner knobs, 1e-4 relative | errors 4.6e-6 .. 9e-6 | against the NEXT preset's migration: misses by 0.92 .. 1.0 |
| M | saved `.tres` with legacy keys loads refitted; a stored `fbm` (before or after the keys) is kept; the FFT is refitted | refit error 0, authored height 3.25 kept | a plain profile differs from the migrated one by 1.0 |

**Gates rescoped, with reasons.**

- `WaterBodiesPhase1Gate` [A]: G4's Gerstner CPU/GPU probe is gone. A now checks that two profiles in one
  scene each reach their own material (FFT textures and lengths, or the fBm pack), with the other profile
  as the control. Parity is `WaterBuoyGate`'s.
- `WaterBuoyGate` [H]: the control is the same profile with `fbm` null answering flat.
- `WaterFBMGate` [H]: a stored GERSTNER (1) must read as PROJECT. [N]'s flat control is `_wave_model` 1
  with no FFT textures.
- `WaterPBRGate` [K]: the crest of known height is a one-octave fBm (drag 0, speed 0, max_peak 1,
  peak_offset 1); at x = λ/4 its height is `height·(1 − unit_mean)` with zero slope.
- `WaterFFTWiringGate`: its GERSTNER controls are FBM.
- `WaterVariantWarningCheck`, `WaterTwoLakesGate`, `WaterShorePoolProbe` [D], and
  `WaterMaterialPropagationCheck` (D moves to the river, the only `WATER_DETAIL` left) now read the
  profile's model instead of `_waves`.
- `WaterBodiesPhase2Gate`'s legacy-ocean checks compare against a profile migrated from the same keys.
- Ocean fixtures in the bench call `fit_sea` with `ocean_default`'s numbers.
- `WaterBodiesPhase2Gate` [B] asks `get_water_height()` twice, frames apart: the first FFT query answers
  flat by contract, which is the answer [B] refuses. Red since Phase 5, unnoticed because the gate is
  red by design on [A]'s image baseline (§6.2), which it still is.

**Clipmap seam, found by the rescoped `WaterTwoLakesGate` [C].** Its readout used to copy `_waves` but
not `_wave_model`, so since Phase 2 it had measured the Gerstner rim while the lake drew the FFT. Carrying
the real model, A's rim read p99 2.47 m against 0.21 m with no waves, though lake_calm's FFT moves a
point at most 0.48 m sideways (readback, p99 0.31 m). The capture showed pinholes on the ring
boundaries: each clipmap ring picked its FFT mip from its own cell size, so a ring's morphed outer edge
and the next ring's inner edge sampled mips a level apart and the shared vertices separated.
`water_surface.gdshaderinc` now scales the spacing by `1 + vertex_lerp`, so the morphed edge reads the
coarse ring's mip. After: p99 0.169 m, and the 8 m-texel control still degrades to 2.92 m. This shipped
from Phase 2 to here; the fBm's octave fade had the same one-level step, now also continuous.
`WaterShorePoolProbe`'s clipmap readout had the same blind spot, copying no wave uniforms at all; it
now carries the pool's model and passes (clipmap rim p99 0.11 m, the static-sheet control alike).

**Sweep after the fix** (windowed Forward+, `SKIP_TIMING=1`): `WaterBuoyGate`, `WaterFBMGate`,
`WaterPBRGate`, `WaterFFTGate`, `WaterFFTWiringGate`, `WaterPhase1Gate`, `WaterBodiesPhase1/3/4/5/6/7Gate`,
`WaterPresetCheck`, `WaterVariantWarningCheck`, `WaterTwoLakesGate`, `WaterBodyLateManagerCheck`,
`GraphWaterNodesGate`, `WaterRetireGerstnerGate` and `WaterShorePoolProbe` pass; `StreamRippleCheck`
and `WaterMaterialPropagationCheck` pass headless; `WaterShaderCompileCheck` compiles every variant.
`WaterBodiesPhase2Gate` fails only [A], the stale image baseline. `GraphWaterNodesGate` once exited 127
after its PASS line on a Vulkan loader error at quit; the rerun exited 0.

## 7. Risks

- **The render-thread dispatch order against the water draw.** If the simulation runs after the draw, the
  surface lags a frame. Harmless, but a buoy compared with the picture would see two frames of latency,
  not one.
- **Half-float displacement** at the ocean's largest cascade (hundreds of metres, amplitudes of metres):
  rgba16f has ~3 significant digits, so ~1 cm at 10 m. Fine for display; it is the floor on buoy parity.
- **Overlapping water bodies on different profiles** each pay a full FFT. A scene with an ocean, a lake
  and a pond profile runs three. The pond preset's short cascades make its share cheap, but it is not
  free.
