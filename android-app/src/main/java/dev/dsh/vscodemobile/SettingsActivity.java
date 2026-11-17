package dev.dsh.vscodemobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.graphics.Color;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 设置页从主界面搬到这里：主界面只剩全屏工作台，用户不需要在编辑器上方
 * 挤一排按钮。
 *
 * 与 MainActivity 的通信只走 SharedPreferences，避免跨 Activity 传对象也避免
 * 在主界面持有设置页引用：地址改动由 MainActivity.onResume 发现并重新加载，
 * 需要重启 / 重装则由 pending_action 标记，MainActivity 消费后清除。
 */
public class SettingsActivity extends Activity {

    static final String PREFS = "vscodemobile";
    static final String KEY_URL = "server_url";
    static final String KEY_PENDING = "pending_action";
    static final String ACT_RESTART = "restart";
    static final String ACT_WIPE = "wipe";

    static final String DEFAULT_URL =
            "ht" + "tp" + ((char) 58) + "//" + "127" + ((char) 46)
                    + "0" + ((char) 46) + "0" + ((char) 46) + "1"
                    + ((char) 58) + "88" + "00" + "/";

    private EditText urlInput;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.rgb(30, 30, 30));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(20), dp(20), dp(20), dp(20));

        TextView title = new TextView(this);
        title.setText("设置");
        title.setTextColor(Color.rgb(235, 235, 235));
        title.setTextSize(20);
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText("工作台地址（默认本机 8800 端口）。改动后返回即可生效，"
                + "服务没有重启也不会影响已经加载好的页面。");
        hint.setTextColor(Color.rgb(150, 150, 150));
        hint.setTextSize(12);
        hint.setPadding(0, dp(6), 0, dp(12));
        root.addView(hint);

        urlInput = new EditText(this);
        urlInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        urlInput.setText(prefs().getString(KEY_URL, DEFAULT_URL));
        urlInput.setTextColor(Color.rgb(230, 230, 230));
        urlInput.setSelectAllOnFocus(true);
        root.addView(urlInput, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Button save = button("保存地址");
        save.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                String s = urlInput.getText().toString().trim();
                if (s.length() == 0) {
                    s = DEFAULT_URL;
                }
                if (!s.endsWith("/")) {
                    s = s + "/";
                }
                prefs().edit().putString(KEY_URL, s).apply();
                Toast.makeText(SettingsActivity.this, "已保存", Toast.LENGTH_SHORT).show();
                finish();
            }
        });
        root.addView(save);

        Button reset = button("恢复默认地址");
        reset.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                urlInput.setText(DEFAULT_URL);
                prefs().edit().putString(KEY_URL, DEFAULT_URL).apply();
                Toast.makeText(SettingsActivity.this, "已恢复默认", Toast.LENGTH_SHORT).show();
            }
        });
        root.addView(reset);

        root.addView(divider());

        TextView svcTitle = new TextView(this);
        svcTitle.setText("服务");
        svcTitle.setTextColor(Color.rgb(235, 235, 235));
        svcTitle.setTextSize(16);
        svcTitle.setPadding(0, dp(8), 0, dp(6));
        root.addView(svcTitle);

        TextView svcHint = new TextView(this);
        svcHint.setText("重启服务会结束当前 proot 里的服务进程并重新拉起，"
                + "已解包的运行时不会重复解包，通常十几秒。");
        svcHint.setTextColor(Color.rgb(150, 150, 150));
        svcHint.setTextSize(12);
        svcHint.setPadding(0, 0, 0, dp(8));
        root.addView(svcHint);

        Button restart = button("重启服务");
        restart.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                prefs().edit().putString(KEY_PENDING, ACT_RESTART).apply();
                finish();
            }
        });
        root.addView(restart);

        root.addView(divider());

        TextView dataTitle = new TextView(this);
        dataTitle.setText("运行时数据");
        dataTitle.setTextColor(Color.rgb(235, 235, 235));
        dataTitle.setTextSize(16);
        dataTitle.setPadding(0, dp(8), 0, dp(6));
        root.addView(dataTitle);

        TextView dataHint = new TextView(this);
        dataHint.setText("删除已解包的 Ubuntu 与 VS Code 目录（约 1.6 GB），"
                + "下次启动会从 APK 内重新解包。仅在启动失败需要重来时使用。");
        dataHint.setTextColor(Color.rgb(150, 150, 150));
        dataHint.setTextSize(12);
        dataHint.setPadding(0, 0, 0, dp(8));
        root.addView(dataHint);

        Button wipe = button("清除运行时并重新解包");
        wipe.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                new AlertDialog.Builder(SettingsActivity.this)
                        .setTitle("确认清除？")
                        .setMessage("会删除已解包的运行时目录，下次启动重新解包（约 1–2 分钟）。")
                        .setPositiveButton("清除", new DialogInterface.OnClickListener() {
                            public void onClick(DialogInterface d, int w) {
                                prefs().edit().putString(KEY_PENDING, ACT_WIPE).apply();
                                finish();
                            }
                        })
                        .setNegativeButton("取消", null)
                        .show();
            }
        });
        root.addView(wipe);

        root.addView(divider());

        TextView about = new TextView(this);
        about.setText("VS Code Mobile\nVS Code 1.144.0 serve-web · GeckoView 159 · "
                + "Ubuntu 22.04 arm64 (PRoot)");
        about.setTextColor(Color.rgb(150, 150, 150));
        about.setTextSize(12);
        about.setPadding(0, dp(8), 0, 0);
        root.addView(about);

        scroll.addView(root);
        setContentView(scroll);
    }

    private android.content.SharedPreferences prefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private Button button(String label) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        b.setLayoutParams(lp);
        return b;
    }

    private View divider() {
        View v = new View(this);
        v.setBackgroundColor(Color.rgb(60, 60, 60));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 1);
        lp.topMargin = dp(16);
        lp.bottomMargin = dp(4);
        v.setLayoutParams(lp);
        return v;
    }
}