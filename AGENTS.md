# AGENTS.md — 资源探测：版本号与正式构建永久规则

> 本文件属于**项目本身**，不属于任何 AI、模型、聊天上下文、本机环境或临时目录。
> 任何 AI（无论何种模型/任务/上下文）或开发者在改动、构建、发布本项目之前，必须先阅读并遵守本文件。
> 本规则长期有效；修改本文件前必须获得用户明确同意。

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
- 历史依据（不得推翻）：`outputs/` 下第 1–5 轮修复报告；第 6 轮为设置页版本号
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
| 1–5 | 功能排查 / 安全审查 / 真实网址 / 用户反馈 / 画质选项（见 outputs/ 报告） | — |
| 6 | 设置页版本号功能（版本体系 v1：version.conf） | v19425.6 |
| 7 | 版本规则永久化：AGENTS.md + PROJECT_VERSION.json + `--release-fix` | v19425.7 |
| 10 | 探测「正在准备呈现…」60 s 空等修复（统一呈现的就绪判定按订阅通道区分：仅预览通道只等缩略图）· 列表行摘要跟随所选画质档位 · 画质下拉缺 label 崩溃防护（报告：`outputs/fix-round-prep-20260913/REPORT.md`） | v22307.10 |
| 11 | UI 体验：设置页左右栏比例三档（3:7 / 2:8 / 2.5:7.5，偏好键 `SevenZZKeyMainPaneRatio`，非法值回退 3:7）· 探测状态文案统一为短文本，不再显示「正在探测第 N/M 个页面：host」· 详情标题完整多行显示不省略，缩略图/字段/直链按面板实际尺寸流式排布 · 设置页与详情区在最小窗口下 0 越界 0 重叠（报告：`outputs/ui-fix-20260916/REPORT.md`） | v24151.11 |

> 新的正式发布轮次由 `--release-fix` 自动追加到 `PROJECT_VERSION.json`；
> 本表由当时的执行者在本节末尾补充一行，且只描述事实。
