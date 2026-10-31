package dev.dsh.vscodemobile;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.util.zip.GZIPInputStream;

/**
 * Minimal tar.gz extractor using JDK only.
 * Supports: regular files, directories, symlinks, hardlinks, GNU long names, pax path headers.
 */
public final class TarGz {

    private TarGz() {
    }

    public static int extract(InputStream raw, File destDir) throws IOException {
        if (!destDir.exists() && !destDir.mkdirs()) {
            throw new IOException("cannot create " + destDir);
        }
        String base = destDir.getCanonicalPath();
        GZIPInputStream gz = new GZIPInputStream(new BufferedInputStream(raw, 65536), 65536);
        byte[] hdr = new byte[512];
        String pending = null;
        int count = 0;
        while (true) {
            int n = readFully(gz, hdr, 512);
            if (n < 512 || isZero(hdr)) {
                break;
            }
            String name = cstr(hdr, 0, 100);
            String prefix = cstr(hdr, 345, 155);
            if (prefix.length() > 0) {
                name = prefix + "/" + name;
            }
            long size = octal(hdr, 124, 12);
            long mode = octal(hdr, 100, 8);
            int type = hdr[156] & 0xFF;
            String link = cstr(hdr, 157, 100);

            if (type == 'L') {
                pending = cstr(readBytes(gz, (int) size), 0, (int) size);
                skipPad(gz, size);
                continue;
            }
            if (type == 'x') {
                String p = paxPath(readBytes(gz, (int) size));
                if (p != null && p.length() > 0) {
                    pending = p;
                }
                skipPad(gz, size);
                continue;
            }
            if (type == 'g' || type == 'K') {
                skipFully(gz, size);
                skipPad(gz, size);
                continue;
            }
            if (pending != null) {
                name = pending;
                pending = null;
            }
            String rel = name;
            while (rel.startsWith("./")) {
                rel = rel.substring(2);
            }
            if (rel.length() == 0 || rel.equals(".")) {
                skipFully(gz, size);
                skipPad(gz, size);
                continue;
            }
            if (rel.startsWith("/") || rel.contains("..")) {
                throw new IOException("unsafe path " + rel);
            }
            File out = new File(destDir, rel);
            String canon = out.getCanonicalPath();
            if (!canon.equals(base) && !canon.startsWith(base + File.separator)) {
                throw new IOException("escape " + rel);
            }
            if (type == '5') {
                if (!out.exists() && !out.mkdirs()) {
                    throw new IOException("cannot create " + out);
                }
                skipFully(gz, size);
                skipPad(gz, size);
                count++;
                continue;
            }
            File parent = out.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                throw new IOException("cannot create " + parent);
            }
            if (type == '2') {
                try {
                    if (out.exists()) {
                        out.delete();
                    }
                    Files.createSymbolicLink(out.toPath(),
                            out.toPath().getFileSystem().getPath(link));
                } catch (Throwable ignored) {
                }
                skipFully(gz, size);
                skipPad(gz, size);
                count++;
                continue;
            }
            if (type == '1') {
                copyFile(new File(destDir, link), out);
                skipFully(gz, size);
                skipPad(gz, size);
                count++;
                continue;
            }
            if (type == 0 || type == '0' || type == '7') {
                OutputStream os = new FileOutputStream(out);
                try {
                    copy(gz, os, size);
                } finally {
                    try {
                        os.close();
                    } catch (Throwable ignored) {
                    }
                }
                skipPad(gz, size);
                if ((mode & 0111) != 0) {
                    out.setExecutable(true, false);
                }
                count++;
            } else {
                skipFully(gz, size);
                skipPad(gz, size);
            }
        }
        try {
            gz.close();
        } catch (Throwable ignored) {
        }
        return count;
    }

    private static String paxPath(byte[] buf) {
        String all = new String(buf);
        int i = 0;
        while (i < all.length()) {
            int sp = all.indexOf(' ', i);
            if (sp < 0) {
                break;
            }
            int len;
            try {
                len = Integer.parseInt(all.substring(i, sp));
            } catch (Throwable t) {
                break;
            }
            if (len <= 0 || i + len > all.length()) {
                break;
            }
            String rec = all.substring(sp + 1, i + len - 1);
            if (rec.startsWith("path=")) {
                return rec.substring(5);
            }
            i += len;
        }
        return null;
    }

    private static void copyFile(File src, File dst) throws IOException {
        if (!src.isFile()) {
            return;
        }
        InputStream in = Files.newInputStream(src.toPath());
        try {
            OutputStream out = new FileOutputStream(dst);
            try {
                copy(in, out, Long.MAX_VALUE);
            } finally {
                out.close();
            }
        } finally {
            in.close();
        }
    }

    private static byte[] readBytes(InputStream in, int len) throws IOException {
        if (len <= 0) {
            return new byte[0];
        }
        byte[] buf = new byte[len];
        int off = 0;
        while (off < len) {
            int n = in.read(buf, off, len - off);
            if (n < 0) {
                break;
            }
            off += n;
        }
        return buf;
    }

    private static void copy(InputStream in, OutputStream out, long len) throws IOException {
        byte[] buf = new byte[65536];
        long left = len;
        while (left > 0) {
            int want = (int) Math.min(buf.length, left);
            int n = in.read(buf, 0, want);
            if (n < 0) {
                break;
            }
            out.write(buf, 0, n);
            left -= n;
        }
    }

    private static void skipFully(InputStream in, long left) throws IOException {
        byte[] buf = new byte[8192];
        long rem = left;
        while (rem > 0) {
            int want = (int) Math.min(buf.length, rem);
            int n = in.read(buf, 0, want);
            if (n < 0) {
                break;
            }
            rem -= n;
        }
    }

    private static void skipPad(InputStream in, long size) throws IOException {
        long pad = (512 - (size % 512)) % 512;
        if (pad > 0) {
            skipFully(in, pad);
        }
    }

    private static int readFully(InputStream in, byte[] buf, int len) throws IOException {
        int off = 0;
        while (off < len) {
            int n = in.read(buf, off, len - off);
            if (n < 0) {
                break;
            }
            off += n;
        }
        return off;
    }

    private static boolean isZero(byte[] b) {
        for (int i = 0; i < b.length; i++) {
            if (b[i] != 0) {
                return false;
            }
        }
        return true;
    }

    private static String cstr(byte[] b, int off, int len) {
        int max = off + len;
        if (max > b.length) {
            max = b.length;
        }
        int end = off;
        while (end < max && b[end] != 0) {
            end++;
        }
        return new String(b, off, end - off);
    }

    private static long octal(byte[] b, int off, int len) {
        long v = 0;
        for (int i = off; i < off + len; i++) {
            int c = b[i] & 0xFF;
            if (c == 0 || c == ' ') {
                if (v != 0) {
                    break;
                }
                continue;
            }
            if (c < '0' || c > '7') {
                continue;
            }
            v = v * 8 + (c - '0');
        }
        return v;
    }

    public static void main(String[] args) throws Exception {
        InputStream in = Files.newInputStream(new File(args[0]).toPath());
        int n = extract(in, new File(args[1]));
        System.out.println("EXTRACTED=" + n);
    }
}
