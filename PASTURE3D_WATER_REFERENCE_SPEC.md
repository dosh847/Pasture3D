# Pasture3D Water: Reference Fidelity

Status: **audit written 2026-10-11. Decisions D1–D5 taken 2026-10-11 (the recommendations, §4). R1 built 2026-10-11 (§7.1), R2 built 2026-10-12 (§7.2), R3 built 2026-10-12 (§7.3), R4 built 2026-10-12 (§7.4); R5–R7 not started.**

## 1. The ask

On 2026-10-11 the user decided:

- **All water shaders should reproduce GarrettGunnell/Water as faithfully as possible.** This covers the
  ocean, lake and pond (`water_ocean*`, `water_body*`). Rivers have no reference and are out of scope.
- **A new `Pasture3DOcean` starts with the Garrett instance.** The water has not shipped, so the default
  wave profiles may change.

This reverses some deliberate departures recorded in PASTURE3D_WATER_FFT_SPEC.md §2.2 and §3.

**Ground truth.** The reference was fetched 2026-10-11 from `GarrettGunnell/Water@HEAD`, last commit
2023-12-30. It has no tags, so this spec cites values rather than a revision. The files are:

- `Assets/Shaders/FFTWater.shader`, the `NEW_LIGHTING` path.
- `Assets/Shaders/FFTWater.compute`.
- `Assets/Scripts/FFTWater.cs`.
- `Assets/Scenes/SampleScene.unity`. Its saved values differ from the script defaults, and its values are
  what the reference renders.

**Colour space.** The reference renders in a linear colour space (`m_ActiveColorSpace: 1`). Its Color
fields are sRGB-authored and linearised by `SetColor`. Godot's `source_color` uniforms do the same, so
its colours port as-is.

## 2. The reference scene

These are the values the Garrett instance must reproduce.

- **Simulation.**
  - N = 1024.
  - seed 1, depth 20, gravity 9.81, speed 1, repeatTime 200.
  - lambda (1, 1), lowCutoff 0.0001, highCutoff 9000.
- **Cascades.**

  | | lengthScale | tile (drawn repeat) | drawn | displaces | foamSubtract |
  |---|---|---|---|---|---|
  | 1 | 94 m | 0.01 (100 m) | yes | yes | +0.04 |
  | 2 | 128 m | 3 (0.33 m) | **no** | no | −0.04 |
  | 3 | 64 m | 3 (0.33 m) | **no** | no | −0.46 |
  | 4 | 32 m | 0.13 (7.7 m) | yes | no | −0.38 |

- **Spectra, a pair per cascade** (scale, wind m/s, direction °, fetch m, spreadBlend, swell, peakEnhancement, shortWavesFade):
  1. 0.1, 2, 22, 1e5, 0.642, 1, 1, 0.025
  2. 0.07, 2, 59, 1e3, 0, 1, 1, 0.01
  3. 0.25, 20, 97, 1e8, 0.14, 1, 1, 0.5
  4. 0.25, 20, 67, 1e6, 0.47, 1, 1, 0.5
  5. 0.15, 5, 105, 1e6, 0.2, 1, 1, 0.5
  6. 0.1, 1, 19, 1e4, 0.298, 0.695, 1, 0.5
  7. 1, 1, 209, 2e5, 0.56, 1, 1, 0.0001
  8. 0.23, 1, 0, 1e3, 0, 0, 1, 0.0001
- **Lighting.**
  - roughness 0.075, foamRoughnessModifier 0.
  - scatter (0.016, 0.0736, 0.16), bubble (0, 0.02, 0.016), bubbleDensity 1.
  - heightModifier 1, wavePeakScatterStrength 1, scatterStrength 1, scatterShadowStrength 0.5.
  - environmentLightStrength 0.5.
  - sunIrradiance (1, 0.694, 0.32). The environment is a cubemap texture.
- **Foam.**
  - colour (0.6, 0.5568, 0.492).
  - bias 0.85, threshold 0.
  - add 0.1 and decayRate 0.0175, both per frame.
- **Fades.** displacement, normal and foam depth attenuation are all 1. normalStrength is 1.
- **Camera.** The far plane is 2000 m, with an `Atmosphere` image effect on the camera.

## 3. Departures, and what fidelity needs

Each line gives what we do, what the reference does, and the proposal.

### 3.1 The simulation (`Pasture3DWaterFFT`, `water_fft.glsl`)

| # | Ours | Reference | Proposal |
|---|---|---|---|
| S1 | One wind + swell pair shared by all cascades | A pair per cascade, 8 spectra | **Port it.** 8 spectra, with spectra 2i and 2i+1 on cascade i. This replaces the `wind/*` and `swell/*` properties with `spectrum_1/*` … `spectrum_8/*`, the reference's names (index 0..7 in `set_spectrum_knob`). The presets are rebuilt from scratch (§5). |
| S2 | Band-limited cascades (default on) | Every cascade spans its full band | **Default off.** Keep the knob for authors who want one physical sea. |
| S3 | h0 normalised so scale 1 is the described sea | `sqrt(2·Ψ·Δk²)`, which is 8× the variance | **Port the reference's normalisation**, so its scales mean what they say. The CPU σ estimate (`get_height_sigma`), gate [P]'s closed form, `fit_sea` and the fBm fit all rescale. |
| S4 | Phase from finite-depth ω, quantised to the loop | Spectrum built with `√(gk·tanh kd)`, phase advanced with deep-water `√(gk)`, also quantised by repeatTime | **OPEN, see D1.** At depth 20 the 94 m waves move about 7% faster in the reference. |
| S5 | Foam decay and add per second | Per frame | **Keep per second.** It is identical at 60 fps, and per frame changes foam life with the frame rate. The defaults are already 0.1 and 0.0175 per frame at 60 fps. |
| S6 | The Nyquist row and column are empty | Filled | **Keep.** The reference leaks between its packed channels there. The difference is a sliver of the shortest cascade's energy. |
| S7 | N ≤ 512 | N = 1024 | **OPEN, see D2.** 1024 needs 32 KB of shared memory, which Vulkan does not guarantee; most desktop GPUs have it. |
| S8 | Phase reduced to one cycle before cos/sin | Raw ω·t | **Keep.** It is a precision fix, invisible at the reference's speeds. |
| S9 | The cos² half of the directional spread is rotated by the wind angle | `lerp(2/π·cos²θ, Cosine2s(θ − angle, s), spreadBlend)`: the cos² half uses the **unrotated** θ | **Reproduce it** (found in R1). The scene's spectrum 2 has spreadBlend 0 at 59°, so all of its energy runs along ±X, and that is part of the look. |
| S10 | Hash constants 789221 and 1376312589 (decimal) | `0x789221U` and `0x1376312589U`; HLSL truncates the second to `0x76312589` | **Reproduce it** (found in R1): `0x789221u` and `0x76312589u`. With the decimals the same seed gives a different sea. |

### 3.2 The surface (`water_waves`, `water_surface`, `water_shading`)

| # | Ours | Reference | Proposal |
|---|---|---|---|
| G1 | A cascade repeats every `cascade_length` m | `worldPos.xz * tile_i`, independent of lengthScale | **Port it.** A `cascade_tiles` Vector4 in metres of repeat, where 0 means the cascade length. The Garrett preset sets 100, 0.33, 0.33, 7.7. |
| G2 | All cascades are drawn | `visualizeLayer` per cascade | **Port it** as `cascade_drawn` (4 bools). A cascade that is not drawn is also skipped by the compute. |
| G3 | All cascades displace | `contributeDisplacement` per cascade | **Port it** as `cascade_displaces` (4 bools). The CPU height query (Phase 5 readback) sums the same set. |
| G4 | No foam offset | `foamSubtract` per cascade, added to each cascade's foam before the sum | **Port it** as `cascade_foam_offset` (Vector4). |
| G5 | Displacement, normal and foam fade by view distance in metres (`fft_fade_*`) | `pow(1 − Linear01Depth, attenuation_x)`, linear in distance to the far plane | **Port it.** The fade is `pow(saturate(1 − d/far), a)` with `a` per channel. The far plane comes from `PROJECTION_MATRIX`. This makes the look depend on the camera's far plane, as it does in the reference. |
| G6 | A mip per clipmap ring, against aliasing | Always mip 0, with tessellation adding vertices | **Keep.** Our geometry differs (a clipmap, not a tessellated plane), and mip 0 on coarse rings aliases. Mips only remove waves the ring cannot carry. |
| G7 | Domain origin subtracted | World xz | **Keep.** It is a precision fix and invisible. |

### 3.3 Lighting and colour

| # | Ours | Reference | Proposal |
|---|---|---|---|
| L1 | Foam is lit (Lambert × `foam_color`) | `lerp(output, _FoamColor, foam)`, an unlit constant | **Port it**, unlit. Foam in shadow will glow, as it does in the reference. |
| L2 | Crest foam is multiplied by `foam_tex` | No texture | **Port it**: the crest is untextured. `foam_tex` stays for shore foam only. |
| L3 | Foam mixes roughness toward `foam_roughness` | `a = roughness + foam · foamRoughnessModifier` | **Port the reference's form.** `foam_roughness` becomes `foam_roughness_modifier` (default 0). |
| L4 | Environment reflection is Godot's sky, through `SPECULAR` = `specular_amount` | `F · texCUBE(env, reflect) · environmentLightStrength`, with its own F | **OPEN, see D3.** |
| L5 | `ALBEDO` = `deep_color` through an absorption solve, which plays the role of `_ScatterColor` | A `_ScatterColor` constant | **Port it** as `scatter_color`. The absorption solve stays only for the shore fade (§3.4). |
| L6 | Every light term takes `ATTENUATION` (shadows) | No shadows | **Keep.** The reference cannot say; this is Godot's lighting. |
| L7 | The sun comes from the scene's DirectionalLight3D | `_SunIrradiance` | **Keep.** Document it: a light coloured (1, 0.694, 0.32) at energy 1 *is* the reference's irradiance (FFT spec §3.1). |
| L8 | `normal_strength` and the normal fade were not ported | `_NormalStrength`, normal depth attenuation | **Port both** (G5 covers the fade). |
| L9 | Alpha from `water_fresnel` | Opaque, ZWrite on | **Keep** for the shore fade (§3.4). In open water our alpha is 1, which matches. |

### 3.4 Ours, with no reference counterpart

The reference has no terrain, so it has no shoreline. These are our additions:

- shore foam
- the depth fade and absorption near land
- the shore mask and terrain check
- underwater

**OPEN, see D4**: whether they stay on in the Garrett instance. They change nothing in open water.

### 3.5 Not water

- **The `Atmosphere` image effect** on the reference camera colours the horizon. It is a post effect, not
  part of the water shader, and is out of scope. A Godot `Environment` with fog stands in for it. The
  look will differ at the horizon until it is ported, and the A/B in §6 notes it.
- **The fBm** (the reference's `Water.shader`) has its own older Blinn-Phong lighting. **OPEN, see D5.**

## 4. Decisions (taken 2026-10-11: every recommendation)

- **D1. The phase dispersion bug (S4).**
  - Option (a), reproduce it: deep-water phase speed over a finite-depth spectrum.
  - Option (b), keep ours: physically consistent speed.
  - *Recommend (b).* At depth 20 the difference is about 7% on the longest waves and nothing on short
    ones. A bug copied on purpose then needs a guard forever.
- **D2. N = 1024 (S7).**
  - Offer 1024 on devices whose shared memory allows it, with fallback to 512 and a warning.
  - *Recommend offering it.* The reference's 94 m cascade at 1024 has 9 cm texels; at 256 it has 37 cm,
    which shows in the near-camera normals. It costs about 4× the compute of 512.
- **D3. The environment reflection (L4).**
  - Option (a), Godot's sky through `SPECULAR`: keeps reflection probes and SSR, but cannot apply the
    reference's F or its 0.5 strength.
  - Option (b), an optional `environment_map` cubemap uniform, reflected the reference's way into
    `EMISSION`, with `SPECULAR` 0: exact, but it loses probes and SSR.
  - *Recommend (b) for the Garrett instance, using Godot's sky when no map is set.*
- **D4. Shore features (§3.4).**
  - *Recommend keeping them on.* They only act where the reference has nothing to say.
- **D5. The fBm's lighting.**
  - Option (a), the PBR model: fBm and FFT swap with no change in shading.
  - Option (b), the reference's Blinn-Phong `Water.shader`.
  - *Recommend (a).* The fBm is the compatibility model, and the switch should change waves, not
    materials.

## 5. Presets

- **ocean_garrett:** §2 copied exactly.
- **lake / pond:** the reference has none. Use the same 8-spectrum structure with lower wind, a shorter
  fetch and smaller cascades. The values are to be proposed in the presets phase and judged by eye.
- **`ocean_default`:** this becomes ocean_garrett. `Pasture3DOcean.wave_profile` and its default material
  point at the Garrett instance (`M_water_ocean.tres` is rewritten to it, not duplicated).
- **The migration from Gerstner-era scenes** (`fit_sea`) is rewritten against the 8-spectrum,
  reference-normalised model.

## 6. Proving it: an A/B against the reference

Fidelity is a claim about pixels, so it is gated on pixels.

- **The pixel A/B.** Port the reference's `NEW_LIGHTING` fragment to a GDScript or compute oracle,
  driven by the same displacement and slope maps. It must match ours per pixel at fixed views, with:
  - Every L-row break as a control that must miss.
  - The foam unlit vs lit as a control.
- **The simulation.**
  - `WaterFFTGate` [P] is re-derived for the reference normalisation.
  - A spectrum gate compares h0 for the reference preset against the reference's formula evaluated
    independently.
- **Not provable here.** We cannot run Unity. A side-by-side with the reference's own frames needs a
  capture from the user's Unity install, or the published screenshots by eye.

## 7. Phases (proposed)

| Phase | Content |
|---|---|
| R1 | Simulation: 8 spectra (S1), the reference normalisation (S3), band_limited off (S2); WaterFFTGate re-derived |
| R2 | Per-cascade tile, drawn, displaces, foam offset (G1–G4); the CPU readback follows G3 |
| R3 | Far-plane fades and normal strength (G5, L8) |
| R4 | Lighting: unlit untextured crest foam, the roughness modifier, scatter_color, the environment map (L1–L5, by D3) |
| R5 | Presets: ocean_garrett as default, lake and pond, `fit_sea` migration, `Pasture3DOcean` default material |
| R6 | The pixel A/B gate; then the WaterFFT, Wiring, PBR, FBM, Buoy and body gates re-run and re-baselined |
| (R7) | N = 1024, if D2 |

### 7.1 R1, as built (2026-10-11)

- **Ported:**
  - Eight spectra as `spectrum_1/*` … `spectrum_8/*`, with cascade i on spectra 2i and 2i+1. The second of a pair is skipped at scale 0, as in the reference.
  - The reference's h0 normalisation.
  - The cos² spread at the unrotated angle (S9).
  - The hash constants as HLSL truncates them (S10).
  - `band_limited` now defaults to off.
  - The defaults are the scene's: depth 20, lengths (94, 128, 64, 32) and the eight spectra.
- **Cascade lengths are no longer sorted.** The scene's lengths are not descending, and sorting them would move a cascade off its spectrum pair. The band split, when on, now walks the cascades by length.
- **`get_height_sigma()` is now exact.**
  - The reference's spectra peak far below its tiles, so a cascade's variance sits in its first ring of about eight modes. There, a continuum integral is off by up to 2×.
  - It now sums the modes within 16 fundamentals one by one, then integrates the rest.
  - WaterFFTGate [P]: its square equals the gate's own per-mode expectation to 1.0000.
- **WaterFFTGate re-derived:**
  - **[H] (new):** the GPU's h0 matches the reference's CS_InitializeSpectrum on every texel, re-evaluated in GDScript including its hash. The decimal-hash, rotated-cos² and variance/8 controls match at most 10% of texels.
  - **[B]:** now runs on a one-sea fixture, since the scene's cascades are four different seas. A scrambled cascade order gives the same banded variance.
  - **[P]:** checks the realised variance against the per-mode expectation, using 48 seeds spaced 100003 apart.
- **Seeds overlap; the reference shares this.** The kernel adds the seed to `x + N·y + N`, so seed s+1 reuses its neighbour texel's draws. The +k and −k modes repeat each other two seeds apart. Consecutive seeds therefore under-sample the dominant ring. With 48 consecutive seeds, [P] read 0.81; with the spacing, 0.995. This is not a fault in a single sea, but a statistics gate must space its seeds.
- **Interim until R5:**
  - `fit_sea` scales the scene's sea, its eight fetches and its lengths, by `length_max / 137`, and the scales by the height target. `get_length_max()` reads the longest cascade × 137/128.
  - Scenes saved with `wind/*` and `swell/*` lose those keys on load and fall back to the scene sea. Nothing has shipped, so there is no migration.
- **Until R2 the sea is too tall.** The sigma and displacement bound count every cascade. The reference displaces with cascade 1 only and draws cascade 2 at a 0.33 m repeat, so the default sea's Hs of about 10.6 m (N = 128) overstates what the reference draws. R2's `cascade_displaces` is what brings the bound down.

### 7.2 R2, as built (2026-10-12)

- **Ported, on `Pasture3DWaterFFT`, with the scene's values as defaults:**
  - `cascade_tiles` (G1), a Vector4 of metres of repeat: 1/_Tile, so (100, 1/3, 1/3, 1/0.13). A tile of 0 means the cascade's length. `get_cascade_repeats()` resolves it.
  - `cascade_drawn` (G2) and `cascade_displaces` (G3), 4-bit flag masks: 0b1001 and 0b0001. `get_displacing_mask()` is drawn AND displaces, as the reference multiplies `_DebugLayer` into `_ContributeDisplacement`.
  - `cascade_foam_offset` (G4): (0.04, −0.04, −0.46, −0.38). The reference adds every cascade's offset, hidden ones included, so the shader takes the sum (`get_foam_offset_sum()`, −0.84) as one uniform.
- **Uniforms.** `_fft_lengths` is gone. The material gets `_fft_repeat`, `_fft_drawn` and `_fft_displaces` (0/1 per cascade), and `_fft_foam_offset`.
  - The vertex stage multiplies each drawn cascade's displacement by its `_fft_displaces`, but takes its slope and foam either way.
  - The fragment stage skips undrawn cascades and adds the offset after the sum; the existing 0–1 clamp is the reference's saturate.
  - A coverage readout that copies wave uniforms by name must carry the two masks too (WaterTwoLakesGate, WaterShorePoolProbe), or it draws the shader's defaults.
- **A hidden cascade is not simulated.** UPDATE, the FFT passes, ASSEMBLE and DOWNSAMPLE take the drawn mask in their push constant and skip it; its layers keep their last frame. INIT and PACK still run every cascade, so showing one again needs no re-init. The FFT skip is uniform per workgroup, so its barriers are still safe.
- **The CPU follows G3.** The readback copies only the displacing layers, `sample()` sums only them at their repeats, and `get_height_sigma()` counts only them.
- **The reference's geometry is gentle.** The scene's displacing sea is cascade 1 alone: sigma 0.10 m, Hs about 0.4 m at N = 128, against 2.66 m sigma with every cascade displacing. Its texture comes from cascade 4's normals at a 7.7 m repeat.
- **Interim until R5: the fit over-drives the hidden cascades.** `fit_sea` scales all eight spectra by one gain to put the DISPLACING sigma on the height target. A default profile's target of 0.86 m therefore multiplies the energy about 70×, and cascade 4's slopes come with it, about 8× steeper than the reference's. `fit_sea` now also scales `cascade_tiles` by r, so a pond's repeats shrink with its lengths. The R5 fit rewrite has to decide whether the height target applies to the displacing cascades only.
- **Gates:**
  - **WaterFFTGate [G] (new):**
    - The defaults, and the tile-0 fallback.
    - Hidden layers stay bit-identical across an update while the shown ones move. Control: drawn 15 moves them.
    - Sigma counts the displacing set: the default sits below the all-displacing estimate, and drawn 0b1001 under displaces 15 equals the reverse (the AND).
    - The other criteria run with all four cascades drawn and displacing.
  - **WaterFFTWiringGate:**
    - [W] checks all four new uniforms.
    - [R] now predicts what the shader draws: the displacing cascades only, trilinear at the vertex stage's mip, at the rest point the horizontal displacement carries onto the pixel. Mip 0 at the rest point read 0.89, because the one displacing cascade is short against its 100 m tile; the model reads 0.997.
  - **WaterBuoyGate:**
    - Its sync sampler follows the mask and the repeats.
    - [A] passes again (rel RMS 0.017), now that the sea is not 10 m tall.

### 7.3 R3, as built (2026-10-12)

- **Ported, as material uniforms in the `waves` group, FFT only, with the scene's values as defaults:**
  - `fft_normal_strength` (L8), default 1. It scales the drawn cascades' summed slope before the normal is built; geometry and foam are untouched.
  - `fft_displacement_falloff`, `fft_normal_falloff` and `fft_foam_falloff` (G5), each default 1. 0 turns that fade off.
- **The fade is the reference's.**
  - The weight is `pow(1 − depth / far, falloff)`, where depth is the REST vertex's linear view depth, computed per vertex and interpolated as the reference does.
  - far is read from `INV_PROJECTION_MATRIX` at reversed-Z depth 0, for perspective and orthographic cameras alike.
  - The displacement scales toward the rest sheet. The normal is lerped toward up, not its slope toward zero, and strength is applied first. The crest foam scales after its clamp.
  - The fBm keeps its own octave fade (D5).
- **The look depends on the camera's far plane, as the reference's does.** The scene is tuned at far 2000 m; Godot's default far is 4000 m, which halves every fade at a given distance.
- **Buoys do not fade.** The CPU answers for no camera, so a buoy at depth d sits `(1 − d / far)^falloff` short of the drawn displacement. At 100 m under a 4000 m far plane that is 2.5% of the wave height. WaterBuoyGate [A] draws with the displacement fade off for that reason; with it on, under its 200 m far plane, it read 0.34 relative RMS.
- **Shadow passes fade by the light's view.** The vertex stage evaluates the fade in whatever view it is drawn for. Water casts no shadows by default (`cast_shadows` off on the ocean and the clipmap), so this is only a caveat.
- **Readouts.**
  - `bench/water_fft_shading_debug.gdshader` (new, `WATER_DEBUG_FFT_SHADING`) writes the fragment's final slope and crest foam, unlit. `WATER_DEBUG_SURFACE` encodes only the vertex normal, which neither normal term touches.
  - The coverage readouts in WaterTwoLakesGate and WaterShorePoolProbe now copy `fft_displacement_falloff` with the other geometry uniforms.
- **Gates:**
  - **WaterFFTWiringGate [F] (new):** an orthographic camera puts every rest vertex at one depth, so the fade is one number. The rendered height reads it within 0.008 at falloff 1, falloff 2, and with the far plane halved. Control: falloff 0 reads 1.000.
  - **WaterFFTWiringGate [N] (new):** strength 2 doubles every slope. Strength 3 under the normal fade matches the normal-lerp form to 0.0035 RMS, where the naive slope × f misses by 0.11. The foam fade scales the crest by f² and moves no slope.
  - **[B] and [R]** now predict the faded field.
  - A windowed compile check drew all ten water shaders and the two readouts without error. Its control, a variant that trips the new `#error`, fails.
- **Found while re-running the gates, from R2 and not R3: WaterBodiesPhase3Gate [B] fails.**
  - Its CPU field is now cascade 1 alone, whose spectra are the reference's short chop, scaled to the lake's height target by the interim fit.
  - That field is rough below the automatic 1.27 m spacing, so coarsening 4× only doubles the sag (0.18 → 0.36 m), where the gate requires more than double.
  - This belongs to the R5 fit and preset rewrite, with `min_wavelength`, which still reads the pre-R2 sea.

### 7.4 R4, as built (2026-10-12)

- **The output is the reference's**, on every lit variant (ocean, lake, pond; not rivers):
  `lerp((1 − F) · scatter + specular, foam_color, foam)`, plus the environment term below.
  - `ALBEDO` is 0. light() writes every sun term to `SPECULAR_LIGHT`, which Godot does not multiply by `ALBEDO`, so the old divide-back-out by `ALBEDO` is gone, and so is Godot's ambient light, which the reference does not have.
  - Water in a shadow is now lit only by its reflection, and is darker than before R4.
- **L1, unlit foam.** The fragment stage emits `foam · foam_color`, and every lit term carries `(1 − foam)`. Foam glows in shadow and at night, as the reference's does.
- **L2, untextured crest.** Under FFT the crest foam is added after the `foam_tex` multiply, so `foam_tex` breaks up only the shore foam. The fBm has no crest; rivers keep the textured slope foam.
- **L3, `foam_roughness_modifier`** (sun group, default 0, the scene's value). It adds `foam · modifier` to the sun lobe's alpha and to the environment Fresnel's. `foam_roughness` remains on rivers only, and is deleted from the four lit presets.
- **L4, `environment_map`** (new `environment` group): `use_environment_map`, a `samplerCube`, and `environment_light_strength` (default 0.5).
  - On: `EMISSION += (1 − foam) · F · env(reflect) · strength`, with the reference's rough Fresnel shared with light() (`water_ref_fresnel`), and `SPECULAR` 0. The reflection is exact, but reflection probes and SSR no longer reach the water (D3).
  - Off (the default until R5 ships a map): Godot's sky through `SPECULAR = specular_amount · (1 − foam)`. Godot's environment BRDF is not linear in `SPECULAR`, so the foam factor is an approximation there.
- **L5, `scatter_color`** (sun group, default the reference's (0.016, 0.0736, 0.16)). It replaces `deep_color` as the body colour on lit variants and is still tinted by the absorption solve, so the shore fade (§3.4) works as before. It reaches light() through a new varying, `v_body_color`.
  - `deep_color` remains for rivers and for the underwater fog.
  - The lake and pond presets carry `scatter_color` = their old `deep_color`. The ocean presets take the reference's default; R5 rewrites them.
- **Gates:**
  - **WaterPBRGate** (7/7). [E] [K] [A] are re-predicted in the new form. New criteria:
    - [S]: `deep_color` set to a decoy is invisible. The decoy control misses by 20×.
    - [F]: foam over a black floor at a known depth. The pixel is `foam · foam_color + (1 − foam) · water`; with the sun hidden, it is `foam · foam_color` (err 0.0008). The lambert-lit control misses by 3.9×.
    - [R]: the modifier's alpha matches to 0.0003. The unmodified-alpha control misses by 0.12.
    - [M]: a cubemap with one distinct face matches `F · +Y · strength` to 0.0024. The other-face control misses by 76×, and the map off draws black.
  - **WaterFFTWiringGate [L] (new, 7/7):** `bench/water_crest_lit.gdshader`, the lit crest path without the clipmap, in a world with no light. Every pixel is `crest · foam_color` to 0.0002, and a black or a white `foam_tex` draws identically. The textured-crest control would read 0.
  - **WaterMaterialPropagationCheck** now writes `foam_roughness_modifier` as its second write path (`foam_roughness` is no longer declared on the lake).
  - **Re-run and passing:** FBM, Buoy, FFT, Phase1, Bodies Phase 1, 4 and 5 (correctness only), PresetCheck, RetireGerstner, VariantWarning, BodySplit. No timing gate was run.
