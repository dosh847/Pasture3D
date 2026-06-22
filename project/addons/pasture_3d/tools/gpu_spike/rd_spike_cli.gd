extends SceneTree
# CLI entry for the Phase 0 RD spike. Run from the repo's `project/` dir:
#   <godot4.7> --path . --rendering-driver vulkan --script res://addons/pasture_3d/tools/gpu_spike/rd_spike_cli.gd
# Uses a real Vulkan device (do NOT pass --headless; the dummy driver has no local RenderingDevice).

func _initialize() -> void:
	var core = load("res://addons/pasture_3d/tools/gpu_spike/rd_spike_core.gd").new()
	var res: Dictionary = core.run_all(func(s): print(s))
	quit(0 if res.get("ok", false) else 1)
