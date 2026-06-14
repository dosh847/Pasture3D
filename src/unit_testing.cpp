// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_loader.hpp>

#include "unit_testing.h"
#include "pasture_3d_data.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_region.h"
#include "pasture_3d_util.h"

void test_differs() {
	UtilityFunctions::print("=== Testing differs function ===");

	// Helper to log differs result with expected and PASS/FAIL
	auto log_differs = [](const auto &a, const auto &b, const String &desc, bool expected) {
		bool d = differs(a, b);
		String result = (d == expected) ? "PASSED" : "FAILED";
		UtilityFunctions::print(desc, ": differs(", a, ", ", b, ") = ", d, " - ", result);
	};

	// 1. Scalars: int, float (should use ==, differs if values differ)
	{
		int i1 = 42;
		int i2 = 42; // Same
		int i3 = 43; // Diff
		log_differs(i1, i2, "int same", false);
		log_differs(i1, i3, "int diff", true);

		double f1 = 3.14;
		double f2 = 3.14; // Same
		double f3 = 3.14159; // Diff
		log_differs(f1, f2, "float same", false);
		log_differs(f1, f3, "float diff", true);
	}

	// 2. Vectors: Vector2, Vector2i, Vector3, Vector3i (should use ==)
	{
		Vector2 v2_1(1.0, 2.0);
		Vector2 v2_2(1.0, 2.0); // Same
		Vector2 v2_3(1.0, 3.0); // Diff
		log_differs(v2_1, v2_2, "Vector2 same", false);
		log_differs(v2_1, v2_3, "Vector2 diff", true);

		Vector2i v2i_1(1, 2);
		Vector2i v2i_2(1, 2); // Same
		Vector2i v2i_3(1, 3); // Diff
		log_differs(v2i_1, v2i_2, "Vector2i same", false);
		log_differs(v2i_1, v2i_3, "Vector2i diff", true);

		Vector3 v3_1(1.0, 2.0, 3.0);
		Vector3 v3_2(1.0, 2.0, 3.0); // Same
		Vector3 v3_3(1.0, 2.0, 4.0); // Diff
		log_differs(v3_1, v3_2, "Vector3 same", false);
		log_differs(v3_1, v3_3, "Vector3 diff", true);

		Vector3i v3i_1(1, 2, 3);
		Vector3i v3i_2(1, 2, 3); // Same
		Vector3i v3i_3(1, 2, 4); // Diff
		log_differs(v3i_1, v3i_2, "Vector3i same", false);
		log_differs(v3i_1, v3i_3, "Vector3i diff", true);
	}

	// 3. String: Share (COW), same value diff ptr, diff value
	{
		String s1 = "test";
		String s2 = s1; // Shared (COW)
		String s3("test"); // Separate alloc, same value
		String s4 = "diff";
		log_differs(String(), String(), "String() vs String()", false);
		log_differs(String(), String("a"), "String() vs String('a')", true);
		log_differs(s1, s2, "String shared", false);
		log_differs(s1, s3, "String same value diff ptr", false); // Length match + == true
		log_differs(s1, s4, "String diff value", true); // Length may match, but == false
	}

	// 4. StringName: Similar to String (uses ==, but test sharing if applicable)
	{
		StringName sn1 = "test";
		StringName sn2 = sn1; // Shared
		StringName sn3("test"); // Separate, same value
		StringName sn4 = "diff";
		log_differs(sn1, sn2, "StringName shared", false);
		log_differs(sn1, sn3, "StringName same value diff ptr", false); // == handles
		log_differs(sn1, sn4, "StringName diff value", true);
	}

	// 5. Array: Share vs mutate
	{
		Array arr1;
		arr1.push_back(42);
		Array arr2 = arr1; // Shared
		Array arr3; // Empty diff
		arr3.push_back(42); // Same content, but separate (differs=true, conservative)
		Array empty_arr; // Explicit empty for size diff
		log_differs(arr1, arr2, "Array shared", false); // Same self ptr
		log_differs(arr1, arr3, "Array same content diff ptr", true); // Diff self ptr (no fallback for Array)
		log_differs(arr1, empty_arr, "Array size diff", true); // Size mismatch
	}

	// 6. TypedArray: e.g., TypedArray<int>
	{
		TypedArray<int> ta1;
		ta1.push_back(42);
		TypedArray<int> ta2 = ta1; // Shared
		TypedArray<int> ta3; // Empty
		ta3.push_back(42); // Separate
		TypedArray<int> empty_ta; // Explicit empty
		log_differs(ta1, ta2, "TypedArray shared", false); // Via Array base
		log_differs(ta1, ta3, "TypedArray same content diff ptr", true); // Diff self
		log_differs(ta1, empty_ta, "TypedArray size diff", true); // Size mismatch
	}

	// 7. Dictionary: Share vs mutate
	{
		Dictionary dict1;
		dict1["key"] = 42;
		Dictionary dict2 = dict1; // Shared
		Dictionary dict3; // Empty
		dict3["key"] = 42; // Separate
		Dictionary empty_dict; // Explicit empty
		log_differs(dict1, dict2, "Dictionary shared", false);
		log_differs(dict1, dict3, "Dictionary same content diff ptr", true); // Diff self
		log_differs(dict1, empty_dict, "Dictionary size diff", true); // Size mismatch
	}

	// 8. Variant types: Wrap above (falls to ==)
	{
		Variant v_int1 = 42;
		Variant v_int2 = 42; // Same
		Variant v_int3 = 43; // Diff
		log_differs(v_int1, v_int2, "Variant int same", false);
		log_differs(v_int1, v_int3, "Variant int diff", true);

		Variant v_float1 = 3.14;
		Variant v_float2 = 3.14;
		Variant v_float3 = 3.14159;
		log_differs(v_float1, v_float2, "Variant float same", false);
		log_differs(v_float1, v_float3, "Variant float diff", true);

		Variant v_str1 = String("test");
		Variant v_str2 = String("test");
		Variant v_str3 = String("diff");
		log_differs(v_str1, v_str2, "Variant String same", false);
		log_differs(v_str1, v_str3, "Variant String diff", true);

		// Variant Object (use RefCounted for ref support)
		Ref<RefCounted> rc1 = memnew(RefCounted);
		Ref<RefCounted> rc2 = rc1; // Same ref
		Ref<RefCounted> rc3 = memnew(RefCounted); // Diff
		Variant v_rc1 = rc1;
		Variant v_rc2 = rc2;
		Variant v_rc3 = rc3;
		log_differs(v_rc1, v_rc2, "Variant RefCounted same ref", false); // Ref == true
		log_differs(v_rc1, v_rc3, "Variant RefCounted diff ref", true);

		// Variant Array
		Array arr_var1;
		arr_var1.push_back(42);
		Variant v_arr1 = arr_var1;
		Array arr_var2 = arr_var1;
		Variant v_arr2 = arr_var2;
		log_differs(v_arr1, v_arr2, "Variant Array shared", false); // Variant == checks inner

		// Variant Dictionary
		Dictionary dict_var1;
		dict_var1["key"] = 42;
		Variant v_dict1 = dict_var1;
		Dictionary dict_var2 = dict_var1;
		Variant v_dict2 = dict_var2;
		log_differs(v_dict1, v_dict2, "Variant Dictionary shared", false);
	}

	UtilityFunctions::print("=== End differs tests ===");
}

// Phase 2 acceptance test (PASTURE3D_LAYERS_GUIDE.md §10.2): with only the synthesized Base layer
// present, compositing must be an identity — the region height map is byte-identical afterwards.
// Also sanity-checks an ADD layer to confirm covered pixels blend and uncovered ones pass through.
void test_layer_compositing() {
	UtilityFunctions::print("=== Testing layer compositing ===");

	const int region_size = 64; // Smallest valid region size; keeps the test fast.
	const Vector2i loc(0, 0);

	// Build a standalone Pasture3DData with one region. add_region(..., false) skips the GPU/terrain
	// path, so no Pasture3D node or RenderingServer is needed.
	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);

	Ref<Image> height_map = region->get_height_map();
	const bool have_map = height_map.is_valid() && height_map->get_format() == Image::FORMAT_RF;
	EXPECT_TRUE(have_map);
	if (!have_map) {
		memdelete(data);
		return;
	}

	// Fill with a deterministic, varied pattern so an identity result is meaningful.
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}
	PackedByteArray original = height_map->get_data();

	// Synthesize a Base-only stack whose dense Base layer aliases the region height map, exactly as
	// Pasture3DData::_synthesize_base_layer does on load.
	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// Acceptance: Base-only composite is byte-identical to the input height map.
	data->composite_region(loc, Rect2i(), false);
	PackedByteArray composited = height_map->get_data();
	EXPECT_TRUE(composited == original);

	// Sanity: an ADD layer raises a covered pixel by its value and leaves an uncovered pixel alone.
	Ref<Pasture3DLayer> detail;
	detail.instantiate();
	detail->set_map_type(TYPE_HEIGHT);
	detail->set_tile_size(region_size);
	detail->set_blend_mode(Pasture3DLayer::ADD);
	const Vector2i covered(10, 10);
	const Vector2i uncovered(20, 20);
	detail->set_sample(loc, covered, 5.f, 1.f);
	stack->add_layer_ref(detail);
	const real_t base_h = height_map->get_pixelv(covered).r;
	const real_t base_u = height_map->get_pixelv(uncovered).r;
	data->composite_region(loc, Rect2i(), false);
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(covered).r, base_h + 5.f));
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(uncovered).r, base_u));

	memdelete(data);
	UtilityFunctions::print("=== End layer compositing tests ===");
}

// Phase 3 acceptance tests (PASTURE3D_LAYERS_GUIDE.md §10 phase 3 / PASTURE3D_LAYERS_PHASE3.md):
//   1. Runtime files unchanged — the saved region image is byte-identical regardless of the stack.
//   2. Stack round-trip — save, clear, load; layer count, metadata, and sampled (value, weight)
//      survive, and the Base layer is re-aliased onto the loaded region image (not a stale copy).
//   3. No-layer-files — a plain (Base-only) terrain writes no pasture3d_layers* files, and load_layers
//      reports nothing to load so the caller synthesizes a single Base layer as before.
// Like test_layer_compositing, this avoids a Pasture3D node by driving save_layers/load_layers and
// region->save directly; it never calls save_directory/load_directory (which require _terrain).
void test_layer_persistence() {
	UtilityFunctions::print("=== Testing layer persistence ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);
	const Vector2i covered(10, 10);
	const Vector2i covered2(40, 33);
	const Vector2i uncovered(20, 20);

	// A clean temp directory under user:// for the round-trip.
	const String dir = "user://p3d_layer_test";
	Ref<DirAccess> da = DirAccess::open("user://");
	if (da.is_valid()) {
		da->make_dir_recursive("p3d_layer_test");
	}
	const String region_path = dir + String("/") + Util::location_to_filename(loc);
	const String manifest_path = dir + String("/") + Util::LAYER_MANIFEST_FILENAME;
	const String slice_path = dir + String("/") + Util::location_to_layer_filename(loc);
	Ref<DirAccess> dda = DirAccess::open(dir);
	if (dda.is_valid()) {
		for (const String &f : Array::make(Util::location_to_filename(loc), String(Util::LAYER_MANIFEST_FILENAME), Util::location_to_layer_filename(loc))) {
			if (dda->file_exists(f)) {
				dda->remove(f);
			}
		}
	}

	// Build a region with a deterministic height pattern and a Base + ADD "Detail" stack.
	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);
	Ref<Image> height_map = region->get_height_map();
	EXPECT_TRUE(height_map.is_valid() && height_map->get_format() == Image::FORMAT_RF);
	if (height_map.is_null()) {
		memdelete(data);
		return;
	}
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}
	region->set_modified(true);
	PackedByteArray original = height_map->get_data();

	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);

	Ref<Pasture3DLayer> detail;
	detail.instantiate();
	detail->set_layer_name("Detail");
	detail->set_map_type(TYPE_HEIGHT);
	detail->set_tile_size(region_size);
	detail->set_blend_mode(Pasture3DLayer::ADD);
	detail->set_opacity(0.5f);
	detail->set_sample(loc, covered, 5.f, 0.75f);
	detail->set_sample(loc, covered2, -3.f, 1.f);
	stack->add_layer_ref(detail);
	data->set_layer_stack(stack);

	// Save the runtime region file and the layer stack.
	region->save(region_path, false);
	data->save_layers(dir);
	EXPECT_TRUE(FileAccess::file_exists(manifest_path));
	EXPECT_TRUE(FileAccess::file_exists(slice_path));

	// (1) Runtime data unchanged: save_layers must not touch the region image.
	EXPECT_TRUE(height_map->get_data() == original);

	// Reload region from disk into a fresh data, then load the layer stack on top.
	Pasture3DData *data2 = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region2 = ResourceLoader::get_singleton()->load(region_path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	EXPECT_TRUE(region2.is_valid());
	if (region2.is_null()) {
		memdelete(data);
		memdelete(data2);
		return;
	}
	region2->set_location(loc);
	data2->add_region(region2, false);
	Ref<Image> height_map2 = region2->get_height_map();

	// (1 cont.) The loaded runtime image matches the saved one byte-for-byte.
	EXPECT_TRUE(height_map2->get_data() == original);

	const bool loaded = data2->load_layers(dir);
	EXPECT_TRUE(loaded);

	// (2) Stack round-trip: count, metadata, and sampled (value, weight) survive.
	Ref<Pasture3DLayerStack> stack2 = data2->get_layer_stack();
	EXPECT_TRUE(stack2.is_valid());
	EXPECT_TRUE(data2->has_layer_stack());
	EXPECT_TRUE(stack2->get_layer_count() == 2);
	Ref<Pasture3DLayer> detail2 = stack2->get_layer(1);
	EXPECT_TRUE(detail2.is_valid());
	EXPECT_TRUE(detail2->get_layer_name() == String("Detail"));
	EXPECT_TRUE(detail2->get_blend_mode() == Pasture3DLayer::ADD);
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_opacity(), 0.5f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_value(loc, covered), 5.f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_weight(loc, covered), 0.75f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_value(loc, covered2), -3.f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_weight(loc, covered2), 1.f));
	// Uncovered pixels round-trip as uncovered: weight 0 (the signal compositing checks). With one
	// region-sized tile the whole region is allocated, so the value is the zero fill, not NaN.
	EXPECT_TRUE(detail2->get_weight(loc, uncovered) == 0.f);
	EXPECT_TRUE(detail2->get_value(loc, uncovered) == 0.f);

	// (2 cont.) The Base layer aliases the loaded region image, so editing the image is visible
	// through the layer — proving it was re-aliased, not restored from a stale copy.
	Ref<Pasture3DLayer> base2 = stack2->get_layer(0);
	EXPECT_TRUE(base2.is_valid());
	height_map2->set_pixel(5, 5, Color(123.f, 0.f, 0.f, 1.f));
	EXPECT_TRUE(Math::is_equal_approx(base2->get_value(loc, Vector2i(5, 5)), 123.f));

	// (3) No-layer-files: a Base-only stack writes nothing and is removed if stale; load reports none.
	const String plain_dir = "user://p3d_layer_test_plain";
	if (da.is_valid()) {
		da->make_dir_recursive("p3d_layer_test_plain");
	}
	Ref<DirAccess> pda = DirAccess::open(plain_dir);
	if (pda.is_valid() && pda->file_exists(Util::LAYER_MANIFEST_FILENAME)) {
		pda->remove(Util::LAYER_MANIFEST_FILENAME);
	}
	Pasture3DData *data3 = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region3;
	region3.instantiate();
	region3->set_region_size(region_size);
	region3->set_location(loc);
	data3->add_region(region3, false);
	Ref<Pasture3DLayerStack> base_only;
	base_only.instantiate();
	Ref<Pasture3DLayer> b3;
	b3.instantiate();
	b3->set_layer_name("Base");
	b3->set_tile_size(region_size);
	b3->set_blend_mode(Pasture3DLayer::REPLACE);
	b3->set_region_image(loc, region3->get_height_map());
	base_only->add_layer_ref(b3);
	data3->set_layer_stack(base_only);
	data3->save_layers(plain_dir);
	EXPECT_FALSE(FileAccess::file_exists(plain_dir + String("/") + Util::LAYER_MANIFEST_FILENAME));
	EXPECT_FALSE(data3->load_layers(plain_dir));

	memdelete(data);
	memdelete(data2);
	memdelete(data3);
	UtilityFunctions::print("=== End layer persistence tests ===");
}