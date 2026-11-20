#!/usr/bin/env bash
# Run every offline check in one go. Individually they answer different questions,
# and the difference matters after 1.0.22-l shipped a payload with a missing library
# while the runtime assertions were green:
#
#   test_downloads.sh  pure logic (file naming, collision numbering) on a JVM
#   test_extract.sh    the app's own TarGz against the real payloads, guest runtime,
#                      and the static ELF closure (assertion 3i)
#   verify_apk.sh      the built APK: manifest, signature, payload presence
#
# test_extract.sh runs the payload; verify_apk.sh needs a built APK. Pass one as the
# first argument to check a specific artifact, otherwise dist/vscode-mobile-L.apk.
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="${APP:-android-app}"
APK="${1:-dist/vscode-mobile-L.apk}"
FAIL=0

printf '== 1/3 download logic ==\n'
if bash "$APP/tools/test_downloads.sh" "$APP" > /tmp/test_all_dl.log 2>&1; then
  tail -n 1 /tmp/test_all_dl.log
else
  FAIL=1
  grep -E '^FAIL|DOWNLOADS_FAILED' /tmp/test_all_dl.log | head -10
fi

printf '== 2/3 payload extraction and closure ==\n'
if bash "$APP/tools/test_extract.sh" "$APP" > /tmp/test_all_extract.log 2>&1; then
  grep -cE '^ok ' /tmp/test_all_extract.log | sed 's/^/assertions passed: /'
  tail -n 1 /tmp/test_all_extract.log
else
  FAIL=1
  grep -E '^FAIL|EXTRACT_FAILED' /tmp/test_all_extract.log | head -10
fi

printf '== 3/3 built apk ==\n'
if [ ! -f "$APK" ]; then
  printf 'skip  %s not built\n' "$APK"
else
  if bash "$APP/tools/verify_apk.sh" "$APK" > /tmp/test_all_apk.log 2>&1; then
    grep -cE '^ok ' /tmp/test_all_apk.log | sed 's/^/assertions passed: /'
    tail -n 1 /tmp/test_all_apk.log
  else
    FAIL=1
    grep -E '^FAIL|VERIFY_FAILED' /tmp/test_all_apk.log | head -10
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  printf '\nALL_TESTS_OK\n'
else
  printf '\nALL_TESTS_FAILED\n'
fi
exit "$FAIL"