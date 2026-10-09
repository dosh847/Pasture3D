# Pasture3D Water — FFT Ocean, fBm Fallback, Microfacet Lighting

Status: **spec written 2026-10-09. Phase 1 built and gated 2026-10-09 (`WaterFFTGate` 6/6, §6.1); not
committed. Phases 2–6 unbuilt.**

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
N=512, which is inside Vulkan's guaranteed 16 KB minimum. N=1024 (32 KB) is desktop-only and is not
offered.

### 2.2 Deliberate deviations from the reference

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
FFT cascades down to ~12 cm make it redundant on the FFT path. It stays compiled for fBm until Phase 6
decides.

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

## 4. Settings and profiles

`Pasture3DWaveProfile` gains an FFT group and an fBm group. The Gerstner knobs (`wave_count`,
`direction_deg`, `spread_deg`, `amplitude`, `length_max`, `steepness`) are deleted in Phase 6, per the
standing rule that superseded code is removed rather than shimmed.

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

## 7. Risks

- **The render-thread dispatch order against the water draw.** If the simulation runs after the draw, the
  surface lags a frame. Harmless, but a buoy compared with the picture would see two frames of latency,
  not one.
- **Half-float displacement** at the ocean's largest cascade (hundreds of metres, amplitudes of metres):
  rgba16f has ~3 significant digits, so ~1 cm at 10 m. Fine for display; it is the floor on buoy parity.
- **Overlapping water bodies on different profiles** each pay a full FFT. A scene with an ocean, a lake
  and a pond profile runs three. The pond preset's short cascades make its share cheap, but it is not
  free.
