@tool
extends EditorScript

## Toggle a bake trace around an edit. Run once (starts), make the edit you want explained, run again
## (stops and writes the report).
##
## This is the ONLY way to exercise the half BakeTraceGate cannot: `Pasture3DBakeTrace.arm` sits behind
## `_can_auto_refresh()`, which requires `Engine.is_editor_hint()`, and `get_stack()` is populated only
## under the editor. The gate proves the recorder works; this proves the schedulers are wired to it.
##
## The report goes to a FILE, not to Output. A real session buries a hundred trace lines under engine
## noise — that is a large part of why the spurious mountain bakes were never pinned down by reading logs.

const REPORT := "user://pasture3d_bake_trace.txt"


func _run() -> void:
	if Pasture3DBakeTrace.is_running():
		Pasture3DBakeTrace.stop()
		var path := Pasture3DBakeTrace.write_report(REPORT)
		print("\n=== bake trace stopped — %d event(s) ===" % Pasture3DBakeTrace.event_count())
		if path != "":
			print("  report: %s" % path)
		# Also to Output, short traces are easier to read inline than to go open a file for.
		if Pasture3DBakeTrace.event_count() <= 60:
			print("\n%s\n" % Pasture3DBakeTrace.report())
	else:
		Pasture3DBakeTrace.start(true)
		print("\n=== bake trace STARTED (stacks on) ===")
		print("  Make the edit you want explained, then run this script again.")
