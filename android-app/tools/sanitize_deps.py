import os, shutil, sys, zipfile

SRC = "/root/VS Code移植/android-app/libs/runtime-deps"
DST = "/root/VS Code移植/android-app/libs/runtime-deps-clean"

# androidx.core-core / androidx.annotation-annotation are byte-identical
# duplicates of androidx-core / androidx-annotation; feeding both to d8 aborts
# with "defined multiple times".
DUPS = {"androidx.core-core-1.19.1.jar", "androidx.annotation-annotation-1.11.0.jar"}

# Old d8 8.2.2 crashes (NPE) on android/support/v4/os/ResultReceiver$1.class.
# GeckoView bytecode contains ZERO references to android/support/*, so this
# legacy support-rename shim tree is safe to strip.
STRIP_PREFIX = "android/support/"


def main():
    if os.path.isdir(DST):
        shutil.rmtree(DST)
    os.makedirs(DST)

    report = []
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".jar"):
            continue
        src = os.path.join(SRC, name)
        if name in DUPS:
            report.append((name, "skip-dup", 0, 0))
            continue
        with zipfile.ZipFile(src) as z:
            entries = z.namelist()
            stripped = [e for e in entries if e.startswith(STRIP_PREFIX)]
            if not stripped:
                shutil.copy2(src, os.path.join(DST, name))
                report.append((name, "copy", len(entries), 0))
                continue
            dst = os.path.join(DST, name)
            with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as out:
                for e in entries:
                    if e.startswith(STRIP_PREFIX) or e.endswith("/"):
                        continue
                    out.writestr(e, z.read(e))
            report.append((name, "strip", len(entries) - len(stripped), len(stripped)))

    total = 0
    for name, action, kept, removed in report:
        size = 0 if action == "skip-dup" else os.path.getsize(os.path.join(DST, name))
        total += size
        print("%-52s %-9s kept=%-5d removed=%-3d %10d" % (name, action, kept, removed, size))
    print("jars written: %d  total bytes: %d" % (sum(1 for r in report if r[1] != "skip-dup"), total))

    with zipfile.ZipFile(os.path.join(DST, "androidx-core-1.19.1.jar")) as z:
        names = z.namelist()
    ok1 = "androidx/core/view/OnApplyWindowInsetsListener.class" in names
    bad = [n for n in names if n.startswith(STRIP_PREFIX)]
    print("OnApplyWindowInsetsListener present:", ok1)
    print("residual android/support entries:", len(bad))
    if not ok1 or bad:
        sys.exit(1)
    print("SANITIZE_OK")


main()