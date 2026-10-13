# Pasture3D Water: Reference Fidelity

Status: **audit written 2026-10-11. Decisions D1–D5 taken 2026-10-11 (the recommendations, §4). R1 built 2026-10-11 (§7.1), R2 built 2026-10-12 (§7.2), R3 built 2026-10-12 (§7.3), R4 built 2026-10-12 (§7.4), R5 built 2026-10-12 (§7.5), R6 built 2026-10-12 (§7.6), R7 built 2026-10-12 (§7.7).**

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

**Colour space.** The reference renders in a linear colour space (`m_ActiveColorSpace: 1`). But
`FFTWater.cs` passes `_SunIrradiance`, `_ScatterColor`, `_BubbleColor` and `_FoamColor` with `SetVector`,
which does not convert: the shader sees the typed numbers as linear. Godot's `source_color` uniforms and a
light's colour are decoded from sRGB, so the port types the reference's numbers **sRGB-encoded**. (This
paragraph said the opposite until R6, whose A/B found it; see §7.6.)

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
| S7 | N ≤ 512 | N = 1024 | **Offered (D2, built in R7).** 1024 needs 32 KB of shared memory and 1024-thread workgroups, which Vulkan does not guarantee; most desktop GPUs have them. |
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
| L7 | The sun comes from the scene's DirectionalLight3D | `_SunIrradiance` | **Keep.** Document it: Godot decodes a light's colour from sRGB, so a light coloured (1, 0.851, 0.601), the encoding of (1, 0.694, 0.32), at energy 1 *is* the reference's irradiance (corrected in R6, §7.6). |
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

### 7.5 R5, as built (2026-10-12)

- **`ocean_default` is ocean_garrett.** The name is kept, since renaming it would orphan every saved
  scene's `wave_profile`.
  - A fresh `Pasture3DWaveProfile` is the reference. Its constructor fits at `REF_LENGTH` (137 m), along
    spectrum 0's heading, with no height gain. It no longer starts from the legacy table.
  - The shipped `ocean_default` is a fresh profile.
- **`M_water_ocean.tres` is the Garrett instance.** The shader's defaults are already the reference's.
  - The file now says so, sets `foam_color` (0.6, 0.5568, 0.492) and `foam_crest_amount` 1, and keeps
    our absorption, `deep_color` and shore (D4).
  - There is no cubemap, so it reflects Godot's sky (D3).
  - `M_water_ocean_low.tres` takes the same `foam_color`.
- **Lake and pond, by Froude similarity.** The new call is `fit_reference_sea(direction, length)`.
  - At r = length / 137, it scales every length, tile, depth, fetch and `short_waves_fade` by r, and the
    wind by √r. The JONSWAP alpha (gF/U²), the spread and the TMA term are then invariant, and the peak
    wavelength scales by r.
  - Heights scale by r, and slopes are unchanged.
  - Every spectrum's heading turns by the same angle, so that spectrum 0 runs along `direction`.
  - `lake_calm` = (35°, 25 m): σ 0.019 m. `pond_still` = (55°, 12 m): σ 0.009 m. Both are to be judged
    by eye.
- **`fit_sea` is the migration.** It does the same, then applies a height gain to every spectrum's
  `scale`. `river_flow` is `fit_sea(0, 10, 0.0236074)` with `min_wavelength` 5.0084, as before.
- **The fBm targets the FFT's actual σ**, not r × the reference's. The discrete low ring puts the FFT
  1.6–2.5% off r.
- **`min_wavelength` comes from a height tolerance**, `HEIGHT_TOLERANCE` = 5 cm.
  - The fit meshes the longest wavelength above which all but a (tol/σ)² fraction of the displacing
    variance lies. That leaves the normals waves whose σ totals under 5 cm.
  - The wavelength comes from the new `Pasture3DWaterFFT.get_variance_wavelength(fraction)`, a
    continuum integral over the displacing bands.
  - Results: ocean 9.1 m. The lake and pond get 17.2 m and 8.2 m, their longest waves, because σ < tol.
  - The first attempt used the 95% variance wavelength. It gave the lake 0.73 m, which pinned the pool
    spacing at its 0.25 m floor and broke WaterBodiesPhase3Gate [B] and [F] and WaterTwoLakesGate.
- **A pool fix that the presets exposed.** A masked pool's clipmap ring count covered half the body's
  diagonal. Its own comment, and a camera at one corner, need all of it.
  - Ring doubling's overshoot had hidden this until the Garrett lake's 2.14 m spacing left lake A in
    WaterTwoLakesGate one ring short: 0.878 coverage, seen from a camera 30 m off its edge.
  - The count now covers the full diagonal plus `mask_range`. That costs at most one more ring (lake A
    2 → 3, lake B 5 → 6).
- **Gates:**
  - **WaterRetireGerstnerGate [P]** is rewritten as "presets are the reference".
    - Each shipped profile equals its construction call. `_knobs` now also covers tiles, depth, wind,
      heading and `short_waves_fade`. Control: the next preset's call misses by more than 0.05.
    - From outside the fit: `ocean_default`'s FFT equals a default `Pasture3DWaterFFT` exactly.
    - σ / (r σ_ref) is 1.0175 for the lake and 1.0250 for the pond, both within 0.03. Control: with the
      wind left unscaled, they read 2.13 and 2.92.
  - **WaterFFTWiringGate [N]** now runs at base strength 4 (`N_BASE`).
    - Why: the reference's sea has a slope rms of 0.05. That is under the criterion's own liveness
      floor, and too gentle for the fade's curvature to show.
    - Now: rms 0.194, and an error of 0.0037 against a tolerance of 0.0119. The control misses by 0.037.
  - **Re-run and passing:** RetireGerstner, Wiring (7/7), FFT, Buoy, FBM, PBR, Phase1, Bodies Phase 1,
    3, 4 and 5 (correctness only), TwoLakes (8/8), SplitScreen, PresetCheck, VariantWarning, BodySplit,
    LateManager, MaterialPropagation. No timing gate was run.

### 7.6 R6, as built (2026-10-12)

- **The A/B found the colours wrong.** `FFTWater.cs` sets the four lighting colours with `SetVector`, which
  passes the numbers through. Our `source_color` uniforms decoded them as sRGB, so the shipped water was:
  - a body 7–13× too dark per channel (scatter and bubble);
  - foam about half as bright.

  The fix is in the values, not the shader: the `water_common` defaults for `scatter_color` and
  `bubble_color`, and `foam_color` in both ocean materials, are now the reference's numbers sRGB-encoded.
  Godot decodes a `DirectionalLight3D`'s colour as well (measured: a (1, 0.694, 0.32) sun lit at
  1 : 0.449 : 0.107), so the reference's sun is a light coloured (1, 0.851, 0.601). §1 and L7 are corrected.
- **The gate, `bench/WaterReferenceABGate`.** It renders the shipped Garrett instance over live FFT
  waves, with no sky, ambient or reflections, a linear tonemap and a float readback. It then reads back
  the same frame once per input, through a debug readout in `water_shading.gdshaderinc`
  (`WATER_DEBUG_REF_INPUTS`, bench shader `water_ref_inputs.gdshader`). Each input is packed into three
  8-bit channels, for 24 bits per pass:
  - the summed slope, the foam and the height, raw;
  - the view direction, the fade depth and the rest position.

  `ref_fp()` is the reference's `NEW_LIGHTING` fragment, transcribed from FFTWater.shader. It is fed
  those inputs and the reference scene's own lighting values, spelled only in the gate.
  - **[D] depth.** Our fade depth is the reference's `1 − Linear01Depth`. The far plane is fitted, not
    assumed: Godot builds its reversed-Z projection in float32, and the depth term cancels, so the depth
    buffer, and our fade, which reads the same matrix, ends at 1997.34 m of a nominal 2000 at near 0.05,
    and at 149.98 m of 150. The fade reaching 0 where Godot clips is the reference's meaning.
    - Result: F within 0.2% of far, residual ~7e-7 against 1e-5.
    - Control: the fit made from the distance instead of z_eye must leave a residual over 1e-4.
  - **[A] the A/B.** Three views:
    - into a low sun (the glitter path and the backlit crest scatter);
    - the sun behind the camera;
    - an exercised view, with normal strength 2, foam roughness modifier 0.5, a 150 m far plane, and the
      foam offset lifted by 0.75. The scene's offset makes no foam on this sea, since raw foam peaks
      near −0.14.

    Error per pixel is max over rgb of |got − want| / (|want| + 0.002).
    - Result: p99 0.0009 against 0.003, and the worst pixel 0.0010 against 0.03, in all three views.
    - Controls: each break must fail the view as a render would, with p99 over 3 × tol or worst over
      3 × max tol. The breaks are colours linearised, sun not linearised, L1, L2, L3, L4, L5, L8 and G5.
      All are caught. The smallest are L3 (0.28 / 0.87) and L2 (0.68 / 0.85).
    - Anti-null: 1451 foamy pixels and about 1200 glint pixels.
- **Two traps, found on the way:**
  - **The texture placeholder.** A material drawn before the FFT textures exist keeps the black
    `Texture2DArrayRD` placeholder: a flat sea, which the A/B saw as Fresnel at n·v = V.y. The gate
    re-uploads the profile into its materials after warm-up.
  - **A mid-grey environment cubemap** carries the GPU's sRGB decode, a 0.3% channel bias. A white map
    decodes to exactly 1.
- **Re-baselined:**
  - WaterPBRGate's bubble constant now follows the new default.
  - **WaterFBMGate [N]** is measured on the per-pixel difference, fBm minus flat, against 0.05 × the
    flat frame's mean. Its flat frame is not uniform: the body falls off with n·v toward the camera, which
    Godot's `VIEW` carries even under the gate's orthographic camera. At the old, too-dark colours that
    falloff was under the frame-spread ratio's noise; at the reference's it is half the fBm frame's
    spread, and the ratio read 2.2 against 10. The difference cancels it: 0.16 × mean. Control: a second
    flat render, differenced the same way, reads 0.
- **Re-run and passing:** ReferenceAB, PBR, Wiring, FFT, FBM, Buoy, PresetCheck, VariantWarning, Phase1,
  Bodies Phase 1, 3, 4 and 5 (correctness only), TwoLakes, SplitScreen, RetireGerstner, BodySplit,
  LateManager, MaterialPropagation. No timing gate was run.

### 7.7 R7, as built (2026-10-12)

- **N = 1024 is offered**, as D2 recommended: on `Pasture3DPoolManager.fft_resolution`, the
  `pasture_3d/water/fft_resolution` project setting and `Pasture3DWaterFFT.resolution`. The default is
  still 256. 1024 is the reference's, and about 16× the simulation work and memory of 256.
- **The fallback is the device's limits, not shared memory alone.** The kernel's FFT pass runs one
  workgroup of N threads per row, so N needs 32 N bytes of shared memory, N invocations and an N-wide
  workgroup. Vulkan guarantees 16 KB and 128 of each, so 512 was already a device question.
  - `Pasture3DWaterFFT.resolution_for_limits(requested, shared, invocations, size_x)` halves the
    request until all three fit, and never goes below 128. `get_max_resolution()` applies it to this
    device's `RenderingDevice` limits, or returns 1024 when there is no device.
  - `set_resolution` clamps to it and logs a warning. The manager's effective resolution takes the same
    minimum. `fft_resolution` keeps what was asked, so a scene keeps its 1024 for a machine that can run
    it, and the manager shows a configuration warning while it falls back.
- **WaterFFTGate [X].**
  - The fallback rule, on eight hand-worked rows of limits, including Vulkan's guaranteed minimums.
  - On this device: a simulation asked for 1024, and a manager's effective resolution, both run at the
    rule applied to the device's limits, and the readback has that many texels.
  - Where that is 1024, the transform at 1024 matches [A]'s direct DFT at two texels in every cascade,
    with [A]'s tolerance and its half-second control.
- **No timing was measured.** The guide's cost table has 1024 as "not measured".
- **Re-run and passing:** FFT (9/9), Wiring, Buoy, PBR, FBM, PresetCheck, VariantWarning, Bodies Phase 1 and 3
  (correctness only), TwoLakes, RetireGerstner, SplitScreen, LateManager, MaterialPropagation.
- **End to end:** WaterReferenceABGate, run once with its manager at 1024, passes as at 256: p99 0.0009,
  every control caught.
- **The reference's foam is tuned for 1024.** At the scene's foam offset, the 256 sea makes no foam (its
  raw foam peaks near −0.14, which is why R6's exercised view lifts the offset). At 1024 the same views
  show foam: 22 foamy pixels at the scene's offset, and 12502 against 1451 in the exercised view. The
  Jacobian sees the short waves that only 1024 resolves. So **at 256 the Garrett instance shows no
  crest foam** in the A/B's views. Whether the default should be 1024, or the foam offset should be retuned per
  resolution, is open for the user.
