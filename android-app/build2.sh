#!/usr/bin/env bash
# VS Code Mobile - self-contained APK build (no Gradle).
# aapt2 compile/link -> javac -> d8 -> package -> zipalign -> apksigner
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
DEPS="/root/android-sdk/m2/deps"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild3"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/7 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/"

echo "== 2/7 aapt2 link =="
"$BT/aapt2" link \
  -o "$B/base.apk" \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$B/gen" \
  --min-sdk-version 26 --target-sdk-version 28 \
  --version-code 1 --version-name "1.0.0" \
  --auto-add-overlay \
  "$B/flat"/*.flat

echo "== 3/7 javac =="
CP="$APP_DIR/libs/geckoview-classes.jar"
for j in androidx-core annotation collection lifecycle-common kotlin-stdlib; do
  [ -f "$DEPS/$j.jar" ] && CP="$CP:$DEPS/$j.jar"
done
# sources copied to an ASCII path: javac @argfile splits on whitespace
find "$APP_DIR/src/main/java" -name '*.java' -exec cp {} "$B/src/" \;
find "$B/gen" -name '*.java' -exec cp {} "$B/src/" \;
javac -proc:none -source 8 -target 8 -nowarn \
  -bootclasspath "$PLATFORM" \
  -classpath "$CP" \
  -d "$B/classes" \
  $(find "$B/src" -name '*.java') 2>&1 | grep -v 'bootstrap class path' || true
ls "$B/classes/dev/dsh/vscodemobile/MainActivity.class" >/dev/null

echo "== 4/7 d8 =="
java -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 26 --release \
  --lib "$PLATFORM" \
  --output "$B/dex" \
  $(find "$B/classes" -name '*.class')
ls -l "$B/dex/classes.dex"

echo "== 5/7 package =="
cp "$B/base.apk" "$B/unsigned.apk"
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B/dex/classes.dex" "$B/stage/"
( cd "$B/stage" && zip -q -r -X "$B/unsigned.apk" lib assets classes.dex )

echo "== 6/7 zipalign =="
"$BT/zipalign" -f -p 4 "$B/unsigned.apk" "$B/aligned.apk"

echo "== 7/7 apksigner =="
KS="$APP_DIR/keystore/release.jks"
java -jar "$BT/lib/apksigner.jar" sign \
  --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
  --ks-key-alias vscodemobile \
  --min-sdk-version 26 \
  --out "$OUT/vscode-mobile.apk" \
  "$B/aligned.apk"

java -jar "$BT/lib/apksigner.jar" verify --print-certs "$OUT/vscode-mobile.apk" | head -4
ls -l "$OUT/vscode-mobile.apk"
echo BUILD_OK
