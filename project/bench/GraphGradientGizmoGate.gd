# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGradientGizmoGate — viewport handles for a Gradient's start / end
# (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §12.1).
#
#   GZ-A  A HOST handle sits at the brush placement applied to the property, derived here from the yaw
#         formula rather than host_placement. Control: not at the raw property; a WORLD handle IS.
#   GZ-B  The handle is where the KERNEL puts it: native evaluation is 0 at start, 1 at end, 0.5 at the
#         midpoint. Control: the raw HOST midpoint does not evaluate to 0.5.
#   GZ-C  Drag round trip re-derives the handle at the target on both spaces, and bumps the revision.
#         Control: the HOST inverse through identity is more than 1 m off.
#   GZ-D  A real camera picks the start handle at its pixel. Control: 40 px away picks nothing, and a
#         driven gradient's handle is not picked at its own pixel.
#   GZ-E  Completion count.
#
# Headless. No terrain, so nothing can reach demo data: handles sit at the brush's own height.
#   Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphGradientGizmoGate.tscn
extends Node

const HANDLES := preload("res://addons/pasture_3d/src/graph_gradient_handles.gd")
const CRITERIA := ["GZ-A", "GZ-B", "GZ-C", "GZ-D"]
const ORIGIN := Vector3(5000.0, 12.0, -3000.0)
const YAW := PI * 0.5
## Long, so a half-cell sampling offset moves t by 2.5e-4, inside the 1e-3 tolerance.
const HOST_START := Vector2(-1000.0, 300.0)
const HOST_END := Vector2(1000.0, -200.0)
const WORLD_START := Vector2(4200.0, -2600.0)
const WORLD_END := Vector2(4700.0, -2900.0)
const EPS := 1.0e-3

var _fail := 0
var _seen := {}
var _mound: Pasture3DMound
var _graph: Pasture3DTerrainGraph
var _host: Pasture3DGraphNodeGradient
var _world: Pasture3DGraphNodeGradient
var _driven: Pasture3DGraphNodeGradient


func _ready() -> void:
	print("=== GraphGradientGizmoGate: Gradient start / end viewport handles (spec §12) ===")
	_fixture()
	_gz_a()
	_gz_b()
	_gz_d() # before C, which moves the handles
	_gz_c()
	var completed := 0
	for c in CRITERIA:
		if _seen.has(c):
			completed += 1
		else:
			print("!! criterion %s never reported" % c)
	_check("GZ-E", completed == CRITERIA.size(), "%d of %d criteria completed" % [completed, CRITERIA.size()])
	print("=== GRADIENT GIZMO %s (%d failures) ===" % ["FAIL" if _fail > 0 else "PASS", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("    [%s] %s — %s" % [p_name, "ok" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _control(p_ok: bool, p_detail: String) -> void:
	print("    control: %s — %s" % ["ok" if p_ok else "DEAD", p_detail])
	if not p_ok:
		_fail += 1


func _gradient(p_space: int, p_start: Vector2, p_end: Vector2) -> Pasture3DGraphNodeGradient:
	var n := Pasture3DGraphNodeGradient.new()
	n.space = p_space
	n.shape = Pasture3DGraphNodeGradient.Shape.LINEAR
	n.repeat = Pasture3DGraphNodeGradient.Repeat.CLAMP
	n.output_mode = Pasture3DGraphNodeGradient.OutputMode.MASK
	n.start = p_start
	n.end = p_end
	return n


func _fixture() -> void:
	_host = _gradient(Pasture3DGraphNodeGradient.Space.HOST, HOST_START, HOST_END)
	_world = _gradient(Pasture3DGraphNodeGradient.Space.WORLD, WORLD_START, WORLD_END)
	# Its start is 30 m east of the HOST start's world position; start_x is wired from a Const.
	var hs := _yaw_place(HOST_START)
	_driven = _gradient(Pasture3DGraphNodeGradient.Space.WORLD, Vector2(hs.x + 30.0, hs.z), Vector2(hs.x + 300.0, hs.z))
	var k := Pasture3DGraphNodeConst.new()
	_graph = Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), _host, Pasture3DGraphNodeOutput.new(), _world, _driven, k]
	_graph.nodes = nodes
	_graph.connections = [[1, 0, 2, 0], [5, 0, 4, 1]]
	_mound = Pasture3DMound.new()
	_mound.name = "GizmoGateHost"
	add_child(_mound)
	_mound.global_position = ORIGIN
	_mound.rotation = Vector3(0.0, YAW, 0.0)
	var mod := Pasture3DNodeGraph.new()
	mod.graph = _graph
	var mods: Array[Pasture3DNode] = [mod]
	_mound.modifiers = mods


## Local (x, z) to world by the Y rotation's own mapping: +X to (cos, -sin), +Z to (sin, cos).
func _yaw_place(p_v: Vector2) -> Vector3:
	return Vector3(ORIGIN.x + cos(YAW) * p_v.x + sin(YAW) * p_v.y, ORIGIN.y,
			ORIGIN.z - sin(YAW) * p_v.x + cos(YAW) * p_v.y)


func _handle(p_node: Pasture3DGraphNodeGradient, p_which: int) -> Dictionary:
	for h in HANDLES.handles(_mound):
		if h["node"] == p_node and int(h["which"]) == p_which:
			return h
	return {}


func _xz(p_v: Vector3) -> Vector2:
	return Vector2(p_v.x, p_v.z)


# --- GZ-A ------------------------------------------------------------------------------------------------
func _gz_a() -> void:
	print("[GZ-A] handles sit at the placement applied to the property")
	var worst := 0.0
	for which in 2:
		var h := _handle(_host, which)
		var want := _yaw_place(HOST_START if which == 0 else HOST_END)
		worst = maxf(worst, _xz(h["world"]).distance_to(_xz(want)) if not h.is_empty() else INF)
	var count := HANDLES.handles(_mound).size()
	_check("GZ-A", worst <= EPS and count == 6, "HOST worst %s m from the yaw formula; %d handles (want 6)" % [str(worst), count])
	var raw_off := _xz(_handle(_host, 0)["world"]).distance_to(HOST_START)
	var world_off := _xz(_handle(_world, 0)["world"]).distance_to(WORLD_START)
	_control(raw_off > 1.0 and world_off <= EPS,
			"HOST handle %s m from its raw property (want > 1); WORLD handle %s m from its raw property (want 0)" % [str(raw_off), str(world_off)])


# --- GZ-B ------------------------------------------------------------------------------------------------
func _eval_at(p_xz: Vector2) -> float:
	Pasture3DGraphSources.resolve(_graph, _mound)
	var out := Pasture3DUtil.graph_eval_grid(_graph.compile_graph_program(), 1, 1,
			Rect2(p_xz.x - 0.5, p_xz.y - 0.5, 1.0, 1.0), PackedFloat32Array([0.0]))
	return out[0] if out.size() == 1 else NAN


func _gz_b() -> void:
	print("[GZ-B] the handles are where the kernel puts t = 0 and t = 1")
	var s := _xz(_handle(_host, 0)["world"])
	var e := _xz(_handle(_host, 1)["world"])
	var t0 := _eval_at(s)
	var t1 := _eval_at(e)
	var tm := _eval_at((s + e) * 0.5)
	_check("GZ-B", absf(t0) <= EPS and absf(t1 - 1.0) <= EPS and absf(tm - 0.5) <= EPS,
			"native t at start %s, end %s, midpoint %s (want 0, 1, 0.5)" % [str(t0), str(t1), str(tm)])
	var raw := _eval_at((HOST_START + HOST_END) * 0.5)
	_control(is_finite(raw) and absf(raw - 0.5) > 0.05, "t at the raw HOST midpoint %s (want not 0.5)" % str(raw))


# --- GZ-C ------------------------------------------------------------------------------------------------
func _gz_c() -> void:
	print("[GZ-C] a drag writes the value that puts the handle where it was dragged")
	# The graph bumps its revision only for an edit that reaches the output (GraphEditModelGate [E]). The
	# HOST gradient is wired to Output, so its drags must bump; the WORLD one is not, so its must not.
	var worst := 0.0
	var host_bumped := true
	var world_bumped := false
	var identity_off := 0.0
	for n in [_host, _world]:
		for which in 2:
			var h := _handle(n, which)
			var target: Vector3 = h["world"] + Vector3(37.0, 0.0, -21.0)
			var v := HANDLES.value_for_world(_mound, h, target)
			var rev: int = _graph._revision
			n.set(HANDLES.property_of(h), v)
			if n == _host:
				host_bumped = host_bumped and _graph._revision > rev
				identity_off = maxf(identity_off, _xz(target).distance_to(v))
			else:
				world_bumped = world_bumped or _graph._revision > rev
			worst = maxf(worst, _xz(_handle(n, which)["world"]).distance_to(_xz(target)))
	_check("GZ-C", worst <= EPS and host_bumped,
			"worst re-derived handle %s m from the drag target; every wired write bumped the revision: %s" % [str(worst), str(host_bumped)])
	_control(identity_off > 1.0 and not world_bumped,
			"HOST value through identity is %s m off (want > 1); an unwired gradient's drag bumped the revision: %s (want false)"
			% [str(identity_off), str(world_bumped)])


# --- GZ-D ------------------------------------------------------------------------------------------------
func _gz_d() -> void:
	print("[GZ-D] a real camera picks the start handle, and never a driven one")
	get_viewport().size = Vector2i(1280, 720)
	var hs := _handle(_host, 0)
	var focus: Vector3 = hs["world"]
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = focus + Vector3(0.0, 60.0, 60.0)
	cam.look_at(focus, Vector3.UP)
	cam.current = true
	var px := cam.unproject_position(focus)
	var all := HANDLES.handles(_mound)
	var want := HANDLES.ID_BASE + all.find(hs)
	var got := HANDLES.pick(_mound, cam, px)
	_check("GZ-D", got == want and want >= HANDLES.ID_BASE, "picked id %d at the start handle's pixel (want %d)" % [got, want])
	var miss := HANDLES.pick(_mound, cam, px + Vector2(40.0, 0.0))
	var dh := _handle(_driven, 0)
	var dpx := cam.unproject_position(dh["world"])
	var dgot := HANDLES.pick(_mound, cam, dpx)
	_control(miss == -1 and dh["driven"] and dgot == -1 and dpx.distance_to(px) > HANDLES.PICK_RADIUS,
			"40 px away picks %d (want -1); driven handle (driven=%s, %s px from start) picks %d (want -1)"
			% [miss, str(dh["driven"]), str(dpx.distance_to(px)), dgot])
	cam.queue_free()
