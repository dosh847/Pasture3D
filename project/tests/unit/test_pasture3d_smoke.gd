extends GdTest
## Project smoke test for Pasture3D: confirms the GDExtension loads in headless mode and its core classes
## register + instantiate. This guards the BUILD / extension wiring (a broken .gdextension or missing lib
## fails here), not the editor tools.
##
## NOTE: the landscape-brush tools (place/undo, detach_placement, etc.) are gated behind
## Engine.is_editor_hint() and CANNOT run in this non-editor headless runner — they early-return. Those
## stay manually verified in the editor, or wait for an editor-context runner. See tests/README.md.

func test_extension_classes_registered() -> void:
	assert_true(ClassDB.class_exists("Pasture3D"), "Pasture3D node class registered by the GDExtension")
	assert_true(ClassDB.class_exists("Pasture3DMaterial"), "Pasture3DMaterial registered")
	assert_true(ClassDB.class_exists("Pasture3DAssets"), "Pasture3DAssets registered")

func test_terrain_node_instantiates() -> void:
	var t: Object = ClassDB.instantiate("Pasture3D")
	assert_not_null(t, "can construct a Pasture3D node")
	if t is Node:
		(t as Node).free()

func test_material_resource_instantiates() -> void:
	var m: Object = ClassDB.instantiate("Pasture3DMaterial")
	assert_not_null(m, "can construct a Pasture3DMaterial resource")
