const std = @import("std");
const idf_data = @import("main/paths.zig");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .linux,
        .abi = .musl,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.esp32c3 },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main/app.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
        }),
    });

    lib.root_module.addCMacro("ESP_PLATFORM", "1");
    lib.root_module.addCMacro("__IEEE_LITTLE_ENDIAN", "1");
    lib.root_module.addCMacro("FORCE_INLINE_ATTR", "static inline");
    // wint_t is expected to be pre-defined by the compiler before newlib's
    // sys/_types.h uses it. Musl-mode clang doesn't provide it, so define it
    // explicitly. On riscv32 newlib it's always unsigned int (32-bit).
    lib.root_module.addCMacro("__WINT_TYPE__", "unsigned int");

    // In build.zig, add these two lines with the other macros:
    lib.root_module.addCMacro("_WINT_T_DECLARED", "1"); // tells newlib "wint_t already exists, skip redeclaration"
    lib.root_module.addCMacro("wint_t", "unsigned int"); // provides the actual type

    // THE REAL FIX: esp_cpu.h contains inline bodies that call rv_utils_* and
    // esprv_* functions, but it includes those headers AFTER using them.
    // Clang (unlike GCC with its sysroot/specs) sees implicit declarations first,
    // then the real static-inline definitions, and flags "redefinition".
    //
    // Solution: add a cImport prefix header that pulls in the riscv headers
    // FIRST, so by the time esp_cpu.h's inline bodies are parsed, the functions
    // are already declared with the correct types.
    lib.root_module.addCMacro(
        "ESP_IDF_RISCV_COMPAT",
        "1",
    );

    // Newlib path must be first
    lib.root_module.addIncludePath(.{ .cwd_relative = "/home/keithgang/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/riscv32-esp-elf/include" });
    lib.root_module.addIncludePath(.{ .cwd_relative = "/home/keithgang/.espressif/v6.0/esp-idf/components/newlib/platform_include" });

    for (idf_data.include_paths) |path| {
        lib.root_module.addIncludePath(.{ .cwd_relative = path });
    }

    b.installArtifact(lib);
}
