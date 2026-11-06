"""Read build metadata and add dylib load commands without moving file contents"""

import struct
from reader import MachO, MachOError

DYLIB_COMMANDS = {0xC, 0x20, 0x80000018, 0x8000001F, 0x80000023}
VERSION_COMMANDS = {0x24: 1, 0x25: 2, 0x2F: 3, 0x30: 4}

def commands(binary: MachO):
    offset = 32
    while offset < binary.header_size:
        command, size = struct.unpack_from("<II", binary.data, offset)
        yield command, offset, size
        offset += size

def build_platform(binary: MachO) -> int:
    platforms = []
    for command, offset, size in commands(binary):
        if command == 0x32:
            if size < 24:
                raise MachOError("Truncated LC_BUILD_VERSION")
            
            platform, _, _, tools = struct.unpack_from("<4I", binary.data, offset + 8)
            if 24 + tools * 8 > size:
                raise MachOError("Truncated build tool table")
            
            platforms.append(platform)
        elif command in VERSION_COMMANDS:
            if size < 16:
                raise MachOError("Truncated minimum OS command")
            
            platforms.append(VERSION_COMMANDS[command])
    if len(platforms) != 1:
        raise MachOError("Expected one Mach-O build platform")
    
    return platforms[0]

def dylib_names(binary: MachO) -> set[str]:
    names = set()
    for command, offset, size in commands(binary):
        if command not in DYLIB_COMMANDS:
            continue
        
        if size < 24:
            raise MachOError("Truncated dylib load command")

        start = struct.unpack_from("<I", binary.data, offset + 8)[0]
        if not 24 <= start < size:
            raise MachOError("Invalid dylib name offset")

        name = binary.data[offset + start : offset + size]
        if b"\0" not in name:
            raise MachOError("Unterminated dylib name")
        names.add(name.split(b"\0", 1)[0].decode("utf-8"))
    return names

def add_dylibs(data: bytes, names: list[str], *, reserved_bytes: int = 0) -> bytes:
    if reserved_bytes < 0:
        raise MachOError("Reserved header space cannot be negative")
    binary = MachO(data)
    existing = dylib_names(binary)
    content_offsets = []
    for command, offset, size in commands(binary):
        if command == 0x19:
            fileoff, filesize = struct.unpack_from("<QQ", data, offset + 40)
            if fileoff and filesize:
                content_offsets.append(fileoff)

            sections = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(sections):
                section = offset + 72 + index * 80
                length = struct.unpack_from("<Q", data, section + 40)[0]
                start = struct.unpack_from("<I", data, section + 48)[0]
                flags = struct.unpack_from("<I", data, section + 64)[0]

                if not length or (flags & 0xFF) in (1, 0xC, 0x12):
                    continue

                if start < binary.header_size or start + length > len(data):
                    raise MachOError("Invalid file-backed section range")
                content_offsets.append(start)

    added = bytearray()
    for name in names:
        if not name or "\0" in name:
            raise MachOError("Invalid dylib load path")
        
        if name in existing:
            raise MachOError(f"Dylib is already loaded: {name}")
        existing.add(name)
        encoded = name.encode("utf-8") + b"\0"
        size = (24 + len(encoded) + 7) // 8 * 8
        command = struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + encoded
        added.extend(command.ljust(size, b"\0"))

    start = binary.header_size
    end = start + len(added)
    reserved_end = end + reserved_bytes
    if (not content_offsets or reserved_end > min(content_offsets) or reserved_end > len(data) or any(data[start:reserved_end])):
        raise MachOError("Not enough unused Mach-O header space for dylib load commands")
    
    result = bytearray(data)
    result[start:end] = added
    count, size = struct.unpack_from("<II", result, 16)
    struct.pack_into("<II", result, 16, count + len(names), size + len(added))
    MachO(result)
    return bytes(result)