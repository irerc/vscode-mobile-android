#!/usr/bin/env bash
# VS Code Mobile - build v5 (no Gradle).
#
# build4 produced three diagnostic variants:
#   D  dex + assets (105 MB, STORED)       signed v1+v2+v3   125 MB
#   E  dex + native libs (170 MB, STORED)  signed v2+v3 only 178 MB
#   F  dex + native libs DEFLATED          signed v1+v2+v3    76 MB
#
# F showed that DEFLATE shrinks the native payload from 170 MB to ~74 MB
# (libxul.so alone: 154 MB -> 23.9 MB). That makes the FULL application
# fit in roughly 180 MB instead of 303 MB, so this script builds:
#
#   G  dex + native libs DEFLATED + assets STORED, v1+v2+v3, vc 16
#      == complete, installable-by-design application package
#
# It also re-signs E with v1 enabled, because build4 signed E with v2+v3
# only and verifying it with --min-sdk-version 21 reports
# "Missing META-INF/MANIFEST.MF", which would confuse the experiment.
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild5"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

[ -f "$B/dex/classes.dex" ] || { echo "FATAL: $B/dex/classes.dex missing, run build4.sh first" >&2; exit 1; }
[ -f "$B/alignedE.apk" ] || { echo "FATAL: $B/alignedE.apk missing, run build4.sh first" >&2; exit 1; }

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

echo "== 1/4 re-sign E with v1+v2+v3 =="
sign_v123 "$B/alignedE.apk" "$OUT/vscode-mobile-E.apk"

echo "== 2/4 aapt2 link for G (vc 16) =="
"$BT/aapt2" link \
  -o "$B/baseG.apk" \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$B/gen" \
  --min-sdk-version 26 --target-sdk-version 28 \
  --version-code 16 --version-name "1.0.3-g" \
  --auto-add-overlay \
  "$B/flat"/*.flat
ls -l "$B/baseG.apk"

echo "== 3/4 package G (dex deflated, libs deflated, assets stored) =="
mkdir -p "$B/stageG/lib/arm64-v8a" "$B/stageG/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stageG/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stageG/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stageG/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stageG/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stageG/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stageG/"

cp -f "$B/baseG.apk" "$B/unsignedG.apk"
( cd "$B/stageG" && zip -q -9 -X "$B/unsignedG.apk" classes*.dex )
( cd "$B/stageG" && zip -q -9 -X "$B/unsignedG.apk" lib/arm64-v8a/*.so )
( cd "$B/stageG" && zip -q -0 -X "$B/unsignedG.apk" assets/omni.ja )
( cd "$B/stageG" && zip -q -0 -X "$B/unsignedG.apk" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )

echo "== 4/4 zipalign + apksigner for G =="
"$BT/zipalign" -f -P 16 4 "$B/unsignedG.apk" "$B/alignedG.apk"
sign_v123 "$B/alignedG.apk" "$OUT/vscode-mobile-G.apk"

for f in E G; do
  echo "--- $f ---"
  java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
    "$OUT/vscode-mobile-$f.apk" 2>&1 | head -8
  "$BT/zipalign" -c -P 16 -v 4 "$OUT/vscode-mobile-$f.apk" 2>&1 | tail -2
  ls -l "$OUT/vscode-mobile-$f.apk"
  md5sum "$OUT/vscode-mobile-$f.apk"
done

echo "--- G entry methods ---"
unzip -v "$OUT/vscode-mobile-G.apk" | awk 'NF>=8 && $1 ~ /^[0-9]+$/ {m=$2; c[m]++} END{for(k in c) print k, c[k]}'
echo BUILD_OK