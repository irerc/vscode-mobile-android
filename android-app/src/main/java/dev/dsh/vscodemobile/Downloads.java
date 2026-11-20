package dev.dsh.vscodemobile;

import java.io.File;
import java.util.Locale;
import java.util.Map;

/**
 * Pure logic behind the download path in MainActivity, kept out of the Activity so
 * it can be exercised on a JVM (tools/test_downloads.sh). MainActivity only does the
 * Android parts: picking a directory, opening streams and showing the Toast.
 *
 * No Android types here on purpose - a JVM test needs to run this without a device.
 */
final class Downloads {

    private Downloads() {
    }

    /**
     * Choose a file name for a response. Content-Disposition wins because it is the
     * only place the server states the intended name; the URL's last segment is the
     * fallback, and a timestamp is the last resort. Query strings and any path
     * components are stripped so the result is always a bare name.
     */
    static String nameFrom(String contentDisposition, String uri) {
        String fromHeader = fromContentDisposition(contentDisposition);
        if (fromHeader != null) {
            return fromHeader;
        }
        String path = uri == null ? "" : uri;
        int q = path.indexOf('?');
        if (q >= 0) {
            path = path.substring(0, q);
        }
        int hash = path.indexOf('#');
        if (hash >= 0) {
            path = path.substring(0, hash);
        }
        int slash = path.lastIndexOf('/');
        String last = slash >= 0 ? path.substring(slash + 1) : path;
        if (last.length() > 0 && last.indexOf(':') < 0) {
            return last;
        }
        return "vscode-download-" + System.currentTimeMillis();
    }

    /** Same as nameFrom, reading the header out of a response's header map. */
    static String nameFromHeaders(Map<String, String> headers, String uri) {
        String cd = null;
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                if (e.getKey() != null && "content-disposition".equalsIgnoreCase(e.getKey())) {
                    cd = e.getValue();
                    break;
                }
            }
        }
        return nameFrom(cd, uri);
    }

    private static String fromContentDisposition(String cd) {
        if (cd == null) {
            return null;
        }
        int i = cd.toLowerCase(Locale.ROOT).indexOf("filename=");
        if (i < 0) {
            return null;
        }
        String v = cd.substring(i + "filename=".length()).trim();
        if (v.startsWith("\"")) {
            int end = v.indexOf('"', 1);
            v = end > 0 ? v.substring(1, end) : v.substring(1);
        }
        // Some servers send a full path; keep only the final component.
        v = v.replace('\\', '/');
        int slash = v.lastIndexOf('/');
        if (slash >= 0) {
            v = v.substring(slash + 1);
        }
        if (v.length() == 0 || v.indexOf(':') >= 0) {
            return null;
        }
        return v;
    }

    /**
     * Pick a path that does not exist yet: name, name-2, name-3, ... extension kept.
     * Overwriting silently would lose the previous download, which is worse than a
     * numbered twin.
     */
    static File unique(File dir, String name) {
        File f = new File(dir, name);
        if (!f.exists()) {
            return f;
        }
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 2; i < 1000; i++) {
            f = new File(dir, stem + "-" + i + ext);
            if (!f.exists()) {
                return f;
            }
        }
        // 999 collisions: fall back to a timestamp rather than reuse a name.
        return new File(dir, stem + "-" + System.currentTimeMillis() + ext);
    }
}