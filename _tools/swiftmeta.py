#!/usr/bin/env python3
"""
swiftmeta.py — recover Swift nominal type + field metadata from a Mach-O.

A stripped Swift binary still ships its *reflection metadata*: the sections
__swift5_types (one descriptor per struct/class/enum) and __swift5_fieldmd
(one field descriptor per nominal type, listing every stored property or
enum case by name). None of that is symbol-table dependent, so it survives
`strip` and gives back the app's type and property vocabulary.

Outputs JSON:

  {
    "types":   [{"name": "...", "mangled": "...", "kind": "struct|enum|class",
                 "fields": [{"name": "...", "type": "...", "flags": N}]}],
    "filemap": {"TypeName": "SourceFileName.swift"}   # inferred, best-effort
  }

Usage:
    swiftmeta.py <macho-file> [--json out.json] [--types]
"""

import json
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from macho import MachO  # noqa: E402

DEMANGLER = ("/Applications/Xcode.app/Contents/Developer/Toolchains/"
             "XcodeDefault.xctoolchain/usr/bin/swift-demangle")


# ------------------------------------------------------------------ helpers

def cstr_at(m, va, maxlen=1024):
    """Read a NUL-terminated UTF-8 string at a virtual address."""
    if va is None or va <= 0:
        return None
    try:
        data = m.read_va(va, maxlen)
    except ValueError:
        return None
    z = data.find(b"\x00")
    if z >= 0:
        data = data[:z]
    if not data or len(data) > 400:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def rel_target(base_va, offset):
    """Swift RelativeDirectPointer: target = address-of-pointer + offset."""
    if offset == 0:
        return None
    return base_va + offset


# ------------------------------------------------------------------ demangle

def demangle_all(names):
    """
    Batch-demangle through the Xcode swift-demangle binary. Returns
    {mangled: demangled} for every input that demangled.
    """
    names = [n for n in dict.fromkeys(names) if n]
    if not names:
        return {}
    if not os.path.exists(DEMANGLER):
        return {}
    payload = "\n".join(names) + "\n"
    try:
        p = subprocess.run([DEMANGLER, "--simplified", "--compact"],
                           input=payload, capture_output=True, text=True, timeout=180)
    except Exception:
        return {}
    lines = p.stdout.splitlines()
    out = {}
    # swift-demangle echoes input lines that it cannot handle, and may wrap
    # long results, so only trust 1:1 line correspondence.
    if len(lines) != len(names):
        return {}
    for raw, dem in zip(names, lines):
        if dem != raw and dem.strip():
            out[raw] = dem
    return out


# ------------------------------------------------------- type descriptors

def parse_swift5_types(m):
    """
    __swift5_types is an array of TypeMetadataRecord (one per nominal type).

    Each entry is a RelativeDirectPointerIntPair<TargetContextDescriptor,
    TypeReferenceKind> (swift/ABI/Metadata.h TargetTypeMetadataRecord):
      int32  RelativeOffsetPlusInt
        low 2 bits = TypeReferenceKind (0=direct, 1=indirect, 2/3=ObjC)
        high bits = (delta from this slot) & ~3   -- 4-byte aligned

    IndirectTypeDescriptor (kind 1) stores a *pointer* to the descriptor at
    the target address, so it must be dereferenced.

    TargetTypeContextDescriptor layout (swift/ABI/Metadata.h):
       +0  uint32  flags          (TargetContextDescriptor)
       +4  int32   parent         (relative)
       +8  int32   name           (relative, -> cstring)
      +12  int32   accessFunction (compact function pointer, nullable)
      +16  int32   fieldDescriptor (relative, nullable)
      +20  uint32  extra flags    (kindSpecific)
    """
    sec = m.find("__TEXT", "__swift5_types")
    if sec is None or sec.size == 0:
        return []

    out = []
    data = m.raw[sec.offset:sec.offset + sec.size]
    for i in range(0, len(data) - 4 + 1, 4):
        (off,) = struct.unpack_from("<i", data, i)
        entry_va = sec.addr + i
        ref_kind = off & 3
        target = entry_va + (off & ~3)     # RelativeDirectPointerIntPair

        if ref_kind == 1:
            # IndirectTypeDescriptor: the slot points at a full pointer
            ptr_bytes = m.read_va(target, 8) if _mapped(m, target) else None
            if not ptr_bytes or len(ptr_bytes) < 8:
                continue
            (target,) = struct.unpack_from("<Q", ptr_bytes)
            if not _mapped(m, target):
                continue
        elif ref_kind != 0:
            # DirectObjCClassName / IndirectObjCClass never appear here
            continue

        # validate: name pointer at +8 must resolve to a plausible cstring
        name_off_bytes = m.read_va(target + 8, 4) if _mapped(m, target + 8) else None
        if not name_off_bytes or len(name_off_bytes) < 4:
            continue
        (name_off,) = struct.unpack("<i", name_off_bytes)
        name = cstr_at(m, target + 8 + name_off) if name_off else None
        if not name or not _plausible_ident(name):
            continue

        # field descriptor at +16
        fd = None
        fd_bytes = m.read_va(target + 16, 4) if _mapped(m, target + 16) else None
        if fd_bytes and len(fd_bytes) == 4:
            (fd_off,) = struct.unpack("<i", fd_bytes)
            if fd_off:
                fd = target + 16 + fd_off
                if not _mapped(m, fd):
                    fd = None

        out.append({"name": name, "descriptor_va": target, "field_descriptor_va": fd})

    # de-duplicate on descriptor address
    seen = set()
    uniq = []
    for t in out:
        if t["descriptor_va"] in seen:
            continue
        seen.add(t["descriptor_va"])
        uniq.append(t)
    return uniq


def _mapped(m, va):
    return m.va_to_off(va) is not None


def _plausible_ident(s):
    if not s or len(s) > 300:
        return False
    bad = set(' \t\n\r"\\')
    return not (set(s) & bad)


# ------------------------------------------------------ field descriptors

def parse_field_descriptor(m, va):
    """
    FieldDescriptor (swift/RemoteInspection/Records.h, official layout):
       +0  int32   MangledTypeName   (RelativeDirectPointer<const char>)
       +4  int32   Superclass        (RelativeDirectPointer)
       +8  uint16  Kind              (FieldDescriptorKind)
      +10  uint16  FieldRecordSize
      +12  uint32  NumFields
      +16  FieldRecord[NumFields]

    FieldRecord (same header):
       +0  uint32  Flags             (FieldRecordFlags: 1 indirect, 2 var, 4 artificial)
       +4  int32   MangledTypeName   (RelativeDirectPointer)
       +8  int32   FieldName         (RelativeDirectPointer -> __swift5_reflstr)
      =12  bytes (RecordSize is always sizeof(FieldRecord))

    FieldDescriptorKind: 0=Struct 1=Class 2=Enum 3=MultiPayloadEnum
                         4=Protocol 5=ClassProtocol 6=ObjCProtocol
                         7=ObjCClass 8=COMProtocol
    """
    hdr = m.read_va(va, 16) if _mapped(m, va) else None
    if hdr is None or len(hdr) < 16:
        return None

    (mangled_off, super_off) = struct.unpack_from("<ii", hdr, 0)
    # MangledTypeName member sits at +0 of the FieldDescriptor; resolve the
    # relative pointer from that member's own address (official Records.h).
    mangled = cstr_at(m, va + 0 + mangled_off) if mangled_off else None

    (kind,) = struct.unpack_from("<H", hdr, 8)
    (rec_size,) = struct.unpack_from("<H", hdr, 10)
    (num,) = struct.unpack_from("<I", hdr, 12)
    if num > 4096:
        return None
    if rec_size not in (12, 0):
        return None          # official: FieldRecordSize == sizeof(FieldRecord) == 12
    if num > 0 and rec_size == 0:
        return None
    fields = _read_fields(m, va + 16, 12, num)
    if fields is None:
        return None
    if kind not in (0, 1, 2, 3):
        return None          # keep only Struct/Class/Enum(+MultiPayloadEnum)
    return {"mangled": mangled, "kind": kind, "fields": fields}


def _read_fields(m, va, rec_size, num):
    if num == 0:
        return []
    if num * rec_size > 0x40000:
        return None
    if not _mapped(m, va):
        return None
    raw = m.read_va(va, num * rec_size)
    if raw is None or len(raw) < num * rec_size:
        return None
    out = []
    for i in range(num):
        base = va + i * rec_size
        (flags, type_off, name_off) = struct.unpack_from("<Iii", raw, i * rec_size)
        # RelativeDirectPointer resolves from the *member's own address*:
        # MangledTypeName member sits at base+4, FieldName at base+8
        # (TargetFieldRecord per swift/RemoteInspection/Records.h).
        name = cstr_at(m, base + 8 + name_off) if name_off else None
        if name is None or not _plausible_ident(name):
            return None
        mangled_type = cstr_at(m, base + 4 + type_off) if type_off else None
        out.append({"name": name, "type_mangled": mangled_type, "flags": flags})
    return out


KIND_NAMES = {0: "struct", 1: "class", 2: "enum", 3: "multipayload_enum"}


# ---------------------------------------------------------------- file map

def infer_file_map(m, type_names):
    """
    Best-effort mapping from Swift type name -> source file name.

    The string table still contains the original #file / #fileID literals
    that Swift bakes into assertions and logging. When a type name appears
    in the same cstring neighbourhood as a "Something.swift" literal we can
    pair them, but anything stronger than adjacency is guesswork, so this
    returns only unambiguous, single-candidate matches.
    """
    sec = m.find("__TEXT", "__cstring")
    if sec is None:
        return {}
    strings = [s for s in _split_cstrings(m.raw[sec.offset:sec.offset + sec.size])]

    swift_files = []
    for s in strings:
        if s.endswith(".swift") and "/" not in s and len(s) < 80:
            swift_files.append(s)
        elif ".swift" in s:
            # e.g. "/Users/x/conductor/.../CompanionManager.swift"
            tail = s.split("/")[-1]
            if tail.endswith(".swift") and len(tail) < 80:
                swift_files.append(tail)

    by_stem = {}
    for f in set(swift_files):
        stem = f[:-len(".swift")]
        by_stem.setdefault(stem.lower(), set()).add(f)

    out = {}
    for t in type_names:
        candidates = by_stem.get(t.lower())
        if candidates and len(candidates) == 1:
            out[t] = next(iter(candidates))
    return out


def _split_cstrings(data, min_len=2):
    out, cur = [], bytearray()
    for b in data:
        if b == 0:
            if len(cur) >= min_len:
                try:
                    out.append(cur.decode("utf-8"))
                except UnicodeDecodeError:
                    pass
            cur = bytearray()
        elif 32 <= b < 127 or b >= 0x80:
            cur.append(b)
        else:
            if len(cur) >= min_len:
                try:
                    out.append(cur.decode("utf-8"))
                except UnicodeDecodeError:
                    pass
            cur = bytearray()
    if len(cur) >= min_len:
        try:
            out.append(cur.decode("utf-8"))
        except UnicodeDecodeError:
            pass
    return out


# -------------------------------------------------------------------- main

def build(path):
    m = MachO(path)

    descriptors = parse_swift5_types(m)

    types = []
    mangled_pool = []
    for d in descriptors:
        entry = {"name": d["name"], "mangled": None, "kind": "unknown", "fields": []}
        fdv = d["field_descriptor_va"]
        if fdv:
            fd = parse_field_descriptor(m, fdv)
            if fd:
                entry["mangled"] = fd["mangled"]
                entry["kind"] = KIND_NAMES.get(fd["kind"], "unknown")
                entry["fields"] = fd["fields"]
                for f in fd["fields"]:
                    if f["type_mangled"]:
                        mangled_pool.append(f["type_mangled"])
        if entry["mangled"]:
            mangled_pool.append(entry["mangled"])
        types.append(entry)

    # demangle everything in one batch
    dem = demangle_all(mangled_pool)
    for t in types:
        if t["mangled"]:
            t["demangled"] = dem.get(t["mangled"], t["mangled"])
        else:
            t["demangled"] = f"HeyClicky.{t['name']}"
        for f in t["fields"]:
            tm = f.pop("type_mangled", None)
            f["type"] = dem.get(tm, _simplify(tm)) if tm else None

    filemap = infer_file_map(m, [t["name"] for t in types])

    return {
        "path": path,
        "type_count": len(types),
        "types": types,
        "filemap": filemap,
    }


def _simplify(mangled):
    """Cheap fallback when swift-demangle can't be reached."""
    if not mangled:
        return None
    s = mangled
    for pre in ("$s", "_$s", "$S"):
        if s.startswith(pre):
            s = s[len(pre):]
    return s


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    result = build(path)

    if "--json" in sys.argv:
        outp = sys.argv[sys.argv.index("--json") + 1]
        with open(outp, "w") as f:
            json.dump(result, f, ensure_ascii=False, indent=1)
        print(f"wrote {outp}")

    if "--types" in sys.argv or "--json" not in sys.argv:
        for t in result["types"]:
            print(f"\n{t['kind']:<8} {t['demangled']}")
            for f in t["fields"]:
                print(f"           {f['name']}: {f['type']}")

    print(f"\n{result['type_count']} nominal types, "
          f"{len(result['filemap'])} name->file matches", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
