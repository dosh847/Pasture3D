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
		var profile := _manager.get_profile(name)
		if src == SOURCE_BUILTIN:
			_button(buttons, "Edit a copy", "Copy the built-in into this scene's profiles, where it can be tuned.",
					_edit_copy.bind(name))
			continue
		_button(buttons, "Open", "Edit this profile in the Inspector.", _open.bind(profile))
		if src == SOURCE_SCENE:
			_button(buttons, "Save to file...", "Write this profile to a .tres, to reuse in other scenes.",
					_ask_save.bind(profile))
		if _manager.is_builtin_profile_name(name):
			_button(buttons, "Revert", "Drop this scene's version and use the built-in again.", _remove.bind(name))
		else:
			_button(buttons, "Remove", "Remove this profile from the scene.", _remove.bind(name))

	_button(self, "Add from file...", "Add a saved wave profile (.tres) to this scene. One named like a built-in overrides it.",
			_ask_add)


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
		return
	var profile := load_profile(p_path)
	if profile != null:
		_commit("Add wave profile '%s'" % profile.profile_name, profiles_with(_manager, profile))
