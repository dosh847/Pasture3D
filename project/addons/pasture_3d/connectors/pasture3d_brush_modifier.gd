# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNode — abstract base for one step of a landscape brush's node stack: an ordered,
# saveable list of operations applied to the brush's OWN output grid, after its profile is rasterised and
# BEFORE that grid is composited into the terrain layer.
#
# The stack is not a new idea in this plugin so much as an existing one made visible. `stamp_mound_loop`
# already runs `profile -> +noise -> +relief -> blur -> composite` with a fixed order, no repeats and no
# way to insert anything between the steps. Phase 3a of PASTURE3D_BRUSH_EROSION_SPEC.md turns that fixed
# pipeline into this list; the three nodes shipped with it reproduce it exactly.
#
# ---- CELL vs GRID, the distinction the whole design rests on (spec §6.1) ----
#
# A CELL node sees one cell and its own coordinates. It contributes metres to the brush's amplitude
# at that cell and can be evaluated inside the rasteriser's own loop, in double precision, alongside the
# profile. Noise and Relief are cell nodes, and so is every relief op.
#
# A GRID node needs the whole grid: a blur reads neighbours, an erosion solve routes water across
# the entire footprint. It cannot be expressed as a relief op — `relief_eval(u, v)` has no grid to look
# at — which is the structural reason this stack has to exist at all rather than erosion becoming
# another entry in the relief op catalogue.
#
# The host rasteriser exploits the split: a maximal RUN of cell nodes is folded into one cell loop,
# and only a grid node forces the working grid to be materialised. A stack of `Noise -> Relief ->
# Smooth` therefore executes as one cell loop plus one blur — which is, instruction for instruction, the
# pipeline it replaces. That is what makes gate BW's "bitwise identical" claim reachable rather than
# aspirational.
@tool
class_name Pasture3DNode
extends Resource

## The name on this modifier's ROW in the brush's Modifiers list. Without it a stack of three Relief
## steps reads as three identical `Pasture3DNodeRelief` rows and the only way to find the one you want is
## to open each in turn.
##
## It is a VIEW ONTO `resource_name`, not a second field. Godot's resource picker already prefers
## `resource_name` over the class name when it draws the row, so the storage and the wiring both exist —
## it is just buried at the bottom of the built-in Resource section where nobody looks. Declaring a
## second string would only give the two a way to disagree, so this one is EDITOR-usage only: it is not
## saved, because `resource_name` already is.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var label: String:
	set(v):
		# `Resource.set_name` emits `changed` itself, which is what relabels the row: the host brush
		# rebuilds its property list when — and only when — a modifier's name or the mask-preview list
		# moves (see Pasture3DTerrainBrush._on_modifier_changed).
		resource_name = v
	get:
		return resource_name

## LIVE recomputes on every refresh; FROZEN caches its output and re-solves only when it has nothing
## cached, or on an explicit Bake.
##
## Hidden on the modifiers that do not support it — see `_supports_freezing`. Shipping a control that
## silently does nothing is worse than not shipping it.
enum Evaluation { LIVE, FROZEN }

## Off leaves the modifier in the list, and in the inspector, without applying it. The point is A/B
## comparison: the alternative is deleting a configured modifier to see what it was doing, and then
## rebuilding it.
@export var enabled: bool = true:
	set(v):
		enabled = v
		_touch()


## Whether this modifier recomputes on every refresh, or caches. See `_supports_freezing` for why it is
## only meaningful on some of them.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		_touch()


## True when this modifier is expensive enough that caching its output is worth a staleness problem.
##
## FALSE by default, and the property is hidden when it is. `auto_refresh` re-bakes on every spline drag,
## which is fine for noise, relief and a blur — they cost microseconds. Freezing one of those would be a
## cache for something cheaper than the cache, plus a way for the viewport to disagree with the inspector.
func _supports_freezing() -> bool:
	return false


func _validate_property(property: Dictionary) -> void:
	if property.name == "evaluation" and not _supports_freezing():
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Invalidate and notify the host brush to re-bake. Every exported setter must call this. Mirrors
## Pasture3DReliefMaterial._touch, and for the same reason: the brush listens to `changed` and has no
## other way to learn that a nested resource moved.
func _touch() -> void:
	emit_changed()


## True when this step needs the whole grid rather than one cell. See the header.
func needs_grid() -> bool:
	return false


## Wire tag the native rasteriser dispatches on. MUST match the string the C++ side reads from the
## `op` key and tests in the node dispatch loop (src/pasture_3d_brush_raster.cpp).
func op() -> StringName:
	return &""


## False when the modifier is present but would contribute nothing — disabled, or configured to zero.
## The host skips it entirely rather than paying for a no-op pass, and, more to the point, a stack whose
## only relief modifier is inactive must not make the brush build the O(cells) field grids for it.
func is_active() -> bool:
	return enabled


## The per-node block handed to the native rasteriser. `op` is added by the caller, and so is the
## cache plumbing for a node that supports freezing.
func to_params() -> Dictionary:
	return {}


## This modifier's whole-grid pass, for a `needs_grid()` step on the GDScript path. The default is the
## identity, which is right for a point modifier — it contributes through `eval_point`, not here.
##
## `p_step` is this modifier's own compiled block; `p_ctx` carries the grid geometry and, in `host`, the
## brush running the stack. Returning `p_vals` unchanged is the honest answer for a node with no grid
## pass; the bug this replaces is a node that HAS one and never gets asked.
##
## It used to be a hardcoded `if`-chain on `op()` in `_apply_field_step`, four arms deep, falling through
## to `return p_vals`. A new grid modifier that forgot to edit that chain did NOTHING, with no error and
## no warning: the brush painted, the stack reported the step, and its pass simply never ran. Dispatching
## through the node makes forgetting unrepresentable — a subclass that does not override this has said so.
func apply_field(_p_step: Dictionary, p_vals: PackedFloat32Array, _p_ctx: Dictionary) -> PackedFloat32Array:
	return p_vals


## True when this modifier cannot run on the native rasteriser and forces the whole stamp to GDScript.
##
## `p_host` is the brush, because the answer is not always a property of the modifier alone: a road
## grader is native only when `stamp_road_line` exists AND it is the stack's only active step. The same
## op-string set used to be re-enumerated in `_stack_forces_gdscript`, so the list of grid ops and the
## list of ops that can bail were two lists that had to agree.
func forces_gdscript(_p_host) -> bool:
	return false


## The deferred-solve entry for this modifier, or `{}` when it has nothing to defer.
##
## `p_out` is the slot the rasteriser wrote during pass 1; a `pending` key in it means the surface that
## WOULD have been solved is waiting. Called for every step that produced one, so a modifier that defers
## says so here rather than being recognised by its class at the call site — which is what used to
## happen, as `m is Pasture3DNodeErosion` / `elif m is Pasture3DNodeGraph`, with a third deferring
## modifier matching neither branch and being dropped in silence.
func make_pending(_p_out: Dictionary, _p_extent: String) -> Dictionary:
	return {}


## Which of the host's deferred queues `make_pending` builds for. Only meaningful when it builds one.
func pending_queue() -> StringName:
	return &""


## True when this modifier needs the working surface at its own position in the stack captured and handed
## back to it. Default false.
##
## The host used to ask this as `m != null and "material" in m and m.material != null and
## m.material.has_method("set_seed_surface")` — a four-deep inline capability probe inside a generic
## loop, which is a type switch spelled as duck-typing. It also answered for the wrong object: `"material"
## in m` is a fact about the modifier, `has_method` a fact about its material, and neither is a fact about
## whether this bake should capture.
func wants_seed_surface() -> bool:
	return false


## Take the captured surface. `p_surface` carries the grid, its dimensions and the loop's ORIENTED frame —
## the two rectangles differ, and on a rotated loop a plain rescale between them would shear the ridges
## off their own crest lines. Returns true when the modifier actually consumed it, which is what tells the
## host another bake is needed.
func take_seed_surface(_p_surface: Dictionary) -> bool:
	return false


## Drop every cached output. The host calls this on an explicit Bake; a modifier that caches nothing has
## nothing to do.
func clear_cache() -> void:
	pass


## Cached bytes currently held, so the brush can report a budget nobody would otherwise see.
func cache_bytes() -> int:
	return 0


## Problems worth telling the user about, in the host brush's configuration warnings. `p_host` is the
## Pasture3DTerrainBrush this modifier is mounted on — some complaints are only true for a given host
## (a Host Profile selector under a Plow, say), so the modifier has to be able to ask.
func modifier_warnings(_p_host) -> PackedStringArray:
	return PackedStringArray()


## Human-readable name for warnings: the label the user gave this modifier, or the class name with the
## Pasture3DMod prefix stripped. Warnings say which modifier they are about, and in a stack with three
## Relief steps "Relief modifier" on its own does not.
func display_name() -> String:
	if not resource_name.is_empty():
		return resource_name
	return String(get_script().get_global_name()).trim_prefix("Pasture3DMod")
