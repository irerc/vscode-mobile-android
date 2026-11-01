#!/usr/bin/env bash
# VS Code Mobile - build v6, variant H (crash diagnostics + deferred GeckoView).
#
# G installs on the device but dies instantly with no UI at all. Two changes
# in H:
#   1. android:zygotePreloadName is removed from the manifest. targetSdk is 28
#      so the platform never honours it, and GeckoView itself logs "Cannot set
#      app Zygote preloading to true below SDK 29"; a dangling preload class on
#      a newer platform is a plausible way to abort the process before any
#      frame is drawn.
#   2. MainActivity.onCreate no longer calls createGecko() synchronously. It
#      installs a default uncaught exception handler that renders the stack
#      trace into a selectable TextView and appends it to crash.log, draws the
#      splash first, and only then brings GeckoView up from a posted Runnable.
#      Whatever throws now leaves a readable message instead of a silent exit.
#
# Packaging is identical to G (dex + libs DEFLATED, assets STORED, v1+v2+v3,
# 16 KB page alignment) because that exact recipe is proven to install.
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
DEPS="/root/android-sdk/m2/deps"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild6"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

echo "== 0/6 checks =="
[ -f "$APP_DIR/jni/arm64-v8a/libxul.so" ] || { echo "FATAL: native libs missing" >&2; exit 1; }
[ -f "$APP_DIR/assets/runtime/vscode.tar.gz" ] || { echo "FATAL: assets missing" >&2; exit 1; }
grep -q zygotePreloadName "$APP_DIR/src/main/AndroidManifest.xml" && {
  echo "FATAL: zygotePreloadName still present" >&2; exit 1; }
grep -q reportFatal "$APP_DIR/src/main/java/dev/dsh/vscodemobile/MainActivity.java" || {
  echo "FATAL: crash handler patch not applied" >&2; exit 1; }
echo "manifest clean, crash handler present"

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/6 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/"

echo "== 2/6 aapt2 link (H, vc 17) =="
"$BT/aapt2" link \
  -o "$B/baseH.apk" \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$B/gen" \
  --min-sdk-version 26 --target-sdk-version 28 \
  --version-code 17 --version-name "1.0.3-h" \
  --auto-add-overlay \
  "$B/flat"/*.flat
ls -l "$B/baseH.apk"

echo "== 3/6 javac (ASCII staging dir) =="
CP="$APP_DIR/libs/geckoview-classes.jar"
for j in androidx-core annotation collection lifecycle-common kotlin-stdlib; do
  [ -f "$DEPS/$j.jar" ] && CP="$CP:$DEPS/$j.jar"
done
find "$APP_DIR/src/main/java" -name '*.java' -exec cp {} "$B/src/" \;
find "$B/gen" -name '*.java' -exec cp {} "$B/src/" \;
ls "$B/src"
javac -proc:none -source 8 -target 8 -nowarn \
  -bootclasspath "$PLATFORM" \
  -classpath "$CP" \
  -d "$B/classes" \
  $(find "$B/src" -name '*.java') 2>&1 | grep -v 'bootstrap class path' || true
ls "$B/classes/dev/dsh/vscodemobile/MainActivity.class" >/dev/null
echo "javac OK"

echo "== 4/6 d8 (app classes + GeckoView) =="
java -Xmx4g -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 26 --release \
  --lib "$PLATFORM" \
  --output "$B/dex" \
  "$APP_DIR/libs/geckoview-classes.jar" \
  $(find "$B/classes" -name '*.class')
ls -l "$B"/dex/classes*.dex
DEX_BYTES=$(cat "$B"/dex/classes*.dex | wc -c)
echo "total dex bytes: $DEX_BYTES"
if [ "$DEX_BYTES" -lt 1000000 ]; then
  echo "FATAL: dex too small, GeckoView classes probably missing" >&2
  exit 1
fi

echo "== 5/6 package H (dex deflated, libs deflated, assets stored) =="
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stage/"

cp -f "$B/baseH.apk" "$B/unsignedH.apk"
( cd "$B/stage" && zip -q -9 -X "$B/unsignedH.apk" classes*.dex )
( cd "$B/stage" && zip -q -9 -X "$B/unsignedH.apk" lib/arm64-v8a/*.so )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedH.apk" assets/omni.ja )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedH.apk" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )

echo "== 6/6 zipalign + apksigner for H =="
"$BT/zipalign" -f -P 16 4 "$B/unsignedH.apk" "$B/alignedH.apk"
KS="$APP_DIR/keystore/release.jks"
java -jar "$BT/lib/apksigner.jar" sign \
  --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
  --ks-key-alias vscodemobile \
  --min-sdk-version 26 \
  --v1-signing-enabled true --v2-signing-enabled true \
  --v3-signing-enabled true --v4-signing-enabled false \
  --out "$OUT/vscode-mobile-H.apk" "$B/alignedH.apk"

echo "--- H verify ---"
java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
  "$OUT/vscode-mobile-H.apk" 2>&1 | head -8
"$BT/zipalign" -c -P 16 -v 4 "$OUT/vscode-mobile-H.apk" 2>&1 | tail -2
"$BT/aapt2" dump badging "$OUT/vscode-mobile-H.apk" 2>/dev/null | head -4
ls -l "$OUT/vscode-mobile-H.apk"
md5sum "$OUT/vscode-mobile-H.apk"
echo "--- H entry methods ---"
unzip -v "$OUT/vscode-mobile-H.apk" | awk 'NF>=8 && $1 ~ /^[0-9]+$/ {m=$2; c[m]++} END{for(k in c) print k, c[k]}'
echo "--- zygote attribute must be absent ---"
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$OUT/vscode-mobile-H.apk" 2>/dev/null | grep -c -i zygote || echo "ZYGOTE_ABSENT"
echo BUILD_OK