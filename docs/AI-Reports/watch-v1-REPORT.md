# 追更 v1 施工报告（watch-v1-REPORT）

> 写给验收者（小肥鱼）：本报告由主智能体在 A/B/C 三方并行完工后串行集成产出。
> 所有退出码与关键输出均为主智能体本人复跑取得（子智能体交回的「通过」未直接采信，
> 见 SUBAGENT-RULES.md §5）。工作树保持未提交，等验收。
> 报告时间：2026-10-03 · 最终构建版本 v28698.18 · fixRound 全程未变（18）

## 0. 一句话结论

追更 v1 三方（App 侧 / 常驻助手 / 构建测试）按契约完工并集成：7 套件串行全绿、
黑盒验证（AX 标识 / JSON 入库 / 助手探测）全部通过、数据层零改动、
fixRound / 图标 / 两份规则文件零改动。集成期修复 6 处跨文件断裂（§3），
断言零删改（1 处断言文件指向修正，见 §3.4）。

## 1. 三方改动清单（并行施工，文件零交集已核实）

集成首检 `git status --porcelain` 仅含下表文件，与契约 §2 完全一致（无越界）。

### A · App 侧（子智能体 A 交回，集成复核通过）
| 文件 | 类型 | 内容 |
| --- | --- | --- |
| src/App/RDWatchlistPage.h | 新建 59 行 | RDWatchlistPageController 接口、RDWatchlistPageDelegate 协议、契约常量（openAndScan/watchNow/watchService/助手 bundle id，字面值定死） |
| src/App/RDWatchlistPage.m | 新建 875 行 | 页面全部构建与数据逻辑：工具栏/列表行 58pt/间隔分段 15·30·60·120 改动即持久化/状态胶囊（＋N 新资源·无更新·已暂停·失败摘要）/设置卡四行；「查看/行点按」=markPendingRead+回主页+填址 scan:；助手运行态=NSWorkspace 查 com.sevenzz.resource-detector.watchlist |
| src/App/ResourceDetectorApp.m | +94/−3 | 仅最小接线：import、协议一致、3 property、3 方法声明、dealloc 补分布式 removeObserver、buildWatchlistPage、applicationDidFinishLaunching 注册 openAndScan 观察者（主线程 + !scanning && !presentationPreparing 门 + generation 保护）、RDWatchNavButton（照「⌘L 下载列表」footer 模式）、showSettingsPage:/showDownloads: 各 1 行 hidden 互斥、追更页 #pragma 段（切页/回主页/填址 scan:/唤醒接收） |
| src/Shared/Infrastructure/PreferencesStore.h/.m | +2/+6 | 契约 §3.3 两键：SevenZZKeyWatchNotifyEnabled=MiliuWatchNotifyEnabled（Bool/YES）、SevenZZKeyWatchQuietHours=MiliuWatchQuietHours（String/00:00-08:00），allKeySpecs 登记。核实工程无「常量名→实际键」映射层，常量值即 defaults 键 |

### B · 助手侧（子智能体 B 交回，集成复核通过）
| 文件 | 类型 | 内容 |
| --- | --- | --- |
| src/Helpers/RDWatchAgentMain.m | 新建 | main：NSApplication accessory 装配，controller 挂 delegate |
| src/Helpers/RDWatchAgentController.h/.m | 新建 ~660 行 | NSStatusItem 菜单（头部状态行/未读条目区点按=标已读+唤起/立即全部重探/暂停恢复/管理观察列表/退出助手；角标=totalPendingNewCount 以按钮标题「追更 N」呈现）；60s tick→dueEntriesBeforeDate:→RDHybridPageProbe 离屏探测（主线程 NSAssert、并发 1、45s 双层超时：动态腿 hardTimeout + 看门狗兜底）；fetchedKeys 按契约 §1（Video/Manifest，dedupKeyForURL，去重保序）→recordProbeResult；UN 通知 identifier=条目 id 先撤再挂；分布式监听 watchNow/watchService（SMAppService agentServiceWithPlistName: 注册/注销）；静音解析 HH:mm-HH:mm 跨零点/off/默认 00:00-08:00/失败回默认；唤起=NSWorkspace 打开主 App（bundleURL 上溯三级，兜底 URLForApplicationWithBundleIdentifier）→1s 宽限→post openAndScan {pageURL 原样} deliverImmediately:YES；偏好按主 App bundle id 作 suite 读（与 A 侧键域一致，集成核实） |
| src/Helpers/Helper-Info.plist | 新建 | CFBundleIdentifier=com.sevenzz.resource-detector.watchlist、CFBundleExecutable=SevenZZWatchAgent、LSUIElement=true、LSMinimumSystemVersion=13.0、NSPrincipalClass=NSApplication |
| src/Helpers/LaunchAgent/com.sevenzz.miliu.watchlist.plist | 新建 | Label=com.sevenzz.miliu.watchlist、RunAtLoad=true、LimitLoadToSessionType=Aqua、AssociatedBundleIdentifiers=[com.sevenzz.resource-detector]；不写 Program/ProgramArguments（SMAppService agent 契约：launchd 从包含 bundle 解析可执行） |

### C · 构建测试侧（子智能体 C 交回，集成复核通过）
| 文件 | 类型 | 内容 |
| --- | --- | --- |
| scripts/build.sh | +63/−1（含集成修复 §3） | 主 bundle 流程后追加：助手源守卫→编 SevenZZWatchAgent（universal/macOS 13，ResourceDetector 全目录+Shared 同组基础件）→组装 觅流.app/Contents/Helpers/觅流追更助手.app（Info.plist+内嵌 LaunchAgent 至 Contents/Library/LaunchAgents/）→同策略签名助手+重签外层→追加 7 条构建后自检（bundle/可执行/LSUIElement/bundle id/LaunchAgent 存在与 Label）。插入点在 --release-fix 写轮数之前：助手失败→构建非零退出→轮数记录不写+事务回滚 |
| tests/Tests/verify.sh | +55/−0 | 9 条新断言（详见 §3.4） |
| tests/Tests/watch-ui.sh | 新建 224 行 | 离屏生产类探针（heredoc 内嵌，照 settings-probe 模式），U1–U7 共 18 项 Check（详见 §3.5）。施工期未运行，集成首跑通过 |

## 2. 集成编译记录

1. **首构建失败（链接期）**：`Undefined symbols: _OBJC_CLASS_$_RDWatchlistPageController / _RDWatchNotificationOpenAndScan`——主 bundle 编译清单缺新 TU RDWatchlistPage.m。版本事务自动回滚正常（"FAIL: 构建失败，已恢复 JSON、源码 plist 与生成版本状态"），fixRound 未动。
2. **修复后构建成功**：`bash scripts/build.sh` → EXIT=0，`CODE_LINES=28689 FIX_ROUND=18 DISPLAY_VERSION=v28689.18`，Built build/觅流.app（含内嵌助手）。
3. **AX 修复后重建**（§3.6，+9 行）→ EXIT=0，v28698.18；主 bundle 与助手 Info.plist 版本键一致（均 v28698.18，PlistBuddy 读回）。
4. 语法全查：5 个改动 .m 全部 `xcrun clang -fsyntax-only`（build.sh 完整 -I 集合）EXIT=0、零输出；3 个脚本 `bash -n` 全过；2 个 plist `plutil -lint` OK。

## 3. 集成期修复（主智能体串行，逐条留痕）

### 3.1 scripts/build.sh 主 bundle 编译清单
`SRC=(ResourceDetectorApp.m ResourceResultRowView.m …)` 追加 `"$SRCROOT/App/RDWatchlistPage.m"`。
原因：App.m #import 其头文件并引用其类/常量，缺 TU 即链接失败（见 §2.1）。

### 3.2 scripts/build.sh 助手编译行补框架
追加 `-framework UserNotifications -framework ServiceManagement`。
原因：RDWatchAgentController.m 使用 UNUserNotificationCenter/SMAppService，缺了链接期未定义符号。

### 3.3 scripts/build.sh 助手版本键覆写
Helper-Info.plist 拷入 bundle 后用 PlistBuddy 把 CFBundleShortVersionString/CFBundleVersion 覆写为本次 $DISPLAY_VERSION。
原因：源 plist 里的历史快照（v26482.18）会随轮次漂移；对齐 AGENTS.md §3「版本写入 bundle Info.plist」一致性要求。

### 3.4 tests/Tests/verify.sh 断言修正（唯一断言语义调整，按 SUBAGENT-RULES §6.7 申报）
- 原断言⑧：`RDWatchAddCurrentPageButton` 出现在 ResourceDetectorApp.m → **新断言**：出现在 RDWatchlistPage.m。
  理由：契约 §3.4 该 AX 标识由页面主体创建，App.m 只做切页接线（集成 grep 实证 App.m 无此串）；仍断言标识存在于 App 侧源码，非放宽。
- 原断言⑨：`com.sevenzz.miliu.openAndScan` 字面在 ResourceDetectorApp.m → **新断言**：字面在 RDWatchlistPage.m（常量定义处）**且** App.m 引用常量 `RDWatchNotificationOpenAndScan`（真实接线处）。
  理由：原断言在 App.m 只会被一行注释命中（弱断言）；新双命中更严。
- 其余 7 条助手 bundle 断言 + 2 条双端 RDWatchlistStore 命中断言原样保留，全为新增（`git diff --numstat`: verify.sh 55 0 / build.sh 既有行未删）。

### 3.5 13 个既有测试/探针脚本补编译单元（零断言改动）
version.sh、repair.sh、ui-experience.sh、user-feedback.sh、display-matrix.sh、download-e2e.sh、thumbnail.sh、streaming-group.sh、unified-presentation.sh、audit.sh、real-site.sh、fix-chain.sh、build/settings-probe/probe.sh —— 各 1 行：SRC 列表在 `"$ROOT/App/ResourceResultRowView.m"` 后追加 `"$ROOT/App/RDWatchlistPage.m"`。
原因：这些脚本的探针 .m `#import "../../src/App/ResourceDetectorApp.m"`，App 源新增了对 RDWatchlistPage 符号的引用，不补 TU 全部链接失败（version.sh 首跑即证实，set -e 静默退出 1）。修改仅编译清单，断言零触碰（逐文件 numstat 均 1/1）。download-page.sh 为纯 rg 断言、download-list-ui.sh 与 performance-smoke.sh 不编译 App 源，无需改。

### 3.6 RDWatchlistPage.m 设置卡 AX 容器覆写（黑盒发现）
普通 NSView 容器被 AX 桥裁剪，`RDWatchSettingsCard` 标识无法被 AX 定位（契约 §3.4 黑盒要求「各标识可定位」）。给 RDWatchSettingsCardView 加：
`isAccessibilityElement=YES + accessibilityRole=AXGroup + accessibilityChildren=未忽略子视图`。
黑盒复验：卡片标识与三个子控件标识（RDWatchAutoLaunchSwitch/RDWatchNotifySwitch/RDWatchQuietHoursControl）同时可定位。watch-ui.sh 复跑仍全绿。

## 4. 套件回归（最终源码态串行复跑，一条跑完再跑下一条）

第一轮串行（AX 修复前）同样全绿；AX 修复后为使验收证据与最终源码一致，7 套件全部重跑。
日志：/tmp/final-*.log（watchlist / watch-ui / verify / version / repair / user-feedback / download-integrity + final-suites.log 汇总）。

| 套件 | 命令 | 退出码 | 输出摘要 |
| --- | --- | --- | --- |
| 1 watchlist | `bash tests/Tests/watchlist.sh` | 0 | 25 项 PASS，"PASS: watchlist contract tests exited 0" |
| 2 watch-ui | `bash tests/Tests/watch-ui.sh` | 0 | 18 项 Check 全 PASS（U1–U7），"PROBE DONE" |
| 3 verify | `bash tests/Tests/verify.sh` | 0 | 含完整构建+签名+9 条追更新断言，"PASS: build, universal binary, …, download wiring checks" |
| 4 version | `bash tests/Tests/version.sh` | 0 | "PASS: --release-fix 纪律（默认不递增/发布恰好递增一次/同轮重复不递增/失败恢复原计数）"、"PASS: 设置页版本号与构建产物、Info.plist、构建日志一致（v28698.18），Z 字图标未修改" |
| 5 repair | `bash tests/Tests/repair.sh` | 0 | "REPAIR-CORE-PASSED checks=74"、"PASS: ASan local test executable exited 0" |
| 6 user-feedback | `bash tests/Tests/user-feedback.sh` | 0 | "PASS: ALL USER-FEEDBACK TESTS"、"PASS: 用户反馈专项测试退出 0" |
| 7 download-integrity | `bash tests/Tests/download-integrity.sh` | 0 | "== 全部 386 项检查通过 =="、"PASS: 下载完整性隔离测试全部通过" |

## 5. 黑盒验证证据（build/ 产物实跑，未安装任何 App）

工具：tests/Tests/UIDrive.m 编译至 /tmp/UIDrive（AX 驱动）+ python3 读 JSON。

1. **AX 标识可定位（契约 §3.4）**
   - `open build/觅流.app` → `UIDrive <app> dump`：主页含 `AXButton title=追更 id=RDWatchNavButton`。
   - `press AXButton 追更` → dump：`RDWatchAddCurrentPageButton`、`RDWatchReloadAllButton`、`RDWatchTableView`、`RDWatchSettingsCard` 四标识逐一命中（AXStaticText 摘要「0 个页面 · 0 个未读 · 助手未运行」+ 状态行「助手未运行 · 助手启动后开始定时重探」同步可见）。
   - 入库一行后 dump：行级标识与契约格式逐字符一致——`RDWatchRowViewButton.<uuid>`、`RDWatchRowSwitch.<uuid>`、`RDWatchRowDelete.<uuid>`（uuid=条目 identifier 原文）。
2. **添加当前页入库**
   - 回主页 → focus-text + keystroke `https://example.com/` → 进追更页 `press "＋ 添加当前页"` → 状态行「已添加当前页到追更」。
   - `~/Library/Application Support/MiliuWatchlist/watchlist.json` 实际新增条目：url=https://example.com（入库归一化去尾斜杠）、intervalMinutes=30、enabled=true、videoOnly=true。
3. **直接运行助手可执行**
   - `build/觅流.app/Contents/Helpers/觅流追更助手.app/Contents/MacOS/SevenZZWatchAgent` 直接后台运行 → 进程存活；System Events 实证 LSUIElement 状态项存在：`menu bar item 追更 of menu bar 1 of application process SevenZZWatchAgent`（角标=0 未读 → 标题「追更」无数字，符合「角标=totalPendingNewCount」语义）。
   - **自动首轮 tick**（启动 3s）：助手日志「开始探测 https://example.com → WebKit 会话开始 → 页面探测成功 html=1974 字节 → 探测完成 键=0 新增=0 错误=-」；JSON lastProbeAt 由 "" → `2026-10-03T02:36:17+08:00`，lastResultAt 同步、无 lastError。
   - **App→助手 watchNow 链路**：追更页 `press "↻ 全部重探"` → 状态行「已请求助手立即重探」→ 助手日志出现新探测（02:36:51，距上轮 34s，非 60s tick 周期）→ lastProbeAt 更新为 `2026-10-03T02:36:51+08:00`。
   - **运行态显示**：切页重进后摘要变「1 个页面 · 0 个未读 · 助手运行中」、状态行「助手运行中 · 到点自动静默重探」。
   - **删除动线**：`press 删除`（行内按钮，AX role=AXUnknown、title 可定位）→ JSON entries 归 0（与黑盒前基线一致，真实存储零残留）→ 摘要实时刷新「0 个页面」。
   - **退出助手**：System Events 点菜单「退出助手」→ 进程退出，日志「退出（注销 LaunchAgent）」（未注册状态下 SMAppService 注销报「Invalid argument」警告后照常退出，见 §6）。
4. 未触碰 /Applications 下任何 App；黑盒对真实 watchlist.json 的净变更=0（加一条→删一条，中间态均有证据）。

## 6. 已知边界与待裁决问题

### 6.1 A 侧报来的裁决项（集成核实后维持现状）
1. **开机自启持久化键**：契约 §3.3 只定两键，任务限定 PreferencesStore「仅加两键」→ 自启期望状态用原生键 `MiliuWatchAutoLaunch`（standardUserDefaults，缺省视为 YES）。设置卡开关读该键；注册/注销经 com.sevenzz.miliu.watchService 通知由助手执行。若要登记进 PreferencesStore 需裁决后小改一处常量。
2. **行内「立即重探」**与「全部重探」同发 watchNow；`RDWatchRowReprobe.<id>` 及 RDWatchBackButton/RDWatchEmptyLabel/RDWatchAutoLaunchSwitch 等为契约外追加标识（不影响 §3.4）。
3. **配色**：预览稿深色 vs App 强制 Aqua 浅色 → 结构尺寸 1:1、配色沿用 App 主题（契约 §3.5 未定配色）。静音时段做两段（00:00–08:00/关闭），未做预览稿「自定义」第三段。行删除无确认框（契约未要求）。
4. **数据层已知限制（禁改语义故未动）**：store 无公开 reload API——助手改盘后 App 端展示快照要到下一次任意 store 变更/进页刷新才更新（黑盒观察一致：页面打开期间助手启动，摘要需重进页面才变「助手运行中」）；updateEntry 整行替换与助手并发写入存在窗口竞态（行动作已改为动作时刻取 store 最新条目缩小窗口）。v2 若做多进程实时同步需 store 层加变更通知。

### 6.2 B 侧报来的裁决项（集成核实后维持现状）
1. **偏好域**：助手按主 App bundle id（com.sevenzz.resource-detector）作 suite 读偏好；与 A 侧键落点核实一致。
2. **LaunchAgent plist 无 ProgramArguments**：符合 SMAppService agent 契约（launchd 从包含 bundle 解析）。真实注册路径**未实测**（见 6.4）。
3. **冷启动竞态**：openApplicationAtURL completion 后固定 1.0s 宽限再投 openAndScan，一次性不重试。若实测冷启动偶发丢通知，建议 App 侧就绪回执或带 token 有限重试。
4. **退出助手的注销警告**：助手从未注册过 LaunchAgent 时点「退出助手」，unregister 返回 Invalid argument（已日志 warn）后照常退出——语义无害；如需完全静音可在退出路径对 NotRegistered/NotFound 状态再细分。
5. **角标形态**：NSStatusItem 无独立 badge API，以按钮标题「追更 N」呈现（N=totalPendingNewCount）。如需图形角标需自绘 NSImage，请裁决。
6. **静音窗口 start==end** 视为零长度不静音（off 是明确关闭字面量）；通知未设 sound（授权申请含 Sound 备用）。

### 6.3 C 侧报来的裁决项（集成已处理）
1. build.sh 插入点在 --release-fix 之前（助手失败则轮数记录根本不写）——采纳，理由见文件注释与 §2.1 实证回滚。
2. 外层重签：助手组装后按同一策略重签 $OUT，否则 verify.sh 既有 `codesign --verify --deep --strict` 必挂——采纳，既有 codesign 段零改动（黑盒与套件实证签名全过）。
3. 助手编译清单「宁可多含」整目录：未收缩；如需最小化按 B 实际 #import 收缩即可（不改断言）。
4. U2/U4 的 API 假设：C 预告会 FAIL——集成已按 A 真实 API（initWithFrame:delegate: + prepareForShow + pageView）重写探针该段，并以 sharedStore「播种→删除→基线核对」方案支撑行级抽查（§3.5 模式之外的探针正文修改，仅 watch-ui.sh 新文件内部，无既有断言）。

### 6.4 未验证项（如实声明，禁止「应该没问题」）
1. **系统通知实弹链路**：UNUserNotificationCenter 授权弹窗/横幅/点按「查看」唤醒（B 的 didReceive→markPendingRead→唤起→openAndScan 全链）——黑盒环境无真实新增资源且未交互授权，仅代码路径+语法+编译验证。**未验证**。
2. **SMAppService 真实注册/注销**（开机自启端到端）：需安装到常规位置并用户确认登录项，黑盒明确禁止安装。**未验证**。
3. **openAndScan 唤醒实弹**：分布式观察者注册代码在（applicationDidFinishLaunching 黑盒可复核），但「助手→App 唤起并自动探测」全链未实测。**未验证**。
4. **跨零点/自定义静音时段实弹**：解析函数为纯逻辑且单进程可测，但未做独立用例；watch-ui 探针覆盖 store 语义未覆盖静音解析。**未验证**（建议验收者如关注可加纯函数断言）。
5. 套件外脚本（adaptive-transport、bug16、dns-bound、download-e2e、external-scripts、rdlog、real-site、real-webkit-redirect、redirect-policy、retry-after、streaming-group、thumbnail、unified-presentation、audit、fix-chain、display-matrix、ui-experience、download-list-ui、peer-binding-unit、performance-smoke）本轮未跑（任务指定 7 套件）；其中编译 App 源的 10 个已按 §3.5 补 TU 并 `bash -n` 通过，验收者跑全量时如遇问题优先核对该清单。

## 7. 工作树状态（完成态＝留改动不提交）

`git status --porcelain`（验收时刻）：
- 契约 §2 内：M scripts/build.sh、M src/App/ResourceDetectorApp.m、M src/Shared/Infrastructure/PreferencesStore.h/.m、M tests/Tests/verify.sh、?? src/App/RDWatchlistPage.h/.m、?? src/Helpers/（5 文件）、?? tests/Tests/watch-ui.sh
- 集成修复（§3）：M tests/Tests/{version,repair,ui-experience,user-feedback,display-matrix,download-e2e,thumbnail,streaming-group,unified-presentation,audit,real-site,fix-chain}.sh、M build/settings-probe/probe.sh（各 +1 行 TU）
- 构建脚本既有行为的产物：M src/Packaging/Info.plist（两版本键 26482→28698，build.sh 既有「源码 plist 同步写入」逻辑所致，非手工编辑）

版本红线核对：PROJECT_VERSION.json fixRound=18 全程未动；lastReleaseVersion=v26482.18 未动（默认构建不写）；AppIcon.icns 不在改动清单（checksum 断言全绿）；AGENTS.md/SUBAGENT-RULES.md 未动；无 git 写操作；未安装任何 App。
