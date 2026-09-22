#!/usr/bin/env python3
"""
macho.py — minimal, dependency-free Mach-O reader.

Parses fat and thin Mach-O files directly from the load commands (no otool
scraping), and exposes the two things we actually need for reversing:

  * every (segment, section) with its vmaddr / file offset / size
  * the ability to read a section's bytes, or read a virtual address

Usage as a library:
    from macho import MachO
    m = MachO("/tmp/hc_arm64")
    for s in m.sections:
        print(s.seg, s.sect, hex(s.addr), hex(s.size))
    data = m.section_bytes("__TEXT", "__cstring")
    text = m.read_va(0x100002a30, 64)

Usage as a CLI:
    macho.py <file>                     # list slices + sections
    macho.py <file> --dump <outdir>     # dump every section to files
"""

import os
import struct
import sys
from dataclasses import dataclass

# ---------------------------------------------------------------- constants

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_MAGIC_32 = 0xFEEDFACE
MH_CIGAM_32 = 0xCEFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA

LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB

CPU_NAMES = {
    7: "x86", 0x01000007: "x86_64",
    12: "arm", 0x0100000C: "arm64",
    0x0200000C: "arm64_32",
}

# Sections that are worth turning into text automatically.
TEXTISH = {
    "__cstring", "__objc_classname", "__objc_methname", "__objc_methtype",
    "__objc_methlist_names", "__swift5_reflstr", "__swift5_typeref",
    "__constg_swiftt", "__swift5_types", "__swift5_protos",
    "__swift5_proto", "__swift5_assocty", "__swift5_builtin",
    "__swift5_capture", "__swift5_mpenum", "__swift5_entry",
    "__swift5_replace", "__swift5_fieldmd", "__swift5_super",
    "__ustring", "__const", "__cfstring", "__oslogstring",
}


# ---------------------------------------------------------------- data types

@dataclass
class Section:
    seg: str
    sect: str
    addr: int
    offset: int          # file offset of the section body
    size: int
    align: int = 0
    flags: int = 0

    @property
    def name(self):
        return f"{self.seg},{self.sect}"


@dataclass
class Slice:
    offset: int          # offset of this slice within the file
    size: int
    cputype: int
    cpusubtype: int
    is64: bool


# ---------------------------------------------------------------- reader

class MachO:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.raw = f.read()
        self.slices = self._read_slices()
        self.sections = []
        self._segments = []          # (name, vmaddr, vmsize, fileoff, filesize)
        self._parse_all()

    # ---- slice table -------------------------------------------------
    def _read_slices(self):
        raw = self.raw
        if len(raw) < 8:
            raise ValueError("file too small to be Mach-O")
        magic = struct.unpack_from(">I", raw, 0)[0]

        if magic in (FAT_MAGIC, FAT_MAGIC_64, FAT_CIGAM, FAT_CIGAM_64):
            is64 = magic in (FAT_MAGIC_64, FAT_CIGAM_64)
            n = struct.unpack_from(">I", raw, 4)[0]
            slices = []
            foff = 8
            for _ in range(n):
                if is64:
                    cputype, cpusub, off, size, align, _res = struct.unpack_from(">iiQQII", raw, foff)
                    foff += 32
                else:
                    cputype, cpusub, off, size, align = struct.unpack_from(">iiIII", raw, foff)
                    foff += 20
                # endianness of the fat header can be swapped
                if magic in (FAT_CIGAM, FAT_CIGAM_64):
                    cputype = _bswap32(cputype)
                    cpusub = _bswap32(cpusub)
                    off = _bswap32(off)
                    size = _bswap32(size)
                slices.append(Slice(off, size, cputype, cpusub, True))
            return slices

        # thin file — one slice covering the whole thing
        cputype, cpusub, _ft, _nc, _sz, _fl = struct.unpack_from("<iiIIII", raw, 4)
        return [Slice(0, len(raw), cputype, cpusub, magic == MH_MAGIC_64)]

    # ---- load commands ------------------------------------------------
    def _parse_all(self):
        for sl in self.slices:
            self._parse_slice(sl)

    def _parse_slice(self, sl):
        raw = self.raw
        base = sl.offset
        magic = struct.unpack_from("<I", raw, base)[0]

        if magic in (MH_MAGIC_64, MH_MAGIC_32):
            endian = "<"
        elif magic in (MH_CIGAM_64, MH_CIGAM_32):
            endian = ">"
        else:
            return  # not a Mach-O slice (could be a fat archive member we mis-framed)

        is64 = magic in (MH_MAGIC_64, MH_CIGAM_64)
        hdrsize = 32 if is64 else 28
        ncmds = struct.unpack_from(endian + "I", raw, base + 16)[0]
        p = base + hdrsize

        for _ in range(ncmds):
            if p + 8 > len(raw):
                break
            cmd, cmdsize = struct.unpack_from(endian + "II", raw, p)
            if cmdsize < 8:
                break

            if cmd == LC_SEGMENT_64 and is64:
                segname = _cstr(raw, p + 8, 16)
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from(endian + "QQQQ", raw, p + 24)
                nsects = struct.unpack_from(endian + "I", raw, p + 64)[0]
                self._segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                sp = p + 72
                for _s in range(nsects):
                    sectname = _cstr(raw, sp, 16)
                    sgname = _cstr(raw, sp + 16, 16)
                    addr, size = struct.unpack_from(endian + "QQ", raw, sp + 32)
                    (offset,) = struct.unpack_from(endian + "I", raw, sp + 48)
                    align, _reloff, _nreloc, flags = struct.unpack_from(endian + "IIII", raw, sp + 52)
                    self.sections.append(Section(sgname or segname, sectname,
                                                 addr, offset, size, align, flags))
                    sp += 80

            elif cmd == LC_SEGMENT and not is64:
                # 32-bit — kept for completeness, HeyClicky has no 32-bit slice
                segname = _cstr(raw, p + 8, 16)
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from(endian + "IIII", raw, p + 24)
                nsects = struct.unpack_from(endian + "I", raw, p + 48)[0]
                self._segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                sp = p + 56
                for _s in range(nsects):
                    sectname = _cstr(raw, sp, 16)
                    sgname = _cstr(raw, sp + 16, 16)
                    addr, size, offset = struct.unpack_from(endian + "III", raw, sp + 32)
                    align, _reloff, _nreloc, flags = struct.unpack_from(endian + "IIII", raw, sp + 44)
                    self.sections.append(Section(sgname or segname, sectname,
                                                 addr, offset, size, align, flags))
                    sp += 68

            p += cmdsize

    # ---- accessors ----------------------------------------------------
    def find(self, seg, sect):
        for s in self.sections:
            if s.seg == seg and s.sect == sect:
                return s
        return None

    def all_named(self, sect):
        return [s for s in self.sections if s.sect == sect]

    def section_bytes(self, seg, sect):
        s = self.find(seg, sect)
        if s is None:
            raise KeyError(f"no section {seg},{sect}")
        return self.raw[s.offset:s.offset + s.size]

    def read_va(self, va, n):
        """Read n bytes at virtual address va (walks the segment table)."""
        for name, vmaddr, vmsize, fileoff, filesize in self._segments:
            if vmaddr <= va < vmaddr + vmsize:
                delta = va - vmaddr
                if delta + n > filesize:
                    n = max(0, filesize - delta)
                return self.raw[fileoff + delta:fileoff + delta + n]
        raise ValueError(f"va 0x{va:x} not mapped")

    def va_to_off(self, va):
        for name, vmaddr, vmsize, fileoff, filesize in self._segments:
            if vmaddr <= va < vmaddr + vmsize:
                return fileoff + (va - vmaddr)
        return None

    def off_to_va(self, off):
        for name, vmaddr, vmsize, fileoff, filesize in self._segments:
            if fileoff <= off < fileoff + filesize:
                return vmaddr + (off - fileoff)
        return None

    def section_at_va(self, va):
        for s in self.sections:
            if s.addr <= va < s.addr + s.size:
                return s
        return None


def _bswap32(v):
    return struct.unpack("<I", struct.pack(">I", v & 0xFFFFFFFF))[0]


def _cstr(raw, off, maxlen):
    chunk = raw[off:off + maxlen]
    z = chunk.find(b"\x00")
    if z >= 0:
        chunk = chunk[:z]
    return chunk.decode("utf-8", "replace")


# ---------------------------------------------------------------- string mining

def extract_cstrings(data, min_len=3):
    """
    Null-terminated printable strings. Accepts UTF-8 continuation bytes so
    non-ASCII (Chinese UI strings) survive.
    """
    out = []
    cur = bytearray()
    for b in data:
        if b == 0:
            if len(cur) >= min_len:
                out.append(_decode(cur))
            cur = bytearray()
        elif 32 <= b < 127 or b >= 0x80:
            cur.append(b)
        else:
            if len(cur) >= min_len:
                out.append(_decode(cur))
            cur = bytearray()
    if len(cur) >= min_len:
        out.append(_decode(cur))
    return out


def _decode(buf):
    try:
        return buf.decode("utf-8")
    except UnicodeDecodeError:
        return buf.decode("latin-1")


def extract_swift_strings(data, min_len=2):
    """
    Swift string literals live back-to-back in __cstring / __swift5_reflstr
    with no alignment padding. Run the same cstring scan but keep short
    fragments too, since reflection strings are often single identifiers.
    """
    return extract_cstrings(data, min_len=min_len)


def extract_beam(data, wordsize=4):
    """
    __swift5_typeref and friends are arrays of 32-bit *relative* pointers.
    Return the resolved target VAs and whether each is indirect.
    """
    out = []
    for i in range(0, len(data) - wordsize + 1, wordsize):
        (v,) = struct.unpack_from("<i", data, i)
        indirect = (v & 1) == 1
        out.append((i, v >> 1, indirect))
    return out


# ---------------------------------------------------------------- CLI

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    path = sys.argv[1]
    m = MachO(path)

    print(f"file      {path}")
    print(f"size      {len(m.raw):,} bytes")
    print(f"slices    {len(m.slices)}")
    for i, sl in enumerate(m.slices):
        print(f"  [{i}] {CPU_NAMES.get(sl.cputype & 0xFFFFFFFF, hex(sl.cputype)):<8} "
              f"subtype=0x{sl.cpusubtype:x} offset={sl.offset:,} size={sl.size:,}")
    print()

    if "--dump" in sys.argv:
        outdir = sys.argv[sys.argv.index("--dump") + 1]
        os.makedirs(outdir, exist_ok=True)
        seen = {}
        n = 0
        for s in m.sections:
            if s.size == 0 or s.offset + s.size > len(m.raw):
                continue
            body = m.raw[s.offset:s.offset + s.size]
            key = s.name
            seen[key] = seen.get(key, 0) + 1
            if seen[key] > 1:
                key = f"{key}#{seen[key]}"
            stem = key.replace(",", "-")
            with open(os.path.join(outdir, stem + ".bin"), "wb") as f:
                f.write(body)
            n += 1
            if s.sect in TEXTISH:
                strs = extract_cstrings(body, min_len=2)
                with open(os.path.join(outdir, stem + ".strings.txt"), "w") as f:
                    f.write(f"# {s.name}  vmaddr=0x{s.addr:x}  offset={s.offset}  size={s.size}\n")
                    f.write(f"# {len(strs)} strings\n\n")
                    f.write("\n".join(strs))
        print(f"dumped {n} sections -> {outdir}")
        return 0

    print(f"{'segment':<18} {'section':<26} {'vmaddr':>14} {'offset':>12} {'size':>12}")
    print("-" * 88)
    for s in m.sections:
        if s.size == 0:
            continue
        print(f"{s.seg:<18} {s.sect:<26} 0x{s.addr:>12x} {s.offset:>12,} {s.size:>12,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
