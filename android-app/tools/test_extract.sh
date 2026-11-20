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

# 3b. The hardlink fix: rootfs has exactly one hardlink (usr/bin/gunzip ->
#     usr/bin/gzip). A hardlink cannot be created through the framework, so TarGz
#     materialises it as a copy and must carry the execute bit over explicitly.
#     Without that it landed as 0644 and every gzip/gunzip call in the guest died
#     with Permission denied - invisible to the count and symlink checks above.
rm -rf "$W/h"; mkdir -p "$W/h"
run "$RT/rootfs.tar.gz" "$W/h" >/dev/null 2>&1
for f in usr/bin/gunzip usr/bin/gzip; do
  if [ -x "$W/h/$f" ]; then ok "$f is executable"; else bad "$f is not executable"; fi
done

# 3c. The VS Code tree ships its own node and the code-server wrapper; both must
#     come out executable or the first launch cannot start the server at all.
rm -rf "$W/v"; mkdir -p "$W/v"
run "$RT/vscode.tar.gz" "$W/v" >/dev/null 2>&1
for f in vscode/node vscode/bin/code-server; do
  if [ -x "$W/v/$f" ]; then ok "$f is executable"; else bad "$f is not executable"; fi
done

# 3d. The Android font fallback lives in the shipped workbench.css. A repack that
#     drops or overwrites that file silently brings the CJK boxes back.
css="$W/v/vscode/out/vs/code/browser/workbench/workbench.css"
if [ -f "$css" ]; then
  hits="$(grep -c 'sans-serif!important' "$css" || true)"
  if [ "$hits" -ge 3 ]; then ok "workbench.css carries the font patch ($hits hits)"; else bad "workbench.css patch missing ($hits hits)"; fi
else
  bad "workbench.css missing from the tree"
fi

# 3e. Pin the exact entry counts so a repack that loses files is caught rather
#     than absorbed by the tolerance above. GNU tar reports one fewer for rootfs
#     because it keeps the hardlink as a link, not a second file.
if [ "$(find "$W/h" -mindepth 1 | wc -l)" -eq 7333 ]; then ok "rootfs entry count is 7333"; else bad "rootfs entry count drifted"; fi
if [ "$(find "$W/v" -mindepth 1 | wc -l)" -eq 4713 ]; then ok "vscode entry count is 4713"; else bad "vscode entry count drifted"; fi

# 3f. The integrated terminal is not simulated: it asks node-pty, a native module,
#     for a real PTY. An ABI or glibc mismatch there makes the terminal panel fail
#     the moment it is opened, so spawn one from the shipped tree and require both
#     a PTY device and shell output back. Loading the module is not enough - the
#     failure mode is inside pty.spawn().
ptyout="$(cd "$W/v/vscode" && LANG=C.UTF-8 LC_ALL=C.UTF-8 timeout 60 ./node -e '
const p=require("./node_modules/node-pty");
const t=p.spawn("/bin/sh",["-c","tty; echo PTY_OK"],{name:"xterm-color",cols:80,rows:24,cwd:process.cwd(),env:process.env});
let o="";
t.onData(function(d){o+=d});
t.onExit(function(){console.log(o);process.exit(0)});
setTimeout(function(){console.log(o);process.exit(2)},20000);
' 2>/dev/null || echo FAILED)"
case "$ptyout" in
  *"/dev/pts/"*"PTY_OK"*) ok "node-pty allocates a real PTY and returns shell output" ;;
  *) bad "node-pty did not produce a PTY ($(echo "$ptyout" | tr '\n' ' ' | cut -c1-80))" ;;
esac

# 3g. Source control is the one headline feature that used to need a manual
#     `apt install git` inside the guest. The rootfs now carries git and its
#     dependency closure, so prove it runs out of the tree that the app's own
#     extractor produced - not out of a tree this script unpacked with tar, which
#     would leave the Java extractor's handling of ~3800 new entries untested.
if [ -x "$W/h/usr/bin/git" ]; then
  gv="$(cd "$W/h" && timeout 120 ./lib/ld-linux-aarch64.so.1 --library-path ./lib/aarch64-linux-gnu:./usr/lib/aarch64-linux-gnu ./usr/bin/git --version 2>/dev/null)"
  case "$gv" in
    "git version "*) ok "guest git runs from the extracted tree ($gv)" ;;
    *) bad "guest git did not run ($(echo "$gv" | head -c 60))" ;;
  esac
else
  bad "usr/bin/git missing from the rootfs payload"
fi

# 3h. python3 ships in the payload too, because the Python extension is useless
#     without an interpreter and a clean device must not need apt first. Import
#     the modules a real interpreter discovery touches (ssl and sqlite3 are the
#     ones that used to be dropped from the payload, see known-issues row 34),
#     and check pip is importable so virtualenvs can be built offline.
if [ -x "$W/h/usr/bin/python3" ]; then
  pv="$(cd "$W/h" && timeout 180 ./lib/ld-linux-aarch64.so.1 --library-path ./usr/lib/aarch64-linux-gnu:./lib/aarch64-linux-gnu ./usr/bin/python3 -c 'import sys,sqlite3,ssl,ctypes; print(sys.version.split()[0])' 2>&1 | tail -1)"
  case "$pv" in
    3.10.*) ok "guest python3 runs from the extracted tree ($pv)" ;;
    *) bad "guest python3 did not run ($(echo "$pv" | head -c 70))" ;;
  esac
  mv="$(cd "$W/h" && timeout 180 ./lib/ld-linux-aarch64.so.1 --library-path ./usr/lib/aarch64-linux-gnu:./lib/aarch64-linux-gnu ./usr/bin/python3 -m pip --version 2>&1 | tail -1)"
  case "$mv" in
    pip*) ok "guest pip is importable" ;;
    *) bad "guest pip is not importable ($(echo "$mv" | head -c 70))" ;;
  esac
else
  bad "usr/bin/python3 missing from the rootfs payload"
fi

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