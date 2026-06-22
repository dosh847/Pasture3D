@tool
extends EditorScript
# In-EDITOR entry for the Phase 0 RD spike — this is the definitive Phase 0 gate per
# PASTURE3D_BRUSH_GPU_RASTER_SPEC.md §7 ("confirm a local RenderingDevice compute dispatch + readback
# completes INSIDE THE EDITOR, not just at runtime").
#
# To run: open this script in the Godot script editor and choose File > Run (Ctrl+Shift+X).
# Output appears in the Output panel.

func _run() -> void:
	var core = load("res://addons/pasture_3d/tools/gpu_spike/rd_spike_core.gd").new()
	core.run_all(func(s): print(s))
