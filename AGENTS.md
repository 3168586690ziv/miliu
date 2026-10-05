# AGENTS.md — 资源探测：版本号与正式构建永久规则

> 本文件属于**项目本身**，不属于任何 AI、模型、聊天上下文、本机环境或临时目录。
> 任何 AI（无论何种模型/任务/上下文）或开发者在改动、构建、发布本项目之前，必须先阅读并遵守本文件。
> 本规则长期有效；修改本文件前必须获得用户明确同意。

## 0. 子智能体（Subagent）委派规则

- 本项目**允许**使用子智能体提高效率（并行独立验证、只读调研、隔离长日志），
  但**必须先读根目录 `SUBAGENT-RULES.md`** 并严格遵守。
- 该文件是**强制规则**，与本文件同等效力。委派前必须按其中的判据自行判断，
  并在动手前写出一行 `【委派决策】派 / 不派 · 理由`，使判断可被审计。
- 一句话概括：**默认自己做**；只有「不碰禁派红线 + 命中该派判据 + 通过成本闸门」三条全中才派；
  子智能体说「通过」不算通过，关键数字与结论必须自己复跑核实。
- 本节编号刻意取 `0`，避免打乱第 1–7 节的编号与文内「见第 2 节」这类互相引用。
- 若本环境不支持子智能体：直接自己做，**不降低任何验收标准**，不得跳过验证或假装派过。

## 1. 版本号格式（固定，不可更改）

- 版本号统一为：`v<代码总行数>.<修复轮数>`，例如 `v19425.7`
- 首字符必须是**小写 `v`**，禁止大写 `V`
- 主文本必须严格匹配正则 `^v[0-9]+\.[0-9]+$`（无空格、无横杠、无多余文字）
- 版本号必须出现在且一致于：设置页右下角版本控件、Info.plist
  （`CFBundleShortVersionString` 与 `CFBundleVersion`）、构建日志、最终报告

### 代码总行数（版本号第一段）

- 由正式构建脚本统一统计，**不允许人工填写**，任何 AI 不得自行更换算法
- 统计工具：`python3 scripts/count-code-lines.py`（只输出一个整数）
- 范围：`src/` 目录，扩展名 `.m` `.h` `.mm` `.c` `.cc` `.cpp` `.swift`
- 排除：`tests/`、`build/`、`outputs/`、`third_party/`、`.git/`、`DerivedData/`、临时目录
- 物理行数：空行、注释行全部计入；文件末尾无换行的最后一行也计入

### 修复轮数（版本号第二段）

- **项目历史事实**，不属于任何 AI、聊天上下文、本机环境或临时目录
- 唯一来源：项目根目录 `PROJECT_VERSION.json` 的 `fixRound`（非负整数）
- 该文件属于项目永久记录，**不得**放入 `build/`、`tmp/`、`DerivedData/` 或用户偏好

## 2. 修复轮数纪律

- **换 AI、换模型、换上下文、换任务、重新打开项目，都不得改变 `fixRound`**
- 普通测试、测试目标编译、临时构建、重复执行同一轮构建、重复执行任何验证脚本
  （verify / audit / repair / user-feedback / fix-chain / thumbnail / download-integrity /
  performance-smoke / version），**一律不得递增**
- 唯一允许递增的情形：**用户明确要求"完成一轮修复并生成可安装测试版本"**，
  通过 `bash scripts/build.sh --release-fix`（或 `bash scripts/build-release.sh --release-fix`）
  在**构建成功后**递增一次并同步 `lastReleaseVersion`
- 同一轮重复执行（`src/` 内容摘要与上次正式发布相同，见 `scripts/release-digest.py`）
  自动识别为同一轮，**不重复递增**
- 构建失败时自动恢复原计数，**不得留下递增过的错误轮数或错误 `lastReleaseVersion`**
- 不得重置为 0、不得猜测数字、不得用当前时间 / 随机数 / AI 名称 / 上下文内容推算轮数
- **无法确定历史修复轮数时，不得猜数字，必须向用户报告无法确认**
- 历史依据（不得推翻）：第 1–5 轮修复报告（原在 `outputs/` 下，**文件已不存在**，
  2026-09-17 清理时确认缺失；结论以本节及第 7 节轮次历史表为准）；第 6 轮为设置页版本号
  （v19425.6，2026-09-09，迁移自 scripts/version.conf 的 FIX_ROUND=6）

## 3. 正式构建

- 唯一正式构建入口：`scripts/build.sh`（`scripts/build-release.sh` 是它的薄包装，禁止另建第二套）
- 默认构建：`bash scripts/build.sh [输出.app 路径]` — 读取现有 `fixRound`，**不递增**（测试/重复编译安全）
- 正式发布：`bash scripts/build-release.sh --release-fix` — 构建成功后 `fixRound+1` 并写回
  `lastReleaseVersion` 与同轮摘要；构建失败自动恢复
- 构建日志必须打印且仅以这三行报告版本：
  - `CODE_LINES=<数字>`
  - `FIX_ROUND=<数字>`
  - `DISPLAY_VERSION=v<数字>.<数字>`
- 构建流程（由脚本自动完成，不得手工绕过）：
  1. 读取 `PROJECT_VERSION.json`；统计 `src/` 代码行数；计算 `DISPLAY_VERSION`
  2. 生成 `build/generated/RDGeneratedVersion.h`（设置页编译期读取，版本号不得写死在界面代码）
  3. 将版本写入 bundle Info.plist 的 `CFBundleShortVersionString` 与 `CFBundleVersion`
  4. universal（arm64 + x86_64）、macOS 13 deployment target、codesign
  5. 构建后自检：生成头 == Info.plist 两键 == 构建日志；`AppIcon.icns` 校验和不变

## 4. 设置页显示

- 版本号控件在真实设置页**右下角**：小字号（≤11pt）、浅灰低对比、不可交互、
  不遮挡任何设置控件、最小窗口尺寸（内容区 760×438）下仍在页面范围内
- 文本来自 `RD_GENERATED_VERSION_STRING`（构建期生成），每次运行期间固定，
  不在打开设置页时重新计算，不放进主探测列表

## 5. 禁止事项

- **最新版唯一规则**：电脑中只保留当前最新版 `资源探测.app`。每次覆盖安装前必须清理旧版本应用、旧安装备份和旧版构建产物；不得保留 `资源探测.app.backup-*` 或带有旧版本的可安装 `.app` 副本。下载记录、下载中的文件和用户图标不属于旧版应用，必须保留。

- 不得修改或替换用户的 **Z 字图标** `resources/Resources/AppIcon.icns`
  （SHA-256 基线：`tests/Tests/icon-checksum.txt`）
- 不得把版本号写死在界面代码里；不得只改 Info.plist 而绕过构建脚本
- 不得把修复轮数存到本机偏好、临时目录或任何 AI 会话状态
- 不得把一次普通编译说成一次新的修复轮
- 不得另建与 `PROJECT_VERSION.json` 冲突的第二套版本来源
  （`scripts/version.conf` 与 `scripts/bump-fix-round.sh` 已废弃删除，见第 2 节流程）
- 安装到 `/Applications/资源探测.app` 前：检查正在运行的实例与进行中的下载，
  不得强制终止下载、不得删除下载记录、不得修改用户图标；
  若运行中的实例是旧版本，必须向用户说明需要重启才生效

## 6. 版本规则测试

`bash tests/Tests/version.sh` 覆盖：规则文件齐备、`fixRound` 为整数、小写 `v` 严格格式、
设置页控件存在且在最小尺寸内、行数/轮数与构建日志一致、设置页与 Info.plist 一致、
`lastReleaseVersion` 一致性、默认构建不递增、同一轮重复构建不递增（隔离沙盒验证）、
`--release-fix` 只递增一次、构建失败恢复计数、与运行环境（AI/上下文）无关、图标校验和不变。

## 7. 轮次历史（永久记录）

| fixRound | 内容 | 版本 |
| --- | --- | --- |
| 1–5 | 功能排查 / 安全审查 / 真实网址 / 用户反馈 / 画质选项（原 outputs/ 报告已不存在） | — |
| 6 | 设置页版本号功能（版本体系 v1：version.conf） | v19425.6 |
| 7 | 版本规则永久化：AGENTS.md + PROJECT_VERSION.json + `--release-fix` | v19425.7 |
| 10 | 探测「正在准备呈现…」60 s 空等修复（统一呈现的就绪判定按订阅通道区分：仅预览通道只等缩略图）· 列表行摘要跟随所选画质档位 · 画质下拉缺 label 崩溃防护（报告：`outputs/fix-round-prep-20260913/REPORT.md`，**文件已不存在**） | v22307.10 |
| 11 | UI 体验：设置页左右栏比例三档（3:7 / 2:8 / 2.5:7.5，偏好键 `SevenZZKeyMainPaneRatio`，非法值回退 3:7）· 探测状态文案统一为短文本，不再显示「正在探测第 N/M 个页面：host」· 详情标题完整多行显示不省略，缩略图/字段/直链按面板实际尺寸流式排布 · 设置页与详情区在最小窗口下 0 越界 0 重叠（报告：`outputs/ui-fix-20260916/REPORT.md`） | v24151.11 |
| 12 | 真实站点抓取能力：由 91 站真实站点语料库（`tests/corpus/`，不进版本库）跑出的缺陷修复 —— ① 直链媒体/流清单地址完全探不到（静态腿改为按响应 MIME 分流，video/* 与 mpegurl/dash+xml 直接由 URL 生成媒体条目；MIME 为 text/html 时走原路径）；② 混合探测动态腿硬超时 20s → 45s（JS 单页应用实测 0 → 56 资源）；③ 静态腿 HTML 上限 2 MB → 8 MB，与 `WebProbe` / `ProductionDiscoveryHTMLProvider` 对齐。复跑 91 站：有资源 64 → 78 站，总耗时 7692s → 2513s，首屏耗时中位 0.89s（台账：`outputs/evidence-20260918/缺陷台账-全量测试.md`） | v24470.12 |
| 13 | 发布前打基础与测试（五阶段 P-A~P-E）：Cloudflare-403 栈指纹拦截双栈回退（新增 `RDAdaptiveTransport` 元数据侧 + `RDCurlFallbackBackend`/`RDCurlHopper` 下载侧，逐跳 URLPolicy + DNS 全 IP 校验、fail-closed）· 下载链路修复（ffmpeg 合流扩展名白名单、系统代理下对端校验误杀）· 探测模式「总/单」迁入设置页并持久化 · 发行加固（`ResourceDetector.entitlements` + hardened runtime）· `DNSResolver` 超时分支空指针守卫（dns-bound 实测 SIGSEGV 修复，自初始提交潜伏）· 复核：14 套件串行全绿 + 31 站真实抽检 27/31 有资源（4 站网络受限；直链 12/12 全过）（报告：`outputs/plan/P-A`~`P-E`） | v26178.13 |
| 14 | 设置页两个清除入口（一键清除下载记录 / 清除网站会话）加「是否清除」确认框（sheet 呈现；回车默认＝取消；清除按钮按系统规范标破坏性）· 清除结果就地写回本行说明（绿色「已清除…」），修复「点击清除无可见反馈」（根因：反馈只写首页 statusNote，设置页内不可见）· `verify.sh` 新增 8 条断言（两个入口必经确认框 / 回车不得触发清除 / 确认后必须写就地反馈）· 实测：14 套件串行全绿 + settings-probe 越界 0 / 重叠 0 + AX 黑盒两条路径「弹框 → 确认 → 行内变绿」 | v26234.14 |
| 15 | 设置页「下载位置」行常驻显示实际生效路径（家目录缩写 ~；自定义目录失效回退时如实标注；进入设置页与选完目录后就地刷新；AX 黑盒读回 `当前下载位置：~/Desktop`）· 画质档位 480p/720p/1080p 三档扩展为 360p~2160p 六档（容差与去重规则不变，4K/2K/低清源不再落无档；旧三档测试断言随规格同步更新）· 播放器画质表采集（scanPlayers 读 videojs currentSources / jwplayer playlist sources 的 label，`data-rd-pid` 与动态腿共享播放器身份；先 post 带标签画质表再 post 兜底 currentSrc 避开 seen 去重吞标签）· 入队磁盘检查由「剩余 < 固定阈值」补齐为「剩余 < 本批在途总量 + 保底水位」（拒绝理由带数字；纯函数化 + 新增 T32；T31「剩余未知不误拒」语义不变）· 修复两个 NSTimer 在 dealloc 未 invalidate 的保留环 · 实测：7 套件全绿（version / repair / display-matrix / thumbnail+ASan / streaming-group / download-integrity / verify 含构建），AX 黑盒设置页验证 | v26308.15 |
| 16 | 设置页「下载」卡片新增「下载性能」行（省电/标准分段控件）：性能模式体系（省电=2 连接/2 任务，标准=20 连接/5 任务分段提速）自 Seven zz 时代即在 PerformancePolicy 中但独立 App 无用户入口，现写 PreferencesStore 七ZZ键（默认 1=标准）与 Policy 读同一键；连接会话与调度器窗口创建时定值，切换对新任务部分生效、重启完全生效（行内说明写明）· verify.sh 分段控件哨兵白名单登记 `RDPerformanceModeControl` · RealSiteProbe 画质声明正则收紧为 `(\d{3,4})p(?![a-z0-9])`（排除 `1080px`/`1080playlist` 误判 FAIL，第 13 轮登记的工具遗留关闭）· 实测：verify / version / settings-probe（越界 0 / 重叠 0）全绿；AX 黑盒读回「下载性能」行与「当前下载位置」hint | v26336.16 |
| 17 | 批量 URL 探测：输入框一次粘贴多个网址（换行/空格分隔、顺序去重、上限 20）即自动进批量模式——串行逐个探测、结果按 dedupKey 跨网址去重聚合到同一列表、状态行带「批量 N/M · host」进度前缀；Esc 取消整批并保留已聚合结果（文案带完成进度）；批量模式跳过 interim 替换式呈现（防止已聚合结果闪烁消失）、不走单网址统一呈现；单网址路径行为不变（零回归）· `applyDiscoveryResult:final:` 拆出数组形态 `applyMediaList:final:` 供聚合刷新 · README 新增界面截图（docs/screenshots/）与批量/六档/预检功能描述 · 实测：user-feedback 新增 B1–B4（解析/驱动聚合/单网址零回归/取消，20 项断言）+ verify/streaming-group/repair 全绿；AX 黑盒真实窗口验证「粘贴两网址 → 回车 → 批量探测完成 · 2 个网址发现 0 个资源」 | v26450.17 |
| 21 | 系统代理与登录站点支持：① curl 回退传输（RDCurlHopper）新增系统代理参数组装（纯函数 `RDCurlProxyArgumentsForURL`：按目标协议取 HTTP/HTTPS 代理、未配置回退系统 SOCKS〔socks5h，域名解析交代理〕、例外列表与简单主机名排除、`RD_SESSION_PROXY_OVERRIDE=direct` 逃生口与下载主会话同一变量；PAC 不处理）——curl 不读 macOS 系统代理，代理网络下被墙目标在此回退路径此前不可达；② 动态腿注入脚本新增接口响应体扫描（fetch clone 副本 + XHR responseText；仅 content-type json/text/javascript；3MB 上限；source 标记 `fetch_body`/`xhr_body`）——媒体链接只存在于需登录接口 JSON 响应体内的站点（如 X/Twitter GraphQL 变体列表）由此可发现；③ 设置页「数据管理」新增「应用内浏览器」行（新组件 `RDInAppBrowserWindow`：与探测 WebView 共用 `WKWebsiteDataStore.defaultDataStore` 的可见窗口，地址栏 + 后退/前进/刷新，用户手动登录后探测自动携带会话；不读取、不打印、不导出会话内容）。新增 curl-proxy.sh（13 项）与 body-scan.sh（7 项，本地夹具服务器 + 真实 WebKit 端到端）两套件；adaptive-transport 16 项、real-webkit-redirect、repair 77 checks、download-integrity 386 项、version、verify 全绿。现场核实：下载主会话本就跟随系统代理（v28799.20 对 twimg 直链实测 2.4s 下载并通过可播放校验），此前「不走系统代理」为代理节点故障期的误判 | v29083.21 |
| 22 | 应用内浏览器窗口布局修复（用户报「点开没有地址栏，只见空白页」）：根因＝AppKit contentView **底部原点**坐标系下工具条控件被误放 y≈8（窗口底部），且从 y=0 铺起的 WKWebView 盖在其上——用户只见全幅空白 WebView。修复：工具条（后退/前进/刷新/地址栏/前往）移至窗口顶部 y=高−30 并以 NSViewMinYMargin 钉顶，webView 底部锚定 + 高度弹性，图层顺序改为 webView 在底、工具条在上 · AX 实测：pressid 打开窗口 → 地址栏 `RDInAppBrowserURLField` 与「前往」按钮均在窗口顶带（y=256@窗口顶 219），focus-text 后自动导航 x.com 成功（value 读回 `https://x.com/`） | v29084.22 |
| 23 | 设置页「应用内浏览器」行说明文字升级为**会话状态显示**（用户需求：设置页应感知已登录站点）：`refreshInAppBrowserSessionHint` 用 Apple 公开 API `fetchDataRecordsOfTypes`（仅 WKWebsiteDataTypeCookies）枚举 Cookie 数据记录的**站点域名**（WKWebsiteDataRecord.displayName），只显示域名、不读取/显示/导出任何 Cookie 值（隐私铁律不变）；无会话显示灰色「尚未有 Cookie 登录态…重启 App 不丢」，有会话显示绿色「已存 Cookie 登录态（N 个站点）：域名列表〔>4 截断〕— 登录后探测自动携带，重启 App 不丢」；刷新时机＝进设置页 + 设置页可见期间收到浏览器窗口关闭通知（新常量 `RDInAppBrowserWindowDidCloseNotification`，windowWillClose 发出，先 remove 再 add 防重复注册）+ 清除网站会话完成后归零 · 23 轮构建含 NSSet 类型警告当场修复，随 24 轮一并交付 | v29140.23 |
| 24 | 修第 23 轮构建警告（`fetchDataRecordsOfTypes:` 参数 NSArray→NSSet），零警告重建交付 · AX 实测（真实登录态）：设置页读回「已存 Cookie 登录态（2 个站点）：hanime2.org、x.com — 登录后探测自动携带，重启 App 不丢」✅ | v29140.24 |
| 25 | 设置页新增「导入浏览器登录态」行（用户拍板的一键导入）：来源扫描（BrowserClaw/Edge/Chrome/Chromium 四候选的 Default/Profile N 目录，Cookies 库计数冒烟）+ 弹出列表选择 + `RDBrowserCookieImporter` 导入器（Keychain SecItem 读取 + PBKDF2-HMAC-SHA1("saltysalt",1003) 派生 + AES-128-CBC(IV=0x20) v10 解密 + NSHTTPCookie 灌入共享会话存储；Cookie 明文只在内存，临时库用完即删，隐私铁律不变）；新增 cookie-import.sh 11 项纯函数测试（v10 解密往返/错误密钥拒绝/v11 拒绝/时间戳换算/服务名）全绿 · 首次真实导入实测：BrowserClaw 授权通过但 **0/129 全部解密失败** | v29530.25 |
| 26 | 导入器密钥自动探测：品牌名钥匙串条目解不开时回退上游 "Chromium Safe Storage"（读样例密文试解，谁解开用谁）+ 解密统计日志（仅计数与前缀分布）；构建失败一次自动回滚后零警告交付 · **真实导入仍失败**：BrowserClaw 两候选钥匙串密码 + peanuts + 160 组合参数穷举均解不开其 v10 密文；Edge 同样解不开（微软官方 Chromium 亦如此）——**【实测结论】2026 年的 Chromium 系浏览器 Cookie 已不可从钥匙串层面解密**（app-bound 时代，正是浏览器安全机制的设计目的），一键导入的「解密灌入」路线到此为止；正当替代路线＝CDP 自动化（浏览器以 headless+调试端口拉起自己解密、经 DevTools 协议导出），待主人拍板 | v29583.26 |
| 27 | 「导入浏览器登录态」改走 CDP 自动化路线（主人拍板「你现在做吧」）：新组件 `RDCdpCookieImporter`——profile **白名单复制**（Local State + 两代 Cookies 库，不带缓存/扩展）到临时目录 → 浏览器 `--headless=new --remote-debugging-port=<随机>` 拉起（无窗口、about:blank）→ 轮询 `/json/version` 就绪 → NSURLSessionWebSocketTask 连 browser 端点发 `Storage.getCookies` → 浏览器**自己解密**交出 Cookie → NSHTTPCookie 灌入共享会话存储 → 终止进程并删除临时副本；全程无钥匙串授权框、不读取加密数据（解密只在浏览器进程内）。施工中修三个真坑：① 灌入若在后台线程首次触碰 WKWebsiteDataStore，WebKit2 初始化强制主线程（runInitializationCode SIGTRAP 实测）→ 灌入段 dispatch 主线程；② per-cookie 完成回调在无网络进程环境可能迟到 → fire-and-forget（store 自身保证持久化）；③ 崩溃栈靠 DiagnosticReports .ips 定位。测试：cdp-cookie-import.sh 14 项纯函数全绿 + 临时 harness 真实端到端（Edge 124/124、BrowserClaw 101/101 全部导入，会话存储 30/55 个站点含 x.com/twitter.com）+ cookie-import.sh 回归仍绿 · App 内实弹 AX 验收：点导入 → 绿字「已导入 101 条（0 条跳过）」→ 会话站点显示 2 → 32 个站点 ✅ | v29913.27 |

> 新的正式发布轮次由 `--release-fix` 自动追加到 `PROJECT_VERSION.json`；
> 本表由当时的执行者在本节末尾补充一行，且只描述事实。
