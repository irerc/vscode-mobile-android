#!/usr/bin/env bash
# Regression test for TarGz: the extractor that aborted every first launch with
#   java.io.IOException: escape etc/alternatives/pager
# because it validated paths with getCanonicalPath(), which resolves symlinks.
#
# Runs the real TarGz class on the JVM against the real shipped tarballs and
# compares the result with GNU tar. android.jar's android.system.Os.symlink is a
# throwing stub on a JVM, so this also exercises the Files.createSymbolicLink
# fallback path.
#
# Usage: tools/test_extract.sh [path/to/android-app]
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="${1:-android-app}"
SRC="$APP/src/main/java/dev/dsh/vscodemobile/TarGz.java"
RT="$APP/assets/runtime"
PLATFORM="${PLATFORM:-/root/android-sdk/platforms/android-34/android.jar}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

FAIL=0
say() { printf '%s\n' "$*"; }
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=1; }

[ -f "$SRC" ] || { bad "missing $SRC"; exit 1; }
[ -f "$PLATFORM" ] || { bad "missing $PLATFORM"; exit 1; }
# javac mangles this project's space+CJK path, so compile from an ASCII copy.
cp "$SRC" "$W/TarGz.java"
javac -encoding UTF-8 -cp "$PLATFORM" -d "$W/out" "$W/TarGz.java" || { bad "javac"; exit 1; }
ok "compiled TarGz"

CP="$W/out:$PLATFORM"
run() { java -cp "$CP" dev.dsh.vscodemobile.TarGz "$1" "$2"; }

for t in rootfs vscode; do
  tgz="$RT/$t.tar.gz"
  [ -f "$tgz" ] || { bad "missing $tgz"; continue; }

  rm -rf "$W/a" "$W/b"; mkdir -p "$W/a" "$W/b"
  # 1. fresh extraction must not throw
  if out="$(run "$tgz" "$W/a" 2>&1)"; then ok "$t: fresh extract $out"; else bad "$t: fresh extract threw: $out"; fi
  # 2. re-extraction over the populated tree must not throw either; this is the
  #    case that aborted on device because the links already existed.
  if out="$(run "$tgz" "$W/a" 2>&1)"; then ok "$t: re-extract over existing tree $out"; else bad "$t: re-extract threw: $out"; fi
  # 3. compare with GNU tar
  tar xzf "$tgz" -C "$W/b" 2>/dev/null
  a_files=$(find "$W/a" -mindepth 1 | wc -l)
  b_files=$(find "$W/b" -mindepth 1 | wc -l)
  a_links=$(find "$W/a" -type l | wc -l)
  b_links=$(find "$W/b" -type l | wc -l)
  say "      entries ours=$a_files tar=$b_files  symlinks ours=$a_links tar=$b_links"
  if [ "$a_links" -eq "$b_links" ]; then ok "$t: symlink count matches tar"; else bad "$t: symlink count differs"; fi
  # Hardlinks are materialised as copies by TarGz, so allow a small delta.
  delta=$(( a_files - b_files )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
  if [ "$delta" -le 5 ]; then ok "$t: entry count within tolerance ($delta)"; else bad "$t: entry count differs by $delta"; fi
done

# 4. the exact entry that used to abort must be a working absolute symlink.
#    Its own extraction dir is needed: $W/a holds the last tarball of the loop.
rm -rf "$W/c"; mkdir -p "$W/c"
run "$RT/rootfs.tar.gz" "$W/c" >/dev/null 2>&1
if [ -L "$W/c/etc/alternatives/pager" ]; then
  ok "etc/alternatives/pager -> $(readlink "$W/c/etc/alternatives/pager")"
else
  bad "etc/alternatives/pager is not a symlink"
fi

# 5. wipe() must delete a tree containing symlinks without following them
rm -rf "$W/w"; mkdir -p "$W/w/d"
ln -s /etc "$W/w/d/escape"
ln -s ../d "$W/w/d/loop"
cat > "$W/Wipe.java" <<'EOF'
package dev.dsh.vscodemobile;
public class Wipe { public static void main(String[] a) { TarGz.wipe(new java.io.File(a[0])); } }
EOF
cp "$SRC" "$W/TarGz.java"
javac -encoding UTF-8 -cp "$PLATFORM" -d "$W/out2" "$W/TarGz.java" "$W/Wipe.java" || bad "javac wipe harness"
java -cp "$W/out2:$PLATFORM" dev.dsh.vscodemobile.Wipe "$W/w" || bad "wipe threw"
[ -e "$W/w" ] && bad "wipe left the tree in place" || ok "wipe removed a tree with symlink loop"
[ -d /etc ] && ok "/etc survived wipe (no symlink follow)" || bad "/etc disappeared: wipe followed a symlink"

if [ "$FAIL" -eq 0 ]; then say "EXTRACT_OK"; else say "EXTRACT_FAILED"; exit 1; fi