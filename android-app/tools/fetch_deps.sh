#!/usr/bin/env bash
# Fetch every jar/AAR that build10.sh needs into libs/.
#
# libs/ is gitignored (30+ MB of third-party binaries), so a clean checkout has
# nothing to compile against. This script rebuilds it reproducibly from Maven
# Central and Google's Maven repo.
#
# Layout produced:
#   libs/geckoview-classes.jar        <- classes.jar from the geckoview AAR
#   libs/runtime-deps-clean/*.jar     <- first closure (androidx/media3/gms/guava/yaml)
#   libs/kotlin/*.jar                 <- kotlin runtime (stdlib matches GeckoView's POM)
#   libs/closure-extra/*.jar          <- second closure (transitive artifacts)
#   libs/aar/*.aar                    <- AARs whose res/ + R.txt are needed
#
# Usage: tools/fetch_deps.sh [--force]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(dirname "$HERE")"
LIB="$APP/libs"
G=https://dl.google.com/dl/android/maven2
M=https://repo1.maven.org/maven2
FORCE="${1:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$LIB/runtime-deps-clean" "$LIB/kotlin" "$LIB/closure-extra" "$LIB/aar"

# fetch <url> <dest>; skips an already valid file (zip test) unless --force
fetch() {
  local url="$1" dest="$2"
  if [[ "$FORCE" != "--force" && -s "$dest" ]] && unzip -l "$dest" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  curl -sSfL --retry 3 --retry-all-errors --max-time 900 -o "$dest.part" "$url"
  mv -f "$dest.part" "$dest"
  printf '  %8d  %s\n' "$(stat -c %s "$dest")" "${dest#$LIB/}"
}

# aar_classes <url> <dest.jar>: AAR -> its classes.jar
aar_classes() {
  local url="$1" dest="$2"
  if [[ "$FORCE" != "--force" && -s "$dest" ]]; then return 0; fi
  local name; name="$(basename "$url")"
  fetch "$url" "$TMP/$name"
  mkdir -p "$(dirname "$dest")"
  if unzip -l "$TMP/$name" 2>/dev/null | grep -q ' classes.jar$'; then
    rm -rf "$TMP/x"; mkdir -p "$TMP/x"
    unzip -qo "$TMP/$name" classes.jar -d "$TMP/x"
    cp -f "$TMP/x/classes.jar" "$dest"
    printf '  %8d  %s (classes.jar of %s)\n' "$(stat -c %s "$dest")" "${dest#$LIB/}" "$name"
  else
    cp -f "$TMP/$name" "$dest"
    printf '  %8d  %s (plain jar)\n' "$(stat -c %s "$dest")" "${dest#$LIB/}"
  fi
}

echo "== geckoview =="
# The GeckoView AAR lives in the local SDK mirror (91 MB, not on Maven Central).
GV_AAR="/root/android-sdk/m2/geckoview-arm64-v8a.aar"
if [[ -s "$GV_AAR" ]]; then
  if [[ ! -s "$LIB/geckoview-classes.jar" || "$FORCE" == "--force" ]]; then
    rm -rf "$TMP/gv"; mkdir -p "$TMP/gv"
    unzip -qo "$GV_AAR" classes.jar -d "$TMP/gv"
    cp -f "$TMP/gv/classes.jar" "$LIB/geckoview-classes.jar"
  fi
  echo "  geckoview-classes.jar from $GV_AAR"
else
  echo "  WARNING: $GV_AAR missing; geckoview-classes.jar left untouched"
fi

echo "== first closure (runtime-deps-clean) =="
aar_classes "$G/androidx/annotation/annotation/1.11.0/annotation-1.11.0.jar"             "$LIB/runtime-deps-clean/androidx-annotation-1.11.0.jar"
aar_classes "$G/androidx/collection/collection/1.6.0/collection-1.6.0.jar"               "$LIB/runtime-deps-clean/androidx-collection-1.6.0.jar"
aar_classes "$G/androidx/core/core/1.19.1/core-1.19.1.aar"                               "$LIB/runtime-deps-clean/androidx-core-1.19.1.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-common/2.11.0/lifecycle-common-2.11.0.jar" "$LIB/runtime-deps-clean/androidx-lifecycle-common-2.11.0.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-runtime/2.11.0/lifecycle-runtime-2.11.0.aar" "$LIB/runtime-deps-clean/androidx-lifecycle-runtime-2.11.0.jar"
aar_classes "$G/androidx/startup/startup-runtime/1.1.1/startup-runtime-1.1.1.aar"       "$LIB/runtime-deps-clean/androidx-startup-runtime-1.1.1.jar"
aar_classes "$G/androidx/tracing/tracing/1.2.0/tracing-1.2.0.aar"                       "$LIB/runtime-deps-clean/androidx-tracing-1.2.0.jar"
aar_classes "$G/androidx/versionedparcelable/versionedparcelable/1.1.1/versionedparcelable-1.1.1.aar" "$LIB/runtime-deps-clean/androidx-versionedparcelable-1.1.1.jar"
aar_classes "$G/androidx/annotation/annotation-experimental/1.6.0/annotation-experimental-1.6.0.aar" "$LIB/runtime-deps-clean/androidx.annotation-annotation-experimental-1.6.0.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-process/2.11.0/lifecycle-process-2.11.0.aar" "$LIB/runtime-deps-clean/androidx.lifecycle-lifecycle-process-2.11.0.jar"
aar_classes "$G/androidx/media3/media3-common/1.11.1/media3-common-1.11.1.aar"           "$LIB/runtime-deps-clean/androidx.media3-media3-common-1.11.1.jar"
aar_classes "$G/androidx/media3/media3-datasource/1.11.1/media3-datasource-1.11.1.aar"   "$LIB/runtime-deps-clean/androidx.media3-media3-datasource-1.11.1.jar"
aar_classes "$G/androidx/media3/media3-decoder/1.11.1/media3-decoder-1.11.1.aar"         "$LIB/runtime-deps-clean/androidx.media3-media3-decoder-1.11.1.jar"
aar_classes "$G/androidx/media3/media3-exoplayer/1.11.1/media3-exoplayer-1.11.1.aar"     "$LIB/runtime-deps-clean/androidx.media3-media3-exoplayer-1.11.1.jar"
aar_classes "$G/androidx/media3/media3-exoplayer-hls/1.11.1/media3-exoplayer-hls-1.11.1.aar" "$LIB/runtime-deps-clean/androidx.media3-media3-exoplayer-hls-1.11.1.jar"
aar_classes "$G/com/google/android/gms/play-services-fido/21.3.1/play-services-fido-21.3.1.aar" "$LIB/runtime-deps-clean/com.google.android.gms-play-services-fido-21.3.1.jar"
aar_classes "$G/com/google/android/gms/play-services-tasks/18.2.0/play-services-tasks-18.2.0.aar" "$LIB/runtime-deps-clean/play-services-tasks-18.2.0.jar"
aar_classes "$M/com/google/guava/guava/33.4.0-android/guava-33.4.0-android.jar"         "$LIB/runtime-deps-clean/guava-33.4.0-android.jar"
aar_classes "$M/org/yaml/snakeyaml/2.2/snakeyaml-2.2.jar"                               "$LIB/runtime-deps-clean/snakeyaml-2.2.jar"

echo "== kotlin runtime =="
fetch "$M/org/jetbrains/kotlin/kotlin-stdlib/2.4.20/kotlin-stdlib-2.4.20.jar"            "$LIB/kotlin/kotlin-stdlib-2.4.20.jar"
fetch "$M/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.10.2/kotlinx-coroutines-core-jvm-1.10.2.jar" "$LIB/kotlin/kotlinx-coroutines-core-jvm-1.10.2.jar"
fetch "$M/org/jetbrains/kotlinx/kotlinx-coroutines-android/1.10.2/kotlinx-coroutines-android-1.10.2.jar"   "$LIB/kotlin/kotlinx-coroutines-android-1.10.2.jar"
fetch "$M/org/jetbrains/annotations/23.0.0/annotations-23.0.0.jar"                       "$LIB/kotlin/annotations-23.0.0.jar"

echo "== second closure (closure-extra) =="
aar_classes "$G/androidx/media3/media3-extractor/1.11.1/media3-extractor-1.11.1.aar"     "$LIB/closure-extra/media3-extractor-1.11.1.jar"
aar_classes "$G/androidx/media3/media3-container/1.11.1/media3-container-1.11.1.aar"     "$LIB/closure-extra/media3-container-1.11.1.jar"
aar_classes "$G/androidx/media3/media3-database/1.11.1/media3-database-1.11.1.aar"       "$LIB/closure-extra/media3-database-1.11.1.jar"
aar_classes "$G/androidx/interpolator/interpolator/1.0.0/interpolator-1.0.0.aar"         "$LIB/closure-extra/interpolator-1.0.0.jar"
aar_classes "$G/androidx/concurrent/concurrent-futures/1.1.0/concurrent-futures-1.1.0.jar" "$LIB/closure-extra/concurrent-futures-1.1.0.jar"
aar_classes "$M/com/google/guava/failureaccess/1.0.2/failureaccess-1.0.2.jar"            "$LIB/closure-extra/failureaccess-1.0.2.jar"
aar_classes "$M/com/google/j2objc/j2objc-annotations/3.0.0/j2objc-annotations-3.0.0.jar" "$LIB/closure-extra/j2objc-annotations-3.0.0.jar"
aar_classes "$G/androidx/arch/core/core-runtime/2.2.0/core-runtime-2.2.0.aar"            "$LIB/closure-extra/arch-core-runtime-2.2.0.jar"
aar_classes "$G/androidx/arch/core/core-common/2.2.0/core-common-2.2.0.jar"              "$LIB/closure-extra/core-common-2.2.0.jar"
aar_classes "$G/androidx/exifinterface/exifinterface/1.4.1/exifinterface-1.4.1.aar"      "$LIB/closure-extra/exifinterface-1.4.1.jar"
aar_classes "$G/androidx/activity/activity/1.11.0/activity-1.11.0.aar"                   "$LIB/closure-extra/activity-1.11.0.jar"
aar_classes "$G/androidx/fragment/fragment/1.8.9/fragment-1.8.9.aar"                     "$LIB/closure-extra/fragment-1.8.9.jar"
aar_classes "$G/androidx/core/core-viewtree/1.0.0/core-viewtree-1.0.0.aar"               "$LIB/closure-extra/core-viewtree-1.0.0.jar"
aar_classes "$G/androidx/customview/customview/1.2.0/customview-1.2.0.aar"               "$LIB/closure-extra/customview-1.2.0.jar"
aar_classes "$G/androidx/loader/loader/1.1.0/loader-1.1.0.aar"                           "$LIB/closure-extra/loader-1.1.0.jar"
aar_classes "$G/androidx/viewpager/viewpager/1.1.0/viewpager-1.1.0.aar"                  "$LIB/closure-extra/viewpager-1.1.0.jar"
aar_classes "$G/androidx/savedstate/savedstate-android/1.4.0/savedstate-android-1.4.0.aar" "$LIB/closure-extra/savedstate-1.4.0.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-viewmodel-android/2.11.0/lifecycle-viewmodel-android-2.11.0.aar" "$LIB/closure-extra/lifecycle-viewmodel-2.11.0.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-viewmodel-savedstate-android/2.11.0/lifecycle-viewmodel-savedstate-android-2.11.0.aar" "$LIB/closure-extra/lifecycle-viewmodel-savedstate-2.11.0.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-livedata/2.11.0/lifecycle-livedata-2.11.0.aar" "$LIB/closure-extra/lifecycle-livedata-2.11.0.jar"
aar_classes "$G/androidx/lifecycle/lifecycle-livedata-core/2.11.0/lifecycle-livedata-core-2.11.0.aar" "$LIB/closure-extra/lifecycle-livedata-core-2.11.0.jar"
aar_classes "$G/com/google/android/gms/play-services-base/18.7.2/play-services-base-18.7.2.aar" "$LIB/closure-extra/play-services-base-18.7.2.jar"
aar_classes "$G/com/google/android/gms/play-services-basement/18.9.0/play-services-basement-18.9.0.aar" "$LIB/closure-extra/play-services-basement-18.9.0.jar"
fetch "$M/org/jetbrains/kotlinx/kotlinx-serialization-core-jvm/1.7.3/kotlinx-serialization-core-jvm-1.7.3.jar" "$LIB/closure-extra/kotlinx-serialization-core-jvm-1.7.3.jar"

echo "== AARs whose res/ and R.txt are merged into the APK =="
for a in \
  "$G/androidx/core/core/1.19.1/core-1.19.1.aar" \
  "$G/androidx/activity/activity/1.11.0/activity-1.11.0.aar" \
  "$G/androidx/arch/core/core-runtime/2.2.0/core-runtime-2.2.0.aar" \
  "$G/androidx/core/core-viewtree/1.0.0/core-viewtree-1.0.0.aar" \
  "$G/androidx/customview/customview/1.2.0/customview-1.2.0.aar" \
  "$G/androidx/exifinterface/exifinterface/1.4.1/exifinterface-1.4.1.aar" \
  "$G/androidx/fragment/fragment/1.8.9/fragment-1.8.9.aar" \
  "$G/androidx/interpolator/interpolator/1.0.0/interpolator-1.0.0.aar" \
  "$G/androidx/lifecycle/lifecycle-runtime-android/2.11.0/lifecycle-runtime-android-2.11.0.aar" \
  "$G/androidx/lifecycle/lifecycle-viewmodel-android/2.11.0/lifecycle-viewmodel-android-2.11.0.aar" \
  "$G/androidx/media3/media3-exoplayer/1.11.1/media3-exoplayer-1.11.1.aar" \
  "$G/androidx/savedstate/savedstate-android/1.4.0/savedstate-android-1.4.0.aar" \
  "$G/androidx/startup/startup-runtime/1.1.1/startup-runtime-1.1.1.aar" \
  "$G/androidx/viewpager/viewpager/1.1.0/viewpager-1.1.0.aar" \
  "$G/com/google/android/gms/play-services-base/18.7.2/play-services-base-18.7.2.aar" \
  "$G/com/google/android/gms/play-services-basement/18.9.0/play-services-basement-18.9.0.aar" ; do
  fetch "$a" "$LIB/aar/$(basename "$a")"
done

echo "FETCH_OK"
