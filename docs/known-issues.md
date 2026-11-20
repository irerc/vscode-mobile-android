# 已知问题与限制（VS Code Mobile）

记录日期：2026-11-08（更新）　目标版本：VS Code 1.144.0 / GeckoView 159 / Android 7.0+

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
| 10 | G/H/J 装上后启动即闪退，无任何界面 | **d8 只拿到 `geckoview-classes.jar` + 3 个 app class**，androidx 只进了 javac 的 classpath 却没进 dex；`buildUi()` 在 MainActivity.java:254 触发 `NoClassDefFoundError: androidx/core/view/OnApplyWindowInsetsListener` | build9.sh 把整个依赖闭包（`runtime-deps-clean` 15 个 jar）一起喂给 d8；K 的 dex 中该类有 9 处命中 |
| 11 | build8.sh 的 d8 崩溃：`java.lang.NullPointerException: Cannot invoke "String.length()" because "<parameter1>" is null`，包装为 `com.android.tools.r8.CompilationFailedException` | 触发文件 `androidx-core-1.19.1.jar:android/support/v4/os/ResultReceiver$1.class`；build-tools 自带 `D8 8.2.2-dev` 的代码生成缺陷 | 双重规避：改用 `cmdline-tools/latest/lib/r8.jar`（`D8 8.2.33`），并从 androidx-core 中剥掉 `android/support/*`（GeckoView 不引用） |
| 12 | d8 报 "defined multiple times" | `runtime-deps/` 里 `androidx.core-core-1.19.1.jar`、`androidx.annotation-annotation-1.11.0.jar` 与无 `core` 前缀的同名包**字节完全相同** | `tools/sanitize_deps.py` 用 `DUPS` 集合排除重复件，生成 `runtime-deps-clean/`；构建脚本只读该目录 |
| 13 | STORED 方式打包的 178MB / 303MB APK 安装失败（「签名校验不通过，目标系统版本过高」） | `.so` 未压缩导致安装器体积/校验上限被击穿 | 改为 DEFLATE（`zip -9` 压 dex+so，`zip -0` 仅用于 assets），200MB 级可正常安装；实测上限约 178MB（STORED） |
| 14（**结论有误，见第 19 行**）| K（v1.0.5-k）打包后的 dex 里仍有 33 个被引用的 androidx 类型没有定义 | 三个独立原因：① `androidx-annotation-1.11.0.jar`、`androidx-collection-1.6.0.jar`、`androidx-lifecycle-common-2.11.0.jar` 是 KMP 的 metadata-only 包（0 个 `.class`，只有 `commonMain/default/linkdata/*.knm`），对 d8 零贡献；② lifecycle-runtime / startup-runtime / tracing / versionedparcelable 从未进闭包；③ 任何 androidx jar 都不发 `R$*`，而 `androidx.core` 字节码直接读 `attr/id/styleable` 常量类 | L（v1.0.6-l）：metadata 包换成真 JVM 产物（`annotation-jvm`/`collection-jvm`/`lifecycle-common-jvm`，版本不变），补齐 4 个传递依赖，按 AAR `R.txt` 合成 `androidx-core-R.jar`（208 个 int + 7 个 int[]）。DEPJARS 增至 20 个；d8 后逐类审计 33/33 命中、0 缺失 |
| 15 | 真机启动即崩：`NoClassDefFoundError: Failed resolution of: Lkotlin/jvm/internal/Intrinsics;`，栈顶 `androidx.collection.SimpleArrayMap.put(SimpleArrayMap.kt:397)` → `GeckoBundle.putString` → `GeckoSessionSettings.<init>` → `createGecko` | **dex 里没有任何 Kotlin 运行时**。androidx.collection / core / lifecycle 与 GeckoView 都是 Kotlin 编写，构建脚本却只喂了 Java 依赖：`kotlin-stdlib`、`kotlinx-coroutines` 从未进入 javac classpath 或 d8 输入，因此首次触碰 Kotlin 类即抛错 | 新增 `libs/kotlin/`：`kotlin-stdlib` **2.4.20**（与 GeckoView POM 声明一致）、`kotlinx-coroutines-core-jvm` / `-android` 1.10.2、`annotations` 23.0.0，同时进 classpath 与 d8；构建尾部加硬门禁，dex 中查不到 `kotlin/jvm/internal/Intrinsics` 就 `FATAL` |
| 16 | 补齐 Kotlin 后仍埋着 `NoClassDefFoundError` 隐患 | 首个闭包漏掉 media3 / fido / guava 的传递件：`androidx.media3.extractor.*`、`androidx.media3.container.*`、`androidx.media3.database.*`、`com.google.android.gms.common.*`、`androidx.concurrent.futures.*`、guava `InternalFutures` | 用 R8（`--dontshrink`）对全部输入跑一次「Missing class」审计，逐条补 `libs/closure-extra/`（AAR 取 `classes.jar`）：media3-extractor/container/database、interpolator、concurrent-futures、`failureaccess`（**不能**用 `listenablefuture`，其 `ListenableFuture` 与 guava 33.4 重复定义）、j2objc-annotations、play-services-base 18.7.2 / basement 18.9.0（旧版 18.5/18.4 缺 `ApiMetadata`、`ComplianceOptions`，正是 fido 21.3.1 的 POM 要求的版本） |
| 17 | 第二轮审计又出现 `androidx.fragment.*` / `androidx.savedstate.*` / `androidx.lifecycle.viewmodel.*` / `kotlinx.serialization.*` | 这条链是被 **play-services-base/basement → fragment → lifecycle/savedstate → kotlinx-serialization** 拖出来的传递依赖（WebAuthn 路径）。只补 fragment 会立刻缺下一层 | 一次补全：activity、fragment、customview、loader、viewpager、savedstate、lifecycle-viewmodel(-savedstate)、lifecycle-livedata(-core)、arch-core-runtime/core-common、exifinterface、core-viewtree、kotlinx-serialization-core 1.7.3 |
| 18 | 库的 `R$*` 常量类不存在（`org.mozilla.geckoview.R$drawable`、`androidx.fragment.R$id`、`com.google.android.gms.base.R$string` …），Gradle 会自动生成，手写链路不会 | ① 各 AAR 的 `res/` 从未合进 APK；② `aapt2 link --extra-packages` **只接受单个包名**（传逗号列表会被当成一个包名，逐包传参则后续参数被当作输入文件）；③ 之前用假 id 手写的 `androidx-core-R.jar`、lifecycle/startup R 存根只是猜测值 | 改为「合并资源 + 反查真实 id」：`tools/genlibR.py` 先 `aapt2 dump resources` 读出链接后的资源表，再按每个 AAR 的 `R.txt` 生成 `<pkg>/R.java`（`styleable` 数组直接取 `R.txt` 常量；style 名需把下划线映射成 aapt2 输出的点号形式）。15 个库包、166 个 id、0 缺失；假 id 存根全部删除 |

| 19 | 真机装 1.0.10-l 后启动即崩：`NoClassDefFoundError: Failed resolution of: Landroidx/collection/SimpleArrayMap;` @ `GeckoAppShell$AndroidSScreenCompat.<init>` → `GeckoAppShell.<clinit>` → `GeckoView.onAttachedToWindow` | **第 14 行声称的「换真 JVM 产物」并没有真正落到抓取脚本里**。`tools/fetch_deps.sh` 仍在用 KMP 根坐标：`collection-1.6.0.jar`、`annotation-1.11.0.jar`、`lifecycle-common-2.11.0.jar`、`lifecycle-runtime-2.11.0.aar`，这 4 个产物都是 0 个 `.class` 的 metadata（只有 `commonMain/default/linkdata/*.knm`）；又因为 `fetch` 对已存在文件默认跳过，错误的文件被一直沿用 | fetch 脚本改取真产物变体：`annotation-jvm`、`collection-jvm`、`lifecycle-common-jvm`、`lifecycle-runtime-android`（aar）。脚本尾部加硬门禁：`libs/` 下任何 classes jar 若 `unzip -l` 数出 0 个 `.class` 立即 `exit 1`（实测该门禁能当场抓住这四个包）；`build10.sh` dex 门禁追加 `androidx/collection/SimpleArrayMap`，命中数 8 |
| 20 | 首次启动停在「运行时解包失败…」，logcat：`java.io.IOException: escape etc/alternatives/pager` @ `TarGz.extract(TarGz.java:82)` ← `MainActivity.ensureRuntime` | 自写 tar 解包器用 `getCanonicalPath()` 校验落地路径，而 **`getCanonicalPath()` 会解析符号链接**。Ubuntu rootfs 里普遍是绝对软链（`etc/alternatives/pager → /usr/bin/pager`、`lib → usr/lib`），只要该路径已存在软链，canonical 就落到 rootfs 之外、被判「escape」后整包中止。更糟的是崩溃残留的半成品会被下次启动复用，于是每次重试都必现同一行 | 解包器改成「单遍流式 + 软链延后统一创建」：普通文件写入阶段软链尚未建立，写入与校验都不会穿过软链；路径合法性改为纯词法判定（拒绝 `/` 开头、拒绝 `..` 段、父目录 canonical 仍须在根内）；写文件前先 `deleteIfLink` 清掉同名软链；`ensureRuntime` 对缺 marker 的阶段先用 `TarGz.wipe()` 递归清理（绝不跟随软链），并把 rootfs / vscode 拆成两个独立 marker，避免 21MB 的 rootfs 因第二阶段失败被反复重解 |
| 21 | 服务能监听 8800、GeckoView 也已连上，但 node 侧报 `Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@vscode/deviceid' imported from /opt/vscode/out/server-main.js` | 打进 APK 的 `vscode.tar.gz` 缺两个包：`node_modules/@vscode/deviceid`、`node_modules/@github/copilot-sdk`（原树 4,318 条目，补全后 4,713，差 395 个文件），`server-main.js` 启动时 ESM 解析失败 | 从与树内 `product.json` 完全同版本（1.144.0 / commit `2c33b50b…`）的官方 `server-linux-arm64` 包里取出这两个包及其依赖树补进树内，重打 `vscode.tar.gz`。容器内（同架构同 glibc）本地复跑验证：`ERR_MODULE_NOT_FOUND` 归零、`Web UI available`、`Extension host agent started`、`workbench.js`(21.5MB) 与全部静态资源 HTTP 200 |

| 22 | 想在环境里直接跑**桌面版 Electron VS Code**（`code` 1.146.0 arm64 deb，装在 Ubuntu 24.04 aarch64 容器 = 与 APK 内 rootfs 同架构同 glibc），窗口建出来但整块纯色 `#F6F5F4`（VS Code 浅色背景），30 秒后 `GPU process exited unexpectedly: exit_code=4` ×2 → `FATAL: chrom-ium gpu_data_manager_impl_private.cc:416 GPU process isn't usable. Goodbye.` | `exit_code=4` 即 **SIGILL**：GPU 子进程在这个 proot 环境里执行到非法指令被杀。改用 `--in-process-gpu --disable-gpu-compositing` 后不再有 GPU 子进程，但同一段代码移到主进程，主进程直接 `Illegal instruction` 退出（bash 明确报 SIGILL） | **桌面版 Electron 走死路**：这不是参数问题，是 proot 的 syscall 转发 + Electron/Chromium GPU 初始化路径不兼容。`serve-web`（纯 Node）在同环境完全正常（监听 8800、workbench.js 21.5MB 全 200），所以架构上只能走「Node 服务 + 客户端渲染」，不能走 Electron 原生窗口。已在容器内证伪，无需真机再试 |
| 23 | 用户反馈真机「扩展市场搜不到」，一度怀疑 rootfs 的 DNS/证书 | 逐一实证：rootfs 内 `etc/resolv.conf` = `8.8.8.8` / `1.1.1.1` / `223.5.5.5`（不是 systemd 的 127.0.0.53 桩）；`etc/nsswitch.conf` = `hosts: files dns`；`etc/ssl/certs/` 有 123 个证书 + `ca-certificates.crt` 完整 bundle | **DNS 与根证书都不是原因**，排除。市场仍搜不到的真因尚未取到证据：需要应用在跑时抓 `logcat` 里 gallery/HTTPS 相关行，或让服务端自己发一次请求。此项留待下一轮，不在此收尾轮猜结论 |

| 24 | 构建链在 2/6 `aapt2 link` 处必挂：`[proroot-stub-loader] stack build failed =7`，退出码 125。**同一条命令在交互 shell 里重放却成功**，一度被误判为"间歇故障" | **已定位并解决**：PRoot stub loader 对子进程的**位置参数**有 255 个硬上限，第 256 个就在 aapt2 启动前把它打死。二分验证：255 个文件输入 link 正常，256 个必挂；把一个选项换成另一个条目不影响分界线，所以只数位置参数。旧构建每个资源文件一个 `.flat`，实际有 348 个（应用 2 + 库 346），必然越界；手动重放之所以"成功"，是因为我看的时候 `flatlib` 里只有一部分库目录。**修法**：`aapt2 compile --dir ... -o <name>.zip` 输出单个 zip 容器（Gradle 本来就这么喂 link），link 输入从 350 个降到 **17 个**，且不排除任何资源。`build10.sh` 已改，两次干净构建 `BUILD_OK`；另保留了每个 aapt2 调用的 5 次重试作保险 |

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
| 依赖校验 | jar 必须验证确实含 `.class`（`unzip -Z1 x.jar | grep -c "\.class$"`），0 个即为 metadata-only 包，不能喂给 d8 |

- **git 推送通道**：曾经只能走本地 CONNECT 代理（`gh-proxy.mjs`，`-c http.proxy=http://127.0.0.1:7891` +  `-c http.version=HTTP/1.1`），代理会间歇返回 502 / `GnuTLS recv error (-110)` / `Proxy CONNECT aborted`。2026-11-15 实测**直连 `api.github.com` 与 `github.com` 已可用**（HTTP 200，`git push` 成功 `b69d2e2..2747d4e`），代理不再是必需项。代理也不总是可靠：若再遇 502，先试直连，再考虑重启代理。

## 四、待真机验证项

- [ ] 首次启动解包 110MB 资源的实际耗时与内存峰值
- [ ] `libproot.so` 在 Android 上通过 `$ORIGIN` 找到 `libtalloc.so` / `libandroid-shmem.so`
- [ ] PRoot 用 rootfs 的 glibc 加载 `/opt/vscode/node` 是否成功
- [ ] GeckoView 加载 `http://127.0.0.1:8800/` 后工作台是否完整渲染（含文件树、终端、扩展面板）
- [ ] 集成终端能否在 PRoot 内起 shell（`/bin/bash`）
- [ ] 后台驻留 10 分钟后 serve-web 是否被系统回收