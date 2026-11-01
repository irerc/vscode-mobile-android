#!/usr/bin/env bash
# VS Code Mobile - self-contained APK build v3 (no Gradle).
# Fixes vs build2.sh:
#   * GeckoView classes are fed to d8 (build2 only put the jar on javac's classpath,
#     so the shipped dex had no org.mozilla.geckoview implementation -> NoClassDefFoundError)
#   * every classes*.dex produced by d8 is packaged
#   * native libs are STORED and aligned to 16 KB pages (zipalign -P 16)
#   * apksigner explicitly enables v1 + v2 + v3
# Produces three install-test variants with ascending versionCode:
#   vscode-mobile-A.apk  manifest + dex only           (small, isolates manifest/dex problems)
#   vscode-mobile-B.apk  A + 17 native libs            (isolates the 170 MB lib payload)
#   vscode-mobile-C.apk  B + 105 MB assets  == full app
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
DEPS="/root/android-sdk/m2/deps"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild4"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/7 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/"

echo "== 2/7 aapt2 link (3 variants) =="
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
link_one 10 "1.0.2-a" "$B/baseA.apk"
link_one 11 "1.0.2-b" "$B/baseB.apk"
link_one 12 "1.0.2-c" "$B/baseC.apk"
ls -l "$B"/base?.apk

echo "== 3/7 javac =="
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

echo "== 4/7 d8 (app classes + GeckoView) =="
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

echo "== 5/7 package =="
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stage/"

pack_dex() {
  # $1 base apk, $2 output
  cp -f "$1" "$2"
  ( cd "$B/stage" && zip -q -9 -X "$2" classes*.dex )
}
pack_libs() {
  ( cd "$B/stage" && zip -q -0 -X "$1" lib/arm64-v8a/*.so )
}
pack_assets() {
  ( cd "$B/stage" && zip -q -0 -X "$1" assets/omni.ja )
  ( cd "$B/stage" && zip -q -0 -X "$1" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )
}

pack_dex "$B/baseA.apk" "$B/unsignedA.apk"
pack_dex "$B/baseB.apk" "$B/unsignedB.apk"
pack_libs "$B/unsignedB.apk"
pack_dex "$B/baseC.apk" "$B/unsignedC.apk"
pack_libs "$B/unsignedC.apk"
pack_assets "$B/unsignedC.apk"

echo "== 6/7 zipalign (16 KB pages) =="
align_one() {
  "$BT/zipalign" -f -P 16 4 "$1" "$2"
}
align_one "$B/unsignedA.apk" "$B/alignedA.apk"
align_one "$B/unsignedB.apk" "$B/alignedB.apk"
align_one "$B/unsignedC.apk" "$B/alignedC.apk"

echo "== 7/7 apksigner (v1+v2+v3) =="
KS="$APP_DIR/keystore/release.jks"
sign_one() {
  java -jar "$BT/lib/apksigner.jar" sign \
    --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
    --ks-key-alias vscodemobile \
    --min-sdk-version 26 \
    --v1-signing-enabled true --v2-signing-enabled true \
    --v3-signing-enabled true --v4-signing-enabled false \
    --out "$2" "$1"
}
sign_one "$B/alignedA.apk" "$OUT/vscode-mobile-A.apk"
sign_one "$B/alignedB.apk" "$OUT/vscode-mobile-B.apk"
sign_one "$B/alignedC.apk" "$OUT/vscode-mobile-C.apk"

for f in A B C; do
  echo "--- $f ---"
  java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
    "$OUT/vscode-mobile-$f.apk" 2>&1 | head -8
  ls -l "$OUT/vscode-mobile-$f.apk"
done
echo BUILD_OK