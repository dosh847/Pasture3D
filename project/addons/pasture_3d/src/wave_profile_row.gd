# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DWaveProfileRow — the Wave Profiles section at the top of a Pasture3DPoolManager's Inspector.
#
# The shipped sea states are built-ins (production spec §2.1): code, never saved, read-only in the
# Inspector, so a retune reaches every scene. That left no way to tune one from the editor. This row is
# the way: per profile name, where it comes from and what can be done with it.
#
#   built-in        Edit a copy -- override_builtin(): a copy in `profiles`, saved with the scene.
#   scene's own     Save to file... -- the profile as a .tres; the scene then references the file, and any
#                   other scene can Add from file... to use the same sea.
#   from a file     Open -- edits the file's resource in the Inspector; saving the scene saves it.
#   either          Revert to built-in (a built-in's name) or Remove (any other name).
#
# A profile file is a Pasture3DWaveProfile with its FFT and fBm embedded. Its profile_name is what a water
# body's wave_profile selects, so a file named like a built-in overrides that built-in where it is added.
#
# The same buttons, for the one profile it uses, sit under `wave_profile` on a Pasture3DOcean or a
# Pasture3DPool (setup_for_body), because that is where you look when a sea needs tuning. There "Edit a copy"
# also opens the copy, and the line rebuilds itself when the body's profile or its source changes.
#
# The array edits go through `profiles`, so they are undoable and need no state here. The logic is the
# static functions, which take no editor objects, so a headless gate can call them
# (bench/WaterProfileFileGate.gd); the controls only route buttons to them.

@tool
extends VBoxContainer

const SOURCE_BUILTIN := "built-in"
const SOURCE_SCENE := "this scene"

var _manager: Pasture3DPoolManager
var _undo: EditorUndoRedoManager
var _dialog: EditorFileDialog
var _dialog_target: Pasture3DWaveProfile
## The ocean or pool whose profile this line shows; null for the manager's full list.
var _body: Node
## What the body line was last built from (_body_signature); see _process.
var _body_shown := ""
var _body_poll := 0.0


## Where the profile p_name resolves from on p_manager: SOURCE_BUILTIN, SOURCE_SCENE, or its file's path.
static func source_of(p_manager: Pasture3DPoolManager, p_name: StringName) -> String:
	var profile := p_manager.get_profile(p_name)
	if profile == null or not p_manager.profiles.has(profile):
		return SOURCE_BUILTIN
	return profile.resource_path if is_file_backed(profile) else SOURCE_SCENE


## True for a profile that is its own file, not embedded in a scene ("res://x.tscn::Resource_abc").
static func is_file_backed(p_profile: Resource) -> bool:
	return p_profile.resource_path != "" and not p_profile.resource_path.contains("::")


## Writes p_profile to p_path and makes it that file, so the scene that holds it references the file from
## now on. Its FFT and fBm are embedded in the file.
static func save_to_file(p_profile: Pasture3DWaveProfile, p_path: String) -> Error:
	var err := ResourceSaver.save(p_profile, p_path)
	if err == OK:
		p_profile.take_over_path(p_path)
	return err


## p_manager's profiles with p_profile in them: in place of one of the same name, or appended.
static func profiles_with(p_manager: Pasture3DPoolManager, p_profile: Pasture3DWaveProfile) -> Array[Pasture3DWaveProfile]:
	var out: Array[Pasture3DWaveProfile] = []
	var placed := false
	for p in p_manager.profiles:
		if p != null and p.profile_name == p_profile.profile_name:
			if not placed:
				out.append(p_profile)
				placed = true
		else:
			out.append(p)
	if not placed:
		out.append(p_profile)
	return out


## p_manager's profiles without the one named p_name.
static func profiles_without(p_manager: Pasture3DPoolManager, p_name: StringName) -> Array[Pasture3DWaveProfile]:
	var out: Array[Pasture3DWaveProfile] = []
	for p in p_manager.profiles:
		if p == null or p.profile_name != p_name:
			out.append(p)
	return out


## The manager whose profiles p_body's `wave_profile` names: its explicit `manager`, else the scene's, else
## null. A Pasture3DOcean has no explicit one; it uses the first manager in the tree, as this does.
static func manager_for(p_body: Node) -> Pasture3DPoolManager:
	var explicit = p_body.get(&"manager")
	if explicit is Pasture3DPoolManager and is_instance_valid(explicit):
		return explicit
	if not p_body.is_inside_tree():
		return null
	for m in p_body.get_tree().get_nodes_in_group(&"pasture3d_water_manager"):
		if m is Pasture3DPoolManager:
			return m
	return null


## Loads p_path as a wave profile, or null with the reason pushed as an error.
static func load_profile(p_path: String) -> Pasture3DWaveProfile:
	var res := ResourceLoader.load(p_path)
	if not res is Pasture3DWaveProfile:
		push_error("%s is not a Pasture3DWaveProfile" % p_path)
		return null
	return res


func setup(p_manager: Pasture3DPoolManager, p_undo: EditorUndoRedoManager) -> Control:
	_manager = p_manager
	_undo = p_undo
	_build()
	return self


## The single line under p_body's `wave_profile`.
func setup_for_body(p_body: Node, p_undo: EditorUndoRedoManager) -> Control:
	_body = p_body
	_undo = p_undo
	_build_body()
	set_process(true)
	return self


func _body_signature() -> String:
	var m := manager_for(_body)
	if m == null:
		return ""
	var name: StringName = _body.get(&"wave_profile")
	return "%s|%s|%s|%s" % [m.get_instance_id(), name, m.has_profile(name), source_of(m, name)]


# Polled, not signalled: setting wave_profile emits nothing the Inspector rebuilds on, and the manager can
# come and go under the body.
func _process(p_delta: float) -> void:
	if _body == null or not is_instance_valid(_body):
		return
	_body_poll += p_delta
	if _body_poll < 0.25:
		return
	_body_poll = 0.0
	if _body_signature() != _body_shown:
		_build_body()


func _build_body() -> void:
	for c in get_children():
		if c != _dialog:
			remove_child(c)
			c.queue_free()
	_manager = manager_for(_body)
	_body_shown = _body_signature()
	var line := HBoxContainer.new()
	add_child(line)
	var where := Label.new()
	where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	where.clip_text = true
	where.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	line.add_child(where)
	if _manager == null:
		where.text = "No Pasture3DPoolManager in the scene"
		where.tooltip_text = "Wave profiles live on a Pasture3DPoolManager. Add one to edit them."
		return
	var name: StringName = _body.get(&"wave_profile")
	if not _manager.has_profile(name):
		where.text = "No profile named '%s'" % name
		return
	var src := source_of(_manager, name)
	where.text = src.get_file() if src.begins_with("res://") else src
	where.tooltip_text = "'%s' on %s, from %s" % [name, _manager.name, src]
	_add_actions(line, name, src)


func _build() -> void:
	var title := Label.new()
	title.text = "Wave Profiles"
	title.add_theme_font_size_override("font_size", 14)
	add_child(title)
	var blurb := Label.new()
	blurb.text = "Built-ins are read-only. Edit a copy to tune one in this scene; Save to file to reuse it elsewhere."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	add_child(blurb)

	var grid := GridContainer.new()
	grid.columns = 3
	add_child(grid)
	for n in _manager.get_profile_names():
		var name := StringName(n)
		var src := source_of(_manager, name)
		var label := Label.new()
		label.text = n
		grid.add_child(label)
		var where := Label.new()
		where.text = src.get_file() if src.begins_with("res://") else src
		where.tooltip_text = src
		where.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
		where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		where.clip_text = true
		grid.add_child(where)
		var buttons := HBoxContainer.new()
		grid.add_child(buttons)
		_add_actions(buttons, name, src)

	_button(self, "Add from file...", "Add a saved wave profile (.tres) to this scene. One named like a built-in overrides it.",
			_ask_add)


## The buttons for the profile p_name, which resolves from p_src.
func _add_actions(p_parent: Control, p_name: StringName, p_src: String) -> void:
	if p_src == SOURCE_BUILTIN:
		_button(p_parent, "Edit a copy", "Copy the built-in into this scene's profiles, where it can be tuned.",
				_edit_copy.bind(p_name))
		return
	var profile := _manager.get_profile(p_name)
	_button(p_parent, "Open", "Edit this profile in the Inspector.", _open.bind(profile))
	if p_src == SOURCE_SCENE:
		_button(p_parent, "Save to file...", "Write this profile to a .tres, to reuse in other scenes.",
				_ask_save.bind(profile))
	if _manager.is_builtin_profile_name(p_name):
		_button(p_parent, "Revert", "Drop this scene's version and use the built-in again.", _remove.bind(p_name))
	elif _body == null:
		# Not on a body: removing the profile it uses would leave it naming nothing.
		_button(p_parent, "Remove", "Remove this profile from the scene.", _remove.bind(p_name))


func _button(p_parent: Control, p_text: String, p_tip: String, p_call: Callable) -> void:
	var b := Button.new()
	b.text = p_text
	b.tooltip_text = p_tip
	b.pressed.connect(p_call)
	p_parent.add_child(b)


func _commit(p_action: String, p_profiles: Array[Pasture3DWaveProfile]) -> void:
	_undo.create_action(p_action)
	_undo.add_do_property(_manager, &"profiles", p_profiles)
	_undo.add_undo_property(_manager, &"profiles", _manager.profiles)
	_undo.add_do_method(_manager, &"notify_property_list_changed")
	_undo.add_undo_method(_manager, &"notify_property_list_changed")
	_undo.commit_action()


func _edit_copy(p_name: StringName) -> void:
	_undo.create_action("Edit a copy of wave profile '%s'" % p_name)
	_undo.add_do_method(_manager, &"override_builtin", p_name)
	_undo.add_undo_property(_manager, &"profiles", _manager.profiles)
	_undo.add_undo_method(_manager, &"notify_property_list_changed")
	_undo.commit_action()
	if _body != null:
		_open(_manager.get_profile(p_name))


func _remove(p_name: StringName) -> void:
	_commit("Remove wave profile '%s'" % p_name, profiles_without(_manager, p_name))


func _open(p_profile: Pasture3DWaveProfile) -> void:
	EditorInterface.edit_resource(p_profile)


func _dialog_for(p_mode: EditorFileDialog.FileMode, p_title: String) -> EditorFileDialog:
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_dialog.add_filter("*.tres", "Wave profile")
		_dialog.add_filter("*.res", "Wave profile (binary)")
		_dialog.file_selected.connect(_on_file_selected)
		add_child(_dialog)
	_dialog.file_mode = p_mode
	_dialog.title = p_title
	return _dialog


func _ask_save(p_profile: Pasture3DWaveProfile) -> void:
	_dialog_target = p_profile
	var d := _dialog_for(EditorFileDialog.FILE_MODE_SAVE_FILE, "Save wave profile")
	d.current_file = "%s.tres" % p_profile.profile_name
	d.popup_file_dialog()


func _ask_add() -> void:
	_dialog_target = null
	_dialog_for(EditorFileDialog.FILE_MODE_OPEN_FILE, "Add wave profile").popup_file_dialog()


func _on_file_selected(p_path: String) -> void:
	if _dialog_target != null:
		var err := save_to_file(_dialog_target, p_path)
		if err != OK:
			push_error("Could not save wave profile to %s: %s" % [p_path, error_string(err)])
			return
		EditorInterface.mark_scene_as_unsaved()
		_manager.notify_property_list_changed()
		if _body != null:
			_build_body()
		return
	var profile := load_profile(p_path)
	if profile != null:
		_commit("Add wave profile '%s'" % profile.profile_name, profiles_with(_manager, profile))
