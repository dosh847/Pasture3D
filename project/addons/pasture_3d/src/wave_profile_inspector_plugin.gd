# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Puts the Wave Profiles row (wave_profile_row.gd) at the top of a Pasture3DPoolManager's Inspector, and its
# one-profile line under `wave_profile` on a Pasture3DOcean or Pasture3DPool. Not on a Pasture3DStream: its
# surface comes from its material's ripples, and it greys `wave_profile` out.

@tool
extends EditorInspectorPlugin

# Preloaded, not by class_name: see graph_inspector_plugin.gd.
const WaveProfileRow = preload("res://addons/pasture_3d/src/wave_profile_row.gd")

var plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object is Pasture3DPoolManager or p_object is Pasture3DOcean or p_object is Pasture3DPool


func _parse_begin(p_object: Object) -> void:
	if p_object is Pasture3DPoolManager:
		add_custom_control(WaveProfileRow.new().setup(p_object as Pasture3DPoolManager, plugin.get_undo_redo()))


func _parse_property(p_object: Object, _type: Variant.Type, p_name: String, _hint: PropertyHint,
		_hint_string: String, _usage: int, _wide: bool) -> bool:
	if p_name == "wave_profile" and not p_object is Pasture3DPoolManager:
		# Under the property, which keeps its own editor: hence false.
		add_custom_control(WaveProfileRow.new().setup_for_body(p_object as Node, plugin.get_undo_redo()))
	return false
