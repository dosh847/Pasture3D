// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_LAYER_STACK_CLASS_H
#define PASTURE3D_LAYER_STACK_CLASS_H

#include "constants.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_util.h"

// An ordered stack of non-destructive height-map layers for a terrain.
//
// Index 0 is the bottom (the dense "Base" layer); higher indices composite over lower ones.
// This is the editor-side source of truth: edits target the active layer, then the stack is
// composited down into the runtime Pasture3DRegion images (phase 2). A terrain with no stack
// behaves exactly as before, so this resource is always optional.
class Pasture3DLayerStack : public Resource {
	GDCLASS(Pasture3DLayerStack, Resource);
	CLASS_NAME();

public: // Constants
	static inline const real_t CURRENT_STACK_VERSION = 0.1f;

private:
	// Saved data
	real_t _version = CURRENT_STACK_VERSION;
	TypedArray<Pasture3DLayer> _layers; // index 0 = Base (bottom), saved in order

	// Working data, not saved
	int _active_layer = 0; // Editor target

public:
	Pasture3DLayerStack() {}
	~Pasture3DLayerStack() {}

	void clear();
	void set_version(const real_t p_version) { _version = CLAMP(p_version, 0.1f, 100.f); }
	real_t get_version() const { return _version; }

	// Layer management
	int get_layer_count() const { return _layers.size(); }
	int add_layer(const String &p_name, const Pasture3DLayer::BlendMode p_blend = Pasture3DLayer::ADD);
	int add_layer_ref(const Ref<Pasture3DLayer> &p_layer);
	void remove_layer(const int p_idx);
	void move_layer(const int p_from, const int p_to);
	Ref<Pasture3DLayer> get_layer(const int p_idx) const;
	Pasture3DLayer *get_layer_ptr(const int p_idx) const;
	int find_layer_by_owner(const String &p_owner_id) const;

	void set_layers(const TypedArray<Pasture3DLayer> &p_layers) { _layers = p_layers; }
	TypedArray<Pasture3DLayer> get_layers() const { return _layers; }

	// Active layer (editor target; not persisted as pixel data)
	int get_active_layer() const { return _active_layer; }
	void set_active_layer(const int p_idx);

	// Serialization
	void set_data(const Dictionary &p_data);
	Dictionary get_data() const;

protected:
	static void _bind_methods();
};

#endif // PASTURE3D_LAYER_STACK_CLASS_H
