#!/usr/bin/env bash
# VS Code Mobile - build v9, variant K (full GeckoView runtime dependency closure).
#
# Root cause of "installs but dies with no UI", proven by the probe-J on-device
# stack trace:
#
#   java.lang.NoClassDefFoundError: Failed resolution of:
#       Landroidx/core/view/OnApplyWindowInsetsListener;
#     at dev.dsh.vscodemobile.MainActivity.buildUi(MainActivity.java:254)
#
# The old pipeline gave javac every androidx jar but gave d8 ONLY
# geckoview-classes.jar plus the three app classes. GeckoView bytecode refers to
# 90+ classes in androidx.core / androidx.annotation / androidx.collection /
# androidx.lifecycle / androidx.media3 / com.google.android.gms.fido /
# com.google.common / org.yaml, and none of them existed in the dex.
#
# Two extra problems surfaced while building v9:
#   1. d8 8.2.2 (build-tools 34.0.0) throws an internal NPE on
#      android/support/v4/os/ResultReceiver$1.class. GeckoView references ZERO
#      android/support/* classes, so that legacy support-rename shim is stripped.
#   2. androidx.core-core / androidx.annotation-annotation are byte-identical
#      duplicates of androidx-core / androidx-annotation; d8 aborts on them.
# tools/sanitize_deps.py produces libs/runtime-deps-clean handling both.
# cmdline-tools' r8.jar (D8 8.2.33) is preferred over build-tools' d8.jar.
#
# Packaging is unchanged from G/H/J because that recipe is proven to install.
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild9"
DEPS="$APP_DIR/libs/runtime-deps-clean"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

echo "== 0/6 checks =="
[ -f "$APP_DIR/jni/arm64-v8a/libxul.so" ] || { echo "FATAL: native libs missing"; exit 1; }
[ -f "$APP_DIR/assets/runtime/vscode.tar.gz" ] || { echo "FATAL: assets missing"; exit 1; }
if grep -q zygotePreloadName "$APP_DIR/src/main/AndroidManifest.xml"; then
  echo "FATAL: zygotePreloadName still present"; exit 1
fi
grep -q reportFatal "$APP_DIR/src/main/java/dev/dsh/vscodemobile/MainActivity.java" || {
  echo "FATAL: crash handler patch missing"; exit 1; }

DEPJARS=(
  "$DEPS/androidx-core-1.19.1.jar"
  "$DEPS/androidx-annotation-1.11.0.jar"
  "$DEPS/androidx-collection-1.6.0.jar"
  "$DEPS/androidx-lifecycle-common-2.11.0.jar"
  "$DEPS/androidx.annotation-annotation-experimental-1.6.0.jar"
  "$DEPS/androidx.lifecycle-lifecycle-process-2.11.0.jar"
  "$DEPS/androidx.media3-media3-common-1.11.1.jar"
  "$DEPS/androidx.media3-media3-datasource-1.11.1.jar"
  "$DEPS/androidx.media3-media3-decoder-1.11.1.jar"
  "$DEPS/androidx.media3-media3-exoplayer-1.11.1.jar"
  "$DEPS/androidx.media3-media3-exoplayer-hls-1.11.1.jar"
  "$DEPS/com.google.android.gms-play-services-fido-21.3.1.jar"
  "$DEPS/play-services-tasks-18.2.0.jar"
  "$DEPS/guava-33.4.0-android.jar"
  "$DEPS/snakeyaml-2.2.jar"
)
for j in "${DEPJARS[@]}"; do
  [ -s "$j" ] || { echo "FATAL: dependency missing: $j"; exit 1; }
  unzip -l "$j" >/dev/null 2>&1 || { echo "FATAL: dependency not a zip: $j"; exit 1; }
done
echo "manifest clean, crash handler present, ${#DEPJARS[@]} dependency jars present"

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/6 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/"

echo "== 2/6 aapt2 link (K, vc 19) =="
"$BT/aapt2" link \
  -o "$B/baseK.apk" \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$B/gen" \
  --min-sdk-version 26 --target-sdk-version 28 \
  --version-code 19 --version-name "1.0.5-k" \
  --auto-add-overlay \
  "$B/flat"/*.flat
ls -l "$B/baseK.apk"

echo "== 3/6 javac =="
CP="$APP_DIR/libs/geckoview-classes.jar"
for j in "${DEPJARS[@]}"; do CP="$CP:$j"; done
find "$APP_DIR/src/main/java" -name '*.java' -exec cp {} "$B/src/" \;
find "$B/gen" -name '*.java' -exec cp {} "$B/src/" \;
ls "$B/src"
javac -proc:none -source 8 -target 8 -nowarn \
  -bootclasspath "$PLATFORM" \
  -classpath "$CP" \
  -d "$B/classes" \
  $(find "$B/src" -name '*.java') || true
ls "$B/classes/dev/dsh/vscodemobile/MainActivity.class" >/dev/null
echo "javac OK"

echo "== 4/6 d8 (app + GeckoView + full runtime dependency closure) =="
D8JAR="/root/android-sdk/cmdline-tools/latest/lib/r8.jar"
[ -s "$D8JAR" ] || D8JAR="$BT/lib/d8.jar"
echo "d8 jar: $D8JAR"
java -cp "$D8JAR" com.android.tools.r8.D8 --version 2>&1 | head -1 || true
rm -rf "$B/dex"
mkdir -p "$B/dex"
java -Xmx3g -cp "$D8JAR" com.android.tools.r8.D8 \
  --min-api 26 --release \
  --lib "$PLATFORM" \
  --output "$B/dex" \
  "$APP_DIR/libs/geckoview-classes.jar" \
  "${DEPJARS[@]}" \
  $(find "$B/classes" -name '*.class')
ls -l "$B"/dex/classes*.dex
NDEX=$(ls "$B"/dex/classes*.dex | wc -l)
DEX_BYTES=$(cat "$B"/dex/classes*.dex | wc -c)
echo "dex files: $NDEX  total dex bytes: $DEX_BYTES"
if [ "$DEX_BYTES" -lt 4000000 ]; then
  echo "FATAL: dex too small, dependency closure probably not merged"; exit 1
fi

echo "== 5/6 package K =="
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stage/"

cp -f "$B/baseK.apk" "$B/unsignedK.apk"
( cd "$B/stage" && zip -q -9 -X "$B/unsignedK.apk" classes*.dex )
( cd "$B/stage" && zip -q -9 -X "$B/unsignedK.apk" lib/arm64-v8a/*.so )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedK.apk" assets/omni.ja )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedK.apk" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )

echo "== 6/6 zipalign + apksigner for K =="
"$BT/zipalign" -f -P 16 4 "$B/unsignedK.apk" "$B/alignedK.apk"
KS="$APP_DIR/keystore/release.jks"
java -jar "$BT/lib/apksigner.jar" sign \
  --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
  --ks-key-alias vscodemobile \
  --min-sdk-version 26 \
  --v1-signing-enabled true --v2-signing-enabled true \
  --v3-signing-enabled true --v4-signing-enabled false \
  --out "$OUT/vscode-mobile-K.apk" "$B/alignedK.apk"

echo "--- K verify ---"
java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
  "$OUT/vscode-mobile-K.apk" 2>&1 | head -8 || true
"$BT/zipalign" -c -P 16 -v 4 "$OUT/vscode-mobile-K.apk" 2>&1 | tail -2 || true
"$BT/aapt2" dump badging "$OUT/vscode-mobile-K.apk" 2>/dev/null | head -4 || true
ls -l "$OUT/vscode-mobile-K.apk"
md5sum "$OUT/vscode-mobile-K.apk"
echo "--- dex list inside apk ---"
unzip -l "$OUT/vscode-mobile-K.apk" | grep 'classes.*dex' || true
echo "--- OnApplyWindowInsetsListener must now be inside the dex ---"
for d in $(cd "$B/dex" && ls classes*.dex); do
  n=$(strings -a "$B/dex/$d" | grep -c "OnApplyWindowInsetsListener" || true)
  echo "  $d hits=$n"
done
echo "--- media3 / guava / fido / yaml markers ---"
for k in "media3/exoplayer" "google/common/net/HttpHeaders" "fido2/api/common" "yaml/snakeyaml"; do
  n=$(cat "$B"/dex/classes*.dex | strings -a | grep -c "$k" || true)
  echo "  $k hits=$n"
done
echo BUILD_OK