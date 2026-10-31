# 已知问题与限制（VS Code Mobile）

记录日期：2026-10-31　目标版本：VS Code 1.144.0 / GeckoView 159 / Android 7.0+

## 一、已解决但值得记录的问题

| # | 现象 | 根因 | 处置 |
|---|------|------|------|
| 1 | `code-tunnel serve-web` 报 `unexpected argument '--disable-updates'` | 1.144.0 的 serve-web 不支持该参数 | 只用 `--host/--port/--without-connection-token/--accept-server-license-terms/--disable-telemetry/--server-data-dir/--default-folder` |
| 2 | 首次启动健康检查超时（HTTP 202） | 首轮 profile 初始化耗时超过 30s | 健康检查改为轮询 300s，202 视为「仍在初始化」 |
| 3 | `server-main.js:268:87` 未捕获异常导致进程退出 | 端口已被旧进程占用 | 严格用 PID 文件管理生命周期，启动前校验端口归属 |
| 4 | `apksigner` 之前 `aapt2 link` 报 `style/GeckoViewTheme not found` | `res-app/values` 为空，主题未生成 | 用脚本重新生成 `styles.xml` |
| 5 | `javac` 报 `invalid flag: /root/VS` | argfile 按空白切分，中文路径含空格 | 源码先复制到 ASCII 路径 `/tmp/apkbuild3/src` 再编译 |
| 6 | `GeckoSession.setSettings()` / `canGoBack()` 找不到符号 | 该版本 API 是构造器传 `GeckoSessionSettings`，回退能力靠 `NavigationDelegate.onCanGoBack` | 已按真实 API 改写 |
| 7 | `dpkg-deb -x` 解 Termux 包报 `Cannot change mode` | 包内路径前缀与本地不一致，chmod 失败但文件已解出 | 忽略该噪声，校验文件存在即可 |
| 8 | Termux 仓库 `Packages.xz` 全面 404 | 仓库只发布 `Packages.gz` | 改用 `Packages.gz` 解析真实文件名 |
| 9 | 真机上 GeckoView 内容进程起不来：白屏或首启即崩，logcat 报 `Unable to start service ... GeckoChildProcessServices$tab0` | v1.0.0 的清单是手写的，只声明了 12 个 GeckoView 服务，漏掉 AAR 中其余 77 个（`tab0..39`、`isolatedTab0..39`、`socket/gpu/rdd/utility` 等），且缺 `isolatedProcess="true"`、`useAppZygote`、``、`glEsVersion` | v1.0.1 改为由 `geckoview-arm64-v8a.aar` 的清单生成：89 个 service、41 个 `isolatedProcess="true"`、1 个 `useAppZygote`、`` 与 `uses-feature glEsVersion 0x00020000` 全部补齐，并用 `aapt2 dump xmltree` 在打包后的 APK 内逐项复核 |

## 二、架构性限制（不可绕过，需知悉）

1. **PRoot 无法在开发容器内验证。** PRoot 的解释器是 Android 的 `/system/bin/linker64`（bionic），Ubuntu 容器里不存在该文件，proot 启动后只会打横幅并挂住。因此 proot 链路只能在真机上首启验证；容器内改用「rootfs 自带 glibc loader + 直接跑 node」证明同一份 payload 能启动并返回 200。
2. **serve-web 的 node 依赖 glibc。** 官方 server 的 `node` 是 Linux glibc 构建，Android 的 bionic 不能直接加载，必须经 PRoot/rootfs 的 glibc。这是必须打包 50MB rootfs 的原因。
3. **Android 10+ 的 app 数据目录不可执行。** `filesDir` 上 exec 被 SELinux 拒绝，所以 `targetSdk` 降到 28，且 proot 本体放到 `nativeLibraryDir`（`libproot.so` / `libprootloader.so` / `libtalloc.so`）并在 `libproot.so` 上写 `$ORIGIN` RUNPATH 让 bionic 找到同目录依赖。
4. **`targetSdk=28`** 是为上面第 3 点付出的代价；功能不受影响，但不符合 Play 商店新应用上架要求（本 APK 为侧载分发）。
5. **首启需解包约 110MB 资源（解包后 ~320MB）。** 期间界面显示进度与「已等待 N 秒」，首次进入工作台通常 30–120 秒，取决于闪存速度。之后启动走 `.ok` 标记直接跳过解包。
6. **不支持 `--user-data-dir` / `--extensions-dir`。** 1.144.0 的 serve-web 没有这两个参数，用户数据与扩展目录固定在 `--server-data-dir` 之下。
7. **Microsoft 账号 / Settings Sync / Live Share 不在支持范围。** 这些依赖微软云服务与内嵌浏览器登录流程，Web 版工作台本身也受限。
8. **Copilot 内置扩展未打包。** 原树 `extensions/copilot` 156MB、`node_modules/@github` 157MB、`mermaid-markdown-features` 47MB 被裁掉以控制 APK 体积（199MB）。需要时可在工作台内从市场安装，或后续追加打进 assets。

## 三、开发环境限制

| 项 | 说明 |
|----|------|
| Gradle | 容器内无可用 Gradle，全程 aapt2 + javac + d8 + apksigner 手工链路 |
| build-tools | 官方包只有 x86_64，改用 lzhiyong 的 aarch64 组合包；`file` 命令缺失，用 `od` 读 ELF 头判断架构 |
| sdkmanager | 下载器损坏，无法在线安装组件 |
| /app/export | 单文件上限 90MB，199MB 的 APK 只能 `cp` 到 `/sdcard/Download/` |
| adb-shell 通道 | `[DEVICE_CHANNEL_UNAVAILABLE]`，需用户在「设置 → 设备能力授权」连接 root / Shizuku / ADB 才能用设备 shell |
| DSHA 无障碍 | `ACCESSIBILITY_UNAVAILABLE`，无法自动点击安装界面，安装需用户手动确认 |
| 工具层字符处理 | 写入含 `` `&` 或完整 URL 字面量的文本会被截断，Java 源码统一用占位符脚本生成 |
| 容器 seccomp | `chroot` 仅首次可用，之后 `Function not implemented`；改用 loader 直跑 |

## 四、待真机验证项

- [ ] 首次启动解包 110MB 资源的实际耗时与内存峰值
- [ ] `libproot.so` 在 Android 上通过 `$ORIGIN` 找到 `libtalloc.so` / `libandroid-shmem.so`
- [ ] PRoot 用 rootfs 的 glibc 加载 `/opt/vscode/node` 是否成功
- [ ] GeckoView 加载 `http://127.0.0.1:8800/` 后工作台是否完整渲染（含文件树、终端、扩展面板）
- [ ] 集成终端能否在 PRoot 内起 shell（`/bin/bash`）
- [ ] 后台驻留 10 分钟后 serve-web 是否被系统回收