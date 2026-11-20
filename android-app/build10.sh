#!/usr/bin/env bash
# VS Code Mobile - build v10, variant L (full GeckoView runtime dependency closure).
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
B="/tmp/apkbuild10"
DEPS="$APP_DIR/libs/runtime-deps-clean"

export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Same PRoot stub-loader flakiness as the link stage below: any child exec can
# die with "[proroot-stub-loader] stack build failed =7" (exit 125) and succeed
# on retry. Wrap every aapt2 call so one flake does not poison the flat dir.
aapt2_retry() {
  _try=0
  while :; do
    _try=$((_try + 1))
    set +e
    "$BT/aapt2" "$@"
    _rc=$?
    set -e
    [ "$_rc" -eq 0 ] && return 0
    [ "$_try" -ge 5 ] && { echo "FATAL: aapt2 $* rc=$_rc after $_try tries"; exit 1; }
    echo "  aapt2 $* rc=$_rc, retry $_try/5"
    sleep 3
  done
}

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
 "$DEPS/androidx-lifecycle-runtime-2.11.0.jar"
 "$DEPS/androidx-startup-runtime-1.1.1.jar"
 "$DEPS/androidx-tracing-1.2.0.jar"
 "$DEPS/androidx-versionedparcelable-1.1.1.jar"
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

# Kotlin runtime. kotlin-stdlib version matches the one GeckoView's POM declares
# (2.4.20); coroutines matches what androidx 1.19 / lifecycle 2.11 use. Both were
# missing from the dex, which is why the v1.0.6-l build died on the device with
#   NoClassDefFoundError: kotlin/jvm/internal/Intrinsics
# at androidx.collection.SimpleArrayMap.put(SimpleArrayMap.kt:397)
# <- GeckoBundle.putString <- GeckoSessionSettings.<init> <- createGecko.
# R8 8.2.33 cannot parse kotlin 2.x @Metadata and prints Info/Warning lines for
# it, but the dex is still produced correctly; do not treat those as errors.
KDIR="$APP_DIR/libs/kotlin"
KOTLIN_JARS=(
  "$KDIR/annotations-23.0.0.jar"
  "$KDIR/kotlin-stdlib-2.4.20.jar"
  "$KDIR/kotlinx-coroutines-core-jvm-1.10.2.jar"
  "$KDIR/kotlinx-coroutines-android-1.10.2.jar"
)

# Second closure gap. R8's "Missing class" report on the L dex showed that the
# first closure still omitted transitive artifacts of media3 / play-services-fido
# / guava (e.g. androidx.media3.extractor.*, com.google.android.gms.common.*).
# Each of those is a real code reference, i.e. another latent NoClassDefFoundError
# exactly like the kotlin one. libs/closure-extra/ holds the jars extracted from
# the corresponding AARs (classes.jar) plus the plain jars from Maven Central.
XD=$APP_DIR/libs/closure-extra
EXTRA_JARS=(
  "$XD/media3-extractor-1.11.1.jar"
  "$XD/media3-container-1.11.1.jar"
  "$XD/media3-database-1.11.1.jar"
  "$XD/interpolator-1.0.0.jar"
  "$XD/concurrent-futures-1.1.0.jar"
  "$XD/failureaccess-1.0.2.jar"
  "$XD/j2objc-annotations-3.0.0.jar"
  "$XD/play-services-base-18.7.2.jar"
  "$XD/play-services-basement-18.9.0.jar"
  "$XD/arch-core-runtime-2.2.0.jar"
  "$XD/exifinterface-1.4.1.jar"
  "$XD/activity-1.11.0.jar"
  "$XD/fragment-1.8.9.jar"
  "$XD/core-viewtree-1.0.0.jar"
  "$XD/loader-1.1.0.jar"
  "$XD/viewpager-1.1.0.jar"
  "$XD/savedstate-1.4.0.jar"
  "$XD/lifecycle-viewmodel-2.11.0.jar"
  "$XD/lifecycle-viewmodel-savedstate-2.11.0.jar"
  "$XD/lifecycle-livedata-2.11.0.jar"
  "$XD/lifecycle-livedata-core-2.11.0.jar"
  "$XD/core-common-2.2.0.jar"
  "$XD/customview-1.2.0.jar"
  "$XD/kotlinx-serialization-core-jvm-1.7.3.jar"
)
for j in "${DEPJARS[@]}" "${KOTLIN_JARS[@]}" "${EXTRA_JARS[@]}"; do
  [ -s "$j" ] || { echo "FATAL: dependency missing: $j"; exit 1; }
  unzip -l "$j" >/dev/null 2>&1 || { echo "FATAL: dependency not a zip: $j"; exit 1; }
done
echo "manifest clean, crash handler present, ${#DEPJARS[@]} dependency + ${#KOTLIN_JARS[@]} kotlin + ${#EXTRA_JARS[@]} extra jars present"

rm -rf "$B"
rm -rf "$B/flat" "$B/flat.zip"
mkdir -p "$B/gen" "$B/classes" "$B/dex" "$B/src" "$OUT"

echo "== 1/6 aapt2 compile =="
# Compile to a single zip container per resource set instead of a directory of
# one flat per resource file. aapt2 link takes such zips as positional inputs,
# and this is what keeps the argument count small: PRoot's stub loader aborts a
# child exec with "[proroot-stub-loader] stack build failed =7" (exit 125) once
# the child gets 256 positional arguments. One flat per file meant 256+ inputs
# (app res 2 + libraries 348) and every build died right there; one zip per
# resource set means 18 inputs, with no resources excluded.
aapt2_retry compile --dir "$APP_DIR/src/main/res" -o "$B/flat.zip"

# Library resources + library R classes.
#
# GeckoView and its dependency closure reference their own R classes
# (org.mozilla.geckoview.R$drawable in GeckoAppShell.getIconForExtension,
# androidx.fragment.R$id, com.google.android.gms.base.R$string, ...). A Gradle
# build gets those for free because AGP merges every AAR's res/ into the app and
# generates R for each package. This hand build did not, so each of them was a
# latent NoClassDefFoundError / Resources$NotFoundException.
#
# Fix: merge every closure AAR's res/, then let aapt2 emit an R class per library
# package via --extra-packages. The R.java files land in $B/gen/<pkg>/R.java.
LIBAARS=(
  "/root/android-sdk/m2/geckoview-arm64-v8a.aar|org.mozilla.geckoview"
  "$APP_DIR/libs/aar/core-1.19.1.aar|androidx.core"
  "$APP_DIR/libs/aar/activity-1.11.0.aar|androidx.activity"
  "$APP_DIR/libs/aar/fragment-1.8.9.aar|androidx.fragment"
  "$APP_DIR/libs/aar/core-viewtree-1.0.0.aar|androidx.core.viewtree"
  "$APP_DIR/libs/aar/lifecycle-runtime-android-2.11.0.aar|androidx.lifecycle.runtime"
  "$APP_DIR/libs/aar/lifecycle-viewmodel-android-2.11.0.aar|androidx.lifecycle.viewmodel"
  "$APP_DIR/libs/aar/startup-runtime-1.1.1.aar|androidx.startup"
  "$APP_DIR/libs/aar/core-runtime-2.2.0.aar|androidx.arch.core"
  "$APP_DIR/libs/aar/exifinterface-1.4.1.aar|androidx.exifinterface"
  "$APP_DIR/libs/aar/savedstate-android-1.4.0.aar|androidx.savedstate"
  "$APP_DIR/libs/aar/viewpager-1.1.0.aar|androidx.viewpager"
  "$APP_DIR/libs/aar/interpolator-1.0.0.aar|androidx.interpolator"
  "$APP_DIR/libs/aar/media3-exoplayer-1.11.1.aar|androidx.media3.exoplayer"
  "$APP_DIR/libs/aar/play-services-base-18.7.2.aar|com.google.android.gms.base"
  "$APP_DIR/libs/aar/play-services-basement-18.9.0.aar|com.google.android.gms.common"
  "$APP_DIR/libs/aar/customview-1.2.0.aar|androidx.customview"
)
rm -rf "$B/libres" "$B/flatlib"
mkdir -p "$B/libres" "$B/flatlib"
EXTRAPKGS=()
LIDX=0
for pair in "${LIBAARS[@]}"; do
  aar="${pair%%|*}"
  pkg="${pair##*|}"
  [ -s "$aar" ] || { echo "FATAL: library aar missing: $aar"; exit 1; }
  d="$B/libres/$LIDX"
  mkdir -p "$d"
  unzip -o -q "$aar" 'res/*' -d "$d" || true
  if [ -d "$d/res" ]; then
    aapt2_retry compile --dir "$d/res" -o "$B/flatlib/$LIDX.zip"
  else
    : > "$B/flatlib/$LIDX.zip"
  fi
  EXTRAPKGS+=("$pkg")
  LIDX=$((LIDX + 1))
done
echo "library packages: ${#EXTRAPKGS[@]}"

echo "== 2/6 aapt2 link (L, vc 33, 1.0.19-l) =="
LINK_INPUTS=("$B/flat.zip")
for z in "$B/flatlib"/*.zip; do [ -s "$z" ] && LINK_INPUTS+=("$z"); done
echo "  link inputs: ${#LINK_INPUTS[@]} zip containers"
if [ "${#LINK_INPUTS[@]}" -gt 240 ]; then
  echo "FATAL: ${#LINK_INPUTS[@]} link inputs is too close to the 255 cap"
  exit 1
fi
LINK_TRY=0
while :; do
LINK_TRY=$((LINK_TRY + 1))
set +e
"$BT/aapt2" link \
  -o "$B/baseL.apk" \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$B/gen" \
  --min-sdk-version 26 --target-sdk-version 28 \
  --version-code 33 --version-name "1.0.19-l" \
  --auto-add-overlay \
  "${LINK_INPUTS[@]}"
LINK_RC=$?
set -e
if [ "$LINK_RC" -eq 0 ] && [ -s "$B/baseL.apk" ]; then
  break
fi
if [ "$LINK_TRY" -ge 5 ]; then
  echo "FATAL: aapt2 link failed rc=$LINK_RC after $LINK_TRY attempts"
  exit 1
fi
echo "  aapt2 link rc=$LINK_RC, retry $LINK_TRY/5"
sleep 3
done
ls -l "$B/baseL.apk"

# aapt2 link cannot emit one R per library package: its --extra-packages takes a
# single package name (a comma list becomes one literal name, verified). So the
# linked table is the source of truth: tools/genlibR.py reads the ids aapt2
# assigned and writes <pkg>/R.java for every merged library.
echo "-- library R classes --"
LIBRARGS=()
for pair in "${LIBAARS[@]}"; do LIBRARGS+=("$pair"); done
python3 "$APP_DIR/tools/genlibR.py" "$B/baseL.apk" "$B/gen" "${LIBRARGS[@]}"

echo "== 3/6 javac =="
CP="$APP_DIR/libs/geckoview-classes.jar"
for j in "${DEPJARS[@]}" "${KOTLIN_JARS[@]}" "${EXTRA_JARS[@]}"; do CP="$CP:$j"; done
find "$APP_DIR/src/main/java" -name '*.java' -exec cp {} "$B/src/" \;
( cd "$B/gen" && find . -name '*.java' -exec cp --parents {} "$B/src/" \; )
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
  "${KOTLIN_JARS[@]}" \
  "${EXTRA_JARS[@]}" \
  $(find "$B/classes" -name '*.class')
ls -l "$B"/dex/classes*.dex
NDEX=$(ls "$B"/dex/classes*.dex | wc -l)
DEX_BYTES=$(cat "$B"/dex/classes*.dex | wc -c)
echo "dex files: $NDEX  total dex bytes: $DEX_BYTES"
if [ "$DEX_BYTES" -lt 4000000 ]; then
  echo "FATAL: dex too small, dependency closure probably not merged"; exit 1
fi

echo "== 5/6 package L =="
mkdir -p "$B/stage/lib/arm64-v8a" "$B/stage/assets/runtime"
cp -f "$APP_DIR"/jni/arm64-v8a/*.so "$B/stage/lib/arm64-v8a/"
cp -f "$APP_DIR/assets/omni.ja" "$B/stage/assets/"
cp -f "$APP_DIR/assets/runtime/rootfs.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/vscode.tar.gz" "$B/stage/assets/runtime/"
cp -f "$APP_DIR/assets/runtime/usr.tar.gz" "$B/stage/assets/runtime/"
cp -f "$B"/dex/classes*.dex "$B/stage/"

cp -f "$B/baseL.apk" "$B/unsignedL.apk"
( cd "$B/stage" && zip -q -9 -X "$B/unsignedL.apk" classes*.dex )
( cd "$B/stage" && zip -q -9 -X "$B/unsignedL.apk" lib/arm64-v8a/*.so )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedL.apk" assets/omni.ja )
( cd "$B/stage" && zip -q -0 -X "$B/unsignedL.apk" assets/runtime/rootfs.tar.gz assets/runtime/vscode.tar.gz assets/runtime/usr.tar.gz )

echo "== 6/6 zipalign + apksigner for L =="
"$BT/zipalign" -f -P 16 4 "$B/unsignedL.apk" "$B/alignedL.apk"
KS="$APP_DIR/keystore/release.jks"
java -jar "$BT/lib/apksigner.jar" sign \
  --ks "$KS" --ks-pass pass:vscodemobile --key-pass pass:vscodemobile \
  --ks-key-alias vscodemobile \
  --min-sdk-version 26 \
  --v1-signing-enabled true --v2-signing-enabled true \
  --v3-signing-enabled true --v4-signing-enabled false \
  --out "$OUT/vscode-mobile-L.apk" "$B/alignedL.apk"

echo "--- L verify ---"
java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 21 --verbose \
  "$OUT/vscode-mobile-L.apk" 2>&1 | head -8 || true
"$BT/zipalign" -c -P 16 -v 4 "$OUT/vscode-mobile-L.apk" 2>&1 | tail -2 || true
"$BT/aapt2" dump badging "$OUT/vscode-mobile-L.apk" 2>/dev/null | head -4 || true
ls -l "$OUT/vscode-mobile-L.apk"
md5sum "$OUT/vscode-mobile-L.apk"
echo "--- dex list inside apk ---"
unzip -l "$OUT/vscode-mobile-L.apk" | grep 'classes.*dex' || true
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
echo "--- kotlin runtime must be inside the dex (hard gate) ---"
for k in "kotlin/jvm/internal/Intrinsics" "kotlinx/coroutines/Dispatchers" "androidx/media3/extractor/DefaultExtractorsFactory" "com/google/android/gms/common/api/Api" "androidx/lifecycle/runtime/R\$id" "androidx/startup/R\$string" "androidx/collection/SimpleArrayMap" "androidx/annotation/Nullable"; do
  n=$(cat "$B"/dex/classes*.dex | strings -a | grep -c "$k" || true)
  echo "  $k hits=$n"
  [ "$n" -gt 0 ] || { echo "FATAL: $k missing from dex"; exit 1; }
done
echo BUILD_OK