#!/usr/bin/env bash
# Verify a built APK against every gate this project has been bitten by.
#
# Usage: tools/verify_apk.sh [path/to/apk]
#   default: dist/vscode-mobile-L.apk
#
# Every check below corresponds to a real failure that reached a device:
#   - signature / alignment        -> install refused by the packager
#   - KMP metadata jars            -> NoClassDefFoundError androidx.collection.SimpleArrayMap
#   - kotlin runtime               -> NoClassDefFoundError kotlin/jvm/internal/Intrinsics
#   - library R classes            -> NoClassDefFoundError androidx.*.R$id
#   - media3/gms closure           -> NoClassDefFoundError androidx.media3.*
#   - assets present               -> TarGz unwrap + serve-web tree
#   - @vscode/deviceid in tree     -> ERR_MODULE_NOT_FOUND at server start
set -u

APK="${1:-dist/vscode-mobile-L.apk}"
# JDK17 raises ExceptionInInitializerError from LoggerFinderLoader when LANG is
# unset, and this project lives in a path containing a space plus CJK characters,
# so java is never handed the real path (argument encoding mangles it).
export LANG=C.UTF-8 LC_ALL=C.UTF-8
BT="${BT:-/root/android-sdk/build-tools/34.0.0}"
FAIL=0

say() { printf '%s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=1; }
ok()  { printf 'ok    %s\n' "$*"; }

[ -f "$APK" ] || { bad "missing $APK"; exit 1; }
say "== $APK =="
say "   size   $(stat -c%s "$APK")"
say "   md5    $(md5sum "$APK" | cut -d' ' -f1)"
say "   sha256 $(sha256sum "$APK" | cut -d' ' -f1)"

# 1. signature ---------------------------------------------------------------
# apksigner ships as a jar inside build-tools; there is no wrapper script here.
TMPAPK="$(mktemp -d)/app.apk"
cp "$APK" "$TMPAPK"
if java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 "$TMPAPK" >/dev/null 2>&1; then
  ok "apksigner verify (v1/v2/v3)"
else
  bad "apksigner verify"
fi

# 2. alignment ---------------------------------------------------------------
if "$BT/zipalign" -c -P 16 4 "$APK" >/dev/null 2>&1; then
  ok "zipalign -c -P 16 4"
else
  bad "zipalign -c -P 16 4"
fi

# 3. manifest ----------------------------------------------------------------
badging="$("$BT/aapt2" dump badging "$APK" 2>/dev/null)"
case "$badging" in
  *"package: name='dev.dsh.vscodemobile'"*) ok "package id" ;;
  *) bad "package id missing" ;;
esac
case "$badging" in
  *"targetSdkVersion:'28'"*) ok "targetSdk 28 (needed for exec from app data dir)" ;;
  *) bad "targetSdk not 28" ;;
esac

# 4. dex must contain the classes whose absence killed previous builds -------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$(dirname "$TMPAPK")"' EXIT
unzip -o -q "$APK" 'classes*.dex' -d "$TMP"
DEXES="$(ls "$TMP"/classes*.dex 2>/dev/null)"
[ -n "$DEXES" ] || bad "no classes*.dex in apk"
for k in \
  "Lkotlin/jvm/internal/Intrinsics" \
  "Lkotlinx/coroutines/Dispatchers" \
  "Landroidx/collection/SimpleArrayMap" \
  "Landroidx/annotation/Nullable" \
  "Landroidx/core/view/OnApplyWindowInsetsListener" \
  "Landroidx/media3/extractor/DefaultExtractorsFactory" \
  "Lcom/google/android/gms/common/api/Api" \
  "Lorg/mozilla/geckoview/GeckoRuntime" ; do
  if cat $DEXES | strings -a | grep -q -- "$k"; then
    ok "dex has $k"
  else
    bad "dex missing $k"
  fi
done

# 5. library R classes (hand-built pipeline does not emit them automatically) -
for k in \
  "Landroidx/fragment/R\$id" \
  "Landroidx/lifecycle/runtime/R\$id" \
  "Landroidx/startup/R\$string" \
  "Lcom/google/android/gms/base/R\$string" ; do
  if cat $DEXES | strings -a | grep -q -- "$k"; then
    ok "dex has $k"
  else
    bad "dex missing $k"
  fi
done

# 6. app classes and self-test hooks ----------------------------------------
for k in "SELFTEST" "ok-rootfs" "ok-vscode" ; do
  if cat $DEXES | strings -a | grep -q -- "$k"; then
    ok "dex has marker '$k'"
  else
    bad "dex missing marker '$k'"
  fi
done

# 7. assets + native libraries ----------------------------------------------
for f in \
  "assets/runtime/rootfs.tar.gz" \
  "assets/runtime/vscode.tar.gz" \
  "lib/arm64-v8a/libproot.so" \
  "lib/arm64-v8a/libprootloader.so" \
  "lib/arm64-v8a/libxul.so" ; do
  if unzip -l "$APK" | grep -q " $f\$"; then
    ok "apk has $f"
  else
    bad "apk missing $f"
  fi
done

# 8. the serve-web tree must carry the packages server-main.js imports ------
unzip -o -q "$APK" 'assets/runtime/vscode.tar.gz' -d "$TMP"
if [ -f "$TMP/assets/runtime/vscode.tar.gz" ]; then
  listing="$(tar tzf "$TMP/assets/runtime/vscode.tar.gz")"
  for p in "vscode/node" "vscode/out/server-main.js" \
           "vscode/node_modules/@vscode/deviceid/package.json" \
           "vscode/node_modules/@github/copilot-sdk/package.json" \
           "vscode/node_modules/node-pty/build/Release/pty.node" \
           "vscode/out/vs/code/browser/workbench/workbench.js" ; do
    if printf '%s\n' "$listing" | grep -q -x "$p"; then
      ok "vscode tree has $p"
    else
      bad "vscode tree missing $p"
    fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  say "VERIFY_OK"
else
  say "VERIFY_FAILED"
  exit 1
fi