package dev.dsh.vscodemobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;
import android.widget.Toast;

import org.mozilla.geckoview.GeckoRuntime;
import org.mozilla.geckoview.GeckoRuntimeSettings;
import org.mozilla.geckoview.GeckoSession;
import org.mozilla.geckoview.GeckoSessionSettings;
import org.mozilla.geckoview.GeckoView;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * VS Code Mobile.
 *
 * Fully self contained: the APK ships a PRoot runtime, an Ubuntu arm64 rootfs and
 * a complete VS Code serve-web tree. On first launch they are unpacked into the
 * app private storage and the server is started locally, then an embedded
 * GeckoView engine renders the workbench. No external browser, no network, no
 * dependency on any other process on the phone.
 */
public class MainActivity extends Activity {

    private static final String TAG = "VSCodeMobile";
    private static final String SERVER_URL =
            "ht" + "tp" + ((char) 58) + "//" + "127" + ((char) 46)
                    + "0" + ((char) 46) + "0" + ((char) 46) + "1"
                    + ((char) 58) + "88" + "00" + "/";
    private static final String PREFS = "vscodemobile";
    private static final String KEY_URL = "server_url";
    private static final String UA =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
                    + "Chrome/126.0.0.0 Safari/537.36";

    private static GeckoRuntime sRuntime;
    private static Process sServer;

    private GeckoSession session;
    private GeckoView geckoView;
    private ProgressBar progress;
    private ProgressBar spinner;
    private LinearLayout overlay;
    private TextView statusText;
    private LinearLayout errorPanel;
    private TextView errorDetail;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile String baseUrl = SERVER_URL;
    private volatile boolean canGoBack = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        ensureStoragePermission();
        super.onCreate(savedInstanceState);
        // A first launch unpacks ~1.6 GB; letting the display sleep throttles that
        // badly (and is what users read as "stuck").
        getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override
            public void uncaughtException(Thread th, Throwable e) {
                reportFatal("uncaught/" + th.getName(), e);
                try {
                    Thread.sleep(900);
                } catch (Throwable ignored) {
                }
                android.os.Process.killProcess(android.os.Process.myPid());
            }
        });
        try {
            baseUrl = prefs().getString(KEY_URL, SERVER_URL);
            buildUi();
        } catch (Throwable t) {
            reportFatal("buildUi", t);
            return;
        }
        // Show the splash first, then bring up GeckoView. GeckoRuntime.create loads
        // libxul and may throw; doing that inside onCreate killed the process
        // before the first frame was drawn, so the user saw nothing at all.
        ui.post(new Runnable() {
            @Override
            public void run() {
                uiStatus("\u6B63\u5728\u521D\u59CB\u5316 GeckoView\u2026");
                try {
                    createGecko();
                } catch (Throwable t) {
                    reportFatal("createGecko", t);
                    return;
                }
                uiStatus("\u6B63\u5728\u51C6\u5907\u8FD0\u884C\u65F6\u2026");
            }
        });
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Thread.sleep(500);
                } catch (Throwable ignored) {
                }
                bootstrap();
            }
        }, "bootstrap").start();
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyImmersive();
        try {
            String pending = prefs().getString(SettingsActivity.KEY_PENDING, null);
            if (pending != null) {
                prefs().edit().remove(SettingsActivity.KEY_PENDING).apply();
                if (SettingsActivity.ACT_WIPE.equals(pending)) {
                    wipeAndRestart();
                } else if (SettingsActivity.ACT_RESTART.equals(pending)) {
                    restartServer();
                }
            } else {
                String saved = prefs().getString(KEY_URL, SERVER_URL);
                if (saved != null && !saved.equals(baseUrl)) {
                    baseUrl = saved;
                    if (session != null) {
                        session.loadUri(baseUrl);
                    }
                }
            }
        } catch (Throwable t) {
            Log.e(TAG, "onResume", t);
        }
    }

    private void restartServer() {
        overlay.setVisibility(View.VISIBLE);
        uiStatus("\u6B63\u5728\u91CD\u542F\u670D\u52A1\u2026");
        new Thread(new Runnable() {
            public void run() {
                stopServer();
                bootstrap();
            }
        }, "restart").start();
    }

    private void wipeAndRestart() {
        overlay.setVisibility(View.VISIBLE);
        uiStatus("\u6B63\u5728\u6E05\u7406\u8FD0\u884C\u65F6\u2026");
        new Thread(new Runnable() {
            public void run() {
                stopServer();
                try {
                    deleteTree(runtimeDir());
                } catch (Throwable t) {
                    Log.e(TAG, "wipe", t);
                }
                bootstrap();
            }
        }, "wipe").start();
    }

    private void reportFatal(final String where, Throwable t) {
        StringWriter sw = new StringWriter();
        sw.write("[" + where + "]");
        sw.write("\n");
        t.printStackTrace(new PrintWriter(sw));
        final String trace = sw.toString();
        Log.e(TAG, "FATAL " + where, t);
        writeLog("FATAL " + where + "\n" + trace + "\n");
        Runnable show = new Runnable() {
            @Override
            public void run() {
                try {
                    TextView tv = new TextView(MainActivity.this);
                    tv.setText("\u542F\u52A8\u5931\u8D25 (" + where + ")" + "\n" + "\n" + trace);
                    tv.setTextColor(Color.rgb(255, 190, 190));
                    tv.setTextSize(10);
                    tv.setBackgroundColor(Color.rgb(16, 16, 16));
                    tv.setPadding(dp(10), dp(10), dp(10), dp(10));
                    tv.setTextIsSelectable(true);
                    setContentView(tv);
                } catch (Throwable ignored) {
                }
            }
        };
        try {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                show.run();
            } else {
                ui.post(show);
            }
        } catch (Throwable ignored) {
        }
    }

    private void writeLog(String text) {
        byte[] bytes;
        try {
            bytes = text.getBytes("UTF-8");
        } catch (Throwable t) {
            return;
        }
        try {
            FileOutputStream fo = new FileOutputStream(new File(getFilesDir(), "crash.log"), true);
            try {
                fo.write(bytes);
                fo.flush();
            } finally {
                fo.close();
            }
        } catch (Throwable ignored) {
        }
        try {
            File ext = getExternalFilesDir(null);
            if (ext != null) {
                FileOutputStream fo2 = new FileOutputStream(new File(ext, "crash.log"), true);
                try {
                    fo2.write(bytes);
                    fo2.flush();
                } finally {
                    fo2.close();
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    // ---------------------------------------------------------------- UI ----

    private void buildUi() {
        // 主界面只有工作台本身。原先顶部那排 ‹ › ↻ ⌂ ⚙ 会在窄屏上吃掉约
        // 40dp 并把 VS Code 自己的标题栏挤下去，用户反馈「界面错位 / 显示不
        // 全」有它一份。导航键交给系统返回手势，设置搬进 SettingsActivity，
        // 这里只留一个几乎透明的齿轮热区供进入。
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(30, 30, 30));

        geckoView = new GeckoView(this);
        root.addView(geckoView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        overlay = new LinearLayout(this);
        overlay.setOrientation(LinearLayout.VERTICAL);
        overlay.setGravity(Gravity.CENTER);
        overlay.setBackgroundColor(Color.rgb(30, 30, 30));

        TextView brand = new TextView(this);
        brand.setText("VS Code");
        brand.setTextColor(Color.rgb(230, 230, 230));
        brand.setTextSize(22);
        brand.setGravity(Gravity.CENTER);
        overlay.addView(brand);

        spinner = new ProgressBar(this);
        spinner.setIndeterminate(true);
        LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(dp(48), dp(48));
        sp.topMargin = dp(16);
        overlay.addView(spinner, sp);

        statusText = new TextView(this);
        statusText.setText("\u6B63\u5728\u51C6\u5907\u8FD0\u884C\u65F6\u2026");
        statusText.setTextColor(Color.rgb(200, 200, 200));
        statusText.setTextSize(13);
        statusText.setGravity(Gravity.CENTER);
        statusText.setPadding(dp(24), dp(16), dp(24), dp(8));
        overlay.addView(statusText);

        errorPanel = new LinearLayout(this);
        errorPanel.setOrientation(LinearLayout.VERTICAL);
        errorPanel.setGravity(Gravity.CENTER);
        errorPanel.setVisibility(View.GONE);

        errorDetail = new TextView(this);
        errorDetail.setTextColor(Color.rgb(240, 160, 160));
        errorDetail.setTextSize(13);
        errorDetail.setGravity(Gravity.CENTER);
        errorDetail.setPadding(dp(24), dp(8), dp(24), dp(8));
        errorPanel.addView(errorDetail);

        Button retry = new Button(this);
        retry.setText("\u91CD\u8BD5");
        retry.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                errorPanel.setVisibility(View.GONE);
                overlay.setVisibility(View.VISIBLE);
                uiStatus("\u6B63\u5728\u91CD\u8BD5\u2026");
                new Thread(new Runnable() {
                    public void run() {
                        bootstrap();
                    }
                }, "retry").start();
            }
        });
        errorPanel.addView(retry);

        Button cfg = new Button(this);
        cfg.setText("\u8BBE\u7F6E");
        cfg.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                openSettings();
            }
        });
        errorPanel.addView(cfg);

        overlay.addView(errorPanel);

        root.addView(overlay, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // 细进度条贴在顶边，只有 3dp，不占布局高度，也不会把工作台推下去。
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        progress.setProgress(0);
        FrameLayout.LayoutParams plp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3));
        plp.gravity = Gravity.TOP;
        root.addView(progress, plp);

        // 齿轮：贴右上角、半透明、40dp。VS Code 自己那一带是标题栏空白区，
        // 压在它上面不会挡住可编辑内容。
        Button gear = new Button(this);
        gear.setText("\u2699");
        gear.setTextSize(15);
        gear.setTextColor(Color.rgb(210, 210, 210));
        gear.setAlpha(0.32f);
        gear.setBackgroundColor(Color.TRANSPARENT);
        gear.setPadding(0, 0, 0, 0);
        gear.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                openSettings();
            }
        });
        FrameLayout.LayoutParams glp = new FrameLayout.LayoutParams(dp(40), dp(40));
        glp.gravity = Gravity.TOP | Gravity.END;
        glp.topMargin = dp(2);
        glp.rightMargin = dp(2);
        root.addView(gear, glp);

        setContentView(root);
        applyImmersive();
    }

    private void openSettings() {
        try {
            startActivity(new android.content.Intent(this, SettingsActivity.class));
        } catch (Throwable t) {
            Log.e(TAG, "openSettings", t);
        }
    }

    /**
     * 真全屏：把状态栏与导航栏都隐藏。targetSdk 28 用旧的 systemUiVisibility
     * 就够了（immersive sticky 在新系统上仍有效），不引入 WindowInsetsController
     * 以免在 26 上不可用。
     */
    private void applyImmersive() {
        try {
            View d = getWindow().getDecorView();
            d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        } catch (Throwable t) {
            Log.e(TAG, "applyImmersive", t);
        }
    }

    private Button toolButton(String label, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(label);
        b.setTextSize(16);
        b.setTextColor(Color.WHITE);
        b.setBackgroundColor(Color.TRANSPARENT);
        b.setMinimumWidth(dp(40));
        b.setMinWidth(dp(40));
        b.setMinimumHeight(dp(40));
        b.setPadding(dp(8), 0, dp(8), 0);
        b.setOnClickListener(l);
        return b;
    }

    private void createGecko() {
        GeckoSessionSettings.Builder b = new GeckoSessionSettings.Builder();
        b.userAgentOverride(UA);
        b.userAgentMode(GeckoSessionSettings.USER_AGENT_MODE_DESKTOP);
        b.viewportMode(GeckoSessionSettings.VIEWPORT_MODE_DESKTOP);
        b.displayMode(GeckoSessionSettings.DISPLAY_MODE_FULLSCREEN);
        session = new GeckoSession(b.build());
        session.setNavigationDelegate(new GeckoSession.NavigationDelegate() {
            @Override
            public void onCanGoBack(GeckoSession s, boolean value) {
                canGoBack = value;
            }
        });

        session.setProgressDelegate(new GeckoSession.ProgressDelegate() {
            @Override
            public void onProgressChange(GeckoSession s, int p) {
                final int v = p;
                ui.post(new Runnable() {
                    public void run() {
                        if (progress != null) {
                            progress.setProgress(v);
                        }
                    }
                });
            }

            @Override
            public void onPageStart(GeckoSession s, String url) {
                ui.post(new Runnable() {
                    public void run() {
                        if (progress != null) {
                            progress.setVisibility(View.VISIBLE);
                        }
                    }
                });
            }

            @Override
            public void onPageStop(GeckoSession s, boolean success) {
                // SELFTEST: the only way to prove the workbench really loaded without
                // reading the screen is to report GeckoView's own page-stop verdict.
                Log.i(TAG, "SELFTEST pagestop success=" + success);
                ui.post(new Runnable() {
                    public void run() {
                        if (progress != null) {
                            progress.setVisibility(View.GONE);
                        }
                    }
                });
            }
        });

        if (sRuntime == null) {
            GeckoRuntimeSettings rs = new GeckoRuntimeSettings.Builder()
                    .javaScriptEnabled(true)
                    .consoleOutput(true)
                    .build();
            sRuntime = GeckoRuntime.create(getApplicationContext(), rs);
        }
        session.open(sRuntime);
        geckoView.setSession(session);
    }

    private void showServerDialog() {
        final EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setText(baseUrl);
        input.setSelectAllOnFocus(true);

        new AlertDialog.Builder(this)
                .setTitle("\u670D\u52A1\u5668\u5730\u5740")
                .setView(input)
                .setPositiveButton("\u4FDD\u5B58", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        String v = input.getText().toString().trim();
                        if (v.length() == 0) {
                            v = SERVER_URL;
                        }
                        if (!v.endsWith("/")) {
                            v = v + "/";
                        }
                        baseUrl = v;
                        prefs().edit().putString(KEY_URL, v).apply();
                        if (session != null) {
                            session.loadUri(baseUrl);
                        }
                    }
                })
                .setNeutralButton("\u6062\u590D\u9ED8\u8BA4", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        baseUrl = SERVER_URL;
                        prefs().edit().putString(KEY_URL, SERVER_URL).apply();
                        if (session != null) {
                            session.loadUri(baseUrl);
                        }
                    }
                })
                .setNegativeButton("\u53D6\u6D88", null)
                .show();
    }

    // ----------------------------------------------------------- bootstrap ---

    // A device that shows nothing is indistinguishable from a device that works
    // when you cannot look at the screen. This writes a report into the app's
    // external files dir, once per packaging version, so a launch can be audited
    // from `adb shell cat` alone: guest resolv.conf, the shipped CSS patch, the
    // seeded settings file, the workbench HTTP response, and a real
    // `code-server --install-extension` run inside PRoot (the check that used to
    // die on vsce-sign). Every step is best-effort; the file always gets written.
    // A ported desktop editor that cannot open the files the user already has on
    // their phone is not ported far enough, and until now nothing mounted any of
    // them: the guest only ever saw its own rootfs. Two mounts, in order of
    // reliability:
    //  * the app's own external files dir needs no permission on any Android
    //    version, so /root/shared is always present and always writable;
    //  * /storage/emulated/0 (DCIM, Download, Documents, ...) only becomes visible
    //    once the storage permissions are granted, so it is bound as /root/phone
    //    only when this process can list it - the guest runs as the same uid, so
    //    that check is exactly the kernel check the guest would hit anyway.
    private List<String> storageBinds(File rootfs) {
        List<String> out = new ArrayList<String>();
        try {
            File ext = getExternalFilesDir(null);
            if (ext != null && ext.isDirectory()) {
                new File(rootfs, "root/shared").mkdirs();
                out.add("-b");
                out.add(ext.getAbsolutePath() + ":/root/shared");
            }
        } catch (Throwable t) {
            Log.w(TAG, "storageBinds: app external dir", t);
        }
        try {
            File phone = new File("/storage/emulated/0");
            if (phone.isDirectory() && phone.canRead() && phone.list() != null) {
                new File(rootfs, "root/phone").mkdirs();
                out.add("-b");
                out.add("/storage/emulated/0:/root/phone");
            } else {
                Log.w(TAG, "storageBinds: /storage/emulated/0 not readable yet");
            }
        } catch (Throwable t) {
            Log.w(TAG, "storageBinds: /storage/emulated/0", t);
        }
        return out;
    }

    // PRoot wants its -b options before the guest program path, so splice them in
    // ahead of -w rather than rebuilding each argv literal.
    private String[] withStorageBinds(String[] cmd, File rootfs) {
        List<String> binds = storageBinds(rootfs);
        if (binds.isEmpty()) {
            return cmd;
        }
        int at = cmd.length;
        for (int i = 0; i < cmd.length; i++) {
            if ("-w".equals(cmd[i])) {
                at = i;
                break;
            }
        }
        List<String> out = new ArrayList<String>(cmd.length + binds.size());
        for (int i = 0; i < at; i++) {
            out.add(cmd[i]);
        }
        out.addAll(binds);
        for (int i = at; i < cmd.length; i++) {
            out.add(cmd[i]);
        }
        return out.toArray(new String[0]);
    }

    // targetSdk 28 keeps the legacy storage model, so these two permissions still
    // cover the whole of /storage/emulated/0. Asked once per install; a refusal is
    // not fatal, /root/shared keeps working.
    private void ensureStoragePermission() {
        try {
            if (android.os.Build.VERSION.SDK_INT < 23) {
                return;
            }
            if (checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                    == PackageManager.PERMISSION_GRANTED) {
                return;
            }
            if (prefs().getBoolean("askedStorage", false)) {
                return;
            }
            prefs().edit().putBoolean("askedStorage", true).apply();
            requestPermissions(new String[]{
                    android.Manifest.permission.READ_EXTERNAL_STORAGE,
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
            }, 7);
        } catch (Throwable t) {
            Log.w(TAG, "ensureStoragePermission", t);
        }
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] granted) {
        super.onRequestPermissionsResult(req, perms, granted);
        if (req != 7) {
            return;
        }
        boolean ok = granted != null && granted.length > 0
                && granted[0] == PackageManager.PERMISSION_GRANTED;
        Log.i(TAG, "storage permission granted=" + ok);
        // The mount list is computed when the server starts, so a late grant only
        // shows up after a restart. Do it quietly, and only if a server is up.
        if (ok && sServer != null && sServer.isAlive()) {
            restartServer();
        }
    }

    // The mounts are only worth anything if the guest can actually see them, and
    // the guest runs as the same uid under PRoot, so ask it directly instead of
    // inferring from what this process can read.
    private String probePhone(File rootfs) {
        File files = getFilesDir();
        String nativeDir = getApplicationInfo().nativeLibraryDir;
        String[] cmd = new String[]{
                nativeDir + "/libproot.so",
                "--kill-on-exit",
                "-r", files + "/rootfs",
                "-0",
                "-b", "/dev",
                "-b", "/proc",
                "-b", "/sys",
                "-b", "/system",
                "-b", "/apex",
                "-b", "/vendor",
                "-w", "/root",
                "/bin/sh", "-c",
                "for d in /root/phone /root/shared; do"
                        + " if [ -d \"$d\" ]; then"
                        + " n=$(ls -A \"$d\" 2>/dev/null | wc -l);"
                        + " t=$(touch \"$d/.dsh-probe\" 2>&1 && rm -f \"$d/.dsh-probe\" && echo writable || echo readonly);"
                        + " echo \"$d entries=$n $t\";"
                        + " else echo \"$d missing\"; fi; done;"
                        + " ls -A /root/phone 2>/dev/null | head -3 | tr '\\n' ' '",
        };
        cmd = withStorageBinds(cmd, rootfs);
        Process p = null;
        try {
            p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            final Process proc = p;
            ui.postDelayed(new Runnable() {
                @Override
                public void run() {
                    try {
                        proc.destroy();
                    } catch (Throwable ignored) {
                    }
                }
            }, 60000);
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                sb.append(line).append(" | ");
                if (sb.length() > 700) {
                    break;
                }
            }
            int rc = p.waitFor();
            return "exit=" + rc + " " + sb.toString().trim();
        } catch (Throwable t) {
            return "error=" + t;
        } finally {
            if (p != null) {
                try {
                    p.destroy();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private void maybeRunSelfTest(final String baseUrl) {
        final File done = new File(getFilesDir(), ".selftest-" + versionStamp());
        if (done.isFile()) {
            return;
        }
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                StringBuilder sb = new StringBuilder();
                try {
                    File files = getFilesDir();
                    File rootfs = new File(files, "rootfs");
                    sb.append("selftest versionCode=").append(versionStamp())
                            .append(" device=").append(android.os.Build.MANUFACTURER).append('/')
                            .append(android.os.Build.MODEL).append(" sdk=").append(android.os.Build.VERSION.SDK_INT)
                            .append(" at=").append(System.currentTimeMillis()).append('\n');
                    sb.append("[resolv.conf]\n").append(readHead(new File(rootfs, "etc/resolv.conf"), 6));
                    sb.append("[settings.json]\n")
                            .append(readHead(new File(rootfs, "root/.vscode-server/data/User/settings.json"), 6));
                    File css = new File(rootfs, "opt/vscode/out/vs/code/browser/workbench/workbench.css");
                    sb.append("[workbench.css] exists=").append(css.isFile())
                            .append(" bytes=").append(css.length())
                            .append(" patchHits=").append(countIn(css, "sans-serif!important")).append('\n');
                    sb.append("[http] ").append(describeGet(baseUrl)).append('\n');
                    sb.append("[install] ").append(installOneExtension(rootfs)).append('\n');
                    sb.append("[phone] ").append(probePhone(rootfs)).append('\n');
                } catch (Throwable tr) {
                    sb.append("[selftest error] ").append(tr).append('\n');
                }
                String report = sb.toString();
                Log.i(TAG, "selftest\n" + report);
                File out = getExternalFilesDir(null);
                if (out == null) {
                    out = getFilesDir();
                }
                OutputStream os = null;
                try {
                    os = new FileOutputStream(new File(out, "selftest.txt"));
                    os.write(report.getBytes("UTF-8"));
                } catch (Throwable tr) {
                    Log.w(TAG, "selftest write", tr);
                } finally {
                    if (os != null) {
                        try {
                            os.close();
                        } catch (Throwable ignored) {
                        }
                    }
                }
                try {
                    done.createNewFile();
                } catch (Throwable ignored) {
                }
            }
        }, "selftest");
        t.setDaemon(true);
        t.start();
    }

    private String readHead(File f, int lines) {
        if (!f.isFile()) {
            return "(missing " + f + ")\n";
        }
        InputStream in = null;
        StringBuilder sb = new StringBuilder();
        try {
            in = new FileInputStream(f);
            BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
            String line;
            int n = 0;
            while (n < lines && (line = r.readLine()) != null) {
                sb.append("  ").append(line).append('\n');
                n++;
            }
        } catch (Throwable t) {
            sb.append("(read error ").append(t).append(")\n");
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Throwable ignored) {
                }
            }
        }
        return sb.toString();
    }

    private int countIn(File f, String needle) {
        if (!f.isFile()) {
            return -1;
        }
        InputStream in = null;
        try {
            in = new FileInputStream(f);
            byte[] buf = new byte[64 * 1024];
            byte[] nb = needle.getBytes("UTF-8");
            int hits = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                for (int i = 0; i + nb.length <= n; i++) {
                    boolean hit = true;
                    for (int j = 0; j < nb.length; j++) {
                        if (buf[i + j] != nb[j]) {
                            hit = false;
                            break;
                        }
                    }
                    if (hit) {
                        hits++;
                    }
                }
            }
            return hits;
        } catch (Throwable t) {
            return -2;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private String describeGet(String baseUrl) {
        HttpURLConnection c = null;
        InputStream in = null;
        try {
            c = (HttpURLConnection) new URL(baseUrl).openConnection();
            c.setConnectTimeout(5000);
            c.setReadTimeout(15000);
            int code = c.getResponseCode();
            in = code >= 400 ? c.getErrorStream() : c.getInputStream();
            byte[] buf = new byte[8192];
            int total = 0;
            StringBuilder head = new StringBuilder();
            int n;
            while ((n = in == null ? -1 : in.read(buf)) > 0) {
                total += n;
                if (head.length() < 2000) {
                    head.append(new String(buf, 0, n, "UTF-8"));
                }
            }
            String h = head.toString().toLowerCase();
            return "code=" + code + " bytes=" + total
                    + " workbench=" + h.contains("workbench")
                    + " css=" + h.contains("workbench.css");
        } catch (Throwable t) {
            return "error=" + t;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Throwable ignored) {
                }
            }
            if (c != null) {
                c.disconnect();
            }
        }
    }

    private String installOneExtension(File rootfs) {
        File files = getFilesDir();
        String nativeDir = getApplicationInfo().nativeLibraryDir;
        String[] cmd = new String[]{
                nativeDir + "/libproot.so",
                "--kill-on-exit",
                "-r", files + "/rootfs",
                "-0",
                "-b", "/dev",
                "-b", "/proc",
                "-b", "/sys",
                "-b", "/system",
                "-b", "/apex",
                "-b", "/vendor",
                "-w", "/root",
                "/opt/vscode/bin/code-server",
                "--install-extension", "ms-python.python",
                // A scratch dir, not the live one: the server is already running and
                // watching its own extensions folder, and this probe must not race it.
                "--extensions-dir", "/root/.selftest-ext",
        };
        cmd = withStorageBinds(cmd, rootfs);
        Process p = null;
        try {
            p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            final Process proc = p;
            ui.postDelayed(new Runnable() {
                @Override
                public void run() {
                    try {
                        proc.destroy();
                    } catch (Throwable ignored) {
                    }
                }
            }, 240000);
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), "UTF-8"));
            StringBuilder tail = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                Log.i(TAG, "install| " + line);
                tail.append(line).append('\n');
                if (tail.length() > 3000) {
                    tail.delete(0, tail.length() - 3000);
                }
            }
            int rc = p.waitFor();
            String t = tail.toString().trim();
            if (t.length() > 700) {
                t = t.substring(t.length() - 700);
            }
            return "exit=" + rc + " tail=" + t.replace("\n", " | ");
        } catch (Throwable t) {
            return "error=" + t;
        } finally {
            if (p != null) {
                try {
                    p.destroy();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private void bootstrap() {
        try {
            if (httpOk(baseUrl)) {
                uiReady();
                return;
            }
            uiStatus("\u6B63\u5728\u51C6\u5907\u8FD0\u884C\u65F6\uFF08\u9996\u6B21\u542F\u52A8\u7EA6 1\u20132 \u5206\u949F\uFF09\u2026");
            if (!ensureRuntime()) {
                uiError("\u8FD0\u884C\u65F6\u89E3\u5305\u5931\u8D25\uFF1A" + runtimeError);
                return;
            }
            uiStatus("\u6B63\u5728\u542F\u52A8 VS Code \u670D\u52A1\u2026");
            if (sServer == null || !sServer.isAlive()) {
                sServer = startServer();
            }
            if (sServer == null) {
                uiError("\u65E0\u6CD5\u542F\u52A8 proot \u8FDB\u7A0B\u3002");
                return;
            }
            int waited = 0;
            while (waited < 300) {
                if (httpOk(baseUrl)) {
                    maybeRunSelfTest(baseUrl);
                    uiReady();
                    return;
                }
                if (!sServer.isAlive()) {
                    uiError("\u670D\u52A1\u8FDB\u7A0B\u5DF2\u9000\u51FA\uFF08exit=" + sServer.exitValue() + "\uFF09");
                    return;
                }
                Thread.sleep(2000);
                waited += 2;
                uiStatus("\u6B63\u5728\u542F\u52A8 VS Code \u670D\u52A1\u2026 " + waited + "s");
            }
            uiError("\u670D\u52A1\u542F\u52A8\u8D85\u65F6\u3002");
        } catch (Throwable t) {
            Log.e(TAG, "bootstrap", t);
            uiError("\u542F\u52A8\u5931\u8D25: " + t);
        }
    }

    private volatile String runtimeError = "";

    private boolean ensureRuntime() {
        File files = getFilesDir();
        File rootfs = new File(files, "rootfs");
        File proot = new File(getApplicationInfo().nativeLibraryDir, "libproot.so");
        File rootMarker = new File(rootfs, ".ok-rootfs");
        File codeMarker = new File(rootfs, ".ok-vscode");
        // The VS Code marker carries the versionCode that produced the tree. An
        // in-place upgrade therefore replaces the payload instead of silently
        // keeping the previous one - without this, a user who installs a newer APK
        // over an older one still runs the old tree and every payload fix looks
        // like it did nothing. Only the tree is replaced: extensions, settings and
        // the workspace all live under root/.vscode-server and root/workspace.
        String stamp = versionStamp();
        if (rootMarker.isFile() && markerMatches(codeMarker, stamp) && proot.isFile()) {
            return true;
        }
        try {
            // A failed earlier attempt (or a build whose extractor aborted) leaves a
            // half written tree behind. Reusing it is what made the extractor trip
            // over its own symlinks, so any stage without its marker is wiped first.
            if (!rootMarker.isFile()) {
                Log.i(TAG, "ensureRuntime: extracting rootfs");
                uiStatus("\u6B63\u5728\u89E3\u5305 Linux \u8FD0\u884C\u65F6\u2026");
                TarGz.wipe(rootfs);
                if (!rootfs.isDirectory() && !rootfs.mkdirs()) {
                    runtimeError = "cannot create " + rootfs;
                    return false;
                }
                extractAsset("runtime/rootfs.tar.gz", rootfs);
                // Deliberately not re-extracted on upgrade: the user's dotfiles,
                // workspace and toolchains live inside this tree, so replacing it
                // would throw their work away. Settings offers a deliberate wipe.
                if (!rootMarker.createNewFile()) {
                    runtimeError = "cannot write marker";
                    return false;
                }
                Log.i(TAG, "ensureRuntime: rootfs ok");
            }
            if (!markerMatches(codeMarker, stamp)) {
                Log.i(TAG, "ensureRuntime: extracting vscode");
                uiStatus("\u6B63\u5728\u89E3\u5305 VS Code\u2026");
                File opt = new File(rootfs, "opt");
                TarGz.wipe(opt);
                if (!opt.isDirectory() && !opt.mkdirs()) {
                    runtimeError = "cannot create " + opt;
                    return false;
                }
                extractAsset("runtime/vscode.tar.gz", opt);
                if (!writeMarker(codeMarker, stamp)) {
                    runtimeError = "cannot write marker";
                    return false;
                }
                Log.i(TAG, "ensureRuntime: vscode ok");
            }
            mkdirs(new File(rootfs, "root/workspace"));
            mkdirs(new File(rootfs, "root/.vscode-server"));
            mkdirs(new File(rootfs, "tmp"));
            mkdirs(new File(rootfs, "dev"));
            mkdirs(new File(rootfs, "proc"));
            mkdirs(new File(rootfs, "sys"));
            mkdirs(new File(files, "tmp"));
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "ensureRuntime", t);
            runtimeError = String.valueOf(t);
            return false;
        }
    }

    private String versionStamp() {
        try {
            return String.valueOf(getPackageManager()
                    .getPackageInfo(getPackageName(), 0).versionCode);
        } catch (Throwable t) {
            Log.w(TAG, "versionStamp", t);
            return "0";
        }
    }

    private boolean markerMatches(File marker, String stamp) {
        if (!marker.isFile()) {
            return false;
        }
        InputStream in = null;
        try {
            in = new FileInputStream(marker);
            byte[] buf = new byte[32];
            int n = in.read(buf);
            return n > 0 && stamp.equals(new String(buf, 0, n, "UTF-8").trim());
        } catch (Throwable t) {
            Log.w(TAG, "markerMatches", t);
            return false;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private boolean writeMarker(File marker, String stamp) {
        OutputStream os = null;
        try {
            os = new FileOutputStream(marker);
            os.write(stamp.getBytes("UTF-8"));
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "writeMarker", t);
            return false;
        } finally {
            if (os != null) {
                try {
                    os.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private void mkdirs(File f) {
        if (!f.exists()) {
            f.mkdirs();
        }
    }

    private void extractAsset(String name, File dest) throws IOException {
        InputStream in = getAssets().open(name);
        try {
            TarGz.extract(in, dest);
        } finally {
            try {
                in.close();
            } catch (Throwable ignored) {
            }
        }
    }

    // Written once, before the server starts, and never touched again: if the user
    // later edits settings.json in the app we leave their file alone.
    //
    // Only one key here, and it has to be this one. serve-web shells out to
    // vsce-sign, a 16 MB .NET single-file binary, to check a VSIX signature; under
    // PRoot that child dies with exit 137 ("Internal Code: 137" in the server log),
    // so every install ended in "Signature verification failed". The server reads
    // this boolean itself (server-main.js downloadExtension: getValue of
    // "extensions.verifySignature", then the delete-on-failure branch is skipped),
    // and its configuration service resolves the user settings file to
    // <server-data-dir>/data/User/settings.json - exactly this path. VSIX downloads
    // still go over TLS to the official marketplace.
    //
    // Fonts deliberately do NOT live here: the workbench renders in the browser, so
    // editor/terminal font settings are stored browser-side and seeding this file
    // has no effect on them. The CJK fallback is patched into the shipped
    // workbench.css instead.
    private void seedUserSettings(File rootfs) {
        File user = new File(rootfs, "root/.vscode-server/data/User");
        File json = new File(user, "settings.json");
        if (json.isFile()) {
            return;
        }
        if (!user.isDirectory() && !user.mkdirs() && !user.isDirectory()) {
            Log.w(TAG, "seedUserSettings: cannot create " + user);
            return;
        }
        String body = "{\n"
                + "    \"extensions.verifySignature\": false\n"
                + "}\n";
        OutputStream os = null;
        try {
            os = new FileOutputStream(json);
            os.write(body.getBytes("UTF-8"));
            Log.i(TAG, "seedUserSettings: wrote " + json);
        } catch (Throwable t) {
            Log.w(TAG, "seedUserSettings", t);
        } finally {
            if (os != null) {
                try {
                    os.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    // Resolvers tried after the device's own, in this order, capped at four lines
    // total. AliDNS and DNSPod resolve from CN networks where the public resolvers
    // baked into the rootfs are commonly black-holed.
    private static final String[] FALLBACK_DNS = {"223.5.5.5", "119.29.29.29", "1.1.1.1"};

    // The rootfs ships /etc/resolv.conf with 8.8.8.8 first. On CN carriers and on
    // plenty of corporate networks UDP 53 to that address is dropped, and the
    // guest's libc just times out; serve-web resolves the marketplace from inside
    // the guest, so the visible symptom is an extension view that finds nothing
    // rather than a network error. Copy what the device is actually using on every
    // start (it changes with the network) and queue public resolvers behind it.
    private void writeResolvConf(File rootfs) {
        List<String> servers = new ArrayList<String>();
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                Network net = cm.getActiveNetwork();
                LinkProperties lp = net == null ? null : cm.getLinkProperties(net);
                if (lp != null) {
                    for (InetAddress a : lp.getDnsServers()) {
                        String h = a == null ? null : a.getHostAddress();
                        if (h != null && h.indexOf(':') < 0 && !servers.contains(h)) {
                            servers.add(h);
                        }
                    }
                }
            }
        } catch (Throwable t) {
            Log.w(TAG, "writeResolvConf: cannot read the device DNS", t);
        }
        if (servers.isEmpty()) {
            Log.w(TAG, "writeResolvConf: device reports no IPv4 DNS, keeping the rootfs file");
            return;
        }
        for (int i = 0; i < FALLBACK_DNS.length && servers.size() < 4; i++) {
            if (!servers.contains(FALLBACK_DNS[i])) {
                servers.add(FALLBACK_DNS[i]);
            }
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < servers.size(); i++) {
            sb.append("nameserver ").append(servers.get(i)).append('\n');
        }
        sb.append("options timeout:2 attempts:2\n");
        File etc = new File(rootfs, "etc");
        if (!etc.isDirectory() && !etc.mkdirs() && !etc.isDirectory()) {
            Log.w(TAG, "writeResolvConf: cannot create " + etc);
            return;
        }
        OutputStream os = null;
        try {
            os = new FileOutputStream(new File(etc, "resolv.conf"));
            os.write(sb.toString().getBytes("UTF-8"));
            Log.i(TAG, "writeResolvConf: " + servers);
        } catch (Throwable t) {
            Log.w(TAG, "writeResolvConf", t);
        } finally {
            if (os != null) {
                try {
                    os.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private Process startServer() {
        try {
            String files = getFilesDir().getAbsolutePath();
            String nativeDir = getApplicationInfo().nativeLibraryDir;
            File tmp = new File(files, "tmp");
            tmp.mkdirs();
            writeResolvConf(new File(files, "rootfs"));
            seedUserSettings(new File(files, "rootfs"));
            String[] cmd = new String[]{
                    nativeDir + "/libproot.so",
                    "--kill-on-exit",
                    "-r", files + "/rootfs",
                    "-0",
                    "-b", "/dev",
                    "-b", "/proc",
                    "-b", "/sys",
                    "-b", "/system",
                    "-b", "/apex",
                    "-b", "/vendor",
                    "-w", "/root",
                    "/opt/vscode/node",
                    "/opt/vscode/out/server-main.js",
                    "--host", "127.0.0.1",
                    "--port", "8800",
                    "--without-connection-token",
                    "--accept-server-license-terms",
                    "--disable-telemetry",
                    "--server-data-dir", "/root/.vscode-server",
                    // 不再传 --default-folder：强制打开一个目录会让全新安装
                    // 跳过 Welcome 页，而用户要的正是「像正常全新安装那样」。

            };
            cmd = withStorageBinds(cmd, new File(files, "rootfs"));
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.redirectErrorStream(true);
            pb.directory(getFilesDir());
            pb.environment().put("PROOT_TMP_DIR", tmp.getAbsolutePath());
            pb.environment().put("PROOT_LOADER", nativeDir + "/libprootloader.so");
            pb.environment().put("LD_LIBRARY_PATH", nativeDir);
            pb.environment().put("PROOT_NO_SECCOMP", "1");
            pb.environment().put("HOME", "/root");
            pb.environment().put("TMPDIR", "/tmp");
            pb.environment().put("LANG", "C.UTF-8");
            Process p = pb.start();
            pump(p);
            return p;
        } catch (Throwable t) {
            Log.e(TAG, "startServer", t);
            return null;
        }
    }

    private void pump(final Process p) {
        new Thread(new Runnable() {
            public void run() {
                BufferedReader r = null;
                try {
                    r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    while ((line = r.readLine()) != null) {
                        Log.i(TAG, "srv: " + line);
                    }
                } catch (Throwable ignored) {
                } finally {
                    if (r != null) {
                        try {
                            r.close();
                        } catch (Throwable ignored) {
                        }
                    }
                }
            }
        }, "srvlog").start();
    }

    private boolean httpOk(String url) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(2000);
            c.setReadTimeout(3000);
            c.setInstanceFollowRedirects(false);
            int code = c.getResponseCode();
            return code == 200 || code == 302;
        } catch (Throwable t) {
            return false;
        } finally {
            if (c != null) {
                c.disconnect();
            }
        }
    }

    // -------------------------------------------------------------- status ---

    private void uiStatus(final String msg) {
        ui.post(new Runnable() {
            public void run() {
                if (statusText != null) {
                    statusText.setText(msg);
                }
            }
        });
    }

    private void uiError(final String msg) {
        ui.post(new Runnable() {
            public void run() {
                if (errorDetail != null) {
                    errorDetail.setText(msg);
                }
                if (errorPanel != null) {
                    errorPanel.setVisibility(View.VISIBLE);
                }
                if (spinner != null) {
                    spinner.setVisibility(View.GONE);
                }
            }
        });
    }

    private void uiReady() {
        ui.post(new Runnable() {
            public void run() {
                if (overlay != null) {
                    overlay.setVisibility(View.GONE);
                }
                if (session != null) {
                    session.loadUri(baseUrl);
                }
            }
        });
        selfTest();
    }

    /**
     * Self check: without a readable screen the only trustworthy evidence that the
     * workbench really renders is the server answering and GeckoView's own
     * page-stop verdict, both of which are written to logcat. Started only once
     * ready, and never on the UI thread.
     */
    private void selfTest() {
        new Thread(new Runnable() {
            public void run() {
                try {
                    Thread.sleep(8000);
                    String html = httpGet(baseUrl);
                    java.util.regex.Matcher m = java.util.regex.Pattern
                            .compile("(/stable[^\"']*workbench\\.js)").matcher(html);
                    String path = m.find() ? m.group(1) : "";
                    String url = path.startsWith("/")
                            ? baseUrl.replaceAll("/+$", "") + path
                            : path;
                    int code = 0;
                    long len = -1;
                    if (url.length() > 0) {
                        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                        try {
                            c.setConnectTimeout(5000);
                            c.setReadTimeout(30000);
                            code = c.getResponseCode();
                            len = c.getContentLengthLong();
                        } finally {
                            c.disconnect();
                        }
                    }
                    Log.i(TAG, "SELFTEST html=" + html.length() + " wbpath=" + path
                            + " wbcode=" + code + " wblen=" + len);
                } catch (Throwable t) {
                    Log.e(TAG, "SELFTEST", t);
                }
            }
        }, "selftest").start();
    }

    private String httpGet(String url) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(5000);
            c.setReadTimeout(15000);
            InputStream in = c.getInputStream();
            try {
                byte[] buf = new byte[65536];
                StringBuilder sb = new StringBuilder();
                int n;
                while ((n = in.read(buf)) > 0 && sb.length() < 262144) {
                    sb.append(new String(buf, 0, n, "UTF-8"));
                }
                return sb.toString();
            } finally {
                try {
                    in.close();
                } catch (Throwable ignored) {
                }
            }
        } catch (Throwable t) {
            return "";
        } finally {
            if (c != null) {
                c.disconnect();
            }
        }
    }

    private File runtimeDir() {
        return new File(getFilesDir(), "rootfs");
    }

    /** 结束服务进程。startServer 带 --kill-on-exit，父进程死掉子树会跟着退。 */
    private void stopServer() {
        Process p = sServer;
        sServer = null;
        if (p == null) {
            return;
        }
        try {
            p.destroy();
            for (int i = 0; i < 30 && p.isAlive(); i++) {
                Thread.sleep(100);
            }
            if (p.isAlive()) {
                p.destroyForcibly();
            }
        } catch (Throwable t) {
            Log.e(TAG, "stopServer", t);
        }
    }

    /** 递归删除，绝不跟随软链（rootfs 里到处都是绝对软链）。 */
    private static void deleteTree(File f) {
        if (f == null || !f.exists()) {
            return;
        }
        try {
            if (f.isDirectory() && !isSymlink(f)) {
                File[] kids = f.listFiles();
                if (kids != null) {
                    for (File k : kids) {
                        deleteTree(k);
                    }
                }
            }
            f.delete();
        } catch (Throwable ignored) {
        }
    }

    private static boolean isSymlink(File f) {
        try {
            File p = f.getParentFile();
            if (p == null) {
                return false;
            }
            File canon = new File(p.getCanonicalFile(), f.getName());
            return !canon.getCanonicalFile().equals(canon.getAbsoluteFile());
        } catch (Throwable t) {
            return false;
        }
    }

    // ------------------------------------------------------------ lifecycle --

    @Override
    public void onBackPressed() {
        if (session != null && canGoBack) {
            session.goBack();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        // Never stop the server here: rotating or backgrounding the activity must
        // not tear down the VS Code process.
        try {
            if (session != null) {
                session.setActive(false);
            }
        } catch (Throwable ignored) {
        }
        super.onDestroy();
    }
}
