// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "logger.h"
#include "pasture_3d_layer_stack.h"

/////////////////////
// Public Functions
/////////////////////

void Pasture3DLayerStack::clear() {
	_version = CURRENT_STACK_VERSION;
	_layers.clear();
	_active_layer = 0;
}

int Pasture3DLayerStack::add_layer(const String &p_name, const Pasture3DLayer::BlendMode p_blend) {
	Ref<Pasture3DLayer> layer;
	layer.instantiate();
	layer->set_layer_name(p_name);
	layer->set_blend_mode(p_blend);
	return add_layer_ref(layer);
}

int Pasture3DLayerStack::add_layer_ref(const Ref<Pasture3DLayer> &p_layer) {
	if (p_layer.is_null()) {
		LOG(ERROR, "Cannot add a null layer");
		return -1;
	}
	_layers.push_back(p_layer);
	LOG(INFO, "Added layer '", p_layer->get_layer_name(), "' at index ", _layers.size() - 1);
	return _layers.size() - 1;
}

void Pasture3DLayerStack::remove_layer(const int p_idx) {
	if (p_idx < 0 || p_idx >= _layers.size()) {
		LOG(ERROR, "Layer index ", p_idx, " out of range [0, ", _layers.size(), ")");
		return;
	}
	if (p_idx == 0) {
		LOG(ERROR, "Cannot remove the Base layer (index 0)");
		return;
	}
	_layers.remove_at(p_idx);
	if (_active_layer >= _layers.size()) {
		_active_layer = _layers.size() - 1;
	}
}

void Pasture3DLayerStack::move_layer(const int p_from, const int p_to) {
	if (p_from < 0 || p_from >= _layers.size() || p_to < 0 || p_to >= _layers.size()) {
		LOG(ERROR, "Move indices out of range: ", p_from, " -> ", p_to);
		return;
	}
	if (p_from == p_to) {
		return;
	}
	if (p_from == 0 || p_to == 0) {
		LOG(ERROR, "The Base layer must stay at index 0");
		return;
	}
	Ref<Pasture3DLayer> layer = _layers[p_from];
	_layers.remove_at(p_from);
	_layers.insert(p_to, layer);
}

Ref<Pasture3DLayer> Pasture3DLayerStack::get_layer(const int p_idx) const {
	if (p_idx < 0 || p_idx >= _layers.size()) {
		return Ref<Pasture3DLayer>();
	}
	return _layers[p_idx];
}

Pasture3DLayer *Pasture3DLayerStack::get_layer_ptr(const int p_idx) const {
	if (p_idx < 0 || p_idx >= _layers.size()) {
		return nullptr;
	}
	return cast_to<Pasture3DLayer>(_layers[p_idx]);
}

int Pasture3DLayerStack::find_layer_by_owner(const String &p_owner_id) const {
	if (p_owner_id.is_empty()) {
		return -1;
	}
	for (int i = 0; i < _layers.size(); i++) {
		const Pasture3DLayer *layer = cast_to<Pasture3DLayer>(_layers[i]);
		if (layer && layer->get_owner_id() == p_owner_id) {
			return i;
		}
	}
	return -1;
}

void Pasture3DLayerStack::set_active_layer(const int p_idx) {
	if (p_idx < 0 || p_idx >= _layers.size()) {
		LOG(ERROR, "Active layer index ", p_idx, " out of range [0, ", _layers.size(), ")");
		return;
	}
	_active_layer = p_idx;
}

void Pasture3DLayerStack::set_data(const Dictionary &p_data) {
	if (p_data.has("version")) {
		_version = p_data["version"];
	}
	if (p_data.has("layers")) {
		_layers = p_data["layers"];
	}
}

Dictionary Pasture3DLayerStack::get_data() const {
	Dictionary dict;
	dict["version"] = _version;
	dict["layers"] = _layers;
	return dict;
}

/////////////////////
// Protected Functions
/////////////////////

void Pasture3DLayerStack::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear"), &Pasture3DLayerStack::clear);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &Pasture3DLayerStack::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Pasture3DLayerStack::get_version);

	ClassDB::bind_method(D_METHOD("get_layer_count"), &Pasture3DLayerStack::get_layer_count);
	ClassDB::bind_method(D_METHOD("add_layer", "name", "blend_mode"), &Pasture3DLayerStack::add_layer, DEFVAL(Pasture3DLayer::ADD));
	ClassDB::bind_method(D_METHOD("add_layer_ref", "layer"), &Pasture3DLayerStack::add_layer_ref);
	ClassDB::bind_method(D_METHOD("remove_layer", "index"), &Pasture3DLayerStack::remove_layer);
	ClassDB::bind_method(D_METHOD("move_layer", "from", "to"), &Pasture3DLayerStack::move_layer);
	ClassDB::bind_method(D_METHOD("get_layer", "index"), &Pasture3DLayerStack::get_layer);
	ClassDB::bind_method(D_METHOD("find_layer_by_owner", "owner_id"), &Pasture3DLayerStack::find_layer_by_owner);

	ClassDB::bind_method(D_METHOD("set_layers", "layers"), &Pasture3DLayerStack::set_layers);
	ClassDB::bind_method(D_METHOD("get_layers"), &Pasture3DLayerStack::get_layers);

	ClassDB::bind_method(D_METHOD("get_active_layer"), &Pasture3DLayerStack::get_active_layer);
	ClassDB::bind_method(D_METHOD("set_active_layer", "index"), &Pasture3DLayerStack::set_active_layer);

	ClassDB::bind_method(D_METHOD("set_data", "data"), &Pasture3DLayerStack::set_data);
	ClassDB::bind_method(D_METHOD("get_data"), &Pasture3DLayerStack::get_data);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "layers", PROPERTY_HINT_ARRAY_TYPE, "Pasture3DLayer", ro_flags), "set_layers", "get_layers");
}
