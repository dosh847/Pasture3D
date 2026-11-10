# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Writes the golden port table `GraphPortDescriptorGate` [A] compares against.
#
# Run it ONLY when a port change is intended, and read the diff of the golden file before keeping it: the
# file is the record of every port every node declares, and regenerating it blindly makes [A] agree with
# whatever the code currently says.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project --script bench/GraphPortTableWrite.gd
extends SceneTree

const Table := preload("res://bench/GraphPortTable.gd")


func _init() -> void:
	var rows := Table.table()
	# A path after `--` writes the table THERE and leaves the golden alone, for diffing by hand.
	var args := OS.get_cmdline_user_args()
	var target: String = args[0] if args.size() > 0 else Table.GOLDEN
	if args.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Table.GOLDEN.get_base_dir()))
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		printerr("GraphPortTableWrite: cannot open %s" % target)
		quit(1)
		return
	f.store_string("\n".join(rows) + "\n")
	f.close()
	print("GraphPortTableWrite: %d rows from %d scripts -> %s" % [rows.size(), Table.node_scripts().size(), target])
	quit(0)
