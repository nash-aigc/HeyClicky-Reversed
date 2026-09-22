#!/usr/bin/env python3
"""
extract_sections.py — parse a Mach-O (thin slice) and dump named sections as strings.

For HeyClicky.app/Contents/MacOS/HeyClicky (stripped Swift binary):
  * __cstring          -> user-facing strings, URLs, error messages, prompts
  * __objc_classname   -> Objective-C-visible class names (usually NOT stripped)
  * __objc_methname    -> Objective-C method names
  * __swift5_reflstr   -> Swift reflection strings (property names of structs/enums)
  * __swift5_fieldmd   -> field descriptor metadata (type+field names of structs)
  * __const / __constg_swiftt -> const data + Swift type metadata descriptors
  * __swift5_typeref   -> type reference strings

Usage: extract_sections.py <macho-file> <output-dir>
"""
import sys, os, struct, subprocess, re

def parse_segments(path):
    """Run otool -l to get segment/section vmaddr,fileoff,filesize for the (first) slice."""
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    segs = []   # list of (segname, vmaddr, fileoff, filesize, sections[])
    sections = []  # (segname, sectname, vmaddr, fileoff, filesize)
    cur_seg = None
    cur_sect = None
    for line in out.splitlines():
        s = line.strip()
        m = re.match(r"segname (\S+)", s)
        if m:
            cur_seg = {"name": m.group(1)}
            cur_sect = None
            continue
        m = re.match(r"sectname (\S+)", s)
        if m and cur_seg is not None:
            cur_sect = {"name": m.group(1)}
            continue
        if cur_sect is not None:
            m = re.match(r"addr (0x[0-9a-fA-F]+)", s)
            if m: cur_sect["vmaddr"] = int(m.group(1), 16)
            m = re.match(r"size (0x[0-9a-fA-F]+)", s)
            if m: cur_sect["size"] = int(m.group(1), 16)
            m = re.match(r"offset (\d+)", s)
            if m: cur_sect["fileoff"] = int(m.group(1))
            if "vmaddr" in cur_sect and "size" in cur_sect and "fileoff" in cur_sect:
                sections.append((cur_seg["name"], cur_sect["name"],
                                 cur_sect["vmaddr"], cur_sect["fileoff"], cur_sect["size"]))
                cur_sect = None
    return sections

def dump_strings(raw, offset, size, min_len=3):
    """Extract printable cstrings from a raw region."""
    data = raw[offset:offset + size]
    out = []
    cur = bytearray()
    for b in data:
        if b == 0:
            if len(cur) >= min_len:
                try:
                    s = cur.decode("utf-8")
                except UnicodeDecodeError:
                    s = cur.decode("latin1")
                out.append(s)
            cur = bytearray()
        elif 32 <= b < 127 or b >= 128:
            cur.append(b)
        else:
            if len(cur) >= min_len:
                try:
                    s = cur.decode("utf-8")
                except UnicodeDecodeError:
                    s = cur.decode("latin1")
                out.append(s)
            cur = bytearray()
    if len(cur) >= min_len:
        try:
            s = cur.decode("utf-8")
        except UnicodeDecodeError:
            s = cur.decode("latin1")
        out.append(s)
    return out

def main():
    path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    raw = open(path, "rb").read()
    sections = parse_segments(path)
    # only the FIRST slice's sections (arm64 or x86_64)
    seen = set()
    for seg, sect, vmaddr, fileoff, size in sections:
        key = (seg, sect)
        if key in seen:
            continue
        seen.add(key)
        if size == 0:
            continue
        # sanity: fileoff+size within file
        if fileoff + size > len(raw):
            continue
        # whole-region raw copy (trim trailing zeros)
        region = raw[fileoff:fileoff + size]
        if sect.startswith("__swift5_fieldmd"):
            fname = f"{seg}-{sect}-fieldmd.hex"
        else:
            fname = f"{seg}-{sect}.bin"
        with open(os.path.join(outdir, fname), "wb") as f:
            f.write(region)
        # strings dump for text-ish sections
        if sect in ("__cstring", "__objc_classname", "__objc_methname",
                    "__swift5_reflstr", "__swift5_typeref", "__constg_swiftt",
                    "__swift5_protos", "__swift5_associated_types",
                    "__swift5_protocol_conformances"):
            strs = dump_strings(raw, fileoff, size, min_len=2)
            with open(os.path.join(outdir, f"{seg}-{sect}.strings.txt"), "w") as f:
                f.write(f"# {seg} {sect} vmaddr=0x{vmaddr:x} fileoff={fileoff} size={size}\n")
                f.write(f"# {len(strs)} strings\n\n")
                f.write("\n".join(strs))
    print(f"done -> {outdir}")

if __name__ == "__main__":
    main()
