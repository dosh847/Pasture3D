# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Puts the Wave Profiles row (wave_profile_row.gd) at the top of a Pasture3DPoolManager's Inspector.

@tool
extends EditorInspectorPlugin

# Preloaded, not by class_name: see graph_inspector_plugin.gd.
const WaveProfileRow = preload("res://addons/pasture_3d/src/wave_profile_row.gd")

var plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object is Pasture3DPoolManager


func _parse_begin(p_object: Object) -> void:
	add_custom_control(WaveProfileRow.new().setup(p_object as Pasture3DPoolManager, plugin.get_undo_redo()))
