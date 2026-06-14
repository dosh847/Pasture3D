# Pasture3D Height-Map Layers — Architecture & Implementation Guide

> Goal: Add **non-destructive height-map layers** to Pasture3D. In the editor a
> terrain is authored as a *stack* of layers (a base plus any number of additive /
> override layers, each only as large as the pixels it actually touches, Krita-style).
> Sculpt tools and tool-API nodes (the **RoadPastureConnector** and friends) target a
> chosen layer. On scene save the stack is **flattened** into the existing
> `pasture3d_*.res` region maps that ship in-game, so there is **zero runtime cost** —
> layers are an editor-only authoring construct.

This guide surveys how other terrain systems and raster editors architect layers,
picks an architecture that fits Pasture3D's existing data model, and lays out an
incremental implementation plan with concrete C++ data structures and APIs.

---

## 1. What Pasture3D already is (and why it's 80 % of the way there)

The single most important fact for this design: **Pasture3D's data store is already a
sparse, tiled, copy-friendly image store** — essentially the same shape as Krita's
tile manager, just at a coarser granularity.

From `src/pasture_3d_data.h` / `pasture_3d_region.h`:

| Concept | Pasture3D today | Equivalent in a raster editor |
|---|---|---|
| World is divided into fixed tiles | `Pasture3DRegion`, default `SIZE_256` (256×256) | Krita 64×64 tiles |
| Sparse storage | `_regions : Dict[Vector2i → Pasture3DRegion]` — only allocated where data exists | tile hash map; absent tile = empty |
| Per-tile pixel data | `_height_map` (`FORMAT_RF`), `_control_map` (`RF`), `_color_map` (`RGBA8`) | per-tile channel planes |
| Stable address | `region_location : Vector2i` | tile coordinate |
| GPU upload | Images → `GeneratedTexture` TextureArrays (`_generated_height_maps` …) | composited surface → screen |
| Per-pixel write | `set_pixel(map_type, global_pos, color)` → region → `img_pos` | `Tile::setPixel` |
| Recompose to GPU | `update_maps(map_type, …)` | layer-stack recomposite |
| Persistence | one `pasture3d_<loc>.res` per region (`save_region`/`load_region`) | layered file on disk |
| Editing | `Pasture3DEditor` brush ops on the active region's images | brush on active layer |

So the height map you see today **is already the composited result of exactly one
(implicit) layer**. The job is to insert a stack *above* the storage layer: keep an
editor-side set of layers, composite them down into the same `Pasture3DRegion` images
that already drive the shader and collision, and persist the stack alongside the baked
regions.

Key code touch-points the design must respect:

- `Pasture3DData::set_pixel` / `get_pixel` — the per-vertex write path. Sculpt, the road
  connector, and import all funnel through `set_height`→`set_pixel`.
- `Pasture3DData::update_maps` — rebuilds the GPU TextureArrays from the region images;
  already supports "all regions" vs "only `is_edited()` regions".
- `Pasture3DData::save_directory` / `save_region` / `load_directory` — per-region `.res`
  I/O and the legacy-migration pattern (great template for adding a parallel layer file).
- `Pasture3DEditor::_operate_map` + undo (`_original_regions`, `backup_region`, `_store_undo`)
  — sculpt strokes and their undo snapshots.
- `RoadPastureConnector` — calls `terrain.data.set_height(...)` / `set_control_hole(...)`
  then `terrain.data.update_maps(...)`. Today it writes **destructively** into the base
  height map; layers fix this.

---

## 2. Prior-art survey

### 2.1 Unreal Engine — Landscape **Edit Layers** (the closest analogue)

Unreal's Landscape Edit Layers are the reference design for *non-destructive height
layers in a game terrain*:

- A landscape owns an **ordered stack of edit layers**. Sculpting and painting always
  target the **currently-active layer**; nothing is ever written directly to the final
  heightmap.
- Each layer stores a **per-component delta** — sparse, only where that layer was
  touched — not a full-resolution copy of the whole landscape.
- Each layer has an **alpha/weight**. A heightmap layer blends as an **additive** delta
  onto the layers below; a *negative* alpha subtracts. Layers can be hidden/locked.
- **Reserved / procedural layers**: e.g. a *Splines* layer that the spline tool renders
  into automatically, and *Patch*/*Brush* layers fed by procedural sources. The user's
  base sculpt stays untouched underneath while the spline layer re-renders on demand.
- At cook/runtime the stack is **collapsed (flattened) into a single heightmap** — the
  layers are an editor authoring structure with no runtime presence.

The lesson: *active-layer routing + sparse additive deltas + reserved layers driven by
tools + flatten-on-cook* is precisely the shape Pasture3D wants, and it maps cleanly onto
the road-connector use case (the connector owns a reserved layer).

### 2.2 Krita / Photoshop / GIMP — raster layer stacks

- **Tile-based, copy-on-write storage** (Krita: 64×64 tiles; GIMP similar). A layer
  allocates a tile only when a pixel in that tile is written; untouched tiles cost
  nothing and can be swapped/discarded. This is the "*only as large as it needs to be*"
  behaviour the user asked for.
- Each layer tracks a **bounds/extent** smaller than the canvas, an **opacity**, a
  **blend mode**, and **visibility/lock** flags.
- Compositing walks the stack **bottom-to-top**, blending each visible layer's covered
  pixels over the accumulator by its mode and opacity. Absent tiles are skipped.
- **Coverage matters**: a paint layer needs to know *which* pixels it actually owns
  (alpha), distinct from "owns a black pixel". Heightmaps have no natural alpha channel,
  so we must carry coverage explicitly (see §4.3).

### 2.3 Others, briefly

- **Unity Terrain** — "Terrain Layers" are *texture/splat* layers only; the heightmap is a
  single array. Layered heightmap authoring there is left to third-party tools (stamping,
  MicroSplat). Confirms that *texture layering ≠ height layering* — Pasture3D can lead here.
- **World Machine / Gaea** — node graphs rather than a paint stack, but the *combiner*
  nodes (Add/Max/Mask/Chooser) are exactly the blend modes a height stack needs, and they
  reinforce **Max/Min** as first-class height operators (stamp a hill = Max; carve a
  canyon = Min).

### 2.4 Principles distilled

1. **Non-destructive**: edits go to a layer, never the base. (UE)
2. **Sparse**: a layer stores only the tiles it touches. (Krita)
3. **Explicit coverage**: height needs a weight/alpha channel to blend correctly. (Krita)
4. **Height-appropriate blend modes**: Replace, Additive (signed), Max, Min. (UE + World Machine)
5. **Tool-owned layers**: generators (roads) render into their own reserved layer and can
   re-render it without disturbing hand-sculpting. (UE Splines layer)
6. **Flatten for runtime**: the shipped data is a single composited heightmap; the stack is
   editor-only. (UE cook)

---

## 3. Chosen architecture for Pasture3D

### 3.1 Two-tier model

```
EDITOR SOURCE OF TRUTH            COMPOSITED / RUNTIME
─────────────────────            ────────────────────
Pasture3DLayerStack              Pasture3DRegion images          GPU + collision
  ├─ Layer 0 "Base"  (dense) ─┐  (_height_map / _control_map)        │
  ├─ Layer 1 "Roads" (sparse)─┼─► composite(dirty area) ──► update_maps ──► shader
  ├─ Layer 2 "Detail"(sparse)─┘        ▲                                    │
  └─ …                                 │ live recomposite on every edit     ▼
                                                                       collision
  saved as pasture3d_layers*.res   saved as pasture3d_<loc>.res (UNCHANGED, ships in game)
```

- The **`Pasture3DRegion` images stay exactly what they are today**: the *composited
  result*. The shader, collision, `get_height`, and the runtime `.res` files are all
  unchanged. A build with no layer files behaves identically to today.
- The **layer stack** is a new editor-side resource. Every edit writes to a layer, then we
  **recomposite only the affected region(s)** back into the region images and call
  `update_maps` on them — so the viewport is always live, just as now.
- **Save** does two things: (a) write the layer stack (`pasture3d_layers*.res`) as the
  editing source, and (b) write the already-composited region images as `pasture3d_<loc>.res`
  (today's path). Shipping the game needs only the latter.

This gives Unreal-style non-destructiveness with **no runtime/VRAM cost** and a trivial
migration story.

### 3.2 Base layer is dense; everything above is sparse

Mirroring a raster editor's opaque background + transparent layers:

- **Layer 0 "Base"** — dense, region-granularity, `Replace` mode, opacity 1, full coverage.
  It *is* the absolute terrain. Migrating an existing terrain = adopt its current region
  height maps as the Base layer (see §7.3). Memory ≈ today.
- **Layers 1..n** — **sparse**, sub-region tiled (§4.2), additive/override. These are where
  "only as large as it needs to be" pays off: a road that crosses a 256² region in a 6 m
  strip allocates a handful of 64² tiles (~tens of KB), not a 256 KB region image.

### 3.3 Why this fits Pasture3D specifically

- Reuses the region/`region_map`/`update_maps`/save-load machinery; the composite target
  already exists.
- The runtime path is untouched → no perf risk, no shader changes, no `.res` format break.
- Sparse sub-region tiles give Krita memory behaviour exactly where it matters (thin
  generated features like roads, rivers, paths).
- Tool-API nodes get a clean "draw into *my* layer" contract, making them idempotent.

---

## 4. Data structures (new C++ classes)

Naming follows the existing `Pasture3D*` / `src/pasture_3d_*.{h,cpp}` convention.

### 4.1 Blend modes & layer metadata

```cpp
// pasture_3d_layer.h
class Pasture3DLayer : public Resource {
    GDCLASS(Pasture3DLayer, Resource);
public:
    enum BlendMode {
        REPLACE,   // result = lerp(below, value, weight*opacity)   (absolute authoring / Base)
        ADD,       // result = below + value * weight * opacity      (signed deltas; roads, detail)
        MAX,       // result = max(below, lerp(below, value, w*op))  (stamp hills, raise-only)
        MIN,       // result = min(below, lerp(below, value, w*op))  (carve, lower-only)
        BLEND_MAX,
    };

private:
    // Metadata (saved)
    String _name = "Layer";
    BlendMode _blend = ADD;
    real_t _opacity = 1.f;
    bool _visible = true;
    bool _locked  = false;
    bool _reserved = false;     // owned by a tool/node; user edits disabled (see §6)
    String _owner_id;           // optional: node path / generator id that owns it

    // Pixel data (saved). Sparse, sub-region tiles. See §4.2/4.3.
    //   _tiles[region_location][tile_coord] -> Ref<Image>(FORMAT_RGF: R=value, G=weight)
    Dictionary _tiles;          // Dict[Vector2i region_loc] -> Dict[Vector2i tile_coord] -> Image
    int _tile_size = 64;        // sub-region tile edge in vertices (power of two, <= region_size)
public:
    // value/weight access, allocating tiles on demand
    void   set_sample(const Vector2i &p_region_loc, const Point2i &p_px, real_t v, real_t w = 1.f);
    real_t get_value (const Vector2i &p_region_loc, const Point2i &p_px) const; // NAN if uncovered
    real_t get_weight(const Vector2i &p_region_loc, const Point2i &p_px) const; // 0 if uncovered
    Ref<Image> get_tile(const Vector2i &region_loc, const Vector2i &tile_coord) const;
    void clear_region(const Vector2i &p_region_loc);   // used by tools to re-render
    Rect2i covered_region_bounds() const;
    // … metadata getters/setters, _bind_methods …
};

// pasture_3d_layer_stack.h
class Pasture3DLayerStack : public Resource {
    GDCLASS(Pasture3DLayerStack, Resource);
    TypedArray<Pasture3DLayer> _layers;  // index 0 = Base (bottom), saved in order
    int _active_layer = 0;               // editor target (not saved, or saved as a hint)
public:
    int  add_layer(const String &name, Pasture3DLayer::BlendMode mode);
    void remove_layer(int idx);
    void move_layer(int from, int to);
    int  find_layer_by_owner(const String &owner_id) const; // for tool-API
    Pasture3DLayer *get_layer(int idx) const;
    int  get_active_layer() const { return _active_layer; }
    void set_active_layer(int idx) { _active_layer = idx; }
    // …
};
```

`MapType` reuse: a layer's value image is one map type at a time. v1 ships **height layers
only** (`TYPE_HEIGHT`). The same structure generalises to `TYPE_CONTROL` (holes / texture)
and `TYPE_COLOR` later — store a `MapType _map_type` on the layer and pick the image format
from the existing `FORMAT[]` table, with weight in a parallel channel.

### 4.2 Sparse sub-region tiling

A layer keeps a **two-level sparse map**: `region_location → (tile_coord → Image)`.

- Outer key reuses the engine's existing region grid so coordinate math, `region_map`, and
  per-region saving all line up with `Pasture3DData`.
- Inner key is a sub-region tile of `_tile_size` (default 64; region default 256 ⇒ 4×4
  tiles per region). A tile is allocated lazily on first write and freed when fully cleared.
- Going coarser is allowed: `_tile_size == region_size` degrades to region-granularity
  sparsity (simpler, more memory). This makes the tile size a single tunable knob — start
  the implementation at `_tile_size = region_size` (trivial, reuses region images verbatim)
  and add sub-tiling as a drop-in optimization once compositing works.

### 4.3 Coverage / weight channel

Height has no alpha, so each layer sample is **(value, weight)**:

- Store tiles as **`FORMAT_RGF`** (two 32-bit floats): `R = value`, `G = weight ∈ [0,1]`.
  (Alternatively a parallel `R8`/`RF` mask image per tile — RGF keeps it to one image and
  blits atomically.)
- `weight == 0` ⇒ pixel not owned by this layer ⇒ skipped in compositing.
- Brush strokes accumulate weight like the existing brush alpha; the road connector writes
  `weight = 1` inside the road, feathering to 0 across `edge_falloff`.
- **⚠ Coverage vs. NaN (Phase 3 finding).** `get_weight()` is the authoritative "is this pixel
  owned?" signal — *not* a NaN `get_value()`. `get_value()` returns NaN **only when no tile exists**
  at that coordinate. With the current `_tile_size == region_size` default, the *first* `set_sample`
  in a region allocates the one region-sized tile, so every other pixel in that region is now
  "allocated but uncovered": `get_weight == 0` and `get_value == 0` (the zero fill), **never NaN**.
  Compositing already does the right thing (it tests `weight == 0` first and skips). Phase 4 code and
  tests must gate coverage on `weight`, not on `isnan(value)`. Sub-region tiling (phase 6) makes NaN
  meaningful again for *whole absent tiles*, but within an allocated tile weight is always the signal.
- The **Base layer** can skip the weight channel (always-covered) and stay a plain `RF`
  region image == today's `_height_map`, to avoid doubling Base memory. (Phase 1/2 alias the
  Base tile directly onto the region image. This is correct for load + a single flatten but
  must be un-aliased before live re-compositing — see the ⚠ note in §5.1.)

---

## 5. Compositing pipeline

### 5.1 Algorithm (per affected region, dirty-scoped)

```
for each pixel p in dirty_rect of region R:
    acc = NAN                                  # or read existing if partial
    for layer L in stack (bottom→top):
        if not L.visible: continue
        (v, w) = L.sample(R, p)                # Base: w=1, v=height
        if w == 0: continue
        a = w * L.opacity
        switch L.blend:
            REPLACE: acc = isnan(acc) ? v : lerp(acc, v, a)
            ADD:     acc = (isnan(acc)?0:acc) + v * a
            MAX:     acc = max(acc, lerp(acc, v, a))
            MIN:     acc = min(acc, lerp(acc, v, a))
    R._height_map.set_pixel(p, acc)            # writes the composited region image
R.set_edited(true)
data.update_maps(TYPE_HEIGHT, /*all_regions=*/false)  # only edited regions go to GPU
```

- **Dirty-scoped**: only recomposite the region rect an edit touched. Reuse the editor's
  existing `add_edited_area` / `_modified_area` and the `is_edited()` fast path in
  `update_maps` — this is already how strokes update the GPU today.
- **Holes / control**: control is a packed `uint32`, not blendable as a float. For v1 keep
  holes on the Base/composited control map (road connector's `set_control_hole` path
  unchanged). When control layers arrive, composite control by **topmost-covered-wins**
  (no arithmetic blend) rather than lerp.
- **NaN**: NaN already means "hole" in `get_height`. Compositing must treat an
  all-uncovered pixel as "fall through to Base"; Base is always covered so the accumulator
  is defined wherever the terrain exists.

> **⚠ Implementation note — Base-layer aliasing (Phase 2 finding).**
> `_synthesize_base_layer` makes the dense Base layer **alias** each region's `_height_map`
> (FORMAT_RF, zero-copy, §4.3), and `composite_region` writes its result back into that *same*
> image. Per pixel this is safe: the Base value is read into the accumulator *before* the
> composited value is written, and pixels are independent — so a **single composite pass is
> correct**, and the Base-only case is byte-identical (verified by `test_layer_compositing`).
>
> It is **not safe to re-composite the same region repeatedly** once `ADD`/`MAX`/`MIN` layers
> exist: the second pass would read an *already-composited* Base and re-accumulate the deltas
> (e.g. an `ADD` layer would apply twice). v1 ships with Base aliased on purpose (the memory
> win, and identity correctness for load + a single flatten). **Before Phase 4's live
> per-stroke re-compositing lands, the Base layer must own its own source image** so the
> composite *target* (`region->_height_map`) and the Base *source* are distinct buffers.
> Options: un-alias the Base (deep-copy its tile) the first time a non-Base layer is added, or
> always give Base its own buffer and treat the region image purely as the composite output.
> A REPLACE-only stack stays safe under aliasing because REPLACE overwrites rather than
> accumulates, but don't rely on that — the un-alias fix is the clean solution.

### 5.2 When compositing runs

- **On every sculpt stroke / tool write** — incrementally, dirty-scoped, for live preview.
- **On layer property change** (visibility, opacity, blend, reorder) — recomposite the
  union of that layer's covered regions.
- **On save** — guaranteed full pass is unnecessary if live compositing is correct; just
  persist. (Offer an explicit "Rebake all" action for safety / after format upgrades.)

---

## 6. Editor UX & sculpt routing

- **Layers panel** (new dock or a section of the Pasture3D tool panel): list with
  drag-reorder, add/remove/duplicate, and per-row visibility, lock, opacity slider, blend
  dropdown. Active layer is highlighted.
- **Active-layer routing**: `Pasture3DEditor::_operate_map` currently writes via
  `data.set_pixel`. Change it to write into `stack.get_active_layer()` (allocating tiles),
  then recomposite the stroke's dirty rect. If the active layer is **locked** or
  **reserved**, block the stroke and flash a warning (UE behaviour).
- **Per-tool default layer**: optionally remember a preferred layer per `Tool` so switching
  to Sculpt selects the user's sculpt layer automatically.
- **Undo/redo**: today the editor snapshots whole `Pasture3DRegion`s
  (`_original_regions`/`backup_region`). Extend to snapshot the **active layer's touched
  tiles** before a stroke (cheap — they're small and sparse) plus the recomposited region
  images, so undo restores both source and composite. Keep using `EditorUndoRedoManager`.

---

## 7. Persistence & migration

### 7.1 File layout

Reuse the per-region directory convention so layers stream and diff like regions do:

| File | Contents | Ships in game? |
|---|---|---|
| `pasture3d_<loc>.res` | composited `Pasture3DRegion` (height/control/color) — **today's format, unchanged** | **Yes** |
| `pasture3d_layers.res` | `Pasture3DLayerStack` manifest: ordered layer metadata (name, blend, opacity, flags, owner_id), `_tile_size`, format version | No |
| `pasture3d_layers_<loc>.res` | per-region slice: each layer's sparse tiles that fall in `<loc>` | No |

- The manifest holds global order/metadata; per-region files hold the pixels, so large
  worlds stay sparse and a region's layer data loads with its region. (For a v1 prototype
  you may embed everything in a single `pasture3d_layers.res` — a `Dict[region_loc →
  Dict[layer_idx → tiles]]` — and split per-region later. Decide based on world size; see §11.)
- Add a `_version` to the stack resource exactly like `Pasture3DRegion::_version` so future
  format bumps upgrade gracefully.

### 7.2 Save flow (`save_directory` extension)

```
save_directory(dir):
    composite_all_dirty()                 # ensure region images are current
    for loc in _regions: save_region(...) # UNCHANGED → pasture3d_<loc>.res (runtime)
    if has_layer_stack:
        save layer manifest  → dir/pasture3d_layers.res
        for loc: save tiles  → dir/pasture3d_layers_<loc>.res
```

A game build simply ships the `pasture3d_<loc>.res` files and omits the `*_layers*` files —
nothing to strip, no runtime branch.

### 7.3 Loading & migrating existing terrains

```
load_directory(dir):
    load pasture3d_<loc>.res            # as today → composited region images
    if pasture3d_layers.res exists:
        load stack + per-region tiles
    else:
        synthesize a single dense "Base" layer that references the loaded region
        height maps (no pixel copy needed if Base aliases the region image)
```

So **every existing terrain opens as a one-layer stack** with no conversion step, and only
gains extra layers when the user/tools add them. This matches the legacy-`terrain3d`
migration philosophy already in `load_directory`.

---

## 8. Tool API — nodes that draw into a layer

This is the feature that makes the **RoadPastureConnector** non-destructive and is the main
reason to build layers.

### 8.1 Contract

A generator node **owns a reserved layer** identified by a stable `owner_id` (e.g. the
node's scene-unique name). On each refresh it:

1. resolves/creates its layer: `int lyr = stack.find_or_create_layer(owner_id, ADD)`;
2. **clears its layer in the affected regions** (`layer.clear_region(loc)`), so stale road
   geometry from a previous pose vanishes — no manual undo of old edits;
3. writes its samples into that layer instead of the base;
4. triggers a dirty-scoped recomposite.

Because the node only ever touches *its own* layer, hand-sculpting underneath is preserved,
and re-running the road tool is **idempotent**.

### 8.2 Proposed `Pasture3DData` additions

```cpp
// Layer-targeted writes (mirror existing absolute-write helpers)
void   set_height_on_layer(int layer_id, const Vector3 &pos, real_t height, real_t weight = 1.f);
void   add_height_on_layer (int layer_id, const Vector3 &pos, real_t delta,  real_t weight = 1.f);
real_t get_layer_height(int layer_id, const Vector3 &pos) const;

// Stack management surfaced for tools
int  get_layer_stack_size() const;
int  find_layer_by_owner(const String &owner_id) const;
int  create_owned_layer(const String &owner_id, const String &name, int blend_mode);
void clear_layer_in_area(int layer_id, const AABB &area);
void set_active_layer(int layer_id);
int  get_active_layer() const;
```

These bind in `_bind_methods` so GDScript nodes can call them, exactly like the connector
already calls `set_height` / `set_control_hole` / `update_maps`.

### 8.3 RoadPastureConnector changes (illustrative)

```gdscript
@export var target_layer_name := "Roads"      # new export
var _layer_id := -1

func _ensure_layer() -> void:
    var owner := str(get_path())              # stable owner id
    _layer_id = terrain.data.find_layer_by_owner(owner)
    if _layer_id < 0:
        # ADD so the road can sink terrain by `offset` as a signed delta,
        # or REPLACE if you prefer absolute road heights. (see §3.1 blend modes)
        _layer_id = terrain.data.create_owned_layer(owner, target_layer_name,
                        Pasture3DLayer.BlendMode.REPLACE)

func refresh_roads(mesh_parents: Array) -> void:
    _ensure_layer()
    terrain.data.clear_layer_in_area(_layer_id, _affected_aabb(mesh_parents)) # drop old road
    # … existing geometry loop, but replace:
    #     terrain.data.set_height(terrain_pos, road_y)
    #   with:
    terrain.data.set_height_on_layer(_layer_id, terrain_pos, road_y, weight)  # weight feathers falloff
    terrain.data.update_maps(PASTURE_3D_MAPTYPE_HEIGHT)
```

Notes:
- `weight` lets the connector express its `edge_falloff` as coverage (1 on the road, easing
  to 0), so the composite naturally feathers into whatever is underneath — removing the
  current `get_height`→`_lerp_smoothed_height` read-modify-write against the base.
- Hole carving (`set_control_hole`) stays on the composited control map for v1; promote it
  to a control layer when control layering lands.
- Backward-compat: if no stack exists (layers feature disabled), `set_height_on_layer`
  falls back to `set_height` so the connector keeps working on plain terrains.

---

## 9. Performance & memory

- **Memory**: a 64² RGF tile = 64·64·8 B = **32 KB**. A 256² region RF image = 256 KB. A
  road across one region in a 64-wide tile band touches ~4–8 tiles ≈ 128–256 KB per region
  *only on layers that road touches* — vs. a full extra 256 KB region image per layer at
  region granularity. Sub-tiling matters most for many thin generated layers.
- **Compositing cost** scales with `dirty_pixels × visible_layers_covering_them`. Strokes
  are tiny; layer-property changes recomposite a layer's bounds. Keep the bottom-up loop
  branch-light (precompute the list of layers covering a region).
- **Threading**: compositing is per-region and embarrassingly parallel; it can reuse
  whatever threading `update_maps` already tolerates. Start single-threaded, measure.
- **GPU**: unchanged — only the final composited region images upload, exactly as now.

---

## 10. Implementation phases

Each phase is independently testable and leaves `main` shippable.

1. ✅ **Core classes, no UX.** `Pasture3DLayer` (start with `_tile_size = region_size`, RGF
   tiles), `Pasture3DLayerStack`, bound to GDScript. `Pasture3DData` holds an optional
   stack; `load_directory` synthesizes the Base layer. No behaviour change yet. **(Done.)**
2. ✅ **Compositing.** Implement `composite_region(loc, dirty_rect)` + REPLACE/ADD/MAX/MIN.
   Wire `update_maps` to read composited images. Unit-test: Base-only composite == identity
   with today's output. **(Done — see `composite_region`/`composite_regions` in
   `pasture_3d_data.cpp` and `test_layer_compositing` in `unit_testing.cpp`; surfaced the
   Base-aliasing caveat in §5.1.)**
3. ✅ **Persistence.** Save/load `pasture3d_layers*.res`; round-trip test; verify a build with
   no layer files is byte-identical in the runtime `pasture3d_<loc>.res`. **(Done — `save_layers`/
   `load_layers` in `pasture_3d_data.cpp`, wired into `save_directory`/`load_directory`;
   `Util::location_to_layer_filename`; `test_layer_persistence` in `unit_testing.cpp`, 24/24 PASSED.
   Manifest + per-region split implemented directly; Base pixels never serialized, re-aliased on
   load; load does NOT re-composite to avoid the §5.1 ADD double-apply.)**
4. ✅ **Editor routing + Layers panel.** Active-layer sculpting, visibility/opacity/blend/lock,
   reorder; undo/redo of layer tiles. **(Done — see below.)**
5. **Tool API + RoadPastureConnector.** `*_on_layer` / owned-layer methods; migrate the
   connector to a reserved "Roads" layer; confirm re-running roads is idempotent and base
   sculpt survives.
6. **Sub-region tiling optimization.** Drop `_tile_size` to 64/128; verify memory win on a
   road-heavy scene. (Pure optimization — composite/coordinate code already abstracts it.)
7. **(Later) Control & color layers.** Holes/texture/color layers using topmost-covered
   compositing for control; extends the road connector's hole carving to a layer.

### 10.4 Phase 4 implementation notes (done)

- **Un-alias the Base (the §5.1 prerequisite).** `Pasture3DData` detects aliasing by pointer identity
  (`_is_base_aliased()` — a Base tile that *is* the region's `_height_map` Ref) so no persisted flag is
  needed. `_unalias_base_layer()` deep-copies each aliased Base tile into a buffer the Base owns; it
  fires the first time a non-Base layer is added (`layer_add`, idx>0) and on multi-layer load. After
  that the composite *target* (region image) and Base *source* are distinct, so per-stroke
  re-compositing is idempotent. Regression guard: `test_layer_idempotent_composite` (5× composite of an
  ADD stack, no drift).
- **Routing predicate.** `Pasture3DData::is_layer_routing()` = stack exists **and** Base is un-aliased.
  A freshly loaded *plain* terrain keeps the Base aliased ⇒ routing **off** ⇒ sculpting writes the
  region image directly exactly as before (zero behaviour change until the user adds a layer).
- **Sculpt routing.** `Pasture3DEditor::start_operation` captures the active height layer into
  `_stroke_layer` for SCULPT/HEIGHT when routing is on; a locked/reserved active layer sets
  `_stroke_blocked` and flashes a warning (plugin → `flash_layer_warning` → Layers dock). In
  `_operate_map`, height writes go to `_stroke_layer->set_sample(..., value=destf, weight=1)` (the brush
  still reads `srcf` from the live composited region map, so it feels identical), and the touched
  per-region rects are recomposited (dirty-scoped) before the existing `update_maps` upload. Hand-sculpt
  layers therefore behave as REPLACE/absolute authoring; ADD/MAX/MIN are for tool-driven layers (Phase 5).
- **Undo/redo.** Alongside the existing whole-region snapshots, a stroke deep-snapshots the active
  layer's touched tiles before/after (`Pasture3DLayer::duplicate_region_tiles` / `restore_region_tiles`)
  and stores them under `layer_tiles` in the same `EditorUndoRedoManager` action, so undo restores both
  the layer **source** and the composited region image. Guard: `test_layer_undo_restore`.
- **⚠ Persistence change (supersedes the Phase 3 "Base pixels never serialized" rule).** Once the Base
  is un-aliased it holds *true base heights* that the flattened `pasture3d_<loc>.res` no longer carries,
  so `save_layers` now serializes the Base's own tiles too (only while un-aliased; an aliased/plain Base
  is still skipped). `load_layers` loads them and leaves the Base un-aliased (routing stays on); only
  regions lacking persisted Base pixels are re-aliased onto the runtime maps. The shipped runtime files
  are unchanged. Cost: per-region layer slices now include a dense Base RF tile (~region-map size) for
  layered terrains — acceptable for editor-only data. Round-trip guard: `test_layer_base_persistence`
  (Base buffer ≠ flattened map; a post-load composite reproduces the runtime image byte-for-byte).
- **Layers panel** (`project/addons/pasture_3d/src/layers_dock.gd`, docked via `add_control_to_dock`):
  top-first list with add / duplicate / remove / move-up / move-down **and** drag-reorder, per-row
  visibility, name, blend, opacity, lock, and a highlighted active row. Structural/visual changes call
  the bound `Pasture3DData::layer_*` / `recomposite_layer` helpers, which un-alias and dirty-scope
  recomposite as needed. New Data binds: `is_layer_routing`, `layer_add`, `layer_duplicate`,
  `layer_remove`, `layer_move`, `recomposite_layer`.

---

## 11. Settled decisions

These four were confirmed and are now binding for the implementation:

1. **Layer file granularity = manifest + per-region.** Global `pasture3d_layers.res`
   manifest (ordered metadata) plus per-region `pasture3d_layers_<loc>.res` pixel slices
   (§7.1), so layers stream and scale with the world. The single-file form is acceptable
   only as a throwaway phase-3 prototype before the per-region split lands.
2. **Road blend mode = `REPLACE`.** Roads author absolute height; the connector's
   `edge_falloff` is expressed as coverage weight that feathers the shoulder into whatever
   is underneath (§8.3). `ADD` is reserved for detail/erosion layers, not roads.
3. **Default `_tile_size` = 64.** Matches the default region size of 256 (4×4 tiles/region)
   and keeps thin generated features (roads, paths, rivers) maximally sparse (§4.2, §9).
4. **v1 is height-only.** Holes and texture/color stay on the composited control/color maps;
   the road connector keeps carving holes via `set_control_hole` until control layering
   arrives in phase 7. No control/color layers ship in v1.

---

## Sources

- [Landscape Edit Layers — Unreal Engine 5.7 docs](https://dev.epicgames.com/documentation/unreal-engine/landscape-edit-layers-in-unreal-engine)
- [Landscape Sculpt Mode — Unreal Engine 5.7 docs](https://dev.epicgames.com/documentation/unreal-engine/landscape-sculpt-mode-in-unreal-engine)
- [Complete Guide to Non-Destructive Landscape Layers — World of Level Design](https://www.worldofleveldesign.com/categories/ue4/landscape-layers-01-sculpting.php)
- [Krita `Tile` (64×64 planar tile) — paint_layer docs](https://docs.rs/krita/latest/krita/paint_layer/struct.Tile.html)
- [How Krita renders tiles / tile manager discussion](https://kimageshop.kde.narkive.com/krDHO1YW/how-does-krita-render-tiles-to-the-screen)
- Pasture3D source: `src/pasture_3d_data.{h,cpp}`, `src/pasture_3d_region.h`, `src/pasture_3d_editor.h`, `project/addons/pasture_3d/connectors/road_connector.gd`
</content>
</invoke>
