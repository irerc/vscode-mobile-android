# VS Code Mobile

把完整的桌面版 **VS Code** 装进一个安卓 APK：**即装即用，不依赖手机上的浏览器、不依赖容器、不需要联网**。

[![Release](https://img.shields.io/badge/release-v1.0.14--l-blue)](https://github.com/irerc/vscode-mobile-android/releases/tag/v1.0.14-l)
[![VS Code](https://img.shields.io/badge/VS%20Code-1.144.0-007ACC)](https://code.visualstudio.com/)
[![GeckoView](https://img.shields.io/badge/GeckoView-159-orange)](https://mozilla.github.io/geckoview/)
[![Android](https://img.shields.io/badge/Android-8.0%2B%20(arm64)-green)]()

## 直接下载

**vscode-mobile-1.0.18-l.apk** · 206,064,075 字节（约 197 MB） · MD5 `e89a650d78e91b5faaf243802665d931` · SHA-256 `9ae1d8e99c6d4e67677e863a5c71cd03b149cd8fbd17d729e1073ad6460bb0ff` · versionCode 32 / `1.0.18-l`

发布页：<https://github.com/irerc/vscode-mobile-android/releases/tag/v1.0.18-l>（资产 id 772818136，`vscode-mobile-1.0.18-l.apk`，GitHub 侧回读的 sha256 为 `9ae1d8e9…`，与上表一致；该版本标为 prerelease，因为最后一步「肉眼确认工作台渲染」仍待设备识屏可用时补证）。

本版在上一版基础上再修两处：新增 APK 与解包器的一键复核脚本（`tools/verify_apk.sh`、`tools/test_extract.sh`），并把 `SELFTEST` 日志探针与 `FLAG_KEEP_SCREEN_ON` 打进应用。累计修掉的真机崩溃链共五处，全部有 logcat 或本地复跑证据：dex 缺 Kotlin 运行时、库 `R$*` 常量类缺失、KMP metadata 空包导致 `androidx.collection.SimpleArrayMap` 不在 dex（`GeckoAppShell.<clinit>` 崩溃）、`TarGz` 把绝对软链误判为路径逃逸导致解包中止（`IOException: escape etc/alternatives/pager`）、`vscode.tar.gz` 缺 `@vscode/deviceid` 与 `@github/copilot-sdk`。详见 `docs/known-issues.md` 第 15–21 条。

> v1.0.13-l（versionCode 27）真机进度（Xiaomi / Android 17 / SDK 37）：安装成功 → 启动**不再闪退** → GeckoView 起 `sandboxed_tab` 内容进程 → 运行时解包完成 → `libproot.so`+`node` 起 `serve-web` → `127.0.0.1:8800` 处于 LISTEN 且已有 GeckoView 连接。剩余一项待肉眼确认：工作台是否完整渲染（设备识屏关闭，无法读屏自证）。验收清单见 `docs/README.md` 第七节。

> **当前进度（1.0.18-l，versionCode 32）**：四个用户可见问题各自落到根因，另补掉两个会让「干净设备即装即用」落空的实际问题，并给下一次安装加了可自证的自检。① 扩展「装不上」：serve-web 用 16MB 的 .NET 单文件 `vsce-sign` 校验 VSIX，该进程在 PRoot 下被 137 打死，日志是 `Signature verification failed with 'UnknownError'`；服务端 `downloadExtension` 里 `getValue("extensions.verifySignature")` 后据此跳过删包，其配置服务解析到的用户设置文件正是 `<server-data-dir>/data/User/settings.json`，App 首启预置该开关有效。② 中文方块：先按「预置 `editor.fontFamily`」修，实测无效——工作台跑在浏览器里、界面用户设置存浏览器侧（浏览器内有 `vscode-web-db`，预置服务端文件后活动栏位置/主题/字体变量全无变化）；改为把兜底规则补进随包发布的 `workbench.css` 末尾，只加载服务端提供的这份 CSS 时编辑器文本字体已以 `sans-serif` 收尾。③ 升级陷阱：解包标记原本只判存在，覆盖安装时旧载荷永不替换；现标记内写 versionCode、不一致就重解 VS Code 树（扩展/设置/工作区不在被重解的目录里），rootfs 仍不重解以免毁数据。④ DNS：rootfs 的 `resolv.conf` 原为写死的 8.8.8.8 优先，国内网络对该地址 UDP 53 常静默丢包；现起服务前读设备实际 DNS 重写，公网解析器按序后备。⑤ 首启自检（每版本一次）：把设备上真正发生的事写进 `getExternalFilesDir(null)/selftest.txt`——guest 解析器、预置设置、`workbench.css` 补丁命中数、首页 HTTP 结果，以及 PRoot 里真跑一次 `code-server --install-extension ms-python.python` 的退出码与输出尾巴（探针用临时扩展目录，不碰运行中的服务器）。实测（无头浏览器 + CDP）：用打进去的树起服务能给出完整欢迎页（标题 `Welcome - Visual Studio Code`、`Welcome` 标签、Start/Walkthroughs/Recent 齐全），扩展市场关键词搜索正常出结果（prettier 一屏，带安装次数与评分），市场查询确由浏览器侧发起。`tools/verify_apk.sh` 30 项全过（`VERIFY_OK`）。**仍未真机验证**：装上后 `selftest.txt` 会直接回答「服务起没起、补丁在不在、扩展能不能装」；欢迎页、沉浸式全屏、设置页、中文渲染仍需肉眼，因此需要在 设置 → 设备能力授权 里重新开启无障碍（当前 `enabled_accessibility_services` 为空）。

> 关于「直接用正常的 Linux 版 VS Code」：已在同架构同 glibc 的 Ubuntu 容器里实测**桌面版 Electron VS Code**（1.146.0 arm64 deb）——窗口能建，但 GPU 子进程 `exit_code=4`（SIGILL）两次后 Chromium 直接 `GPU process isn't usable. Goodbye`；改成 `--in-process-gpu` 则主进程自身收到 `Illegal instruction`。这是 proot 的 syscall 转发与 Chromium GPU 初始化路径不兼容，**桌面版走不通**，而 `serve-web`（纯 Node）在同环境完全正常。故本项目采用「Node 服务 + 客户端渲染」，与官方 `code-server` 同构。详见 `docs/known-issues.md` 第 22 条。

> 你反馈的三项界面问题（中文显示成方块/乱码、界面错位显示不全、扩展市场搜不到，以及缺少欢迎页、要求把设置移出主界面并默认全屏）是下一轮的工作面。已先排除两项结构性猜测：rootfs 的 DNS 配置（`8.8.8.8`/`1.1.1.1`/`223.5.5.5` + `hosts: files dns`）与根证书（123 个证书 + 完整 bundle）都正常，市场问题真因尚需应用运行时的 logcat 证据。

安装时需允许「安装未知来源应用」。装完点开图标即可，首次启动会自解包（约 1–2 分钟），之后冷启动数秒。

## 它是什么

一个自包含的安卓应用，内部串起四层：

```
┌──────────────── 单个 APK（dev.dsh.vscodemobile）────────────────┐
│ Java 层      MainActivity（工具栏 / 进度 / 错误面板 / 地址设置）    │
│              TarGz（纯 JDK 的 tar.gz 解包器）                     │
├──────────────────────────────────────────────────────────────────┤
│ 浏览器引擎    GeckoView 159（omni.ja + 13 个 arm64-v8a 原生库）     │
├──────────────────────────────────────────────────────────────────┤
│              HTTP 127.0.0.1:8800                                 │
├──────────────────────────────────────────────────────────────────┤
│ Linux 运行时  libproot.so（nativeLibraryDir，$ORIGIN RUNPATH）     │
│              └─ Ubuntu 22.04 arm64 精简根（glibc 2.35）           │
│                 └─ /opt/vscode/node → out/server-main.js          │
└──────────────────────────────────────────────────────────────────┘
```

- **VS Code 本体**是微软官方的 `serve-web` 1.144.0 产物（commit `2c33b50b`），与桌面版同一份 workbench / Monaco / 扩展宿主代码。
- **浏览器内核**是随包发布的 GeckoView，所以手机上装没装 Chrome 都无关。
- **运行环境**用 PRoot 做系统调用翻译，让 Linux glibc 的 `node` 在 Android bionic 上跑起来。

## 功能

编辑器、智能补全、转到定义、全局搜索替换、多文件夹工作区、集成终端（rootfs 内真 bash）、Git、扩展市场、调试、任务、命令面板、外接键鼠——都可用。

逐项对照见 **[docs/feature-matrix.md](docs/feature-matrix.md)**。

## 从源码构建

无需 Gradle，纯 `aapt2 + javac + d8 + zipalign + apksigner` 流水线：

```bash
bash android-app/tools/fetch_deps.sh   # 重建 libs/（gitignore，约 1 分钟）
bash android-app/build10.sh            # 产物 dist/vscode-mobile-L.apk
```

需要：Android SDK build-tools 34.0.0（aarch64 版 `aapt2`/`zipalign`）、JDK 17、`android.jar`（API 34）、GeckoView AAR 解出的 `libs/geckoview-classes.jar` 与 `jni/arm64-v8a/*.so`。

仓库不包含体积巨大的二进制（`android-app/jni/`、`android-app/assets/`、`dist/` 均在 `.gitignore` 中），它们由 `docs/README.md` 第五节描述的步骤生成：

| 资源 | 大小 | 来源 |
|---|---|---|
| `assets/runtime/rootfs.tar.gz` | 20,955,828 B | ubuntu-base 22.04.5 arm64 精简 |
| `assets/runtime/vscode.tar.gz` | 88,607,778 B | serve-web 1.144.0 裁剪树（含中文字体兜底补丁）|
| `assets/omni.ja` | 15,141,515 B | GeckoView 159 |
| `jni/arm64-v8a/*.so` | 170 MB | GeckoView + Termux proot |

## 目录

| 路径 | 说明 |
|---|---|
| [`android-app/`](android-app) | APK 工程（Java 源码、Manifest、构建脚本） |
| [`docs/README.md`](docs/README.md) | 完整交付说明：架构、首次使用、构建复现、验证记录 |
| [`docs/feature-matrix.md`](docs/feature-matrix.md) | 逐项功能矩阵 |
| [`docs/known-issues.md`](docs/known-issues.md) | 已知问题、架构性限制、真机待验收项 |
| [`bin/`](bin) | 开发容器内使用的 serve-web 生命周期脚本（`start-web.sh` 等） |

## 已知限制

- 只支持 **arm64-v8a**（Android 8.0+）。
- `targetSdk = 28`：Android 10+ 对 app 数据目录施加 `noexec`，PRoot 必须放在 `nativeLibraryDir` 才能执行，这是必要代价。侧载分发不受影响。
- Copilot、`@github`、mermaid 三个扩展为控制体积已裁剪，可在工作台内自行安装。
- 设置同步 / Live Share 依赖微软账号与实时服务，未打通。

完整清单见 **[docs/known-issues.md](docs/known-issues.md)**。

## 许可

本仓库的胶水代码（Java 层、构建脚本、文档）为 MIT。APK 内打包的 VS Code 受 Microsoft 软件许可约束，GeckoView 为 MPL-2.0，Ubuntu rootfs 内各组件的许可证随包保留在 `rootfs/usr/share/doc/`。