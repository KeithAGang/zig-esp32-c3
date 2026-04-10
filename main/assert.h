// Mock assert.h to satisfy Zig's @cImport in freestanding mode.
// CMake and GCC will use the real ESP-IDF assert during final linking.
#pragma once
#define assert(x) ((void)(x))
