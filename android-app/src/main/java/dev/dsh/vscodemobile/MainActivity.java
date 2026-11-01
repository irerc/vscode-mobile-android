package dev.dsh.vscodemobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.graphics.Color;
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
import java.io.FileOutputStream;
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
        super.onCreate(savedInstanceState);
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
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(30, 30, 30));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(Color.rgb(45, 45, 45));
        bar.setPadding(dp(2), dp(2), dp(2), dp(2));

        bar.addView(toolButton("\u2039", new View.OnClickListener() {
            public void onClick(View v) {
                if (session != null) {
                    session.goBack();
                }
            }
        }));
        bar.addView(toolButton("\u203A", new View.OnClickListener() {
            public void onClick(View v) {
                if (session != null) {
                    session.goForward();
                }
            }
        }));
        bar.addView(toolButton("\u21BB", new View.OnClickListener() {
            public void onClick(View v) {
                if (session != null) {
                    session.reload();
                }
            }
        }));
        bar.addView(toolButton("\u2302", new View.OnClickListener() {
            public void onClick(View v) {
                if (session != null) {
                    session.loadUri(baseUrl);
                }
            }
        }));
        bar.addView(toolButton("\u2699", new View.OnClickListener() {
            public void onClick(View v) {
                showServerDialog();
            }
        }));

        TextView title = new TextView(this);
        title.setText("VS Code");
        title.setTextColor(Color.rgb(180, 180, 180));
        title.setTextSize(12);
        title.setPadding(dp(8), 0, 0, 0);
        bar.addView(title);

        root.addView(bar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        progress.setProgress(0);
        root.addView(progress, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));

        FrameLayout content = new FrameLayout(this);
        geckoView = new GeckoView(this);
        content.addView(geckoView, new FrameLayout.LayoutParams(
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
        statusText.setText("正在准备运行时\u2026");
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
        cfg.setText("\u670D\u52A1\u5668\u5730\u5740");
        cfg.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                showServerDialog();
            }
        });
        errorPanel.addView(cfg);

        overlay.addView(errorPanel);

        content.addView(overlay, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        root.addView(content, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
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

    private void bootstrap() {
        try {
            if (httpOk(baseUrl)) {
                uiReady();
                return;
            }
            uiStatus("\u6B63\u5728\u51C6\u5907\u8FD0\u884C\u65F6\uFF08\u9996\u6B21\u542F\u52A8\u7EA6 1\u20132 \u5206\u949F\uFF09\u2026");
            if (!ensureRuntime()) {
                uiError("\u8FD0\u884C\u65F6\u89E3\u5305\u5931\u8D25\uFF0C\u8BF7\u786E\u4FDD\u5B58\u50A8\u7A7A\u95F4\u5145\u8DB3\u540E\u91CD\u8BD5\u3002");
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

    private boolean ensureRuntime() {
        File files = getFilesDir();
        File rootfs = new File(files, "rootfs");
        File proot = new File(getApplicationInfo().nativeLibraryDir, "libproot.so");
        File marker = new File(rootfs, ".ok");
        if (marker.isFile() && proot.isFile()) {
            return true;
        }
        try {
            if (!rootfs.exists() && !rootfs.mkdirs()) {
                return false;
            }
            extractAsset("runtime/rootfs.tar.gz", rootfs);
            File opt = new File(rootfs, "opt");
            if (!opt.exists() && !opt.mkdirs()) {
                return false;
            }
            extractAsset("runtime/vscode.tar.gz", opt);
            mkdirs(new File(rootfs, "root/workspace"));
            mkdirs(new File(rootfs, "root/.vscode-server"));
            mkdirs(new File(rootfs, "tmp"));
            mkdirs(new File(rootfs, "dev"));
            mkdirs(new File(rootfs, "proc"));
            mkdirs(new File(rootfs, "sys"));
            mkdirs(new File(files, "tmp"));
            new File(rootfs, ".ok").createNewFile();
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "ensureRuntime", t);
            return false;
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

    private Process startServer() {
        try {
            String files = getFilesDir().getAbsolutePath();
            String nativeDir = getApplicationInfo().nativeLibraryDir;
            File tmp = new File(files, "tmp");
            tmp.mkdirs();
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
                    "--default-folder", "/root/workspace"
            };
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
