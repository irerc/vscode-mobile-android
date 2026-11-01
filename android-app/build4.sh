#!/usr/bin/env bash
# VS Code Mobile - diagnostic variant build v4 (no Gradle).
# Variant A (manifest + dex only, 606 KB) INSTALLS FINE on the target device,
# so manifest / signature scheme / targetSdk 28 / dex are all ruled out.
# What remains is only present in B and C: the 170 MB native lib payload
# and the 105 MB asset payload. This script splits those two apart and also
# tests the v1 (JAR) signature over a very large archive.
#
#   D  vc 13  dex + assets (105 MB, STORED)              signed v1+v2+v3
#   E  vc 14  dex + native libs (170 MB, STORED)         signed v2+v3 only
#   F  vc 15  dex + native libs (170 MB, DEFLATED)       signed v1+v2+v3
#
# Reading the results:
#   E installs        -> v1 JAR signing over 300 MB was the blocker
#   D installs, E not -> the native lib payload (size/STORED/extract) is the blocker
#   D and E both fail -> plain APK size threshold on the installer
#   F installs        -> STORED/uncompressed .so is the blocker, not the bytes
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
DEPS="/root/android-sdk/m2/deps"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild5"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/6 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/"

echo "== 2/6 aapt2 link (3 variants D/E/F) =="
link_one() {
  local vc="$1" vn="$2" outp="$3"
  "$BT/aapt2" link \
    -o "$outp" \
    -I "$PLATFORM" \
    --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
    --java "$B/gen" \
    --min-sdk-version 26 --target-sdk-version 28 \
    --version-code "$vc" --version-name "$vn" \
    --auto-add-overlay \
    "$B/flat"/*.flat
}
link_one 13 "1.0.3-d" "$B/baseD.apk"
link_one 14 "1.0.3-e" "$B/baseE.apk"
link_one 15 "1.0.3-f" "$B/baseF.apk"
ls -l "$B"/base?.apk

echo "== 3/6 javac =="
CP="$APP_DIR/libs/geckoview-classes.jar"
for j in androidx-core annotation collection lifecycle-common kotlin-stdlib; do
  [ -f "$DEPS/$j.jar" ] && CP="$CP:$DEPS/$j.jar"
done
find "$APP_DIR/src/main/java" -name '*.java' -exec cp {} "$B/src/" \;
find "$B/gen" -name '*.java' -exec cp {} "$B/src/" \;
javac -proc:none -source 8 -target 8 -nowarn \
  -bootclasspath "$PLATFORM" \
  -classpath "$CP" \
  -d "$B/classes" \
  $(find "$B/src" -name '*.java') 2>&1 | grep -v 'bootstrap class path' || true
ls "$B/classes/dev/dsh/vscodemobile/MainActivity.class" >/dev/null

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
  echo "FATAL: dex looks too small, GeckoView classes probably missing" >&2
  exit 1
fi

echo "== 5/6 package =="
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stage/"

pack_dex() {
  cp -f "$1" "$2"
  ( cd "$B/stage" && zip -q -9 -X "$2" classes*.dex )
}
pack_libs_stored() {
  ( cd "$B/stage" && zip -q -0 -X "$1" lib/arm64-v8a/*.so )
}
pack_libs_deflated() {
  ( cd "$B/stage" && zip -q -9 -X "$1" lib/arm64-v8a/*.so )
}
pack_assets_stored() {
  ( cd "$B/stage" && zip -q -0 -X "$1" assets/omni.ja )
  ( cd "$B/stage" && zip -q -0 -X "$1" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )
}

# D: dex + assets, no native libs
pack_dex "$B/baseD.apk" "$B/unsignedD.apk"
pack_assets_stored "$B/unsignedD.apk"

# E: dex + native libs (STORED), no assets
pack_dex "$B/baseE.apk" "$B/unsignedE.apk"
pack_libs_stored "$B/unsignedE.apk"

# F: dex + native libs (DEFLATED), no assets
pack_dex "$B/baseF.apk" "$B/unsignedF.apk"
pack_libs_deflated "$B/unsignedF.apk"

echo "== 6/6 zipalign + apksigner =="
align_one() {
  "$BT/zipalign" -f -P 16 4 "$1" "$2"
}
align_one "$B/unsignedD.apk" "$B/alignedD.apk"
align_one "$B/unsignedE.apk" "$B/alignedE.apk"
align_one "$B/unsignedF.apk" "$B/alignedF.apk"

KS="$APP_DIR/keystore/release.jks"
sign_v123() {
  java -jar "$BT/lib/apksigner.jar" sign \
    --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
    --ks-key-alias vscodemobile \
    --min-sdk-version 26 \
    --v1-signing-enabled true --v2-signing-enabled true \
    --v3-signing-enabled true --v4-signing-enabled false \
    --out "$2" "$1"
}
sign_v23() {
  java -jar "$BT/lib/apksigner.jar" sign \
    --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
    --ks-key-alias vscodemobile \
    --min-sdk-version 26 \
    --v1-signing-enabled false --v2-signing-enabled true \
    --v3-signing-enabled true --v4-signing-enabled false \
    --out "$2" "$1"
}

sign_v123 "$B/alignedD.apk" "$OUT/vscode-mobile-D.apk"
sign_v23  "$B/alignedE.apk" "$OUT/vscode-mobile-E.apk"
sign_v123 "$B/alignedF.apk" "$OUT/vscode-mobile-F.apk"

for f in D E F; do
  echo "--- $f ---"
  java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
    "$OUT/vscode-mobile-$f.apk" 2>&1 | head -8
  "$BT/zipalign" -c -P 16 -v 4 "$OUT/vscode-mobile-$f.apk" 2>&1 | tail -2
  ls -l "$OUT/vscode-mobile-$f.apk"
  md5sum "$OUT/vscode-mobile-$f.apk"
done
echo BUILD_OK