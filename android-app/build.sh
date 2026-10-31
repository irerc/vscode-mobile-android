#!/usr/bin/env bash
# VS Code Mobile —— 无 Gradle 手工 APK 构建流水线
# aapt2 compile/link → javac → d8 → 组包 → zipalign → apksigner
set -u

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
DEPS="/root/android-sdk/m2/deps"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$OUT"

echo "== 1/7 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/" || exit 1

echo "== 2/7 aapt2 link =="
"$BT/aapt2" link \
  -o "$B/base.apk" \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$B/gen" \
  --min-sdk-version 26 --target-sdk-version 34 \
  --version-code 1 --version-name "1.0.0" \
  --auto-add-overlay \
  "$B/flat"/*.flat || exit 1

echo "== 3/7 javac =="
CP="$APP_DIR/libs/geckoview-classes.jar:$DEPS/androidx-core.jar:$DEPS/annotation.jar:$DEPS/collection.jar:$DEPS/lifecycle-common.jar:$DEPS/kotlin-stdlib.jar"
find "$APP_DIR/src/main/java" -name '*.java' > "$B/sources.txt"
find "$B/gen" -name '*.java' >> "$B/sources.txt"
javac -proc:none -source 8 -target 8 -nowarn \
  -bootclasspath "$PLATFORM" \
  -classpath "$CP" \
  -d "$B/classes" \
  @"$B/sources.txt" 2>&1 | grep -v 'bootstrap class path' | head -40
echo "javac rc=${PIPESTATUS[0]}"
ls "$B/classes/dev/dsh/vscodemobile/" | head

echo "== 4/7 d8 =="
java -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 26 --release \
  --lib "$PLATFORM" \
  --output "$B/dex" \
  $(find "$B/classes" -name '*.class') 2>&1 | head -20
ls -l "$B/dex"

echo "== 5/7 组包 =="
cp "$B/base.apk" "$B/unsigned.apk"
cd "$B" || exit 1
mkdir -p stage/lib/arm64-v8a stage/assets
cp -f "$APP_DIR"/jni/arm64-v8a/*.so stage/lib/arm64-v8a/
cp -f "$APP_DIR"/assets/* stage/assets/ 2>/dev/null
cp -f "$B/dex/classes.dex" stage/
cd stage || exit 1
zip -q -r -X "$B/unsigned.apk" lib assets classes.dex || exit 1
cd "$B" || exit 1

echo "== 6/7 zipalign =="
"$BT/zipalign" -f -p 4 "$B/unsigned.apk" "$B/aligned.apk" || exit 1

echo "== 7/7 apksigner =="
KS="$APP_DIR/keystore/release.jks"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -v -keystore "$KS" -storepass vscodemobile -keypass vscodemobile \
    -alias vscodemobile -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=VS Code Mobile, OU=DSH, O=DSH, L=NA, ST=NA, C=CN" 2>&1 | tail -3
fi
java -jar "$BT/lib/apksigner.jar" sign \
  --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
  --ks-key-alias vscodemobile \
  --min-sdk-version 26 \
  --out "$OUT/vscode-mobile-gecko.apk" \
  "$B/aligned.apk" 2>&1 | head -10

echo "== 校验 =="
java -jar "$BT/lib/apksigner.jar" verify --print-certs "$OUT/vscode-mobile-gecko.apk" 2>&1 | head -6
ls -l "$OUT/vscode-mobile-gecko.apk"
echo "BUILD_OK"