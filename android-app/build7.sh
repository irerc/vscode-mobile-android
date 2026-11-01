#!/usr/bin/env bash
# VS Code Mobile - build v7, variant J (synchronous GeckoRuntime probe).
#
# H installs but still exits with no UI at all. H deferred createGecko() into a
# posted Runnable, which means that if GeckoRuntime.create() aborts the whole
# process (libxul load failure, ZygotePreload reflection, etc.) before the
# splash is even laid out we would still see a blank screen.
#
# J removes that ambiguity: onCreate calls createGecko() synchronously inside
# try/catch. If GeckoRuntime is what kills us, reportFatal() will render the
# stack trace. If J is still blank, the process dies before onCreate returns
# and the problem is in manifest / native lib loading / class init, not Gecko.
#
# Packaging identical to H/G (proven to install on the device).
set -eu

APP_DIR="/root/VS Code移植/android-app"
BT="/root/android-sdk/build-tools/34.0.0"
PLATFORM="/root/android-sdk/platforms/android-34/android.jar"
DEPS="/root/android-sdk/m2/deps"
OUT="/root/VS Code移植/dist"
B="/tmp/apkbuild7"
PROBE_SRC="/tmp/probej/src/MainActivity.java"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

echo "== 0/6 checks =="
[ -f "$APP_DIR/jni/arm64-v8a/libxul.so" ] || { echo "FATAL: native libs missing" >&2; exit 1; }
[ -f "$APP_DIR/assets/runtime/vscode.tar.gz" ] || { echo "FATAL: assets missing" >&2; exit 1; }
[ -f "$PROBE_SRC" ] || { echo "FATAL: probe J source missing" >&2; exit 1; }
grep -q zygotePreloadName "$APP_DIR/src/main/AndroidManifest.xml" && {
echo "FATAL: zygotePreloadName still present" >&2; exit 1; }
grep -q "PROBE J" "$PROBE_SRC" || { echo "FATAL: probe J marker missing" >&2; exit 1; }
grep -q "probeJ/createGecko" "$PROBE_SRC" || { echo "FATAL: probe J catch missing" >&2; exit 1; }
echo "manifest clean, probe J source sane"

rm -rf "$B"
mkdir -p "$B/flat" "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/6 aapt2 compile =="
"$BT/aapt2" compile --dir "$APP_DIR/src/main/res" -o "$B/flat/"

echo "== 2/6 aapt2 link (J, vc 18) =="
"$BT/aapt2" link \
-o "$B/baseJ.apk" \
-I "$PLATFORM" \
--manifest "$APP_DIR/src/main/AndroidManifest.xml" \
--java "$B/gen" \
--min-sdk-version 26 --target-sdk-version 28 \
--version-code 18 --version-name "1.0.4-j" \
--auto-add-overlay \
"$B/flat"/*.flat
ls -l "$B/baseJ.apk"

echo "== 3/6 javac (ASCII staging dir, probe J source) =="
CP="$APP_DIR/libs/geckoview-classes.jar"
for j in androidx-core annotation collection lifecycle-common kotlin-stdlib; do
[ -f "$DEPS/$j.jar" ] && CP="$CP:$DEPS/$j.jar"
done
find "$APP_DIR/src/main/java" -name '*.java' -exec cp {} "$B/src/" \;
find "$B/gen" -name '*.java' -exec cp {} "$B/src/" \;
cp -f "$PROBE_SRC" "$B/src/MainActivity.java"
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

echo "== 5/6 package J (dex deflated, libs deflated, assets stored) =="
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stage/"

cp -f "$B/baseJ.apk" "$B/unsignedJ.apk"
( cd "$B/stage" && zip -q -9 -X "$B/unsignedJ.apk" classes*.dex )
( cd "$B/stage" && zip -q -9 -X "$B/unsignedJ.apk" lib/arm64-v8a/*.so )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedJ.apk" assets/omni.ja )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedJ.apk" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )

echo "== 6/6 zipalign + apksigner for J =="
"$BT/zipalign" -f -P 16 4 "$B/unsignedJ.apk" "$B/alignedJ.apk"
KS="$APP_DIR/keystore/release.jks"
java -jar "$BT/lib/apksigner.jar" sign \
--ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
--ks-key-alias vscodemobile \
--min-sdk-version 26 \
--v1-signing-enabled true --v2-signing-enabled true \
--v3-signing-enabled true --v4-signing-enabled false \
--out "$OUT/vscode-mobile-J.apk" "$B/alignedJ.apk"

echo "--- J verify ---"
java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
"$OUT/vscode-mobile-J.apk" 2>&1 | head -8
"$BT/zipalign" -c -P 16 -v 4 "$OUT/vscode-mobile-J.apk" 2>&1 | tail -2
"$BT/aapt2" dump badging "$OUT/vscode-mobile-J.apk" 2>/dev/null | head -4
ls -l "$OUT/vscode-mobile-J.apk"
md5sum "$OUT/vscode-mobile-J.apk"
echo "--- J entry methods ---"
unzip -v "$OUT/vscode-mobile-J.apk" | awk 'NF>=8 && $1 ~ /^[0-9]+$/ {m=$2; c[m]++} END{for(k in c) print k, c[k]}'
echo "--- zygote attribute must be absent ---"
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$OUT/vscode-mobile-J.apk" 2>/dev/null | grep -c -i zygote || echo "ZYGOTE_ABSENT"
echo "--- probe J marker must be inside the dex ---"
unzip -p "$OUT/vscode-mobile-J.apk" classes.dex | strings -a | grep -c "probeJ/createGecko" || echo "PROBE_MARKER_MISSING"
echo BUILD_OK