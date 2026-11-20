#!/usr/bin/env python3
"""Audit the ELF dependency closure of a rootfs payload.

Why this exists: the runtime checks in test_extract.sh run guest binaries through
the guest loader from a directory on the *host*. That loader still resolves
absolute DT_NEEDED paths such as /lib/aarch64-linux-gnu/libexpat.so.1 against the
host filesystem, so a payload that is missing a library can look healthy while
being broken on a device that has no host libraries at all. That is precisely how
1.0.22-l shipped without libexpat.so.1.8.7 (see docs/known-issues.md row 34).

This script resolves DT_NEEDED strictly inside the payload. Anything it cannot
find is a file the device will not have; anything it reports is a real defect.

Usage: check_elf_deps.py <tree> [...] [--vscode <vscode-tree>]
Exit code 0 when the closure is complete, 1 when something is missing.
"""
import os
import struct
import sys

DT_NEEDED = 1
DT_STRTAB = 5
PT_LOAD = 1
PT_DYNAMIC = 2


def elf_needed(path):
    """Return (needed, interpreter) for an aarch64 ELF, or None if not an ELF."""
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return None
    if len(data) < 64 or data[:4] != b'\x7fELF':
        return None
    if data[4] != 2:  # not ELFCLASS64
        return None
    e_phoff, = struct.unpack_from('<Q', data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from('<HH', data, 0x36)
    loads, dynamic = [], None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 56 > len(data):
            break
        p_type, = struct.unpack_from('<I', data, off)
        p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from('<QQQQQQ', data, off + 8)
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == PT_DYNAMIC:
            dynamic = (p_offset, p_filesz)
    if dynamic is None:
        return [], None

    def vaddr_to_off(vaddr):
        for va, fo, size in loads:
            if va <= vaddr < va + size:
                return fo + (vaddr - va)
        return None

    dyn_off, dyn_size = dynamic
    needed_offsets, strtab_vaddr = [], None
    for i in range(dyn_size // 16):
        off = dyn_off + i * 16
        if off + 16 > len(data):
            break
        tag, val = struct.unpack_from('<QQ', data, off)
        if tag == 0:
            break
        if tag == DT_NEEDED:
            needed_offsets.append(val)
        elif tag == DT_STRTAB:
            strtab_vaddr = val
    interp = None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from('<I', data, off)
        if p_type == 3:  # PT_INTERP
            p_offset, = struct.unpack_from('<Q', data, off + 8)
            p_filesz, = struct.unpack_from('<Q', data, off + 32)
            interp = data[p_offset:p_offset + p_filesz].rstrip(b'\0').decode('utf-8', 'replace')
    needed = []
    if strtab_vaddr is not None:
        str_off = vaddr_to_off(strtab_vaddr)
        if str_off is not None:
            for noff in needed_offsets:
                start = str_off + noff
                end = data.index(b'\0', start)
                needed.append(data[start:end].decode('utf-8', 'replace'))
    return needed, interp


# Directories a payload ELF would find libraries in, in loader order.
LIB_SUBDIRS = [
    'usr/lib/aarch64-linux-gnu', 'lib/aarch64-linux-gnu',
    'usr/lib', 'lib', 'usr/lib64', 'lib64', 'usr/local/lib',
]


def main(argv):
    trees, vscode = [], None
    i = 1
    while i < len(argv):
        if argv[i] == '--vscode':
            i += 1
            vscode = argv[i]
        else:
            trees.append(argv[i])
        i += 1
    if not trees:
        print('usage: check_elf_deps.py <tree> [...] [--vscode <vscode-tree>]')
        return 2

    # Collect the libraries the payload actually provides.
    available = {}
    for tree in trees:
        roots = [tree] + ([vscode] if vscode else [])
        for root in roots:
            if not os.path.isdir(root):
                continue
            for sub in LIB_SUBDIRS:
                d = os.path.join(root, sub)
                if not os.path.isdir(d):
                    continue
                try:
                    entries = os.listdir(d)
                except OSError:
                    continue
                for name in entries:
                    if '.so' in name:
                        available.setdefault(name, os.path.join(d, name))

    missing = {}
    scanned = 0
    for tree in trees:
        for dirpath, _, filenames in os.walk(tree):
            for name in filenames:
                p = os.path.join(dirpath, name)
                if os.path.islink(p) or not os.access(p, os.X_OK):
                    continue
                info = elf_needed(p)
                if not info:
                    continue
                needed, interp = info
                scanned += 1
                # The interpreter may live in any of the payload trees: the
                # vscode tree's node binary asks for /lib/ld-linux-aarch64.so.1,
                # which the rootfs provides.
                if interp and not any(os.path.exists(os.path.join(t, interp.lstrip('/')))
                                      for t in trees):
                    missing.setdefault('interp ' + interp, []).append(p)
                for lib in needed:
                    if lib not in available:
                        missing.setdefault(lib, []).append(p)

    print('scanned %d ELF executables/libraries' % scanned)
    if not missing:
        print('ELF_DEPS_OK: every DT_NEEDED library and interpreter is inside the payload')
        return 0
    print('ELF_DEPS_MISSING: %d unresolved dependency name(s)' % len(missing))
    for lib in sorted(missing):
        users = missing[lib]
        print('  %-34s needed by %d file(s), e.g. %s'
              % (lib, len(users), os.path.relpath(users[0], trees[0])))
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))