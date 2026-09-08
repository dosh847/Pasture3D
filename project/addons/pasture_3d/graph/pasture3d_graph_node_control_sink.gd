# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeControlSink — paints the terrain's CONTROL map (base texture, overlay texture, blend)
# wherever its mask is on. PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.1: "a graph that computes a slope mask
# should be able to paint with it."
#
# Read Pasture3DGraphNodeChannelSink's header first — the write-stencil rule, the terminality, and why a
# negative index is refused rather than clamped all live there and are shared by all four sinks.
#
# ---- WHAT IT PRESERVES ----
#
# It authors base, overlay and blend, and copies the rest of the word — rotation, scale, hole, nav,
# autoshader, and bits 3–6 — from whatever is composited beneath it. That is the same discipline
# `pasture3d_splat.gd:201` follows (`| (cur & 0x6)`), for the same reason: the composite is topmost-
# covered-wins, so anything this sink does not carry forward is not blended with, it is DESTROYED. The
# four free bits are copied through untouched and never set; §12.15 is why there is nothing to set.
@tool
class_name Pasture3DGraphNodeControlSink
extends Pasture3DGraphNodeChannelSink

## Base texture index, used where the `base` port is unwired. 0..31; there is no NONE (see the base
## class header) — paint nothing by leaving the mask at zero.
@export_range(0, 31, 1) var base_texture: int = 0:
	set(v):
		base_texture = v
		emit_changed()

## Overlay texture index, used where the `overlay` port is unwired.
@export_range(0, 31, 1) var overlay_texture: int = 0:
	set(v):
		overlay_texture = v
		emit_changed()

## Base→overlay mix where the `blend` port is unwired. 0 = all base, 1 = all overlay.
@export_range(0.0, 1.0, 0.01) var blend_amount: float = 0.0:
	set(v):
		blend_amount = clampf(v, 0.0, 1.0)
		emit_changed()

## Keep the base texture already on the ground instead of authoring `base_texture`. The same option
## `pasture3d_splat.gd` carries, and for the same use: overlaying one material onto varied ground.
@export var preserve_base: bool = false:
	set(v):
		preserve_base = v
		emit_changed()


func op() -> StringName:
	return &"control_sink"


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["mask", "base", "overlay", "blend"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.INT, PortType.INT, PortType.MASK])


## The value/field split the PortType header requires: a value-typed port names a params slot, a
## field-typed one names -1. This node never lowers, so no kernel reads these slots — but the
## declaration is what the editor and GraphPortTypeGate [C] read to decide whether a port is a grid, and
## a node that got it wrong would advertise `base` as wirable from a height field.
func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 0, 1, -1])


## NOTHING is required. `base_texture` is an export and `base` is the port that overrides it, so this
## node always has a payload; overlay, blend and mask are all optional too. A bare Control Sink writes
## its base texture across the whole brush footprint at full strength.
##
## Requiring the `base` PORT would have blocked the default output exactly as the old mask requirement
## did. What the sink needs is a base texture VALUE, and it has one whether or not anything is wired.
func required_ports() -> PackedInt32Array:
	return PackedInt32Array()


func sink_map_type() -> int:
	return MAPTYPE_CONTROL


func sink_owner_suffix() -> String:
	return "#graph_control"


func sink_layer_label() -> String:
	return "Graph Control"


func sink_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not preserve_base:
		var m := index_refusal("Base texture", base_texture)
		if m != "":
			w.append(m)
	var m2 := index_refusal("Overlay texture", overlay_texture)
	if m2 != "":
		w.append(m2)
	return w


## p_values carries the resolved ports: "base"/"overlay" as ints, "blend" as a per-cell field or a scalar.
## p_below is the composited control word already on the ground at this cell.
func control_word(p_below: int, p_values: Dictionary, p_cell: int) -> int:
	var base_id: int = Pasture3DUtil.get_base(p_below) if preserve_base \
			else int(p_values.get("base", base_texture))
	var over_id: int = int(p_values.get("overlay", overlay_texture))
	if base_id < 0 or base_id > MAX_TEXTURE_INDEX or over_id < 0 or over_id > MAX_TEXTURE_INDEX:
		return -1 # Refused; sink_warnings() has already said why. Never clamped into a plausible texture.
	var blend: float = blend_amount
	var bf = p_values.get("blend", null)
	if bf is PackedFloat32Array and p_cell < (bf as PackedFloat32Array).size():
		blend = (bf as PackedFloat32Array)[p_cell]
	elif bf is float:
		blend = bf
	var blend_int: int = clampi(int(round(clampf(blend, 0.0, 1.0) * 255.0)), 0, 255)
	# Everything not authored here is carried through from below. See the header: under topmost-covered-
	# wins, "not carried" means "destroyed", not "left alone".
	var keep: int = p_below & 0x3FFF # rot(4) | scale(3) | free(4) | hole | nav | auto
	return Pasture3DUtil.enc_base(base_id) | Pasture3DUtil.enc_overlay(over_id) \
			| Pasture3DUtil.enc_blend(blend_int) | keep
