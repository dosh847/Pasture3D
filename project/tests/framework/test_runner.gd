extends SceneTree
## Headless test runner. Discovers every `test_*.gd` under a tests directory, runs each `test_*` method on
## the GdTest subclass it finds, prints a summary, and sets the process EXIT CODE (0 = all passed, 1 = any
## failure) so an agent or CI step can detect the result without parsing text.
##
## Run directly:
##   godot --headless --path <project> --script res://tests/framework/test_runner.gd
## Or via the launchers next to it:
##   tests/run_tests.ps1   /   tests/run_tests.sh
##
## Optional args (pass after a literal `--`):
##   --dir=res://tests/unit     limit discovery to a subtree (default: res://tests)
##   --filter=detach            only run test methods whose name contains the substring
##
## DROP-IN: copy tests/framework (+ the launchers) into any Godot 4.x project. See tests/README.md.

const FRAMEWORK_DIR := "res://tests/framework"


func _initialize() -> void:
	var dir := "res://tests"
	var filt := ""
	# User args (after `--`) take precedence; also scan full cmdline so it works either way.
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
		elif a.begins_with("--filter="):
			filt = a.substr(9)

	var files := _find_tests(dir)
	files.sort()
	if files.is_empty():
		print("[tests] no test_*.gd files found under %s" % dir)
		quit(0)
		return

	var total := 0
	var passed := 0
	var failed := 0
	var empty := 0
	var t0 := Time.get_ticks_msec()
	print("[tests] running %d test file(s) under %s\n" % [files.size(), dir])

	for path in files:
		var script: GDScript = load(path)
		if script == null:
			print("  ! could not load %s" % path)
			failed += 1
			continue
		var inst: Object = script.new()
		if not (inst is GdTest):
			print("  - skip %s (script is not a GdTest)" % path)
			continue
		inst.scene_tree = self
		print("• %s" % path.get_file())
		var methods := _test_methods(inst, filt)
		if methods.is_empty():
			print("   (no matching test_* methods)")
			print("")
			continue
		inst.before_all()
		for m in methods:
			total += 1
			inst._begin_method()
			inst.before_each()
			inst.call(m)
			inst.after_each()
			var fails: PackedStringArray = inst._failures
			if not fails.is_empty():
				failed += 1
				print("   FAIL %s" % m)
				for f in fails:
					print("        - %s" % f)
			elif int(inst._asserts) == 0:
				empty += 1
				passed += 1
				print("   ok   %s   (warning: 0 assertions)" % m)
			else:
				passed += 1
				print("   ok   %s" % m)
		inst.after_all()
		print("")

	var ms := Time.get_ticks_msec() - t0
	var warn := "  [%d with no assertions]" % empty if empty > 0 else ""
	print("[tests] %d passed, %d failed, %d total in %d ms%s" % [passed, failed, total, ms, warn])
	quit(1 if failed > 0 else 0)


## Test methods on `inst`: names beginning with `test_`, optionally filtered by substring, sorted, deduped.
func _test_methods(inst: Object, filt: String) -> PackedStringArray:
	var seen := {}
	var out := PackedStringArray()
	for m in inst.get_method_list():
		var n: String = m.name
		if n.begins_with("test_") and not seen.has(n) and (filt == "" or n.findn(filt) >= 0):
			seen[n] = true
			out.append(n)
	out.sort()
	return out


## Recursively collect `test_*.gd` files under `root`, skipping the framework folder itself.
func _find_tests(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(root)
	if da == null:
		return out
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if fname == "." or fname == "..":
			fname = da.get_next()
			continue
		var full := root.path_join(fname)
		if da.current_is_dir():
			if full != FRAMEWORK_DIR:
				out.append_array(_find_tests(full))
		elif fname.begins_with("test_") and fname.ends_with(".gd"):
			out.append(full)
		fname = da.get_next()
	da.list_dir_end()
	return out
