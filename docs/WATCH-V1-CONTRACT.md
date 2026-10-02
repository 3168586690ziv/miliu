# WATCH-V1-CONTRACT — 追更功能并行施工契约（主智能体与全部子智能体必读）

> 本文件是「追更 v1」并行施工的唯一权威契约。三个子任务（A=App 侧、B=助手侧、
> C=构建测试侧）按文件零交集切分，能并行的前提就是本契约把接口、文件名、
> 符号、控件标识全部定死。与契约冲突的实现一律返工。
> 依据：根目录 AGENTS.md、SUBAGENT-RULES.md；数据契约 RDWatchlistStore.h
> （已实现并通过 tests/Tests/watchlist.sh 25 项断言）。

## 1. 数据层（三方共用，禁止改动语义）

- 唯一存储：`RDWatchlistStore`（`src/Features/ResourceDetector/RDWatchlistStore.h`）
  - 默认路径 `~/Library/Application Support/MiliuWatchlist/watchlist.json`（sharedStore）
  - 记账入口：`recordProbeResult:fetchedKeys:error:` / `markPendingRead:` /
    `dueEntriesBeforeDate:` / `totalPendingNewCount`
- **fetchedKeys 口径（探测侧实现，B/A 共同遵守）**：结果媒体中
  `resourceKind` 为视频或清单（**不含图片**）的 `[DetectedMedia dedupKeyForURL:mediaURL]`，
  去重、保持发现顺序。

## 2. 文件边界（零交集，越界即冲突）

| 子任务 | 独占文件（新建 ★ / 修改 †） |
| --- | --- |
| A · App 侧 | †`src/App/ResourceDetectorApp.m`（只加最小接线）★`src/App/RDWatchlistPage.h` ★`src/App/RDWatchlistPage.m` †`src/Shared/Infrastructure/PreferencesStore.h` †`src/Shared/Infrastructure/PreferencesStore.m` |
| B · 助手侧 | ★`src/Helpers/RDWatchAgentMain.m` ★`src/Helpers/RDWatchAgentController.h` ★`src/Helpers/RDWatchAgentController.m` ★`src/Helpers/Helper-Info.plist` ★`src/Helpers/LaunchAgent/com.sevenzz.resource-detector.watchlist.plist` |
| C · 构建测试侧 | †`scripts/build.sh` †`tests/Tests/verify.sh` ★`tests/Tests/watch-ui.sh` |

任何子任务不得创建/修改上表之外的文件（临时文件放 /tmp）。

## 3. 符号与标识契约

### 3.1 跨进程通知（唤醒）
- 分布式通知名：`com.sevenzz.miliu.openAndScan`
- userInfo：`{ @"pageURL": <规范化地址字符串> }`
- 助手发送时机：用户点通知「查看」或点菜单未读条目后；发送顺序＝先
  `NSWorkspace` 打开觅流主 App，再 post 本通知。
- App 接收（A 实现）：`applicationDidFinishLaunching` 注册观察者；回调在主线程、
  仅当 `!self.scanning && !self.presentationPreparing` 时生效：置 `urlField` 并调
  `scan:`；generation 保护照旧，迟到/乱序通知不得打断进行中的探测。

### 3.2 助手产物（B/C 共同遵守）
- 可执行名：`SevenZZWatchAgent`；bundle id：`com.sevenzz.resource-detector.watchlist`
- Helper-Info.plist：`LSUIElement=true`、`LSMinimumSystemVersion=13.0`、
  `NSPrincipalClass=NSApplication`
- 最终布局（C 组装）：`觅流.app/Contents/Helpers/觅流追更助手.app/`
- LaunchAgent plist：label `com.sevenzz.resource-detector.watchlist`、`RunAtLoad=true`；放在助手 bundle 的
  `Contents/Library/LaunchAgents/` 内，由助手用 `SMAppService.agent` 注册/注销。
- 静音时段解析（B）：偏好字符串 `HH:mm-HH:mm`（跨零点合法，如 `00:00-08:00`）；
  字面 `off` 表示关闭静音。默认值 `00:00-08:00`。

### 3.3 偏好键（A 注册进 PreferencesStore，B 读取）
- `SevenZZKeyWatchNotifyEnabled` → `MiliuWatchNotifyEnabled`，BOOL，默认 YES
- `SevenZZKeyWatchQuietHours` → `MiliuWatchQuietHours`，NSString，默认 `00:00-08:00`

### 3.4 AX 标识（A 创建，C 断言与黑盒探针依赖）
- 主页入口按钮：`RDWatchNavButton`（标题「追更」，与「下载列表」同级切页）
- 追更页内：`RDWatchAddCurrentPageButton`、`RDWatchReloadAllButton`、
  `RDWatchTableView`、`RDWatchSettingsCard`
- 行级（`<id>` 为条目 identifier）：`RDWatchRowSwitch.<id>`、
  `RDWatchRowDelete.<id>`、`RDWatchRowViewButton.<id>`、`RDWatchRowInterval.<id>`
- 状态胶囊文案：`＋N 新资源` / `无更新` / `已暂停` / `失败：<lastError 摘要>`

### 3.5 追更页结构（A 实现基准＝已定稿预览稿）
- 工具栏：＋添加当前页（把 urlField 当前地址 upsert）、全部重探（助手未运行时
  状态行提示「助手未运行」；运行中则发通知 `com.sevenzz.miliu.watchNow` 触发立即
  轮询——B 监听同名通知）、摘要（N 个页面 · M 个未读 · 助手运行中/未运行，
  运行态检测＝NSWorkspace.runningApplications 查 bundle id …watchlist）。
- 列表行（≈58pt）：标题+地址（截断）/ 间隔分段 15·30·60·120 / 上次探测相对时间 /
  状态胶囊 / 立即重探 / NSSwitch / 删除；点「查看」或行＝标已读＋回主页＋scan:。
- 设置卡四行：开机自启（开关；实现＝助手运行时经分布式通知
  `com.sevenzz.miliu.watchService` userInfo {enabled:BOOL} 让助手注册/注销
  SMAppService；助手未运行时仅写偏好并提示下次启动生效）/ 新资源通知 /
  静音时段（分段：00:00–08:00 / 关闭）/ 判定范围（v1 固定「仅视频」，置灰注明 v2）。

## 4. 并行纪律（SUBAGENT-RULES 红线的本地化）

1. **施工期间一律不得运行** `scripts/build.sh`、`scripts/generate-version.sh`、
   `tests/Tests/*.sh`（共享生成头 `build/generated/RDGeneratedVersion.h` 会被踩踏，
   且半成品源码必然编译失败）。子任务自查仅允许
   `xcrun clang -fsyntax-only`（附必要 -I 与 -framework）与 `bash -n`。
2. 文件边界即红线：A 独占 `ResourceDetectorApp.m`，B/C 不得触碰。
3. 全部套件回归只在**集成阶段由主智能体串行**执行（一条跑完再跑下一条）。
4. git 写操作、`--release-fix`、安装/替换 `/Applications` 下任何 App、
   改 `AGENTS.md`/`SUBAGENT-RULES.md`/`PROJECT_VERSION.json`/`AppIcon.icns`
   ——一律禁止，留给用户与验收 AI。
