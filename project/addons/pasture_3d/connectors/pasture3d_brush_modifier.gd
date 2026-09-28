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


# ---- Spilling the frozen cache to disk (PASTURE3D_BAKE_MEMORY_SPEC.md M6) -----------------------------
#
# A FROZEN modifier's `_cache` is state, not a cache: it is served on every rebake until the user presses
# Bake, so dropping it would let the next rebake re-solve on whatever the surface is then. But it is also
# per brush and independent of which regions are loaded, so on a large world it grows with the brush count.
# A scoped bake that releases every region a brush touches spills that brush's caches here: written to one
# file and dropped from memory. The first accessor that needs them reads them back (`_unspill`) and deletes
# the file. A file that is missing or unreadable reads as "nothing cached", which is what every frozen
# modifier already is after a reload.
#
# THE RULE FOR SUBCLASSES: every accessor that reads or writes `_cache` calls `_unspill()` first, and every
# explicit drop (a Bake button, `clear_cache`) calls `_drop_spill()`. `cache_bytes()` does not unspill: it
# reports what memory holds, and a spilled cache holds none.

## Where spills go by default: per machine and unversioned (§11 decision 3), like the cache always was.
const SPILL_DIR := "res://.godot/pasture3d_frozen"

## The frozen cache, keyed by grid extent. Declared here, not per subclass, so the spill can reach it.
var _cache: Dictionary = {}
## The file `_cache` is spilled to, or "" while it is in memory.
var _spill_path: String = ""


func is_spilled() -> bool:
	return not _spill_path.is_empty()


## Write `_cache` to a file in `p_dir` and drop it from memory. Returns the bytes released, or 0 when there
## is nothing to spill or it cannot be: a value `store_var` cannot carry (an Object), or a failed write. The
## cache then stays in memory, which is exactly the behaviour before M6.
func spill_cache(p_dir: String = SPILL_DIR) -> int:
	if _cache.is_empty() or is_spilled() or not _plain(_cache):
		return 0
	var bytes := cache_bytes()
	DirAccess.make_dir_recursive_absolute(p_dir)
	var path := p_dir.path_join("%d_%d.spill" % [OS.get_process_id(), get_instance_id()])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return 0
	f.store_var(_cache)
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(path)
		return 0
	_cache = {}
	_spill_path = path
	return bytes


## Read a spilled cache back and delete its file. Anything stored since the spill wins over what the
## file holds (the accessors unspill first, so there should be nothing).
func _unspill() -> void:
	if _spill_path.is_empty():
		return
	var path := _spill_path
	_spill_path = ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var v = f.get_var()
		f.close()
		if v is Dictionary:
			(v as Dictionary).merge(_cache, true)
			_cache = v
	DirAccess.remove_absolute(path)


## Forget a spill without reading it: the explicit Bake, which re-solves anyway.
func _drop_spill() -> void:
	if _spill_path.is_empty():
		return
	DirAccess.remove_absolute(_spill_path)
	_spill_path = ""


func _notification(p_what: int) -> void:
	# Inline, not `_drop_spill()`: a script method cannot be called on an instance being deleted.
	if p_what == NOTIFICATION_PREDELETE and not _spill_path.is_empty():
		DirAccess.remove_absolute(_spill_path)


## Delete spill files another process left behind (a crash, a killed gate), once they are older than
## `p_max_age_sec`. A live process deletes its own files as it reads or frees them; the age guard is for a
## second Godot process on the same project, whose files are young. Returns how many were deleted.
static func sweep_spills(p_dir: String = SPILL_DIR, p_max_age_sec: int = 86400) -> int:
	var da := DirAccess.open(p_dir)
	if da == null:
		return 0
	var mine := "%d_" % OS.get_process_id()
	var now := int(Time.get_unix_time_from_system())
	var n := 0
	for f in da.get_files():
		if not f.ends_with(".spill") or f.begins_with(mine):
			continue
		var path := p_dir.path_join(f)
		if now - int(FileAccess.get_modified_time(path)) > p_max_age_sec and da.remove(f) == OK:
			n += 1
	return n


## True when `p_v` holds no Object at any depth: `store_var` cannot carry one without full objects, and a
## spill that silently turned one into null would lose state.
static func _plain(p_v: Variant) -> bool:
	match typeof(p_v):
		TYPE_OBJECT:
			return false
		TYPE_DICTIONARY:
			for k in p_v:
				if not _plain(k) or not _plain(p_v[k]):
					return false
		TYPE_ARRAY:
			for e in p_v:
				if not _plain(e):
					return false
	return true


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
