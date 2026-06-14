// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_COMPAT_CLASS_H
#define PASTURE3D_COMPAT_CLASS_H

#include "pasture_3d_assets.h"
#include "pasture_3d_material.h"
#include "pasture_3d_mesh_asset.h"
#include "pasture_3d_region.h"
#include "pasture_3d_texture_asset.h"

// Backward-compatibility classes.
//
// Terrain3D 1.0.x saved its terrain data and resources (region .res, material/assets .tres) with
// the class name baked into the file. After the Pasture3D rebrand those names no longer exist, so
// the files would fail to load. Registering these empty subclasses keeps the old names resolvable,
// so old data deserializes into a Pasture3D* object. Region data is then migrated to the new class
// and re-saved under the new pasture3d_*.res name (see Pasture3DData::load_directory).
//
// These add no behavior; they exist only so ResourceLoader can instantiate the legacy type.

class Terrain3DRegion : public Pasture3DRegion {
	GDCLASS(Terrain3DRegion, Pasture3DRegion);

protected:
	static void _bind_methods() {}
};

class Terrain3DMaterial : public Pasture3DMaterial {
	GDCLASS(Terrain3DMaterial, Pasture3DMaterial);

protected:
	static void _bind_methods() {}
};

class Terrain3DAssets : public Pasture3DAssets {
	GDCLASS(Terrain3DAssets, Pasture3DAssets);

protected:
	static void _bind_methods() {}
};

class Terrain3DMeshAsset : public Pasture3DMeshAsset {
	GDCLASS(Terrain3DMeshAsset, Pasture3DMeshAsset);

protected:
	static void _bind_methods() {}
};

class Terrain3DTextureAsset : public Pasture3DTextureAsset {
	GDCLASS(Terrain3DTextureAsset, Pasture3DTextureAsset);

protected:
	static void _bind_methods() {}
};

#endif // PASTURE3D_COMPAT_CLASS_H
