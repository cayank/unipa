"""Select compatible Mach-O slices and thin copied binaries"""

import os
import stat
import struct
import tempfile
from pathlib import Path
from reader import FAT_MAGICS, MachO, MachOError

FAT_FORMATS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}

def architecture_score(cpu: int, subtype: int, target: MachO) -> int:
    if cpu != target.cpu:
        return 0

    if subtype == target.subtype:
        return 2

    if (cpu == 0x100000C and subtype == 0) or (cpu == 0x1000007 and subtype == 3):
        return 1

    return 0

def select_slice(data: bytes, target: MachO) -> tuple[bytes, bool]:
    if data[:4] not in FAT_MAGICS:
        binary = MachO(data)
        if not architecture_score(binary.cpu, binary.subtype, target):
            raise MachOError("Binary architecture does not match the app")

        return data, False

    if len(data) < 8:
        raise MachOError("Truncated universal header")

    endian, wide = FAT_FORMATS[data[:4]]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    record_size = 32 if wide else 20
    table_end = 8 + count * record_size

    if not count or table_end > len(data):
        raise MachOError("Invalid universal architecture table")

    slices = []
    ranges = []
    for index in range(count):
        record = struct.unpack_from(
            endian + ("IIQQII" if wide else "IIIII"), data, 8 + index * record_size
        )

        cpu, subtype, offset, size, alignment = record[:5]
        if (
            alignment > (63 if wide else 31)
            or offset < table_end
            or not size
            or offset + size > len(data)
            or offset % (1 << alignment)
            or (wide and record[5])
        ):
            raise MachOError("Invalid universal slice range or alignment")

        ranges.append((offset, offset + size))
        score = architecture_score(cpu, subtype, target)
        if score:
            slices.append((score, cpu, subtype, offset, size))

    ranges.sort()
    if any(left[1] > right[0] for left, right in zip(ranges, ranges[1:])):
        raise MachOError("Universal slices overlap")

    if not slices:
        raise MachOError("Universal binary has no architecture matching the app")

    best = max(item[0] for item in slices)
    matches = [item for item in slices if item[0] == best]
    if len(matches) != 1:
        raise MachOError("Universal binary has ambiguous matching architectures")

    _, cpu, subtype, offset, size = matches[0]
    selected = data[offset : offset + size]
    binary = MachO(selected)
    if (binary.cpu, binary.subtype) != (cpu, subtype):
        raise MachOError("Universal slice header disagrees with its architecture table")

    return selected, True

def read_binary(path: Path, target: MachO) -> tuple[MachO, bool]:
    data = path.read_bytes()
    thinned = False
    if data[:4] in FAT_MAGICS:
        data, thinned = select_slice(data, target)
    return MachO(data), thinned

def _thin_binary(path: Path, target: MachO) -> bool:
    data, thinned = select_slice(path.read_bytes(), target)
    if not thinned:
        return False

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
        temporary.chmod(stat.S_IMODE(path.stat().st_mode))
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True

def thin_bundle(inspection: dict) -> dict:
    app = Path(inspection["path"])
    target = MachO(Path(inspection["executable"]).read_bytes())
    thinned = []
    for filename in inspection["universal"]:
        path = Path(filename)
        relative = path.relative_to(app)
        if _thin_binary(path, target):
            thinned.append(str(relative))
    return {"binaries": thinned}