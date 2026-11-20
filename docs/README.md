# VS Code Mobile —— 安卓移植交付说明

记录日期：2026-11-08（更新）　版本：VS Code 1.144.0 / GeckoView 159 / Android 8.0+

## 一、交付物

| 产物 | 路径 | 大小 |
|---|---|---|
| 安装包（已签名，可直接安装） | `dist/vscode-mobile-L.apk` | 206,064,075 字节（约 197 MB），MD5 `e89a650d78e91b5faaf243802665d931`，SHA-256 `9ae1d8e99c6d4e67677e863a5c71cd03b149cd8fbd17d729e1073ad6460bb0ff`（v1.0.18-l / versionCode 32） |
| 手机侧副本（可直接点开安装） | `/sdcard/Download/vscode-mobile-L.apk` | 需在每次构建后重新 `cp` 并核对 MD5 |
| GitHub 发布页 | `irerc/vscode-mobile-android` | 见 Release 页 |
| APK 源码工程 | `android-app/` | — |
| 一键构建脚本 | `android-app/build10.sh` | — |
| 依赖拉取脚本 | `android-app/tools/fetch_deps.sh` | 从 Maven Central + Google Maven 重建 `libs/`（约 1 分钟） |
| 库 R 生成器 | `android-app/tools/genlibR.py` | 按 AAR `R.txt` + 链接后的资源表生成各库 `R.java` |
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
| 源代码管理（Git） | ⚠️ | rootfs 未预装 git：需在终端内联网 `apt install git` 后配置凭据，离线状态下不可用 |
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
bash android-app/tools/fetch_deps.sh    # 首次或换机后：重建 libs/（gitignore）
bash android-app/build10.sh             # 产物 dist/vscode-mobile-L.apk
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

## 六、复核产物（任何人都能跑）

```bash
bash android-app/tools/verify_apk.sh dist/vscode-mobile-L.apk
```

一条命令覆盖本项目被真机打回过的每一类缺陷：签名（v1/v2/v3）、`zipalign -P 16`、`targetSdk=28`、dex 里的 Kotlin 运行时 / `androidx.collection.SimpleArrayMap` / `androidx.*.R$*` / media3+gms 闭包、自检 marker（`SELFTEST`、`ok-rootfs`、`ok-vscode`）、APK 内 assets 与 native 库、以及 serve-web 树里的 `node` / `server-main.js` / `@vscode/deviceid` / `@github/copilot-sdk` / `node-pty` 预编译件。全过输出 `VERIFY_OK`。

解包器另有一条可复现回归（正是让每次首启停在「运行时解包失败」的那条路径）：

```bash
bash android-app/tools/test_extract.sh android-app
```

它在 JVM 上直接跑真实的 `TarGz`，对 `rootfs.tar.gz` 与 `vscode.tar.gz` 各做「全新解包 + 覆盖已存在树再解一遍」，并与 GNU `tar` 比对条目数与软链数；最后还验证 `TarGz.wipe()` 对「软链指到 `/etc`」和「软链成环」的树只删自己、不跟随。全过输出 `EXTRACT_OK`。实测结果：rootfs 1290 项 / 软链 246 个（与 tar 一致，唯一差异是 1 个硬链按内容复制），vscode 4713 项 / 0 软链。

脚本本身也踩过两个坑并已固化：JDK 17 在 `LANG` 未设时 `LoggerFinderLoader` 抛 `ExceptionInInitializerError`，以及含空格+中文的工程路径直接传给 `java` 会参数乱码——所以脚本 `export LANG=C.UTF-8` 且先 `cp` 到 ASCII 临时路径。

## 六、验证记录（历史）

**v1.0.13-l（versionCode 27，历史产物、未发布）的静态 + 真机验证**

- `apksigner verify` → v1/v2/v3 全部通过；`zipalign -c -P 16 4` 通过。
- `aapt2 dump badging` → `dev.dsh.vscodemobile`，`minSdk=26`，`targetSdk=28`。
- dex 关键类门禁（构建脚本内 `FATAL` 级）：`kotlin/jvm/internal/Intrinsics`、`kotlinx/coroutines/Dispatchers`、`androidx/media3/extractor/DefaultExtractorsFactory`、`com/google/android/gms/common/api/Api`、`androidx/lifecycle/runtime/R$id`、`androidx/startup/R$string` 全部命中。
- 库 R 类实测进 dex：`androidx.fragment.R$id/$animator/$styleable`、`org.mozilla.geckoview.R$drawable`、`com.google.android.gms.base.R$string/$styleable`、`androidx.media3.exoplayer.R$string`、`androidx.core.R$id/$string`、`androidx.activity.R$id`、`androidx.lifecycle.runtime.R$id`。
- R8 `--dontshrink` 全量缺失类审计 → 剩余 59 条全部是 `android.*` / `java.*` / `javax.*` / `libcore.*` 框架桩或 `org.checkerframework`、`org.jspecify` 等纯注解类型，无实际类型缺失。
- APK 206,485,963 字节，MD5 `f8bb77f936051cd82fa8040220a7c1ec`，SHA-256 `e09b8062482e8e860e5de6969c711d35fc774bdd28d001a8cfe9a969d882087c`（v1.0.13-l 的历史指纹，保留备查）。
- 依赖闭包门禁：`tools/fetch_deps.sh` 尾部对 `libs/` 下每个 classes jar 数 `.class` 条目，任何一个是 0 立即失败——这条门禁正是用来抓住 KMP metadata 空包的（`collection-1.6.0.jar` / `annotation-1.11.0.jar` / `lifecycle-common-2.11.0.jar` / `lifecycle-runtime-2.11.0.aar` 全部为 0）。
- dex 新增门禁 `androidx/collection/SimpleArrayMap`（命中 8 处），这是上一版真机崩溃 `GeckoAppShell.<clinit>` 的直接元凶。
- 解包器回归：`TarGz` 改为「单遍流式 + 软链延后创建」，rootfs 里的 `etc/alternatives/* → /usr/bin/*` 绝对软链不再被判为路径逃逸；`ensureRuntime` 分阶段 marker（`.ok-rootfs` / `.ok-vscode`）。
- serve-web 树完整性：容器内（同架构同 glibc）实跑 `out/server-main.js` → `Web UI available`、`Extension host agent started`、`ERR_MODULE_NOT_FOUND` 归零，`/` 返回 200，`workbench.js`(21,490,997 B)、`workbench.css`(1,811,449 B)、`nls.messages.js`(1,321,164 B) 等静态资源全部 200。
- **真机（Xiaomi 26048RP6AC / Android 17 / SDK 37）实测链路**：`/app/install` 安装 27 → 启动进程存活且不再闪退 → GeckoView 起 `:crashhelper`/`:gpu`/两个 `:sandboxed_tab` 内容进程 → 首次解包成功 → 子进程 `libproot.so` + `node` 起来 → `/proc/net/tcp` 中 `127.0.0.1:8800` 为 LISTEN（uid 10321）且已有 GeckoView 的 ESTABLISHED 连接。
- 依赖可从零重建：`tools/fetch_deps.sh` 在 64 秒内重建被 gitignore 的 `libs/`（19 个首轮闭包 + 4 个 kotlin + 24 个第二闭包 + 16 个 AAR），随后 `build10.sh` 直接 `BUILD_OK`。

**v1.0.6-l（历史产物）的静态验证**

- `apksigner verify` → 通过（SHA-256 `1d571632…c47416346`）。
- `aapt2 dump badging` → `package=dev.dsh.vscodemobile`，`minSdk=26`，`targetSdk=28`，`extractNativeLibs=true`。
- APK 内含 `classes.dex`（26KB）、`resources.arsc`、`assets/omni.ja`、3 个 `assets/runtime/*.tar.gz`、16 个 `lib/arm64-v8a/*.so`（含 `libxul.so` 154MB、`libproot.so`、`libtalloc.so`、`libprootloader.so`）。
- **端到端证明**：用 APK 内同一份 `rootfs.tar.gz` + `vscode.tar.gz` 解包后，以 rootfs 自带 glibc loader 直接运行 serve-web，4 秒内返回 HTTP 200，返回页面含 7 处 `workbench`，`workbench.js` / `workbench.css` / `nls.messages.js` / 图标 / manifest 全部 200，日志出现 `Extension host agent started.`。
- `TarGz.java` 解包正确性：对 `rootfs.tar.gz` 解出 1290 项、对 `vscode.tar.gz` 解出 3490 文件 + 829 目录，与系统 `tar` 结果完全一致，符号链接与可执行位均正确。

## 七、待真机验收

**v1.0.13-l 已在真机上跑通「安装 → 启动 → 解包 → PRoot → serve-web 监听 8800」整条链路**，这是历史上第一次走过闪退。

仍未由助手自证的一项：**工作台是否完整渲染**（左侧资源管理器、底部终端、扩展面板）。原因不在代码，而在设备侧观察通道——识屏（无障碍）仍被判定为关闭，App 桥返回 `SCREEN_MODE_OFF` / `SCREEN_MODE_PHYSICAL_OFF`，助手无法读屏或截图；容器网络与设备回环不在同一命名空间，也无法从容器直接探 `127.0.0.1:8800`。

要把它变成自证，只需二选一：

1. 用户在 **设置 → 设备能力授权 → 识屏** 选「实体」（选完若仍报 `SCREEN_MODE_PHYSICAL_OFF`，把 DSHA App 切后台再切回，让能力开关重新加载）；
2. 或用户肉眼确认一次界面后告知，助手据此更新验收结论。

其余待验收项见 `docs/known-issues.md` 第四节：首启解包耗时与内存峰值、集成终端能否在 PRoot 内起 `/bin/bash`、后台驻留 10 分钟后 serve-web 是否被系统回收。
