#!/usr/bin/env python3
"""Generate R.java for merged library resources.

The APK is built by hand (aapt2 + javac + d8) instead of Gradle, so AGP never
creates an R class for the libraries whose res/ we merge into the app package.
Without it, references such as androidx.fragment.R$id or
com.google.android.gms.base.R$string resolve to nothing and throw
NoClassDefFoundError the first time those code paths run.

Usage: genlibR.py <linked.apk> <gen-root> "<aar>|<java package>" ...

The APK's resource table holds the ids aapt2 actually assigned, so every
(type, name) in an AAR's R.txt is looked up there. styleable arrays are
synthetic (they never appear in the table) and carry their constants inline in
R.txt, so they are emitted verbatim.
"""
import os
import re
import subprocess
import sys
import zipfile

AAPT2 = "/root/android-sdk/build-tools/34.0.0/aapt2"


def dump_ids(apk):
    out = subprocess.run([AAPT2, "dump", "resources", apk],
                         capture_output=True, text=True, check=True).stdout
    ids = {}
    for line in out.splitlines():
        m = re.match(r"\s+resource 0x([0-9a-fA-F]+) ([a-zA-Z][a-zA-Z0-9_-]*)/(\S+)", line)
        if m:
            ids[(m.group(2), m.group(3))] = int(m.group(1), 16)
    return ids


def parse_r_txt(text):
    simple = []   # (type, name)
    arrays = []   # (name, [raw values])
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.match(r"int\[\] (\w+) (\w+) \{ (.*) \}$", line)
        if m:
            arrays.append((m.group(2), [v.strip() for v in m.group(3).split(",") if v.strip()]))
            continue
        m = re.match(r"int (\w+) (\w+) ", line)
        if m:
            typ, name = m.group(1), m.group(2)
            if typ == "styleable":
                continue  # index constants; unused, arrays above carry the data
            simple.append((typ, name))
    return simple, arrays


def emit(pkg, ids, simple, arrays, out_root):
    nested = {}
    missing = []
    for typ, name in simple:
        rid = ids.get((typ, name))
        if rid is None and "_" in name:
            # aapt2 reports style entries with their dotted parent name
            # (TextAppearance.Compat.Notification) while R.txt keeps the
            # underscore form androidx.core uses in code.
            rid = ids.get((typ, name.replace("_", ".")))
        if rid is None:
            missing.append("%s/%s" % (typ, name))
        else:
            nested.setdefault(typ, []).append((name, rid))

    lines = ["package %s;" % pkg, "", "/** Generated from the merged resource table; do not edit. */",
             "public final class R {"]
    for typ in sorted(nested):
        lines.append("    public static final class %s {" % typ)
        for name, rid in sorted(nested[typ]):
            lines.append("        public static final int %s = 0x%08x;" % (name, rid))
        lines.append("    }")
    if arrays:
        lines.append("    public static final class styleable {")
        for name, vals in sorted(arrays):
            lines.append("        public static final int[] %s = { %s };"
                         % (name, ", ".join(vals) if vals else ""))
        lines.append("    }")
    lines.append("}")

    d = os.path.join(out_root, *pkg.split("."))
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "R.java")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return path, missing


def main():
    apk, out_root = sys.argv[1], sys.argv[2]
    ids = dump_ids(apk)
    for pair in sys.argv[3:]:
        aar, pkg = pair.split("|")
        with zipfile.ZipFile(aar) as z:
            try:
                text = z.read("R.txt").decode("utf-8")
            except KeyError:
                print("  %-42s (no R.txt)" % pkg)
                continue
        simple, arrays = parse_r_txt(text)
        path, missing = emit(pkg, ids, simple, arrays, out_root)
        print("  %-42s %4d ids, %2d styleable %s"
              % (pkg, len(simple) - len(missing), len(arrays),
                 ("MISSING " + ",".join(missing[:5])) if missing else ""))
        if not path:
            sys.exit("failed to write R for " + pkg)


if __name__ == "__main__":
    main()
