#!/usr/bin/env python3
"""
swiftsyms.py — harvest every mangled Swift symbol that survived `strip`.

When a Swift binary is stripped, the *symbol table* goes away but the
*metadata* does not: reflection records, conformance descriptors and
type-context descriptors all reference their own mangled names as literal
strings inside __TEXT,__const. Batch-demangling those gives back the app's
full vocabulary — types, properties, methods with signatures, protocol
witnesses — without a decompiler.

Usage:
    swiftsyms.py <macho-file> [--json out.json] [--module HeyClicky]
"""

import json
import os
import re
import struct
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from macho import MachO, extract_cstrings  # noqa: E402

DEMANGLER = ("/Applications/Xcode.app/Contents/Developer/Toolchains/"
             "XcodeDefault.xctoolchain/usr/bin/swift-demangle")

# A mangled Swift name: optional leading underscore, `$s`/`$S`, then a module
# reference and the rest of the mangling. The tail is deliberately loose —
# demangler failures are filtered afterwards.
MANGLED = re.compile(r"^_?\$[sS][0-9A-Za-z_$][0-9A-Za-z_$.]*$")

# Things that come out of SwiftUI protocol conformances and are noise when
# you're trying to read the app's own design.
NOISE_SUFFIX = (
    "body.getter", "body.modify", "Body", "makeBody(configuration:).getter",
)


def demangle_batch(names, chunk=4000):
    """Demangle a list of mangled names in chunks. Returns {mangled: plain}."""
    out = {}
    if not os.path.exists(DEMANGLER):
        return out
    names = list(dict.fromkeys(names))
    for i in range(0, len(names), chunk):
        batch = names[i:i + chunk]
        payload = "\n".join(batch) + "\n"
        try:
            p = subprocess.run([DEMANGLER, "--simplified"],
                               input=payload, capture_output=True,
                               text=True, timeout=300)
        except Exception:
            continue
        lines = p.stdout.splitlines()
        if len(lines) != len(batch):
            # one bad line derails the 1:1 mapping; fall back to per-line
            for n in batch:
                try:
                    q = subprocess.run([DEMANGLER, "--simplified"],
                                       input=n + "\n", capture_output=True,
                                       text=True, timeout=20)
                    line = q.stdout.strip()
                    if line and line != n:
                        out[n] = line
                except Exception:
                    pass
            continue
        for raw, plain in zip(batch, lines):
            if plain and plain != raw:
                out[raw] = plain
    return out


def harvest(path, module="HeyClicky"):
    m = MachO(path)
    found = defaultdict(set)

    # 1. literal mangled strings sitting in data sections
    for seg, sect in (("__TEXT", "__const"), ("__TEXT", "__cstring"),
                      ("__TEXT", "__constg_swiftt"), ("__DATA_CONST", "__const"),
                      ("__TEXT", "__swift5_reflstr")):
        sec = m.find(seg, sect)
        if sec is None or sec.size == 0:
            continue
        for s in extract_cstrings(m.raw[sec.offset:sec.offset + sec.size], min_len=8):
            if MANGLED.match(s):
                found[s].add(f"{seg},{sect}")

    # 2. reflection strings that look like identifiers (property names)
    refl = m.find("__TEXT", "__swift5_reflstr")
    refl_strings = set()
    if refl and refl.size:
        refl_strings = set(extract_cstrings(
            m.raw[refl.offset:refl.offset + refl.size], min_len=1))

    plain = demangle_batch(list(found.keys()))

    # ---- organise by module and by type ------------------------------
    # NOTE: swift-demangle strips the module prefix from its output, so the
    # owning module has to be read off the *mangled* name, not the plain one.
    own, foreign = {}, {}
    for mangled, plain_name in plain.items():
        mod = module_of(mangled)
        dem = f"{mod}.{plain_name}" if mod else plain_name
        rec = {"mangled": mangled, "plain": dem, "found_in": sorted(found[mangled])}
        if mod == module:
            own[mangled] = rec
        else:
            foreign.setdefault(mod or "?", {})[mangled] = rec

    # ---- bucket the app's own symbols by their type -------------------
    by_type = defaultdict(lambda: {"members": [], "kinds": set()})
    free_functions = []
    for mangled, rec in own.items():
        tname, kind = owning_type(rec["plain"], module)
        if tname is None:
            free_functions.append(rec)
        else:
            by_type[tname]["members"].append(rec)
            by_type[tname]["kinds"].add(kind)

    return {
        "path": path,
        "module": module,
        "counts": {
            "own": len(own),
            "foreign_modules": len(foreign),
            "own_types": len(by_type),
            "free_functions": len(free_functions),
            "reflection_strings": len(refl_strings),
        },
        "own": own,
        "by_type": {k: {"members": [x["plain"] for x in v["members"]],
                        "kinds": sorted(v["kinds"])}
                    for k, v in sorted(by_type.items())},
        "free_functions": [r["plain"] for r in free_functions],
        "foreign_modules": {k: [r["plain"] for r in v.values()]
                            for k, v in sorted(foreign.items())},
        "reflection_strings": sorted(refl_strings),
    }


def module_of(mangled):
    """
    Pull the module name out of a mangling. Module refs are
    <len><identifier>: $s9HeyClicky13KeyCapChipRowV -> HeyClicky (the
    identifier is EXACTLY `len` characters; longer trailing identifiers
    must not be consumed).
    """
    s = mangled
    if s.startswith("_"):
        s = s[1:]
    if s.startswith("$s") or s.startswith("$S"):
        s = s[2:]
    else:
        return None
    m = re.match(r"(\d+)", s)
    if not m:
        return None
    n = int(m.group(1))
    name = s[m.end():m.end() + n]
    if not name or len(name) != n:
        return None
    if not name[0].isalpha() and name[0] != "_":
        return None
    return name


def owning_type(plain, module="HeyClicky"):
    """
    From a module-qualified demangled signature, work out which nominal type
    it hangs off. `plain` is expected to look like 'HeyClicky.Foo.bar.getter'.
    Returns (type_name, kind) or (None, 'free') for a free function.
    """
    if not plain:
        return None, None
    prefix = module + "."
    if not plain.startswith(prefix):
        # extension declared elsewhere: '(extension in Mod): HeyClicky.Foo.m()'
        m = re.search(r"\b" + re.escape(prefix), plain)
        if not m:
            return None, "free"
        plain = plain[m.start():]
    rest = plain[len(prefix):]
    m = re.match(r"^([A-Za-z_][\w]*)(?:\.|$)", rest)
    if not m:
        return None, "free"
    return m.group(1), "member"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    module = "HeyClicky"
    if "--module" in sys.argv:
        module = sys.argv[sys.argv.index("--module") + 1]

    r = harvest(path, module)

    print(json.dumps(r["counts"], indent=1), file=sys.stderr)

    if "--json" in sys.argv:
        outp = sys.argv[sys.argv.index("--json") + 1]
        with open(outp, "w") as f:
            json.dump(r, f, ensure_ascii=False, indent=1)
        print(f"wrote {outp}", file=sys.stderr)
    else:
        for t, info in r["by_type"].items():
            print(f"\n## {t}")
            for m_ in info["members"]:
                print(f"   {m_}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
