import json
import os
import subprocess

def get_newlib_path():
    """Ask the riscv elf gcc where its newlib headers live."""
    try:
        result = subprocess.run(
            ["riscv32-esp-elf-gcc", "-print-sysroot"],
            capture_output=True, text=True
        )
        sysroot = result.stdout.strip()
        candidate = os.path.join(sysroot, "include")
        if os.path.isdir(candidate):
            return candidate
    except Exception:
        pass
    return None

def generate():
    try:
        with open('build/compile_commands.json', 'r') as f:
            commands = json.load(f)
        
        include_paths = set()
        for cmd in commands:
            parts = cmd['command'].split()
            for i, part in enumerate(parts):
                if part.startswith('-I'):
                    include_paths.add(part[2:].strip())
                elif part in ('-isystem', '-iwithprefix', '-iwithprefixbefore') and i + 1 < len(parts):
                    include_paths.add(parts[i+1].strip())

        # Inject newlib path so @cImport can resolve sys/features.h
        newlib = get_newlib_path()
        if newlib:
            include_paths.add(newlib)

        with open('main/paths.zig', 'w') as f:
            f.write('pub const include_paths = &[_][]const u8{\n')
            for path in sorted(include_paths):
                clean_path = path.replace("\\", "/")
                f.write(f'    "{clean_path}",\n')
            f.write('};\n')
        print("Successfully generated main/paths.zig")
    except Exception as e:
        print(f"Error generating paths: {e}")

if __name__ == "__main__":
    generate()
