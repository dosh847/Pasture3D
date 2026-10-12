# Pasture3D Water — user guide

Water in Pasture3D is one shader family and four nodes:

- **`Pasture3DPoolManager`** — one per scene. Owns the clock, the sun, and the named wave profiles
  every body selects from. Nothing moves without it.
- **`Pasture3DOcean`** — an endless sea on a camera-following clipmap. Its Y is the sea level.
- **`Pasture3DPool`** — still water filling a **closed** outline: a lake, a pond, a reservoir.
- **`Pasture3DStream`** — running water along an **open** channel: a river, a creek, a canal.

The last two are normally created by pressing one button on the landscape brush that carved the
ground, and which of them you get is decided by the curve — you do not choose. They share a base
class, `Pasture3DWaterBody`, so buoys (§5) and the query API (§6) work the same on both, and so do
the material, underwater and level controls in §4.

Waves are an **FFT ocean simulation** (Tessendorf, four cascades, after Garrett Gunnell's Water) run
on the GPU once per wave profile per frame, with an **fBm** compatibility model for renderers without
a RenderingDevice. The fBm is not the cheaper model (§3, §10). Rivers have their own channel model (§4).
The sun is lit by Garrett's microfacet model inside `light()`.

Design rationale, measurements and the phase history live in
[PASTURE3D_WATER_FFT_SPEC.md](PASTURE3D_WATER_FFT_SPEC.md),
[PASTURE3D_WATER_SHADER_SPEC.md](PASTURE3D_WATER_SHADER_SPEC.md) and
[PASTURE3D_WATER_BODIES_SPEC.md](PASTURE3D_WATER_BODIES_SPEC.md). This file is how to use it.

> **Upgrading from a scene made before 2026-07-29?** The ocean used to live on the `Pasture3D` node
> as `ocean_*` properties. Those are gone; §9 maps every one of them to where it went, and your old
> scene keeps its settings and offers a one-press **Migrate Ocean** button until you convert it.
>
> **Upgrading a scene with rivers in it?** Rivers used to be `Pasture3DPool` nodes that noticed their
> curve was open and meshed themselves as a ribbon. They are `Pasture3DStream` now. An old river
> pool draws nothing, says so in its configuration warning, and grows a **Convert to Stream**
> button that swaps it in place, keeping its name, its transform and every setting. One press per
> river, undoable. Lakes are unaffected.

---

## 1. Quick start

### A lake or a pond

1. Carve a basin with a landscape brush — a `Pasture3DMound` with `blend_mode` set to `MIN`, or a
   `Pasture3DTrough`.
2. Press **Add Water** on the brush.

That is the whole setup. The button fills the brush's loop with a `Pasture3DPool` named
`<Brush>Water`, seats it on the spline, picks a wave profile from the loop's size, and creates a
`Pasture3DPoolManager` if the scene does not have one. Undo removes all of it in one step.

If the brush *raises* terrain, the button asks first — water inside a landform is water you cannot
see. "Add Anyway" is a real option; the resulting pool keeps a warning saying why.

Quicker still: a **`Pasture3DPond`** is a brush that carves its basin and presses the button
itself. Drop one in and you have a pond.

### A river

The same button. An **open** spline gives you a `Pasture3DStream` named `<Brush>Stream` instead of a
pool: it follows the channel downhill, takes its surface level from the banks, and flows its texture
along the run. Nothing else to set — the fallback width comes from a `Pasture3DTrough`'s
`bed_half_width`, and the river preset is applied for you.

**The curve picks the node.** Closed is a pool, open is a stream, decided once when the button is
pressed. If you later open a lake's loop, or close a river's channel, the water does not change kind
on its own — the node tells you what is wrong and, on a pool, offers **Convert to Stream**. That is
deliberate: a shape edit silently rewriting what a node *is* was the old behaviour, and it meant a
misplaced click could turn a lake into a river with nothing in the scene to say so.

### An ocean

1. Add a **`Pasture3DPoolManager`** to the scene and set its **`sun_light`** to your
   `DirectionalLight3D`.
2. Add a **`Pasture3DOcean`**. Move it in Y to set the sea level.
3. Assign its **`material`**: `M_water_ocean.tres`, or `M_water_ocean_low.tres` for the low tier. A new
   ocean has none, and with none it draws nothing. The node shows a "No material" warning.

The ocean is hidden wherever the terrain is above it, so set the sea level below the coast and above
the seabed.

`sun_light` is not decoration — it is how the plugin learns the sun's direction and colour, which it
publishes to the global uniforms every water body reads. Without it the water is lit by Godot's light
loop but its own sun-dependent terms (specular tint, scattering) sit at their defaults.

### Water on a bare mesh, with no plugin nodes at all

Put `M_water_lake.tres` or `M_water_pond.tres` on any `MeshInstance3D`. Give the mesh subdivisions —
the waves are a **vertex** effect, so a two-triangle plane will not move. This path needs no manager
and no terrain, but nothing drives its clock either (§7), and with no manager there is no FFT
simulation: the material draws the fBm at its default knobs, a reference sea about a metre high.

---

## 2. The presets

All five live in `addons/pasture_3d/extras/shaders/water/`.

| Preset | Shader | Waves | Crest foam | Shore foam | Scattering | Flow | Receives shadows |
|---|---|---|---|---|---|---|---|
| `M_water_ocean.tres` | `water_ocean` | profile | yes | yes | yes | no | yes |
| `M_water_ocean_low.tres` | `water_ocean_low` | profile | no | yes | no | no | no |
| `M_water_lake.tres` | `water_body` | profile | no | yes | yes | no | yes |
| `M_water_pond.tres` | `water_body_low` | profile | no | yes | no | no | no |
| `M_water_river.tres` | `water_river` | channel | no | yes | no | **yes** | no |

"Profile" means the waves come from the body's wave profile (§3), FFT or fBm, the same on every
tier. "Channel" is the river's own model (§4).

**The low tiers are different shaders, not the same shader turned down.** The features they drop are
`#define`-d out at compile time, so they are not branched over at runtime. A pond is genuinely
cheaper.

**`M_water_river.tres` is the one preset that is not drop-anywhere.** It needs three things only a
`Pasture3DStream` mesh writes: the flow direction and speed in `ARRAY_COLOR.rgb`, the distance to the
bank in `ARRAY_COLOR.a`, and the flow travel time in `UV2.x`. On a bare `MeshInstance3D` the vertex
colours read white and `UV2` reads zero — a full-speed diagonal with every vertex at the same phase,
so the whole surface bobs in unison. On a `Pasture3DPool` it is harmless but inert: pools write a
neutral colour that decodes to no flow at all.

Measured at 1280×800 with the water filling the frame, before the FFT port: ocean high tier
0.295 ms, low tier 0.235 ms, against 0.452 ms for the shader these replaced. River costs **+7%** over
lake (0.155 vs 0.145 ms) for the two extra texture fetches its flow cross-fade needs. The FFT tiers
have not been re-timed; see §10.

**Press "Make Unique" before editing a preset.** They are plugin files and a plugin update will
overwrite them. The button is on every water body; "Save Unique Material" then writes your version out
as a project asset. Editing a preset in place also loses its documentation header, because the Godot
editor strips `.tres` comments when it re-saves.

---

## 3. Wave profiles

Every body selects a **profile by name** from the scene's `Pasture3DPoolManager`. A fresh manager
ships four:

| Profile | Heading | Longest wave | Height σ | Shortest wave meshed | Intended for |
|---|---|---|---|---|---|
| `ocean_default` | 20° | 137 m | 0.86 m | 10.2 m | `Pasture3DOcean` |
| `lake_calm` | 35° | 25 m | 0.12 m | 10.2 m | Lakes over ~40 m across |
| `pond_still` | 55° | 12 m | 0.013 m | 6.0 m | Ponds under ~40 m across |
| `river_flow` | 0° | 10 m | 0.024 m | 5.0 m | A stream's buoyancy and mesh density only — see §4 |

These are the Gerstner presets the plugin shipped until 2026-10-09, carried through the same fit an
old scene gets on load (below), so a lake still loads as that lake.

### Which model draws: `wave_model`

| Setting | Where | Meaning |
|---|---|---|
| `wave_model` | `Pasture3DPoolManager` | **Project Setting** (default), **FFT** or **fBm**. |
| `pasture_3d/water/wave_model` | Project Settings | FFT (default) or fBm, for every manager left on Project Setting. A game's options menu can write it at runtime with `ProjectSettings.set_setting()`; the managers follow without a node reference. |
| `fft_resolution` | `Pasture3DPoolManager` | 0 = the project setting. Otherwise 128, 256 or 512 texels per cascade. |
| `pasture_3d/water/fft_resolution` | Project Settings | 256 by default. 128 is a quarter of the work. |

**FFT needs a RenderingDevice** — Forward+ or Mobile. On Compatibility, or headless, a manager that
asks for FFT draws fBm instead, warns once, and `is_wave_model_fallback()` says so.

**fBm is the compatibility model, not the cheap one.** It is a sum of 40 `exp(sin)` octaves evaluated
in the shader: no textures and no compute. Its per-pixel cost is about what the FFT's simulation and
draw cost together (§10), and it looks worse: it has no breaking signal, so it draws no crest foam.
It is the right choice where:

- **There is no RenderingDevice:** Compatibility, or a headless server. There it is the only model,
  and nothing warns.
- **CPU height queries must be exact and same-frame.** `get_water_height()` under the fBm is the
  shader's own sum (§6), with no readback lag and no first-frame flat answer. That suits a server
  that simulates buoys headless, or lockstep multiplayer that needs every peer to agree.

**Choosing fBm on Forward+ or Mobile warns.** The manager shows a configuration warning, logs once
per run, and `is_fbm_by_choice()` returns true. It stays selectable, because it is useful for
previewing what Compatibility players see. It may be hidden from the Forward+ inspector later. To
save GPU time, lower `fft_resolution` to 128 instead.

### The knobs, on `Pasture3DWaveProfile`

| Property | Meaning |
|---|---|
| `profile_name` | The selection key. Bodies name it in `wave_profile`. |
| `fft` | A `Pasture3DWaterFFT`: the simulation and its knobs. `seed`, `depth`, `choppiness`, `cascade_lengths` (any order), `band_limited` (off: every cascade spans every wavelength, as the reference does), and eight spectra, `spectrum_1/*` … `spectrum_8/*`, two per cascade (cascade i carries spectra 2i−1 and 2i) — `scale`, `wind_speed`, `direction_deg`, `fetch`, `spread_blend`, `swell`, `peak_enhancement`, `short_waves_fade`. Foam: `foam_bias`, `foam_threshold`, `foam_add`, `foam_decay`. |
| `fbm` | A `Pasture3DWaterFBM`: the fallback's knobs, a `vertex/*` set for the geometry and a `fragment/*` set for the normals. `seed` is the heading in radians, `frequency` the first octave's wavenumber, `height` the metres the normalised sum is scaled to. |
| `min_wavelength` | Metres. The shortest wave the mesh must resolve: water bodies mesh at an eighth of it. A **cost** knob — the FFT picks its mip from the mesh spacing and the fBm drops octaves it cannot draw, so a coarser mesh loses short waves from the geometry while the fragment stage still draws them as slope. |

**Sizing a sea from three numbers.** `fit_sea(direction_deg, length_max, sigma)` sets both models to
a sea whose longest wave is `length_max` metres, running along `direction_deg`, with a height standard
deviation of `sigma` metres. That is how the presets are made; start there and tune.

The loop period is **not** on the profile. It is `loop_period` on the manager, because the
quantisation that makes the clock wrap seamlessly — the FFT's dispersion and the fBm's speeds — is
computed against a single period for the whole scene.

> ⚠️ **Height σ is not the wave height.** Crests reach several σ. If you are sizing a cull margin, a
> boat's clearance, or a camera height, use `get_amplitude_sum()` on the profile: 6σ under the FFT,
> the octaves' true reach under the fBm.

Do **not** set `_wave_model`, `_fft_*` or `_fbm_*` on a material driven by a manager. They are
re-uploaded whenever a knob changes, so anything written there is overwritten, and until it is, the
CPU height query and the drawn surface disagree.

Waves are evaluated relative to `_water_domain_origin`, which every water body sets from its own
position, so a pond kilometres from the world origin keeps its float precision. A **bare mesh** does
not get one and needs that instance uniform set by hand.

### Scenes saved before 2026-10-09

Profiles used to carry Gerstner knobs (`wave_count`, `direction_deg`, `spread_deg`, `amplitude`,
`length_max`, `steepness`). A scene that still has them loads fine: the profile reads them once and
fits the FFT and the fBm to them — the longest wave, the heading, and a height σ of 0.176 × the old
table's amplitude sum — and sets `min_wavelength` to the old table's shortest wave. It does that only
where the scene did not also store the model itself. Nothing writes the old knobs back, so the next
save stores the fitted models instead. `spread_deg` and `steepness` have no counterpart and are
dropped.

---

## 4. `Pasture3DPool` and `Pasture3DStream` — the water bodies

The two nodes the Add Water button creates. Both can be added by hand. Everything in this section
down to *Underwater* is shared — it lives on their common base, `Pasture3DWaterBody` — and each has
one section of its own after that.

### Source (both)

| Property | Meaning |
|---|---|
| `source_spline` | A `Path3D` — normally a brush's. Carries the curve **and its transform**, so moving the brush moves the water. |
| `curve` | A raw `Curve3D`, overriding `source_spline`. Read in **this node's** space, so a curve lifted off an offset brush lands offset. For water authored without a brush. |

**The class decides what gets built, not the curve.** A `Pasture3DPool` fills a closed outline; a
`Pasture3DStream` follows an open channel. Give a pool an open curve and it says so and offers
**Convert to Stream**; give a stream a closed one and it runs a channel all the way around the loop,
which is a moat and is occasionally what you want.

### Shape (both)

| Property | Meaning |
|---|---|
| `edge_offset` | Metres the mesh is grown past the curve, so its rim is buried in the bank instead of ending in open air. |
| `fill_offset` | Metres added to the level when **Fit to Curve** runs. Negative sits the water under the rim, which is where a basin's water is. On a stream it is only the fallback — see below. |
| `vertex_spacing` | 0 = automatic, at an eighth of the profile's shortest wavelength. This is correctness, not taste — see §7. |
| `max_vertices` | Ceiling on the generated mesh. Raise it to buy resolution on a large body; lower it to catch a spacing mistake before the editor locks up. The build refuses past it and says what it would have taken. |

**Fit to Curve** seats the node on its spline: XZ onto the spline's origin, Y onto the curve's lowest
point plus `fill_offset`. It is never automatic, because the brushes re-snap their spline points to
the terrain and an automatic fit would move the water level whenever the ground under the rim moved.

**On a `Pasture3DPond`, set the level on the BRUSH, not here.** The pond has a `water_offset` under
its own **Water** group — same frame, same sign, same number as `fill_offset` — and typing into it
moves water that already exists, with no Fit to Curve press and no hunting for the pool in the Scene
dock. It also seeds the level when Add Water fires, so a pond dropped in with a non-default offset
lands right the first time. `fill_offset` here still works and still wins until the brush's value next
changes; when the two disagree the pond says so in its configuration warnings and its **Level Water**
button re-applies. See `PASTURE3D_POND_WATER_OFFSET_SPEC.md`.

Dragging a **pool** in **Y** moves the water level. Dragging it in **XZ** does not move the water —
the spline decides where that is — but it does move `_water_domain_origin`, which is what keeps wave
phase precise far from the world origin. Water driven by a bare `curve` is the exception and travels
with its node in both.

### `Pasture3DStream` only — the channel, the banks and the flow

| Property | Meaning |
|---|---|
| `ribbon_half_width` | **Fallback** half-width, before `edge_offset` is added each side. Used only where the banks cannot be sampled. |
| `bank_height` | Metres below the bank top that the water sits — freeboard. This is the level control; the bed does not set it. |
| `bank_search_width` | How far out to look for the bank top. 0 = automatic, from the `Pasture3DTrough` that carved the channel. |
| `bank_smoothing` | Passes of smoothing over the sampled surface line. Terrain samples are noisy, and a river surface that climbs even by centimetres reads as broken. |
| `flow_speed` | Metres per second the water runs. Drives the texture advection, the ripple crests and the ripple amplitude. It moves the *surface*, not the water body: nothing is simulated and no buoy is pushed downstream by it. |
| `flow_slope_gain` | How much a downhill gradient adds to that speed, so steep reaches read as rapids. |
| `flow_reverse` | Run the flow the other way, for a channel drawn from the mouth up. Flips which way `flow_slope_gain` counts as downhill, and which way the ripples travel. |

`wave_profile` is greyed out on a stream, and that is the interesting part.

**A river does not use the profile's waves at all.** A sea's crests carry fixed world-space
headings; a river bends; so on every reach that heads against them, the crests travel
*upstream*. There is no amplitude, steepness or direction that fixes it — the model has one
direction and a river has many — and the only setting that hides it is amplitude 0, which is what
this plugin's own demo scene had to ship before this was solved.

So a stream's surface motion comes from **material** uniforms instead, on `M_water_river.tres`, in
three groups. The **ripples** are the base undulation, athwart the current:

| Uniform | Meaning |
|---|---|
| `ripple_amplitude` | Crest-to-trough height at full speed, in metres, before the bank fade. Centimetres, not metres: this is chop on a channel, not swell on a sea. |
| `ripple_frequency` | How often the surface bobs at a fixed point, in Hz. **Not** a wavelength — see below. |
| `ripple_speed_ref` | The flow speed at which ripples reach full amplitude. Below it they scale down, so a river slowing into a pool goes glassy by itself. |
| `ripple_bank_fade` | Where across the half-width the ripples start fading out, so no crest stands proud of the dry bank. |

The **chop** is what stops the river being a rolling carpet. The ripples are a function of travel
time alone, so every point on a cross-section sits at exactly the same height; chop is two oblique
octaves that cross into the diamond lattice moving water actually shows.

| Uniform | Meaning |
|---|---|
| `chop_amplitude` | Crest-to-trough height in metres, mid-channel at full speed. Gated by the same speed and bank fades as the ripples. **0 is a supported setting** and gives the columns back — see below. |
| `chop_wavelength` | Distance between chop crests measured *across* the channel, in metres. This is what sets the mesh's column spacing. |

The **standing waves** are the stationary undulations below a ford or a chute. Unlike everything
else on this surface they do not move — they sit still in the world while the water runs through
them — and **nobody authors where they are**: they appear wherever the flow goes supercritical.

| Uniform | Meaning |
|---|---|
| `standing_amplitude` | Crest-to-trough height in metres at `standing_depth_ref` of water. Scaled down in shallower water. |
| `standing_froude_onset` | The Froude number `v / √(g·d)` they begin at. 1.0 is the physical critical point; shipped slightly under, because the transition looks abrupt if it starts exactly at the textbook value. |
| `standing_depth_ref` | Depth in metres at which they reach full amplitude, and the scale they fade out over as a reach dries. |

They are on the material and not on the node because everything that differs *between reaches* —
how fast the water is running, how steep, how deep, how near the bank — is already carried
per-vertex by the mesh. The material only has to say how much wave a given reach earns.

**Why frequency and not wavelength.** The mesh carries, per vertex, the *flow travel time* from the
head of the channel, and the ripples are a function of it. That one substitution is what makes
crests run downstream on every reach — travel time increases along the channel by construction, so
there is no reach on which the phase can turn around. It also makes crests move at the **local**
flow speed for free, with the wavelength stretching through fast reaches and packing together in
slow ones, which is what real water does. Frequency is the thing that stays constant in steady
flow, so frequency is the knob.

**`ripple_frequency` is quietly expensive.** Wavelength is speed ÷ frequency and the mesh has to
resolve it, so doubling the frequency halves the vertex spacing a stream picks and roughly
quadruples its vertex count. The shipped 0.3 Hz is about a 5 m undulation at 1.5 m/s. Anything
finer than that belongs to the detail normal map, which already flows along the same channel and
costs nothing extra.

**`chop_wavelength` is expensive too, but only in one axis.** Rows down the channel are sized by
`ripple_frequency`; columns across it are sized by `chop_wavelength`, at about six samples per
wavelength. They are separate numbers on purpose, because a river is long and narrow and columns
are therefore the cheap axis — on a 120 m channel the shipped chop settings take a strip from 7
columns to 30, which is 4× the vertices, where buying the same detail by halving the *row* spacing
twice would have been 16×. Setting `chop_amplitude` to 0 gives every one of those columns back;
the gate asserts it, so it will stay true.

**Standing waves choose their own reaches, and sometimes choose none.** They need
`v / √(g·d) > 1`, so at the shipped 1.5 m/s they want water shallower than about 28 cm. A river
running a metre deep will never show them however high `standing_amplitude` goes — which is
correct, and is also the most likely reason you see nothing. Raise the bed toward the surface (or
`flow_speed`) and they arrive on their own.

They also have a resolution floor that is not a quality setting. A standing wave's wavelength is
`2πv²/g`, which is *short* at the speeds that go supercritical — 1.4 m at 1.5 m/s — and a mesh
sampled every 2 m cannot draw it. Rather than alias it into noise, the stream fades it out and
raises a configuration warning naming how many rows it suppressed. Lower `vertex_spacing` if you
want them; the warning exists so the choice is yours rather than silent.

**A stream's surface comes from its banks, not its spline.** A `Pasture3DTrough`'s spline is the bed
*floor*, so offsetting it downward — which is what `fill_offset` means on a pool — buries the water
under its own channel. Instead each row measures the terrain on both sides, takes the **lower**
crest (water cannot stand higher than the side it would spill over) and sits `bank_height` below it.

Two things follow for free. **Depth varies**: a reach where the bed rises toward the surface becomes
a ford the player can wade, with nothing authored. And **width varies**: the waterline is found the
same way, per side, so the strip widens through a shallow reach, narrows in a gorge, and sits
off-centre where the channel is cut into a slope.

With no `Pasture3D` in the scene there is nothing to sample, and the surface falls back to bed +
`fill_offset` at a constant width — which is why `fill_offset` greys out on a stream over terrain
and comes back when there is none.

If a river fills to somewhere absurd partway up a hillside, `bank_search_width` is the knob: the
search has to reach the bank crest and stop, and pushed out onto the slope above it will find its
"bank" up there and fill to it.

### Underwater

| Property | Meaning |
|---|---|
| `underwater_enabled` | Build the submersion volume at all. |
| `volume_depth` | How far below the surface "in this water" reaches. |
| `underwater_fog` | Spawn a `FogVolume` tinted from the water material. |
| `underwater_overlay` | Spawn the screen effect when the camera goes under. Runtime only. |
| `overlay_transition` | Seconds to ramp that effect in and out across the crossing. |

Signals: `body_submerged(body)`, `body_surfaced(body)`, `camera_submerged(bool)`.

> **`body_submerged` will not fire for a `StaticBody3D`.** Godot 4.4+ defaults 3D physics to Jolt,
> whose areas do not report static bodies unless
> `physics/jolt_physics_3d/simulation/areas_detect_static_bodies` is enabled. Rigid, character and
> kinematic bodies are reported normally. `is_point_underwater()` has no such limit — it is geometry,
> not physics, so anything at all can be asked about it directly.

### Selecting one

A pool draws only an internal-child mesh, so there is nothing in the viewport to click. An **orange
octahedron** floats above the water, the same marker the brushes use in purple; click it to select
the pool. While it is selected the underwater volume's box is outlined too.

---

## 5. Floating things — `Pasture3DBuoy`

One buoy is one **sample point**, not one boat. Three or four on a hull give pitch and roll for free,
because each computes its own submersion at its own position and pushes at its own offset. One gives
a bobbing barrel.

Put them as children of a `RigidBody3D`. They find the hull themselves, and they find the water
themselves — a boat crossing from a lake into the ocean does not need telling.

| Property | Meaning |
|---|---|
| `displacement` | Cubic metres **this buoy** displaces at full submersion. |
| `full_depth` | Metres of submersion for full force. |
| `linear_drag` | Newtons per m/s at full submersion. |
| `angular_drag` | Per second at full submersion. Applied once per **body**, not once per buoy — using the **largest** value among that body's buoys, so mixed values are not averaged and the node warns when it sees them. |
| `sample_interval` | Re-read the wave height *and* re-check which water this is every N ticks, holding both between. Costs 1/N; in exchange the buoy notices it has left a body up to N ticks late. For crowds; leave at 1 on a hero boat. |
| `water_body` | Optional override. Empty = ask the manager. A body removed from the tree counts as no body — the boat falls rather than floating on a surface nothing is drawing. |

**The arithmetic that decides whether it floats**, and the reason `displacement` is in cubic metres
rather than some tuning unit:

```
sum(displacement) over the body's buoys  must exceed  mass / 1000
equilibrium submersion  f = (mass / 1000) / sum(displacement)
it settles at  f × full_depth  below the surface
```

The node reports both numbers in its configuration warning, so "why does my boat sink" is a sentence
rather than a puzzle.

Budget: **one wave solve per buoy per physics tick**, and 64 buoys inside 0.5 ms — both measured, on
a lake and on the ocean. `sample_interval` is the knob if you need more than that; it divides the
cost by N.

Two things that surprise people, neither of which is a bug:

**A floating boat may fall asleep, and that is fine.** Godot stops simulating a `RigidBody3D` that
has been at rest, and a boat riding still water qualifies. The buoyancy force wakes it again the
moment the water moves, so it rises on the next swell without any help. You do not need to set
`can_sleep = false`.

**Gravity does not change the waterline.** A hull with `gravity_scale = 2` weighs twice as much and
displaces twice as hard, so it settles at exactly the same depth. The buoyancy follows whatever
gravity the body is actually under, including an `Area3D` override — so if you want a boat to ride
lower, change its mass or its displacement, not its gravity.

---

## 6. Querying the water from code

```gdscript
var body := manager.body_at(global_position)      # the pool or ocean at a point, or null
if body:
    var h: float = body.get_water_height(Vector2(global_position.x, global_position.z))
    var n: Vector3 = body.get_water_normal(Vector2(global_position.x, global_position.z))
```

`Pasture3DOcean`, `Pasture3DPool` and `Pasture3DStream` all answer these, so code does not need to
know which kind of water it is standing in.

| Method | On | Returns |
|---|---|---|
| `get_water_height(global_xz)` | ocean, pool, stream | Surface height in world space. On a stream, the height of the reach you are over. |
| `get_water_normal(global_xz)` | ocean, pool, stream | Surface normal in world space. |
| `contains_point(global_pos)` | ocean, pool | Is this point in this body's water? A polygon test, not a bounding box. |
| `is_point_underwater(global_pos)` | pool | The same question under the name the underwater feature asks it by. |
| `get_water_depth(global_xz)` | stream | How deep the channel is here, in metres. 0 off the stream. **A centreline depth** — the bed is only known along the spline, so this is the depth of the middle of the channel at the nearest row, not the depth under the caller's feet. Good enough to decide whether a reach can be waded; not good enough to place a footstep. |
| `body_at(global_pos)` | manager | The innermost body containing a point. Finite bodies first, ocean as the fallback. |
| `get_water_time()` | manager | The wrapped clock both CPU and GPU use. Not `Time.get_ticks_msec()`, and not Godot's `TIME`. |
| `evaluate_height(profile, domain_xz)` | manager | The named profile's height at a rest-domain point, before the inversion. Mostly of interest to tests. |

`get_water_height()` answers from the model the materials draw:

- **fBm:** the shader's own sum, transcribed. It agrees with the drawn surface to about 1% RMS of the
  wave height (`WaterBuoyGate` [B]). The fBm moves vertically only, so there is no inversion.
- **FFT:** a readback of the simulation, one to three frames behind the picture. The first query on a
  quiet sea starts the readback and answers a flat surface until a frame lands; every query keeps it
  running. The FFT displaces sideways as well as up, so the query inverts that iteratively (up to 16
  steps). Within the latency it agrees with the drawn surface to 0.5% RMS (`WaterBuoyGate` [A]).

Fine for a few dozen floating objects per frame; do not call it per particle.

Containment is cheap, though — it reads the mesher's own inside mask, so it is a bounds check and an
array lookup for all but the cells the shoreline crosses.

---

## 7. Global uniforms

Water reads its clock and sun from project-wide shader globals, so one write drives every body in the
scene. The editor plugin registers them in `project.godot` on first run.

| Global | Written by | Purpose |
|---|---|---|
| `water_time` | `Pasture3DPoolManager`, every physics frame | The wrapped wave clock. |
| `water_time_period` | `Pasture3DPoolManager`, on change | Loop length; keeps the clock from growing without bound. |
| `water_sun_direction` | `Pasture3DPoolManager`, from `sun_light` | Sun vector. |
| `water_sun_color` | as above | Sun colour × energy. |

A scene with **no `Pasture3DPoolManager`** has nothing driving `water_time`, and the water will sit
still. That is the normal case for the bare-mesh path in §1. Drive it yourself:

```gdscript
func _physics_process(_delta: float) -> void:
    RenderingServer.global_shader_parameter_set(
            "water_time", fmod(Time.get_ticks_msec() / 1000.0, 120.0))
```

---

## 8. Tuning

The uniforms are grouped in the inspector. The ones worth reaching for first:

**`absorption`** (per-channel, 1/metres) is what makes water look like a particular body of water.
Higher values absorb faster, so the water goes opaque sooner and takes on the complementary colour.
The ocean's low red absorption is why it is blue; the pond's high values are why it is murky. It also
drives the underwater fog and the underwater screen tint, so those follow the surface automatically.

**`deep_color`** is what you see once absorption is total.

**`sun_roughness`** is the width of the sun's highlight (Beckmann α). The ocean's 0.075 is the
reference's; still water wants less, which is why the pond ships at 0.035. Raising it spreads the sun
path into a broad blown-out streak.

**`view_scatter`, `shadow_scatter`, `wave_peak_scatter`, `bubble_color`/`bubble_density`** are the
reference's subsurface terms: light through the body toward the viewer, light on the sun-facing side,
light through a crest per metre of crest height, and a flat bubble term.

**`foam_crest_amount`** scales the FFT's own foam, which comes from the wave Jacobian — whitecaps
where the surface folds. The simulation's `foam_*` knobs on the profile shape it; the fBm draws none.

**River only — `detail_strength`** scales the ripple texture's slope (0.25 applies about 0.10 m/m rms
slope; much past 0.5 tilts reflections below the horizon, which reads as coloured speckle).
**`variance_to_roughness`**: if a distant river shimmers, *raise* it, do not lower roughness — detail
the distance fade removes is converted into roughness. **`foam_crest_threshold`** is a slope, the
river's whitecap onset. The other presets have none of these: the FFT's cascades reach ~12 cm and
filter their own mips.

**`flow_period`** (river only) is how long the surface texture advects before the cross-fade hands
over to a fresh copy. Longer is more coherent motion but more visible smearing at the end of each
cycle. It is quantised against `loop_period` so the hand-over cannot be caught mid-way when the clock
wraps; `flow_quantise` turns that off, and exists so the seam can be demonstrated.

**Refraction is off**, deliberately. It measured 16–22% of the ocean's cost for an effect capped at
22.5% opacity. To opt in, duplicate `water_ocean.gdshader` and add `#define WATER_REFRACTION` before
the includes.

---

## 9. Upgrading from the `ocean_*` properties

Before 2026-07-29 the ocean lived on the `Pasture3D` node. It now lives on `Pasture3DOcean` and
`Pasture3DPoolManager`. **A scene saved before the change keeps its settings**: they are held on the
terrain, reported in a configuration warning, and converted by a **Migrate Ocean** button that
creates both nodes and transfers everything in one undoable step. They are not re-serialised, so
re-saving without migrating loses them — migrate first.

| Old property on `Pasture3D` | Now |
|---|---|
| `ocean_enabled` | `Pasture3DOcean.enabled`, or just delete the node |
| `ocean_material` | `Pasture3DOcean.material` |
| `ocean_light_target` | `Pasture3DPoolManager.sun_light` |
| `ocean_mesh_lods` | `Pasture3DOcean.mesh_lods` |
| `ocean_mesh_size` | `Pasture3DOcean.mesh_size` |
| `ocean_tessellation_level` | `Pasture3DOcean.tessellation_level` |
| `ocean_vertex_spacing` | `Pasture3DOcean.vertex_spacing` |
| `ocean_cull_margin` | `Pasture3DOcean.cull_margin` |
| `ocean_cast_shadows` | `Pasture3DOcean.cast_shadows` |
| `ocean_gi_mode` | `Pasture3DOcean.gi_mode` |
| `ocean_render_layers` | `Pasture3DOcean.render_layers` |
| `ocean_domain_origin` | `Pasture3DOcean.domain_origin` |
| `ocean_wave_count`, `ocean_wave_direction`, `ocean_wave_spread`, `ocean_wave_amplitude`, `ocean_wave_length_max`, `ocean_wave_steepness` | The manager's profile, fitted from them as in §3 (*Scenes saved before 2026-10-09*) |
| `ocean_wave_loop_period` | `Pasture3DPoolManager.loop_period` |

Two things moved rather than being renamed:

- **Sea level.** There was never an `ocean_sea_level` property — it was the material's `sea_level`
  uniform. It is now the **`Pasture3DOcean` node's Y**. Move the node.
- **`get_water_height()` and friends** were on `Pasture3D`. They are on the bodies now, and
  `Pasture3DPoolManager.body_at()` is how you find the right one. See §6.

### The bench gate that still uses the old properties

`WaterBodiesPhase0Baseline` builds its fixture the pre-extraction way — `terrain.ocean_material`,
`terrain.ocean_wave_count`, `terrain.get_water_time()`. Those properties are now only `_legacy_ocean`,
the migration capture, so the fixture builds no ocean and renders an empty frame; everything the gate
then reports is a control refusing that frame. **A red result from it says nothing about the water
code.** (`WaterPhase2Gate`..`WaterPhase5Gate` shared the problem and measured Gerstner; they were
deleted with it.) Everything else in the family — `WaterPhase1Gate`, `WaterBodiesPhase1..7`,
`WaterFFTGate`, `WaterFFTWiringGate`, `WaterPBRGate`, `WaterFBMGate`, `WaterBuoyGate`,
`WaterRetireGerstnerGate`, `WaterVariantWarningCheck` — is current and green (windowed; most of them
await `RenderingServer.frame_post_draw`, which never emits headless).

---

## 10. Performance notes

- **The FFT costs one simulation per profile in use,** every frame, whatever the screen covers and
  even with the water hidden: an ocean, a lake and a pond on three profiles run three.
- **`fft_resolution` is the cost lever, not `wave_model`.** Measured GPU time, simulation plus draw,
  for one body at 1280×800 on an RTX 3070 (`WaterModelCostTiming`, FFT spec §6.4):

  | Model | Ocean | Lake |
  |---|---|---|
  | FFT, `fft_resolution` 128 | 0.27 ms | 0.27 ms |
  | FFT, 256 (default) | 0.38 ms | 0.37 ms |
  | FFT, 512 | 0.83 ms | 0.79 ms |
  | fBm, 40 octaves (shipped) | 0.39 ms | 0.35 ms |

  The fBm's cost is all fragment work, and its octave count cannot come down. At 16 octaves it
  times like FFT 128, but cutting the series loses the short waves: the water goes glassy close up
  and the sun glint turns into a blob. Respacing 16 octaves over the same wavelengths keeps the
  detail but streaks (`WaterFBMOctaveCompare`).
- **Geometry is nearly free; fragments are not.** Measured clipmap geometry cost is inside the noise
  floor. If you need the water cheaper, use the low tier or reduce how much screen it covers — do not
  reduce `mesh_lods`.
- **`vertex_spacing` and `mesh_lods` move together** on the ocean. The clipmap is scale-invariant:
  halving the spacing halves the ocean's reach, and one more LOD buys it back. Half-extent is
  `2 × mesh_size × vertex_spacing × 2^(mesh_lods − 1)` — 8192 m at the defaults.
- **Vertex spacing should be about an eighth of `min_wavelength`.** The pool and the stream do this
  for you when `vertex_spacing` is 0. Coarser loses the short waves from the geometry (the FFT's mip
  and the fBm's octave fade drop them cleanly) while the fragment stage still draws them as slope.
- **Water-body rebuilds are debounced and off the interaction path.** A 500 m lake at automatic spacing is
  169 k vertices in about 120 ms. Rebuilds happen when the curve changes, when the brush moves, when a
  stream's *baked* material uniforms change (see below), or on demand.
- **A stream re-meshes when you edit `ripple_frequency`, `chop_wavelength`, `chop_amplitude` or
  `flow_speed_scale`,** because those four are read when the mesh is built and frozen into it — the
  first two set the row and column spacing, and the last scales the speed the stationary phase is
  integrated against. Dragging any of them costs one debounced rebuild when you let go, not sixty.
  Every other uniform on the material is drawn with rather than baked, and changing it costs nothing.
  `standing_froude_onset` and `standing_depth_ref` sit in between: they refresh the suppression
  warning without re-meshing.
- **The underwater overlay** costs 0.043 ms per megapixel — about 0.09 ms at 1080p.
- **Steam Deck performance is unverified.** Every Deck figure in the spec is extrapolated from a
  desktop measurement; no Deck was available. Measure before relying on it.

---

## 11. Troubleshooting

**The water is flat.** The waves are a vertex effect. A `PlaneMesh` with no subdivisions has four
vertices. Add subdivisions. (`Pasture3DPool` and `Pasture3DStream` never have this problem — they
tessellate themselves.)

**The water does not move.** Nothing is driving `water_time`. Add a `Pasture3DPoolManager`, or write
the global yourself — see §7.

**The Add Water button says my brush raises terrain.** It does, and water inside a landform is hidden
by it. Set the brush's `blend_mode` to `MIN` to carve a basin, or press "Add Anyway" if you meant a
raised pool on a plateau.

**A pool warns about `volumetric_fog_enabled`.** A `FogVolume` renders nothing at all unless the
scene's `Environment` has volumetric fog switched on — no error, just no fog. Enable it on the
`WorldEnvironment`, or turn off `underwater_fog`.

**The river's texture slides diagonally, or the whole surface bobs in unison.** `M_water_river.tres`
is on a mesh that is not a `Pasture3DStream`. With no vertex colours it reads white — a diagonal at
full speed — and with no `UV2` every vertex shares one phase. (`CUSTOM0` reads zero too, so the chop
degenerates into more of the same and the standing waves never fire.) Put it on a stream.

**My river is flat.** Check `flow_speed`. Ripple amplitude scales with it and reaches full size at
`ripple_speed_ref` (2 m/s by default), so a river authored at 0.1 m/s is *correctly* glassy. Also
check `wave_profile` is not what you are trying to tune: it does nothing to a stream's surface (§4).

**My river costs more vertices than I expected.** Two knobs, and they bill in different axes.
`ripple_frequency` sets the **rows**: wavelength is speed ÷ frequency and the mesh resolves it, so
the knob that looks like a style choice is really the density dial. `chop_wavelength` sets the
**columns**, at about six samples across each wavelength. Set `vertex_spacing` explicitly to decide
both yourself, or `chop_amplitude` to 0 to buy the column budget back.

**I see no standing waves at all.** Almost always because the river is too deep for them. They need
a Froude number above 1 — `v / √(g·d)` — which at 1.5 m/s means water shallower than about 28 cm.
Check `get_water_depth()` on the reach you expect them in. If the depth is right and they are still
missing, look at the node's configuration warning: a mesh too coarse to carry their wavelength
fades them out deliberately and says so.

**My river is a rolling carpet — the whole width rises and falls together.** That is the ripples
with no chop on top. Raise `chop_amplitude` on `M_water_river.tres`. It is the only term that
varies across the channel, so it is the only thing that breaks that read — and note it is scaled
against `ripple_amplitude`, not relative to it, so on a river tuned for big swell you will need a
proportionally bigger number before you notice it.

**The pool's water did not move when I moved the brush.** It should — check `source_spline` is set
rather than `curve`. A raw `Curve3D` carries no transform and does not track anything.

**Distant water shimmers or crawls.** On a river, raise `variance_to_roughness` (§8). Elsewhere,
check `fft_resolution` is not above what the mesh and the screen can carry.

**Coloured speckle on a river.** `detail_strength` is too high for the texture in use; normals are
tilting past the horizon.

**The water is flat in the first frame, or a buoy starts flat.** Under the FFT the CPU answer is a
readback, and the first query on a quiet sea answers flat until one lands (§6). It is one to three
frames.

**My sea looks different on Compatibility.** It is the fBm, not the FFT: that renderer has no
RenderingDevice (§3). Set `wave_model` to fBm on Forward+ to preview it there. The manager will warn
that fBm is the compatibility model, which is expected while previewing.

**The manager warns "wave_model is fBm on a renderer that can run the FFT".** fBm was chosen,
directly or through `pasture_3d/water/wave_model`, on Forward+ or Mobile. It costs as much as the FFT
there and looks worse (§3). Switch back to FFT, or use `fft_resolution` 128 to save GPU time. Keep
fBm only to test, or when you need exact same-frame CPU heights.

**The ocean vanishes when the camera moves.** Its cull volume is sized from the node's Y and the wave
amplitude sum. Raise `cull_margin`.

**Water disappears at a distance you did not expect.** Check the half-extent formula in §10 — the
ocean is finite, and `mesh_lods` is what sets how far it goes.

**A boat floats above or below the surface.** Under the FFT, `get_water_height()` is one to three
frames behind the picture (§6); a fast sea moves visibly in that time. Under either model the drawn
mesh chords between vertices and sits slightly below the true surface at cell centres.

**A boat sinks.** Read the buoy's configuration warning: it quotes the displacement the body has and
the displacement it needs. See §5.

**A boat freezes mid-bob and stops responding.** It has not gone to sleep — that would fix itself on
the next swell (§5). Check instead that its `water_body` override, if it has one, is still in the
tree: a water body removed from the scene counts as no water, and the buoy stops applying force
rather than floating the boat on a plane nobody is drawing.

**A boat spins for too long, and changing `angular_drag` does nothing.** Angular damping is applied
once per body using the **largest** `angular_drag` among that body's buoys, so raising one of four
changes nothing unless it is already the largest. The buoy warns when a hull's values disagree.
