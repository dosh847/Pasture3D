// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_REGISTER_TYPES_H
#define PASTURE3D_REGISTER_TYPES_H

#ifdef GDEXTENSION
#include <godot_cpp/godot.hpp>
using namespace godot;
#else
#include "modules/register_module_types.h"
#endif

// NOTE: These have module ending for custom module build compatibility.
void initialize_pasture_3d_module(ModuleInitializationLevel p_level);
void uninitialize_pasture_3d_module(ModuleInitializationLevel p_level);

#endif // PASTURE3D_REGISTER_TYPES_H
