#!/usr/bin/env bash
# Exercise the pure download logic on a JVM. Downloads.java deliberately has no
# Android imports, so it compiles and runs here without a device - which matters
# because the surrounding onExternalResponse path cannot be executed offline at all.
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="${1:-android-app}"
SRC="$APP/src/main/java/dev/dsh/vscodemobile/Downloads.java"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

FAIL=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=1; }

[ -f "$SRC" ] || { bad "missing $SRC"; exit 1; }

# The class is package-private and references nothing Android, but the package
# statement requires the directory layout.
mkdir -p "$W/src/dev/dsh/vscodemobile"
cp "$SRC" "$W/src/dev/dsh/vscodemobile/Downloads.java"

cat > "$W/src/dev/dsh/vscodemobile/DownloadTest.java" <<'JAVA'
package dev.dsh.vscodemobile;

import java.io.File;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

public final class DownloadTest {
    private static int failures = 0;

    private static void check(String what, Object got, Object want) {
        boolean ok = want == null ? got == null : want.equals(got);
        System.out.println((ok ? "ok    " : "FAIL  ") + what
                + (ok ? "" : "  got=" + got + " want=" + want));
        if (!ok) {
            failures++;
        }
    }

    public static void main(String[] args) throws IOException {
        // Content-Disposition is the authoritative name.
        check("quoted filename",
                Downloads.nameFrom("attachment; filename=\"git-2.34.1.tar.gz\"", "https://x/y"),
                "git-2.34.1.tar.gz");
        check("unquoted filename",
                Downloads.nameFrom("attachment; filename=profile.json", "https://x/y"),
                "profile.json");
        check("uppercase header name",
                Downloads.nameFrom("attachment; FILENAME=\"Report.PDF\"", "https://x/y"),
                "Report.PDF");
        check("path in filename is stripped",
                Downloads.nameFrom("attachment; filename=\"/etc/passwd\"", "https://x/y"),
                "passwd");
        check("windows path in filename is stripped",
                Downloads.nameFrom("attachment; filename=\"C:\\\\tmp\\\\a.txt\"", "https://x/y"),
                "a.txt");
        check("no filename= falls through to the URL",
                Downloads.nameFrom("attachment", "https://host/dir/extension.vsix"),
                "extension.vsix");
        check("null disposition uses the URL",
                Downloads.nameFrom(null, "https://host/dir/extension.vsix"),
                "extension.vsix");
        check("query string is dropped",
                Downloads.nameFrom(null, "https://host/pkg.vsix?version=1.2.3"),
                "pkg.vsix");
        check("fragment is dropped",
                Downloads.nameFrom(null, "https://host/pkg.vsix#frag"),
                "pkg.vsix");
        // No path at all: the last segment is empty, so a timestamp is the only
        // sane name. With no trailing slash the host itself is the last segment,
        // which is still a usable file name and is kept.
        String trailing = Downloads.nameFrom(null, "https://host/");
        check("trailing slash falls back to a timestamp name",
                Boolean.valueOf(trailing.startsWith("vscode-download-")), Boolean.TRUE);
        check("bare host is used as the name", Downloads.nameFrom(null, "https://host"),
                "host");
        // An opaque uri still ends up with a usable name after the last slash; no
        // colon survives in it, which is what keeps the name writable on Android.
        String opaque = Downloads.nameFrom(null, "data:text/plain,hello");
        check("opaque uri keeps the segment after the last slash", opaque, "plain,hello");
        check("opaque uri result has no colon", Boolean.valueOf(opaque.indexOf(':') < 0),
                Boolean.TRUE);

        // Header map lookup is case-insensitive and tolerates other headers.
        Map<String, String> headers = new LinkedHashMap<String, String>();
        headers.put("Content-Type", "application/octet-stream");
        headers.put("content-Disposition", "attachment; filename=\"a.zip\"");
        check("header map lookup",
                Downloads.nameFromHeaders(headers, "https://x/b.zip"), "a.zip");
        check("empty header map",
                Downloads.nameFromHeaders(new LinkedHashMap<String, String>(),
                        "https://x/b.zip"), "b.zip");
        check("null header map",
                Downloads.nameFromHeaders(null, "https://x/plain.txt"), "plain.txt");

        // Collision handling: never overwrite, keep the extension, number upwards.
        File dir = new File(System.getProperty("java.io.tmpdir"),
                "dl-test-" + System.nanoTime());
        dir.mkdirs();
        check("free name is used as-is",
                Downloads.unique(dir, "a.zip").getName(), "a.zip");
        new File(dir, "a.zip").createNewFile();
        check("first collision becomes -2",
                Downloads.unique(dir, "a.zip").getName(), "a-2.zip");
        new File(dir, "a-2.zip").createNewFile();
        check("second collision becomes -3",
                Downloads.unique(dir, "a.zip").getName(), "a-3.zip");
        check("no extension still numbers",
                Downloads.unique(dir, "LICENSE").getName(), "LICENSE");
        new File(dir, "LICENSE").createNewFile();
        check("no-extension collision",
                Downloads.unique(dir, "LICENSE").getName(), "LICENSE-2");
        check("dotfile keeps its dot",
                Downloads.unique(dir, ".env").getName(), ".env");
        for (File f : dir.listFiles()) {
            f.delete();
        }
        dir.delete();

        System.out.println(failures == 0 ? "DOWNLOADS_OK" : "DOWNLOADS_FAILED " + failures);
        System.exit(failures == 0 ? 0 : 1);
    }
}
JAVA

javac -encoding UTF-8 -d "$W/out" "$W/src/dev/dsh/vscodemobile/Downloads.java" \
      "$W/src/dev/dsh/vscodemobile/DownloadTest.java" 2>&1 | head -20

java -cp "$W/out" dev.dsh.vscodemobile.DownloadTest 2>&1 | tail -25