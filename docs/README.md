# VS Code Mobile —— 安卓移植交付说明

记录日期：2026-10-31　版本：VS Code 1.144.0 / GeckoView 159 / Android 8.0+

## 一、交付物

| 产物 | 路径 | 大小 |
|---|---|---|
| 安装包（已签名，可直接安装） | `dist/vscode-mobile.apk` | 199,112,604 字节（约 190 MB），MD5 `5d94aa6b8c955334a205d3047fc28daf` |
| 手机侧副本（可直接点开安装） | `/sdcard/Download/vscode-mobile.apk` | 同上，MD5 `5d94aa6b8c955334a205d3047fc28daf` |
| GitHub 发布页 | `irerc/vscode-mobile-android`，Release `v1.0.0` 附件 `vscode-mobile.apk` | 同上 |
| APK 源码工程 | `android-app/` | — |
| 一键构建脚本 | `android-app/build2.sh` | — |
| 已知问题清单 | `docs/known-issues.md` | — |

**这个 APK 是完全自包含的**：VS Code 服务端、Ubuntu 用户态、PRoot 执行器、GeckoView 浏览器内核全部打进包里。安装后不依赖容器、不依赖局域网、不依赖手机上任何已有浏览器，飞行模式下也能启动。

## 二、架构

```
┌─────────────────────── 手机（单个 APK，无外部依赖）───────────────────────┐
│  VS Code Mobile（dev.dsh.vscodemobile）                                    │
│                                                                            │
│  ┌── Java 层 ────────────────────────────────────────────────────────┐    │
│  │ MainActivity：工具栏 / 进度 / 错误面板 / 服务器地址设置            │    │
│  │ TarGz：纯 JDK 的 tar.gz 解包器（首次启动展开 assets）              │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                            │
│  ┌── 浏览器引擎（随包）─────────────────────────────────────────────┐    │
│  │ GeckoView 159：omni.ja + 13 个 arm64-v8a 原生库                    │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                          │ HTTP 127.0.0.1:8800                            │
│                          ▼                                                │
│  ┌── 内置 Linux 运行时（随包）───────────────────────────────────────┐    │
│  │ libproot.so（nativeLibraryDir，$ORIGIN RUNPATH）                   │    │
│  │   └─ rootfs/  Ubuntu 22.04 arm64 精简根（glibc 2.35）              │    │
│  │        └─ /opt/vscode/node  →  out/server-main.js（serve-web）     │    │
│  └──────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────────┘
```

**为什么需要 PRoot**：微软 serve-web 的 `node` 是 Linux glibc 构建，Android 的 bionic 链接器无法直接加载它。所以随包带一个 21MB（压缩）的 Ubuntu 精简根（只保留 glibc、libstdc++、bash 与核心工具），由 PRoot 做系统调用翻译，让 Linux node 以为自己在普通 Linux 上运行。

**为什么 proot 放在 nativeLibraryDir**：Android 10+ 对 app 数据目录（`filesDir`）施加 `noexec`，从那里 `exec` 会被 SELinux 拒绝。原生库目录不受此限制，因此 `proot`、`proot` 的静态 loader、`libtalloc`、`libandroid-shmem` 都以 `lib*.so` 形式放进 `lib/arm64-v8a/`，并在 `libproot.so` 上写入 `$ORIGIN` RUNPATH 让 bionic 找到同目录依赖。代价是 `targetSdk` 必须降到 28（侧载分发不受影响）。

## 三、首次使用

1. 在手机上点开 `Download/vscode-mobile.apk` 安装（需允许“安装未知来源应用”）。
2. 打开「VS Code Mobile」。首次启动会自动把约 110MB 压缩资源解包到应用私有目录（展开后约 320MB），界面显示「正在准备运行时（首次启动约 1–2 分钟）」与实际秒数。
3. 解包完成后 PRoot 启动内置 VS Code 服务端，界面显示「正在启动 VS Code 服务… Ns」，通常 10–30 秒后自动进入工作台。
4. 之后每次启动走 `.ok` 标记跳过解包，冷启动一般为数秒。

**不需要**：容器在跑、局域网、端口转发、手机上有浏览器。

## 四、已实现能力（对应“电脑版功能”）

| 功能 | 状态 | 说明 |
|---|---|---|
| 编辑器（语法高亮 / 多光标 / 查找替换） | ✅ | Monaco，桌面级 |
| 文件资源管理器、新建/重命名/删除 | ✅ | 走 rootfs 内真实文件系统，默认工作区 `/root/workspace` |
| 集成终端 | ✅ | rootfs 内 `/bin/bash`，可运行 Linux 命令 |
| 源代码管理（Git） | ✅ | 需在终端内 `apt` 安装 git 并配置凭据 |
| 扩展市场 | ✅ | 联网时从 Marketplace / Open VSX 安装 |
| 调试（Node/Python 等） | ✅ | 依赖对应 debug adapter，由扩展提供 |
| 任务 / 输出 / 问题面板 | ✅ | — |
| 命令面板、快捷键 | ✅ | 软键盘 + 外接键盘均可用 |
| 多文件夹工作区 | ✅ | URL 参数 `?folder=` |
| 深链接 `vscodemobile://open?folder=/path` | ✅ | 外部可唤起并打开指定目录 |
| 主题 / 字号 / 布局设置 | ✅ | 与桌面版一致 |
| 完全离线自包含 | ✅ | 服务端、运行时、浏览器全部在 APK 内 |

## 五、构建方法（复现）

```bash
bash "/root/VS Code移植/android-app/build2.sh"
```

流水线：`aapt2 compile → aapt2 link → javac（JDK17，-source 8）→ d8 → 打包 so/assets → zipalign → apksigner`。

全程无需 Gradle；Android SDK 组件为 aarch64 版 `aapt2/zipalign` + 官方 `apksigner.jar`/`d8.jar`。
签名密钥：`android-app/keystore/release.jks`（口令 `vscodemobile`，别名 `vscodemobile`，有效期 10000 天）。

打包进 APK 的运行时资源（`android-app/assets/runtime/`）：

| 文件 | 大小 | 内容 |
|---|---|---|
| `rootfs.tar.gz` | 20,955,828 B | Ubuntu 22.04.5 arm64 精简根（glibc 2.35、libstdc++ 6.0.30、bash、CA 证书、resolv.conf、bootstrap.sh） |
| `vscode.tar.gz` | 88,452,362 B | 裁剪后的 serve-web 树（node、node_modules、94 个内置扩展、out） |
| `usr.tar.gz` | 136,008 B | PRoot 备用副本（实际运行走 nativeLibraryDir） |
| `omni.ja` | 15,141,515 B | GeckoView 资源包 |

## 六、验证记录

- `apksigner verify` → 通过（SHA-256 `1d571632…c47416346`）。
- `aapt2 dump badging` → `package=dev.dsh.vscodemobile`，`minSdk=26`，`targetSdk=28`，`extractNativeLibs=true`。
- APK 内含 `classes.dex`（26KB）、`resources.arsc`、`assets/omni.ja`、3 个 `assets/runtime/*.tar.gz`、16 个 `lib/arm64-v8a/*.so`（含 `libxul.so` 154MB、`libproot.so`、`libtalloc.so`、`libprootloader.so`）。
- **端到端证明**：用 APK 内同一份 `rootfs.tar.gz` + `vscode.tar.gz` 解包后，以 rootfs 自带 glibc loader 直接运行 serve-web，4 秒内返回 HTTP 200，返回页面含 7 处 `workbench`，`workbench.js` / `workbench.css` / `nls.messages.js` / 图标 / manifest 全部 200，日志出现 `Extension host agent started.`。
- `TarGz.java` 解包正确性：对 `rootfs.tar.gz` 解出 1290 项、对 `vscode.tar.gz` 解出 3490 文件 + 829 目录，与系统 `tar` 结果完全一致，符号链接与可执行位均正确。

## 七、待真机验收

见 `docs/known-issues.md` 第四节。要点：首启解包耗时、PRoot 在真实 bionic 下的加载、GeckoView 渲染完整工作台、集成终端可用性、后台驻留存活。