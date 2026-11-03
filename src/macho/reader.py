"""Mach-O parsing and core-memory reads.

File layouts follow XNU's EXTERNAL_HEADERS/mach-o/loader.h
"""

from __future__ import annotations

import hashlib
import mmap
import struct
from bisect import bisect_right
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

MAGIC = b"\xcf\xfa\xed\xfe"
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}

MH_EXECUTE = 2
MH_CORE = 4
MH_DYLIB = 6
MH_BUNDLE = 8

LC_SEGMENT_64 = 0x19
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
SG_HIGHVM = 1
INSTRUCTION_ATTRIBUTES = 0x80000400

MACH_HEADER_SIZE = 32
SEGMENT64_SIZE = 72
SECTION64_SIZE = 80
MAX_LOAD_COMMAND_BYTES = 64 * 1024 * 1024


class MachOError(ValueError):
    pass


@dataclass(frozen=True)
class Segment:
    name: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    flags: int

    @property
    def stored_vmaddr(self) -> int:
        if self.flags & SG_HIGHVM:
            return self.vmaddr + self.vmsize - self.filesize
        return self.vmaddr


@dataclass(frozen=True)
class Encryption:
    cryptoff: int
    cryptsize: int
    cryptid: int
    id_offset: int


class MachO:
    def __init__(self, data):
        self.data = data
        if bytes(data[:4]) in FAT_MAGICS:
            raise MachOError(
                "Universal/FAT Mach-O is unsupported; supply a thin 64-bit executable"
            )
        if len(data) < MACH_HEADER_SIZE or data[:4] != MAGIC:
            raise MachOError("Expected a little-endian 64-bit Mach-O")
        _, self.cpu, self.subtype, self.filetype, ncmds, sizeofcmds, _, _ = (
            struct.unpack_from("<8I", data)
        )
        self.header_size = MACH_HEADER_SIZE + sizeofcmds
        if (
            self.header_size > len(data)
            or sizeofcmds > MAX_LOAD_COMMAND_BYTES
            or ncmds > sizeofcmds // 8
        ):
            raise MachOError("Invalid or truncated load command table")
        self.segments: list[Segment] = []
        self.instruction_ranges: list[tuple[int, int]] = []
        self.encryption: Encryption | None = None
        cursor = MACH_HEADER_SIZE
        for _ in range(ncmds):
            if cursor + 8 > self.header_size:
                raise MachOError("Truncated load command")
            cmd, size = struct.unpack_from("<II", data, cursor)
            if size < 8 or size % 8 or cursor + size > self.header_size:
                raise MachOError("Invalid load command size")
            if cmd == LC_SEGMENT_64:
                self._read_segment(cursor, size)
            elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
                self._read_encryption(cursor, size, cmd)
            cursor += size
        if cursor != self.header_size:
            raise MachOError("Load command count and size disagree")

    def _read_segment(self, offset: int, command_size: int) -> None:
        if command_size < SEGMENT64_SIZE:
            raise MachOError("Truncated LC_SEGMENT_64")

        fields = struct.unpack_from("<16sQQQQiiII", self.data, offset + 8)
        name, vmaddr, vmsize, fileoff, filesize, _, _, nsects, flags = fields
        sections_end = SEGMENT64_SIZE + nsects * SECTION64_SIZE
        if (
            sections_end > command_size
            or filesize > vmsize
            or fileoff + filesize > len(self.data)
        ):
            raise MachOError("Invalid segment file range or section table")

        self.segments.append(
            Segment(
                name.rstrip(b"\0").decode("ascii", "replace"),
                vmaddr,
                vmsize,
                fileoff,
                filesize,
                flags,
            )
        )
        for index in range(nsects):
            section_offset = offset + SEGMENT64_SIZE + index * SECTION64_SIZE
            section = struct.unpack_from("<16s16sQQIIIIIIII", self.data, section_offset)
            section_size, file_offset, section_flags = (
                section[3],
                section[4],
                section[8],
            )
            if not section_size or not section_flags & INSTRUCTION_ATTRIBUTES:
                continue
            if file_offset < fileoff or file_offset + section_size > fileoff + filesize:
                raise MachOError("Instruction section exceeds stored segment")
            self.instruction_ranges.append((file_offset, section_size))

    def _read_encryption(self, offset: int, size: int, command: int) -> None:
        minimum_size = 24 if command == LC_ENCRYPTION_INFO_64 else 20
        if size < minimum_size or self.encryption is not None:
            raise MachOError("Invalid or duplicate encryption command")

        cryptoff, cryptsize, cryptid = struct.unpack_from("<III", self.data, offset + 8)
        if cryptoff + cryptsize > len(self.data):
            raise MachOError("Encrypted range exceeds executable")
        self.encryption = Encryption(cryptoff, cryptsize, cryptid, offset + 16)

    def segment_for_file_range(self, offset: int, size: int) -> Segment:
        matches = [
            segment
            for segment in self.segments
            if segment.filesize
            and segment.fileoff <= offset
            and offset + size <= segment.fileoff + segment.filesize
        ]
        if len(matches) != 1:
            raise MachOError(
                "File range must be contained in exactly one stored segment"
            )
        return matches[0]

    @property
    def preferred_base(self) -> int:
        segment = self.segment_for_file_range(0, self.header_size)
        return segment.stored_vmaddr - segment.fileoff

    def normalized_header(self, header: bytes | None = None) -> bytes:
        if header is None:
            header = self.data[: self.header_size]
        result = bytearray(header)
        if self.encryption:
            struct.pack_into("<I", result, self.encryption.id_offset, 0)
        return bytes(result)

    def info(self) -> dict:
        encryption_info = None
        if self.encryption:
            encryption_info = {
                "cryptoff": self.encryption.cryptoff,
                "cryptsize": self.encryption.cryptsize,
                "cryptid": self.encryption.cryptid,
                "cryptid_offset": self.encryption.id_offset,
            }
        return {
            "cpu": hex(self.cpu),
            "filetype": self.filetype,
            "preferred_base": hex(self.preferred_base),
            "encryption": encryption_info,
            "segments": [
                {
                    "name": segment.name,
                    "vmaddr": hex(segment.vmaddr),
                    "fileoff": segment.fileoff,
                    "filesize": segment.filesize,
                    "vmsize": segment.vmsize,
                }
                for segment in self.segments
            ],
        }


class Core:
    def __init__(self, path: Path):
        self._resources = ExitStack()
        try:
            self.file = self._resources.enter_context(path.open("rb"))
            if not path.stat().st_size:
                raise MachOError("Empty core dump")
            self.data = self._resources.enter_context(
                mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
            )
            self.macho = MachO(self.data)
            if self.macho.filetype != MH_CORE:
                raise MachOError("Input is not a Mach-O core dump (MH_CORE)")
            self.segments = sorted(
                (segment for segment in self.macho.segments if segment.filesize),
                key=lambda segment: segment.stored_vmaddr,
            )
            self.starts = [segment.stored_vmaddr for segment in self.segments]
            for left, right in zip(self.segments, self.segments[1:]):
                if left.stored_vmaddr + left.filesize > right.stored_vmaddr:
                    raise MachOError("Overlapping stored VM ranges in core")
        except Exception:
            self._resources.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self._resources.close()

    def read(self, address: int, size: int) -> bytes:
        if address < 0 or size < 0:
            raise MachOError("Negative memory address or length")
        parts = []
        remaining = size
        while remaining:
            index = bisect_right(self.starts, address) - 1
            if index < 0:
                raise MachOError(f"Memory missing from core at {hex(address)}")
            segment = self.segments[index]
            offset = address - segment.stored_vmaddr
            length = min(remaining, segment.filesize - offset)
            if length <= 0:
                raise MachOError(f"Memory missing from core at {hex(address)}")
            start = segment.fileoff + offset
            parts.append(self.data[start : start + length])
            remaining -= length
            address += length
        return b"".join(parts)

    def find_bases(self, original: MachO) -> list[int]:
        if (self.macho.cpu, self.macho.subtype) != (original.cpu, original.subtype):
            raise MachOError("Core and executable CPU types/subtypes differ")
        reference = original.normalized_header()
        bases = set()
        for segment in self.segments:
            start, end = segment.fileoff, segment.fileoff + segment.filesize
            while start < end:
                found = self.data.find(MAGIC, start, end)
                if found == -1:
                    break
                address = segment.stored_vmaddr + found - segment.fileoff
                try:
                    header = self.read(address, original.header_size)
                    if original.normalized_header(header) == reference:
                        bases.add(address)
                except MachOError:
                    pass
                start = found + 4
        return sorted(bases)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _clear_instruction_samples(
    original: MachO, encryption: Encryption
) -> list[tuple[int, bytes]]:
    """Return preferred addresses and bytes from unencrypted code."""
    samples = []
    encrypted_end = encryption.cryptoff + encryption.cryptsize
    for offset, size in original.instruction_ranges:
        intervals = [
            (
                max(offset, original.header_size),
                min(offset + size, encryption.cryptoff),
            ),
            (max(offset, encrypted_end), offset + size),
        ]
        for start, end in intervals:
            if end <= start:
                continue
            length = min(64, end - start)
            for position in sorted({start, end - length}):
                segment = original.segment_for_file_range(position, length)
                address = segment.stored_vmaddr + position - segment.fileoff
                samples.append((address, original.data[position : position + length]))
    return samples


def analyze(core: Core, original: MachO) -> dict:
    encryption = original.encryption
    if encryption is None or encryption.cryptid == 0:
        raise MachOError(
            "Executable is already unencrypted or has no encryption command"
        )
    if encryption.cryptsize == 0 or encryption.cryptoff < original.header_size:
        raise MachOError("Empty encrypted range or range overlaps load commands")

    segment = original.segment_for_file_range(encryption.cryptoff, encryption.cryptsize)
    encrypted_end = encryption.cryptoff + encryption.cryptsize
    disk = original.data[encryption.cryptoff : encrypted_end]
    samples = _clear_instruction_samples(original, encryption)
    candidates = []
    for base in core.find_bases(original):
        slide = base - original.preferred_base
        address = slide + segment.stored_vmaddr + encryption.cryptoff - segment.fileoff
        candidate = {"base": hex(base), "slide": hex(slide), "address": hex(address)}
        try:
            memory = core.read(address, encryption.cryptsize)
            differs_from_disk = memory != disk
            has_data = any(memory)
            candidate.update(
                {
                    "sha256": digest(memory),
                    "first32": memory[:32].hex(),
                    "differs_from_disk": differs_from_disk,
                    "usable": differs_from_disk and has_data,
                }
            )
            if not differs_from_disk:
                candidate["reason"] = "unchanged encrypted bytes"
            elif not has_data:
                candidate["reason"] = "all-zero memory"

            checks = [
                core.read(slide + preferred_address, len(expected)) == expected
                for preferred_address, expected in samples
            ]
            candidate["clear_instruction_checks"] = {
                "matched": sum(checks),
                "total": len(checks),
            }
            if not all(checks):
                candidate.update(
                    {
                        "usable": False,
                        "reason": "unencrypted instruction samples do not match",
                    }
                )
        except MachOError as error:
            candidate.update({"usable": False, "reason": str(error)})
        candidates.append(candidate)
    return {
        "binary": original.info(),
        "disk_sha256": digest(disk),
        "disk_first32": disk[:32].hex(),
        "candidates": candidates,
    }


def choose_candidate(report: dict, base: int | None = None) -> dict:
    candidates = [
        candidate
        for candidate in report["candidates"]
        if candidate["usable"] and (base is None or int(candidate["base"], 16) == base)
    ]
    if len(candidates) != 1:
        raise MachOError(
            f"Expected one usable runtime base, found {len(candidates)}; "
            "inspect the report and select --base explicitly if ambiguous"
        )
    return candidates[0]


def patch_bytes(original: bytes, region: bytes) -> bytes:
    binary = MachO(original)
    encryption = binary.encryption
    if not encryption or encryption.cryptid == 0 or encryption.cryptsize == 0:
        raise MachOError("Expected a nonempty encrypted executable")
    if len(region) != encryption.cryptsize:
        raise MachOError(
            f"Region length {len(region)} != cryptsize {encryption.cryptsize}"
        )
    if encryption.cryptoff < binary.header_size:
        raise MachOError("Encrypted range overlaps load commands")
    binary.segment_for_file_range(encryption.cryptoff, encryption.cryptsize)

    start = encryption.cryptoff
    end = start + encryption.cryptsize
    if region == original[start:end] or not any(region):
        raise MachOError("Refusing unchanged or all-zero replacement bytes")

    patched = bytearray(original)
    patched[start:end] = region
    struct.pack_into("<I", patched, encryption.id_offset, 0)
    result = bytes(patched)

    patched_binary = MachO(result)
    if (
        len(result) != len(original)
        or not patched_binary.encryption
        or patched_binary.encryption.cryptid != 0
    ):
        raise MachOError("Patched executable verification failed")
    return result
