# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Operation Builder for Pasture3D
extends RefCounted


const ToolSettings: Script = preload("res://addons/pasture_3d/src/tool_settings.gd")


var tool_settings: ToolSettings


func is_picking() -> bool:
	return false


func pick(p_global_position: Vector3, p_terrain: Pasture3D) -> void:
	pass


func is_ready() -> bool:
	return false


func apply_operation(editor: Pasture3DEditor, p_global_position: Vector3, p_camera_direction: float) -> void:
	pass
