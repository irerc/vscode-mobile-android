# VS Code Mobile

把完整的桌面版 **VS Code** 装进一个安卓 APK：**即装即用，不依赖手机上的浏览器、不依赖容器、不需要联网**。

[![Release](https://img.shields.io/badge/release-v1.0.0-blue)](https://github.com/irerc/vscode-mobile-android/releases/tag/v1.0.0)
[![VS Code](https://img.shields.io/badge/VS%20Code-1.144.0-007ACC)](https://code.visualstudio.com/)
[![GeckoView](https://img.shields.io/badge/GeckoView-159-orange)](https://mozilla.github.io/geckoview/)
[![Android](https://img.shields.io/badge/Android-8.0%2B%20(arm64)-green)]()

## 直接下载

**[vscode-mobile.apk](https://github.com/irerc/vscode-mobile-android/releases/download/v1.0.0/vscode-mobile.apk)** · 199,116,700 字节（约 190 MB） · MD5 `5af63fd82c8304255b44f489e7fe8362`

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
bash android-app/build2.sh
```

需要：Android SDK build-tools 34.0.0（aarch64 版 `aapt2`/`zipalign`）、JDK 17、`android.jar`（API 34）、GeckoView AAR 解出的 `libs/geckoview-classes.jar` 与 `jni/arm64-v8a/*.so`。

仓库不包含体积巨大的二进制（`android-app/jni/`、`android-app/assets/`、`dist/` 均在 `.gitignore` 中），它们由 `docs/README.md` 第五节描述的步骤生成：

| 资源 | 大小 | 来源 |
|---|---|---|
| `assets/runtime/rootfs.tar.gz` | 20,955,828 B | ubuntu-base 22.04.5 arm64 精简 |
| `assets/runtime/vscode.tar.gz` | 88,452,362 B | serve-web 1.144.0 裁剪树 |
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