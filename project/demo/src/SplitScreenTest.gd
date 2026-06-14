# Pasture3D — multi-camera split-screen clipmap test.
#
# Four SubViewports share ONE World3D and therefore ONE Terrain3D (one Terrain3DData in VRAM).
# Each viewport has its own Camera3D; terrain.set_cameras([...]) renders a separate geo-clipmap per
# camera, each snapped + LOD'd to its own camera, isolated by render layer via per-camera cull_mask.
# Gameplay markers live on layers 1-16 so every viewport sees them — only the terrain LOD is per-view.
#
# What to look for:
#   * Each quadrant shows high-detail terrain around ITS player, regardless of where the others are.
#   * As cameras separate, no quadrant's nearby ground drops to coarse LOD (the bug this fork fixes).
#   * All four colored markers ("karts") are visible in every quadrant (shared gameplay layers).
#   * No one falls through: collision is a single FULL_GAME shape, independent of cameras.
#   * VRAM stays ~ a single terrain copy (check your GPU profiler) even with 4 views.
extends Control

const GAMEPLAY_MASK: int = 0x0FFFF # Layers 1-16, seen by every camera
const TERRAIN_TOP_BIT: int = 19 # Camera 0 -> layer 20 (bit 19), descending
const PLAYER_COUNT: int = 4 # 2-4; edit and the grid below stays a 2x2 (empty cells if <4)

# Spread the players far apart so per-camera LOD differences are obvious.
const FOCUS_POINTS := [
	Vector3(-160.0, 0.0, -160.0),
	Vector3(160.0, 0.0, -160.0),
	Vector3(-160.0, 0.0, 160.0),
	Vector3(160.0, 0.0, 160.0),
]
const MARKER_COLORS := [
	Color(1.0, 0.25, 0.2), # red
	Color(0.25, 0.6, 1.0), # blue
	Color(0.3, 1.0, 0.35), # green
	Color(1.0, 0.85, 0.2), # yellow
]

@onready var terrain: Terrain3D = $Grid/VC0/VP0/Terrain3D
@onready var _viewports: Array[SubViewport] = [
	$Grid/VC0/VP0,
	$Grid/VC1/VP1,
	$Grid/VC2/VP2,
	$Grid/VC3/VP3,
]

var _cameras: Array[Camera3D] = []
var _time: float = 0.0


func _ready() -> void:
	# Collision is built once for the whole terrain, independent of cameras (no one falls through).
	terrain.collision_mode = Terrain3DCollision.FULL_GAME

	for i in PLAYER_COUNT:
		var focus: Vector3 = FOCUS_POINTS[i]

		# A gameplay marker ("kart") on layer 1 — visible to every camera.
		var marker := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(8, 8, 8)
		marker.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = MARKER_COLORS[i]
		mat.emission_enabled = true
		mat.emission = MARKER_COLORS[i]
		mat.emission_energy_multiplier = 0.6
		marker.material_override = mat
		marker.layers = 1 # gameplay
		marker.position = focus + Vector3(0, _ground_height(focus) + 4.0, 0)
		# Markers can live under any viewport; the shared World3D shows them everywhere.
		$Grid/VC0/VP0.add_child(marker)

		# One camera per viewport.
		var cam := Camera3D.new()
		cam.far = 4000.0
		# Each camera sees gameplay (1-16) + only its own terrain layer.
		cam.cull_mask = GAMEPLAY_MASK | (1 << (TERRAIN_TOP_BIT - i))
		_viewports[i].add_child(cam)
		cam.current = true
		_cameras.append(cam)

	# The whole point of the fork: one node, N cameras, one shared Terrain3DData.
	terrain.set_cameras(_cameras)
	_update_cameras()
	_build_overlay()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _process(p_delta: float) -> void:
	_time += p_delta
	_update_cameras()


# Slowly orbit each camera around its focus point so each clipmap continuously recenters/LODs.
func _update_cameras() -> void:
	for i in _cameras.size():
		var focus: Vector3 = FOCUS_POINTS[i]
		var angle: float = _time * 0.2 + float(i) * (TAU / float(PLAYER_COUNT))
		var radius: float = 90.0
		var eye := focus + Vector3(cos(angle) * radius, 55.0, sin(angle) * radius)
		eye.y = _ground_height(eye) + 55.0
		var look_at := focus + Vector3(0, _ground_height(focus), 0)
		_cameras[i].global_position = eye
		_cameras[i].look_at(look_at, Vector3.UP)


func _ground_height(p_pos: Vector3) -> float:
	if terrain == null or terrain.get_data() == null:
		return 0.0
	var h: float = terrain.get_data().get_height(p_pos)
	return 0.0 if is_nan(h) else h


func _unhandled_key_input(p_event: InputEvent) -> void:
	if p_event is InputEventKey and p_event.pressed:
		match p_event.keycode:
			KEY_F7, KEY_ESCAPE:
				get_tree().change_scene_to_file("res://demo/Demo.tscn")
			KEY_F8:
				get_tree().quit()


# Instructions overlay drawn on top of all quadrants (CanvasLayer, outside the SubViewports).
func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	label.position = Vector2(10, 8)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.66))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.text = "Pasture3D split-screen test — %d cameras, 1 shared Terrain3DData\n" % PLAYER_COUNT \
		+ "Each quadrant keeps high-detail terrain around its own orbiting player.\n" \
		+ "F7 / Esc: back to demo     F8: quit"
	layer.add_child(label)
