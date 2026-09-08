# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeColorMix — a COMBINER over the COLOUR sideband: two COLOR inputs folded by `mode`
# into one COLOR output, for wiring into a Color Sink or another Color Mix.
#
# ---- WHY THIS IS NOT A KERNEL OP, AND WHY THAT IS THE POINT ----
#
# The SSA program's buffers hold one float per cell. A colour is four, so a COLOR wire has never carried
# a value through the evaluator — the Color Sink resolves its colour port by walking UPSTREAM at bake
# time (Pasture3DGraphChannelSinks._color_of), which makes the colour a compile-time sideband rather
# than a field.
#
# So this node lowers to nothing. It has no `op()` a kernel would recognise, never lands in
# `graph_op_ids()`, and therefore cannot be the one op that drops the whole graph — erosion included —
# onto the GDScript evaluator (§10). That freedom is exactly why the colour vocabulary can grow here
# while the field vocabulary has to grow inside Blend's existing mode enum.
#
# The cost of the same choice: a colour is UNIFORM over the footprint. There is no per-cell colour, so
# "tint by the erosion mask" is not something this node can express. The mask on the Color Sink is what
# decides WHERE; this decides WHAT.
#
# ---- THE MODES ----
#
# MIX/ADD/SUB/MUL/SCREEN/OVERLAY are the same arithmetic as GraphBlendMode's, applied per channel,
# because two vocabularies for "screen" would drift. ALPHA is deliberately carried through MIX only:
# on every other mode the result keeps A's alpha, since the Color Sink reads alpha as coverage
# (see Pasture3DGraphNodeColorSink's header) and an arithmetic coverage is meaningless.
@tool
class_name Pasture3DGraphNodeColorMix
extends Pasture3DGraphNode

## Per-channel fold of A and B. Values are serialised, so append — never reorder.
enum Mode { MIX, ADD, SUB, MUL, SCREEN, OVERLAY }

## How A and B combine.
@export var mode: Mode = Mode.MIX:
	set(v):
		mode = v
		emit_changed()

## The blend weight. 0 is pure A, 1 is the full fold. Applied to every mode, so a MUL at 0.5 is
## halfway to the product rather than a second, hidden operation.
@export_range(0.0, 1.0, 0.001) var factor: float = 1.0:
	set(v):
		factor = clampf(v, 0.0, 1.0)
		emit_changed()

## Used for the `a` port when it is unwired.
@export var color_a: Color = Color.WHITE:
	set(v):
		color_a = v
		emit_changed()

## Used for the `b` port when it is unwired.
@export var color_b: Color = Color.BLACK:
	set(v):
		color_b = v
		emit_changed()


func op() -> StringName:
	return &"color_mix"


func role() -> Role:
	return Role.COMBINER


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["a", "b"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR, PortType.COLOR])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR])


## Fold this node's colour. `p_upstream` maps input NAMES to the Colors resolved from the wires; a name
## that is absent is unwired and falls back to the inline export, which is the declared default rather
## than an impostor (§4.4).
func graph_color(p_upstream: Dictionary = {}) -> Color:
	var a: Color = p_upstream.get("a", color_a)
	var b: Color = p_upstream.get("b", color_b)
	if not (a is Color):
		a = color_a
	if not (b is Color):
		b = color_b
	var r := a
	match mode:
		Mode.MIX:
			r = b
		Mode.ADD:
			r = Color(a.r + b.r, a.g + b.g, a.b + b.b, a.a)
		Mode.SUB:
			r = Color(a.r - b.r, a.g - b.g, a.b - b.b, a.a)
		Mode.MUL:
			r = Color(a.r * b.r, a.g * b.g, a.b * b.b, a.a)
		Mode.SCREEN:
			r = Color(_screen(a.r, b.r), _screen(a.g, b.g), _screen(a.b, b.b), a.a)
		Mode.OVERLAY:
			r = Color(_overlay(a.r, b.r), _overlay(a.g, b.g), _overlay(a.b, b.b), a.a)
	# MIX is the one mode that moves alpha, because there it IS the operation: lerping A to B without
	# its coverage would make a fully-transparent B paint at A's strength.
	var out := a.lerp(r, factor)
	if mode != Mode.MIX:
		out.a = a.a
	return Color(clampf(out.r, 0.0, 1.0), clampf(out.g, 0.0, 1.0), clampf(out.b, 0.0, 1.0),
			clampf(out.a, 0.0, 1.0))


static func _screen(p_x: float, p_y: float) -> float:
	return 1.0 - (1.0 - p_x) * (1.0 - p_y)


static func _overlay(p_x: float, p_y: float) -> float:
	return (2.0 * p_x * p_y) if p_x < 0.5 else (1.0 - 2.0 * (1.0 - p_x) * (1.0 - p_y))


## A COLOR is not a field, so there is no per-cell value to return. Nothing evaluates this node — see
## the header — and 0.0 is what a node that produces no field owes the evaluator.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0
