# Pasture3D Water: Production Readiness

Status: **plan written 2026-10-16, from the user's review of `sculpting_2.tscn` after the reference port
(PASTURE3D_WATER_REFERENCE_SPEC.md, R1–R7). Decisions taken 2026-10-16: every recommendation in §3, with
P-D5 deferred as recommended. W1 built (§2.1); W2 built (§2.4); W3 built (§2.2); W4–W6 not started.**

The reference port proved that our shading equals GarrettGunnell/Water's, per pixel. It did not prove the
water looks finished in a real scene. The user's review found five problems. Two had causes that could be
traced in a few minutes; the other three need a measurement before a fix.

## 1. What was measured

**Cost of N = 1024** (`WaterModelCostTiming`, RTX 3070, 1280×800, 2026-10-16). GPU ms, simulation plus draw,
for one body:

| N | Ocean | Lake | Simulation alone |
|---|---|---|---|
| 128 | 0.25 | 0.23 | 0.04 |
| 256 (default) | 0.31 | 0.28 | 0.09 |
| 512 | 0.59 | 0.56 | 0.37 |
| 1024 | 2.24 | 2.13 | 2.01 |

- 1024 costs 5.5× what 512 does, more than its 4× the work: 1024-thread workgroups with 32 KB of shared
  memory run at lower occupancy.
- The cost is per profile in use, and is paid even when the water is hidden. An ocean, a lake and a pond
  at 1024 spend 6 ms a frame.
- 1024 also holds about 280 MB of simulation textures per profile, against 17 MB at 256.

**1024 is not a shippable default.** That settles the foam question's first option (§2.2).

## 2. The problems

### 2.1 The lake, pond and river "move far too fast" — the scene holds stale copies of the presets

**Cause, found.** `sculpting_2.tscn` saves its own `Pasture3DPoolManager.profiles`: four embedded
`Pasture3DWaveProfile` sub-resources named `ocean_default`, `lake_calm`, `pond_still` and `river_flow`.
These were written by the interim, Gerstner-era fit. Each stores only `cascade_lengths` (and
`min_wavelength`); every other FFT knob is left at its default.

Since R1 the defaults are the **reference ocean's**: its 8 spectra, its wind and its fetch. So the scene's
lake is the full ocean's spectrum squeezed into cascades of 91, 15.5, 2.9 and 0.73 m, and the pond's into
44, 7.4, 1.4 and 0.35 m. The energy and phase speeds are an ocean's, on lake-sized tiles. R5's Froude-scaled
presets never reach the scene, because the scene's copies shadow them.

Also, `PondWater` selects `ocean_default`, not `pond_still`.

This is a production bug as much as a tuning one. **Any scene saved before a preset changes keeps the old
preset, silently.** The same will happen to every user's scenes after every retune.

**Plan.**
- Stop serialising stock presets into scenes. The manager ships `ocean_default`, `lake_calm`, `pond_still`
  and `river_flow` as built-ins. A scene stores only profiles it adds, or overrides it makes, and an override
  is explicit (a duplicate under a new name, or an "override" flag).
- Migrate on load: a scene profile with a stock name whose stored knobs are a known stale fit (only
  `cascade_lengths` and `min_wavelength` set) is dropped in favour of the built-in, with a log line.
- Point `PondWater` at `pond_still`.
- Then judge the R5 lake and pond by eye (§2.5). Until the stale copies are gone, nobody has seen them.
- **Gate:** a scene saved with the stock presets reloads with the built-ins' knobs, after the built-ins
  change. Control: a profile marked as an override keeps its own.

**Built (W1, 2026-10-16).**
- `Pasture3DPoolManager` holds the four in `_builtin_profiles`, which is never serialised and is shown
  read-only as `builtin_profiles`. `profiles` is empty by default. A profile there named like a built-in
  overrides it. `override_builtin(name)` makes one: a deep copy of the current built-in.
- **The override is the name, not a flag.** Godot cannot tell a stale stock copy from a deliberate one by
  any marker the old scenes carry, so the migration recognises the copies instead. `set_profiles()` drops
  a stock-named profile that is one of three kinds, and prints a line for each:
  - **A Gerstner-era copy:** unauthored, with the retired keys at exactly the retired preset's values
    (`big_regions.tscn` holds all four).
  - **An interim copy:** an FFT storing only `cascade_lengths` (`sculpting_2.tscn` holds all four).
  - **A copy of the current built-in.**

  The interim and Gerstner copies were found by loading the two real scenes. The plan's single
  signature would have kept big_regions' four as overrides.
- **Untouched overrides.** One made by `override_builtin()` and never tuned equals the built-in, so on
  reload it is dropped as a copy. That is the right answer, since it overrode nothing.
- `PondWater` in `sculpting_2.tscn` now selects `pond_still`.
- **Gate `WaterBuiltinPresetsGate`:** PASS, 5/5 criteria.
  - [S] A fresh manager saves no profiles. Control: a tuned override is saved and reloads tuned.
  - [M] The fixture `bench/fixtures/stale_water_presets.tscn` holds sculpting_2's stale copies, and they
    load as the built-ins. Witness: the stale lake's cascades differ from the built-in's. Controls: a
    tuned pond_still and the scene's own profile survive.
  - [C] A copy of the current built-in is dropped. Controls: a moved choppiness or min_wavelength is kept.
  - [O] `override_builtin()` copies deeply.
  - [L] Gerstner-era copies are dropped. Controls: a moved amplitude, and the retired keys under another
    name, are kept.
- InspectorStabilityGate [CV] named its bare test profile `lake_calm`, which is now a stale copy. It was
  renamed `calm_test`, and the dropdown is compared against `get_profile_names()`, which now lists the
  built-ins as well.
- The terrain brush's profile fallback is deleted. `_closest_profile_for` picked the longest profile that
  fit when a manager lacked `lake_calm`, `pond_still` or `river_flow`, and that can no longer happen.
  `_seed_profile_for(spline)` now returns a name from the loop's size, and rivers seed `river_flow`.
  WaterBodiesPhase4Gate's fallback criterion became: a manager holding only custom profiles still answers
  both seeded names with the built-ins. Control: an override answers instead, and an unknown name
  answers nothing. Phase 4 passes. Phase 2 (12 failures) and Phase 3 (1) fail identically with and
  without W1.

### 2.2 No crest foam — the reference's foam is tuned for N = 1024

**Cause, known since R7.** At the reference's foam settings, the Jacobian only goes foamy where the short
waves are resolved. At 256 the raw foam peaks near −0.14 and no pixel foams. At 1024 the same views foam.

1024 is too expensive (§1). **Plan: calibrate the foam to the resolution**, so each N shows the reference's
foam coverage at 1024.
- Measure the reference's foam coverage at 1024 on the default sea: the fraction of the surface above a
  foam threshold, averaged over a loop period and over seeds.
- Find the `foam_bias` (or a per-N offset added to `cascade_foam_offset`) that makes 128, 256 and 512 match
  that fraction. Store the calibration in code as a table per N, not in the materials, so it follows
  `fft_resolution`.
- **Gate:** coverage at each N is within 20% of 1024's. Control: the uncalibrated 256 coverage, which is 0,
  must miss.
- Judge by eye that the foam sits on crests and not as a uniform haze. A bias can buy coverage with
  smeared foam.

**Built (W3, 2026-10-16).** The premise was wrong in two ways, and the user re-scoped W3 from the numbers.
- **256 is not foamless, and 1024 is not the target.** bench/WaterFoamCoverageProbe reads the cascades' foam
  straight off the simulation's texels (mip 0, every drawn cascade, histograms convolved since the cascades
  tile at incommensurate repeats). At the reference's offsets the mean crest is 0.047 at 1024, 0.018 at 512,
  0.011 at 256 and 0.004 at 128: 256 makes a quarter of 1024's foam, not none, and 1024's is itself sparse.
  The user chose the look by eye instead, from bench/WaterFoamLevelCompare's grids: +0.45 on the offset at
  256 (mean crest 0.044, 27% coverage).
  - A first rendered probe (a 64 m view) gave lifts that moved 40% between runs: the view saw less than one
    tile of the 100 m cascade, and at 1024 each pixel already averaged eight texels before the clamp. The
    texel probe is reproducible to 0.004.
- **The offset, split in two.** `Pasture3DWaterFFT.foam_lift` (default 0, the reference) is added to the
  offsets' sum; the built-in ocean_default ships 0.25, the lift at 1024 that gives the chosen mean crest.
  The shader adds a per-resolution lift on top, `water_fft_foam_resolution_lift()`: 512 +0.13, 256 +0.2,
  128 +0.315, 1024 0, so 256 lands on the user's +0.45 and every N shows the same mean crest. Matching the
  MEAN also matched coverage (27–28% at every N), which coverage-matching alone would not have promised.
  N is read off the texture with textureSize(), so a resolution change needs no material upload. The
  correction is calibrated on the ocean only; lake_calm and pond_still are W5's.
- **Foam vanished past ~40 m: the mips average the foam before the clamp.** clamp(mean) is far below
  mean(clamp) where foam is patchy, and at the shipped offset the mean foam never clears it. The slope
  texture now stores (slope, foam, foam²) (its Jacobian channel was unread), so the box mips carry the
  foam's second moment, both read through the one anisotropic sampler. The fragment treats the summed
  foam over a footprint as normal with that mean and variance (cascades add) and takes the clamp's
  expectation in closed form, `water_fft_crest()`. `fft_foam_footprint` (default on) switches it; off is
  the reference.
- **Then the 7.7 m tile showed.** Foam that carries also shows the short cascade's lattice: its foam (mean
  0.30 per texel, against the long cascade's 0.017) dominates the crest, and its 7.7 m repeat lines up in
  rows down the view. As a pixel's footprint grows from 0.004 to 0.02 of a cascade's repeat, that
  cascade's foam moments go to the whole tile's (its last mip): the same mean crest, an even tone instead
  of rows. Judged by eye; no gate measures the lattice.
- **Gate: WaterFoamGate.** The truth is the sea's mean crest from the texels of the frame being rendered.
  [F] at N 1024, the rendered mean crest over 100, 400 and 1600 m top-down views (0.2 to 3.1 m a pixel) is
  0.95 of the truth at every scale (tol 10%); control, the footprint off, 0.009 at 1600 m. [R] at every N
  the rendered mean crest is within 3.3% of 256's (tol 10%); control, the truths at the uploaded offset
  without the resolution lift, spread 12x.
- WaterReferenceABGate runs with the ocean's foam_lift taken back out and the footprint off.
- Not seen before because there was no far foam: one probe run crashed with an out-of-memory error
  inside libpasture while switching N 512 to 128, and did not recur in three reruns.

### 2.3 Shore foam reads as one tiled image

**Cause, read from the shader.** Shore foam is a depth band (`foam_shore_depth`, `foam_shore_amount`)
multiplied by ONE tap of `foam_tex`, at `foam_scale` 0.07 (a 14 m tile), scrolling by a constant. Since R4
foam is emitted unlit, so the band glows uniformly, in shadow too, and the repeat is plain. With no crest
foam (§2.2) it is the only foam on screen, so it carries the whole look.

The reference has no shore foam (D4 kept ours), so there is nothing to match. This is design work.

**Plan.**
- Break the repeat: two taps at unrelated scales and rotations, and a low-frequency noise mask.
- Move the band with the water: drive it with the FFT height, so foam washes up and back with the swell
  instead of sitting as a fixed ring.
- Light the shore foam, or dim its emission in shadow. P-D3 decides whether shore foam stays unlit like
  the reference's crest foam.
- Give each material a shore depth in metres that suits its body (the ocean's 1.2 m band at 0.38 is wide).
- **Gate:** a tiling metric (autocorrelation of the foam mask at the tile period) under a threshold.
  Control: the single tap must exceed it.

### 2.4 Jagged black edges in a band of mid-distance reflections

**Not yet diagnosed.** The ocean material has no environment map (R5, D3), so its reflection is Godot's
sky through `SPECULAR`, at `ROUGHNESS` 0.075. Three hypotheses, each testable:

- **H1. Reflections below the horizon.** At grazing angles a wave facet tilted away from the camera
  reflects downward, and Godot's sky below the horizon is the dark ground colour. That would put black
  facets in exactly a distance band: near the camera, rays rarely dip below the horizon; far away, the
  normal fade flattens the facets.
  - Test: colour the sky's ground red. If the edges turn red, it is H1.
  - Fix: bend the reflection direction back above the horizon, as most water shaders do.
- **H2. Specular aliasing.** The slope mips average the normal, but nothing widens the highlight for the
  variance the average lost. At mid distance one pixel covers many waves of the 0.33 m cascades, and a
  sharp reflection of a few sampled normals flickers and stair-steps.
  - Test: the edges crawl as the camera moves slowly; H1's edges move with the waves.
  - Fix: store slope² in the slope texture's spare channels, so its mips carry the variance, and add it to
    the roughness (LEAN/Toksvig). This changes the reference's look, deliberately, and only where pixels
    are minified.
- **H3. The fades are tuned for a 2000 m far plane.** The editor camera's default far is 4000 m, so
  normals fade half as fast, and more unresolved slope reaches the mid distance. This makes H2 worse.
  - Test: set the editor's far to 2000 and compare.
  - Fix: decouple the fades from the camera's far plane (P-D4).

**Plan.** Diagnose first, with a bench scene reproducing the user's third screenshot: the ocean, the editor's
default sky, a camera at 6 m pitched −10°. Measure the fraction of pixels whose reflection points below the
horizon, and a temporal-stability metric: per-pixel luminance variance across a slow pan. Fix what
the measurements point to. **Gate:** both metrics under a threshold, on the bench and with the editor's far.

**Built (W2, 2026-10-16).**
- **H1 confirmed and fixed.** bench/WaterReflectionBandProbe renders one frozen sea under three skies that
  differ only below the horizon. With a red ground the dark streaks turned red, exactly; with a ground
  equal to the horizon colour the band vanished. 15–22% of the water reflected below the horizon,
  up to 47% in the rows just under it.
  - Fix: `reflection_min_elevation` (degrees, default 3; −90 off). Where the reflection of the view about
    the normal dips below that elevation, the normal is replaced by the half vector between the view and
    the same reflection lifted to it. Only the reflection direction changes; the sun highlight, Fresnel and
    scatter all read the bent normal, as the facet now "is" one that reflects the horizon.
  - Gate: WaterHorizonBendGate. [B] under 2% below the horizon in three views (measured 0.0–0.1%);
    control, the bend off, over 10% (15.5–20.1%). [U] bent to 0°, 99.8% of the pixels it changes reflect
    below the horizon; control, a 60° bend, 34.5%. The first [U] claimed a steep view down changes
    nothing, and failed: even at −70° pitch, 0.15% of facets near the camera reflect below the horizon.
  - WaterReferenceABGate runs with the bend off: the reference has none.
- **P-D4 built.** `fft_fade_distance` (metres, default 2000) replaces the far plane in the G5 fades; 0
  restores the reference's far-plane fade, which the A/B gate uses since its [D] reads the far plane back.
  WaterFFTWiringGate [F] now also asserts that moving the camera's far plane does not move the fade.
- **H2 measured, not a problem; no LEAN/Toksvig.** bench/WaterShimmerProbe pans a frozen sea a quarter
  pixel per frame under the editor's 4000 m far plane, and compares per-pixel temporal luminance std
  against the same pan rendered at 4x and box-filtered (the answer without aliasing). From 25 to 110 m
  the 1x render shimmers LESS than the truth (ratio 0.94 down to 0.50: the slope mips average detail
  away); at 10–19 m it shimmers 8–28% more. Neither is the band.
- **H3 measured, negligible at these distances.** The far-plane fade at 4000 m and the 2000 m metric fade
  give the same shimmer to the third decimal out to 110 m; they differ only where the fade is a large
  fraction of its distance. P-D4 stands for the stability of the look, not for H2.

### 2.5 Lake, pond and river presets need tuning by eye

Even after §2.1, the presets need the user's judgement:
- R5's lake and pond are Froude-scaled from the reference: calm (σ 0.019 m and 0.009 m) and physically
  consistent. Physically right is not necessarily right for a game. A 1 m wave travels at 1.25 m/s, which
  can read as busy on a small pond.
- `river_flow` is still the Gerstner-era migration (`fit_sea(0, 10, 0.0236)`). The river draws its own
  stream waves; what the profile contributes to a river has not been checked since the port.

**Plan.** After §2.1 lands, put the four presets side by side in a review scene, and tune them with the
user. Knobs that slow a sea without changing its look: a time-scale on the profile (P-D5), or less wind
with the same fetch. Then lock the result with WaterRetireGerstnerGate [P].

## 3. Decisions for the user

Taken 2026-10-16: the recommendation in each. P-D5 waits for W5, as recommended.

- **P-D1. Default resolution.**
  - *Recommend 256, with the foam calibrated per N (§2.2).* 1024 costs 2 ms per profile.
  - 512 is the step up, at 0.37 ms of simulation, for projects that want finer near normals.
- **P-D2. Stock presets in scenes.**
  - *Recommend built-ins that scenes reference by name, with explicit overrides (§2.1)*, rather than
    embedded copies that go stale.
- **P-D3. Shore foam lighting.**
  - The reference's crest foam is unlit, and we kept that. Shore foam has no reference to match.
  - *Recommend lighting it*, so that it darkens in shadow like the beach beside it.
- **P-D4. The fades and the far plane.**
  - The reference fades with the camera's far plane, so every camera change retunes the water.
  - *Recommend a fade distance in metres on the material, defaulting to 2000 m*: the reference's look at
    the reference's far plane, and stable under any camera. This reverses R3's G5 port and needs your
    sign-off.
- **P-D5. Slowing the small-water presets.**
  - A profile time-scale is cheap and direct, but breaks Froude consistency: waves that move slower
    than their length allows.
  - The alternative is a different spectrum (less wind, shorter fetch), which stays physical but changes
    the shape as well.
  - *Recommend deciding after seeing §2.1's fixed presets.*

## 4. Phases

| Phase | Work | Needs |
|---|---|---|
| W1 | Built-in presets, scene migration, PondWater's profile (§2.1) | P-D2 |
| W2 | Reflection diagnosis bench; then the fix it points to (§2.4) | P-D4 if H3 |
| W3 | Foam calibration per N, and foam that carries to the distance (§2.2) | P-D1 |
| W4 | Shore foam (§2.3) | P-D3 |
| W5 | Preset review and tuning by eye, with the user (§2.5) | W1, P-D5 |
| W6 | Production checks: the timing gates Phase 2, 6 and 7 (run only with the user's go-ahead), the low tier, Mobile, and a device that falls back from 1024 | W1–W5 |

W1 comes first because every later judgement by eye needs the scene to show the real presets. W2 comes next
because it is the most visible problem, and it is in every view.
