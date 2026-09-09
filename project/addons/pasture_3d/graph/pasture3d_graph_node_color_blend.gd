# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeColorBlend — two COLOR inputs chosen between PER CELL by a mask field.
#
# ---- WHY THIS EXISTS ALONGSIDE COLOR MIX ----
#
# Color Mix folds two colours into ONE colour. That is all the colour sideband could carry: a COLOR wire
# is resolved at bake time by walking upstream, because the SSA program's buffers hold one float per cell
# and a colour is four. So a Mix is uniform over the whole footprint, and "snow on the high ground, rock
# below" is not something it can say — the Color Sink's mask decides WHERE the tint lands, not WHICH
# tint lands there.
#
# This node is the other half. Its `mask` port is a real FIELD, tapped from the program the same way the
# sink's own mask is, and the colour it publishes is a PackedColorArray — one Color per cell — rather
# than a single Color. Everything downstream that already asked a node for its colour keeps working,
# because the sink reads its colour through `color_at(values, cell)` and has done since it was written.
#
# ---- WHAT IT COSTS, SAID PLAINLY ----
#
# The mask is resolved by compiling and tapping its ancestry, which is a second evaluation pass over the
# bake grid on top of the sink's own. That is the price of a per-cell colour in a scalar program, it is
# paid once per Color Blend per bake, and it is paid only by graphs that contain one.
#
# When the mask is unwired there is nothing to tap and no field to publish, so the node falls back to a
# single uniform colour — the same answer Color Mix would give. That is stated rather than hidden: an
# unwired mask on a node whose whole purpose is the mask is worth noticing in the editor.
@tool
class_name Pasture3DGraphNodeColorBlend
extends Pasture3DGraphNode

## How A and B combine before the mask chooses between them. The same six folds as Color Mix, so there
## is one colour vocabulary rather than two. Values are serialised — append, never reorder.
enum Mode { MIX, ADD, SUB, MUL, SCREEN, OVERLAY }

## The fold applied to A and B. MIX is the plain "B where the mask is on".
@export var mode: Mode = Mode.MIX:
	set(v):
		mode = v
		emit_changed()

## Scales the mask. 1 lets a fully-on mask reach B completely; 0.5 stops halfway everywhere.
@export_range(0.0, 1.0, 0.001) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		emit_changed()

## Used for the `a` port when it is unwired — the colour the mask blends AWAY from.
@export var color_a: Color = Color.WHITE:
	set(v):
		color_a = v
		emit_changed()

## Used for the `b` port when it is unwired — the colour the mask blends TOWARDS.
@export var color_b: Color = Color.BLACK:
	set(v):
		color_b = v
		emit_changed()


func op() -> StringName:
	return &"color_blend"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var ca: Color = color_a if color_a is Color else Color.WHITE
	var cb: Color = color_b if color_b is Color else Color.BLACK
	p[0] = ca.get_luminance()
	p[1] = cb.get_luminance()
	p[2] = float(mode)
	p[3] = strength
	return {"params": p}


func role() -> Role:
	return Role.COMBINER


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["a", "b", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR, PortType.COLOR, PortType.MASK])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR])


## Which input port carries the field this node needs tapped. The resolver asks rather than assuming a
## position, for the same reason `aux_grid_port` exists on the native side: six ops once read their
## secondary grid from `in1` unconditionally, which was right for exactly one of them.
func color_mask_port() -> int:
	return 2


## The uniform answer, for when the mask is unwired or could not be tapped. Deliberately A rather than a
## half-and-half average: with no mask there is no "where", and A is the colour this node blends away
## FROM, so an unresolvable Blend reads as "unchanged" instead of inventing a midpoint.
func graph_color(p_upstream: Dictionary = {}) -> Color:
	var a = p_upstream.get("a", color_a)
	return a if a is Color else color_a


## One Color per cell. `p_upstream` maps the COLOR input names to what they resolved to — a Color, or
## itself a PackedColorArray when another Color Blend feeds this one. `p_mask` is the tapped field.
##
## A non-finite mask cell is "no opinion", which means 0 HERE and not 1: this node's unwired-mask answer
## is A, so an unreadable cell has to agree with it. The scalar Blend makes the opposite call for the
## opposite reason — its unwired mask is a filled 1.0. The two are consistent with their own defaults,
## which is the property that matters; see PASTURE3D_NODE_VOCABULARY.md.
func graph_color_cells(p_upstream: Dictionary, p_mask: PackedFloat32Array, p_n: int) -> PackedColorArray:
	var a = p_upstream.get("a", color_a)
	var b = p_upstream.get("b", color_b)
	var out := PackedColorArray()
	out.resize(p_n)
	for i in range(p_n):
		var ca := _at(a, i, color_a)
		var cb := _at(b, i, color_b)
		var m := 0.0
		if i < p_mask.size() and is_finite(p_mask[i]):
			m = clampf(p_mask[i], 0.0, 1.0) * strength
		out[i] = ca.lerp(_fold(ca, cb), m)
	return out


## The A/B fold, before the mask. Identical arithmetic to Color Mix's, per channel.
func _fold(p_a: Color, p_b: Color) -> Color:
	match mode:
		Mode.ADD:
			return Color(_c(p_a.r + p_b.r), _c(p_a.g + p_b.g), _c(p_a.b + p_b.b), p_a.a)
		Mode.SUB:
			return Color(_c(p_a.r - p_b.r), _c(p_a.g - p_b.g), _c(p_a.b - p_b.b), p_a.a)
		Mode.MUL:
			return Color(_c(p_a.r * p_b.r), _c(p_a.g * p_b.g), _c(p_a.b * p_b.b), p_a.a)
		Mode.SCREEN:
			return Color(_c(_screen(p_a.r, p_b.r)), _c(_screen(p_a.g, p_b.g)), _c(_screen(p_a.b, p_b.b)), p_a.a)
		Mode.OVERLAY:
			return Color(_c(_overlay(p_a.r, p_b.r)), _c(_overlay(p_a.g, p_b.g)), _c(_overlay(p_a.b, p_b.b)), p_a.a)
	# MIX is B outright, alpha included: it is the one mode where the mask IS the operation, and a
	# fully-transparent B has to be able to fade coverage out.
	return p_b


static func _at(p_v, p_i: int, p_fallback: Color) -> Color:
	if p_v is Color:
		return p_v
	if p_v is PackedColorArray and p_i < p_v.size():
		return p_v[p_i]
	return p_fallback


static func _c(p_x: float) -> float:
	return clampf(p_x, 0.0, 1.0)


static func _screen(p_x: float, p_y: float) -> float:
	return 1.0 - (1.0 - p_x) * (1.0 - p_y)


static func _overlay(p_x: float, p_y: float) -> float:
	return (2.0 * p_x * p_y) if p_x < 0.5 else (1.0 - 2.0 * (1.0 - p_x) * (1.0 - p_y))


## A COLOR is not a field, so there is no per-cell scalar to return. Nothing evaluates this node — its
## output travels the colour sideband, never the program — and 0.0 is what a node that produces no field
## owes the evaluator.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0
