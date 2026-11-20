#!/bin/sh
# Rebuild android-app/assets/runtime/rootfs.tar.gz with extra Debian packages
# merged in, so a clean device never has to run apt first.
#
# Why this script exists: the first two rounds of doing this by hand shipped a
# rootfs that was missing files, and nobody noticed because the tools that would
# have used them were run in a container where /lib resolves to the *host's*
# libraries. Both traps documented in docs/known-issues.md row 34 are handled
# here so they cannot bite a third time:
#
#   1. dpkg-deb -x empties the destination directory's existing contents, so
#      every package is unpacked into its own scratch directory and merged after.
#   2. Ubuntu 22.04 is merged-usr: /lib and /bin are symlinks to usr/lib and
#      usr/bin. Packages still ship files under ./lib/, and cp refuses to merge a
#      directory onto a symlink ("cannot overwrite non-directory"), silently
#      skipping those files. They are therefore explicitly re-merged into
#      usr/lib and usr/bin.
#
# Usage: pack-rootfs.sh <deb-dir> <output.tar.gz> [base.tar.gz]
#   deb-dir     directory of .deb files to merge (git, python3, ...)
#   output      tarball to write
#   base        optional: start from this payload instead of a temp unpack of
#               the current assets/runtime/rootfs.tar.gz
#
# The result is asserted afterwards by tools/test_extract.sh, which runs the
# guest binaries out of the tree the app's own extractor produced.
set -eu

DEB_DIR=${1:?usage: pack-rootfs.sh <deb-dir> <output.tar.gz> [base.tar.gz]}
OUT=${2:?usage: pack-rootfs.sh <deb-dir> <output.tar.gz> [base.tar.gz]}
HERE=$(cd "$(dirname "$0")" && pwd)
APP_DIR=$(cd "$HERE/.." && pwd)
BASE=${3:-$APP_DIR/assets/runtime/rootfs.tar.gz}

export LANG=C.UTF-8 LC_ALL=C.UTF-8
W=$(mktemp -d /tmp/packrootfs.XXXXXX)
trap 'rm -rf "$W"' EXIT INT TERM

echo "== 1/4 unpack base ($BASE) =="
mkdir -p "$W/tree"
( cd "$W/tree" && gzip -dc "$BASE" | tar -xf - )

echo "== 2/4 unpack $(ls "$DEB_DIR"/*.deb | wc -l) package(s), one directory each =="
mkdir -p "$W/stage"
i=0
for d in "$DEB_DIR"/*.deb; do
    i=$((i + 1))
    mkdir -p "$W/stage/$i"
    dpkg-deb -x "$d" "$W/stage/$i" || { echo "FAIL unpack $d" >&2; exit 1; }
done

echo "== 3/4 merge into the tree =="
for s in "$W"/stage/*; do
    # Regular paths. --no-preserve=links because this container lacks
    # CAP_FOWNER, so cp relinks hardlink groups with EPERM otherwise; the
    # packages we merge here have none we care about.
    cp -a --no-preserve=links "$s/." "$W/tree/" 2>/dev/null || true
    # Merged-usr paths: the tree's /lib, /bin, /sbin are symlinks, so the loop
    # above skipped these entries. Merge them where they actually live.
    for d in lib bin sbin; do
        [ -d "$s/$d" ] || continue
        [ -L "$W/tree/$d" ] || continue
        cp -a --no-preserve=links "$s/$d/." "$W/tree/$(readlink "$W/tree/$d")/"
    done
done

echo "== 4/4 pack =="
prev=$(pwd)
cd "$W/tree"
# Break every hardlink before archiving. The tar in this container (GNU tar
# 1.35, and --hard-dereference does not help) encodes the second name of a
# hardlink group as a *relative symlink pointing back at the source directory*
# instead of a tar hardlink entry. The base rootfs has one such pair -
# usr/bin/gunzip and usr/bin/uncompress are the same 2346-byte script - so the
# shipped archive used to unpack to a dangling gunzip on the device. Copying the
# duplicate costs 2346 bytes and makes the failure mode impossible.
# Detect with stat, not find: in this container find reports a link count of 1
# for a file stat reports as 2, and tar trusts that same broken view, which is
# how the symlink got in. stat is the one that agrees with reality here.
n=0
for f in $(find . -type f); do
    h=$(stat -c %h "$f" 2>/dev/null) || continue
    [ -n "$h" ] && [ "$h" -gt 1 ] || continue
    cp -p "$f" "$f.breaklink" && mv -f "$f.breaklink" "$f" && n=$((n + 1))
done
[ "${PACK_VERBOSE:-0}" = 1 ] && echo "   broke $n hardlink name(s)"
tar --format=gnu --numeric-owner --owner=0 --group=0 --sort=name -czf "$OUT" .
cd "$prev"
gzip -t "$OUT"
echo "PACK_OK entries=$(tar -tzf "$OUT" | wc -l) size=$(wc -c < "$OUT")"