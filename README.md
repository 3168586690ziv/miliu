# 资源探测

## 项目简介

macOS 原生（Objective-C + AppKit）桌面应用：输入一个网址，探测该页面里的视频 / 音频 / 图片资源，
选择画质档位后下载到本地。

## 功能特性

- **真实网址探测**：静态 HTML 分析与真实 WebKit 动态渲染合并（`RDHybridPageProbe`），
  支持子页面链接提取、HLS / DASH manifest 解析、脚本内直链分析。
- **结果列表**：多页面探测（`MultiPageResourceProbe` / `ResourceDiscoveryCoordinator`），
  结果按「视频 / 图片」分类，可切换只显示视频或只显示图片；列表行摘要跟随所选画质档位。
- **画质选择**：详情区提供画质档位下拉（480p / 720p / 1080p 等），档位与资源一一对应。
- **资源详情面板**：完整标题（多行显示、不省略）、时长 / 来源 / 下载直链等字段、
  缩略图及其生成进度（`RDThumbnailGenerator`）。
- **下载管理**：多任务下载（`DownloadManager`）、断点与完整性校验（`DownloadStore`）、
  自适应传输调度（`AdaptiveTransferScheduler`）、HLS 分片流式下载（`RDStreamDownloadTask`），
  分片流由随包的 ffmpeg 合流。
- **下载列表**：与主界面同窗口的独立页面（非独立面板），含「全部 / 下载中 / 已成功 / 已失败」
  四个筛选态、进度条与指标文字。
- **统一日志**：`RDLog` 统一日志组件（分级写入、轮转、崩溃处理、诊断导出），
  设置页「日志与诊断」可直接打开日志文件。
- **设置页**：左右栏比例三档（左 3:右 7 / 左 2:右 8 / 左 2.5:右 7.5，写入偏好）、
  只显示视频 / 只显示图片、下载位置、日志与诊断；右下角显示当前版本号。

## 系统要求

- macOS 13.0 或更高版本（`LSMinimumSystemVersion` = 13.0）
- Xcode Command Line Tools（提供 `clang` / `xcrun` / `codesign`），无需完整 Xcode 工程

## 构建方式

```bash
bash scripts/build.sh
```

- 产物：`build/资源探测.app`（universal：arm64 + x86_64，ad-hoc 或本机开发者身份签名）
- 构建日志会打印且仅打印这三行版本信息：

  ```
  CODE_LINES=<src/ 代码总行数>
  FIX_ROUND=<修复轮数>
  DISPLAY_VERSION=v<CODE_LINES>.<FIX_ROUND>
  ```

- `scripts/build.sh` 是唯一构建入口，普通构建**不会**改变修复轮数（可反复执行）。
- 正式发布入口是 `bash scripts/build-release.sh --release-fix`，仅在用户确认「完成一轮修复并产出
  可安装版本」时使用；细节见 `AGENTS.md`。
- `src/Packaging/Info.plist` 中的 `CFBundleShortVersionString` 与 `CFBundleVersion`
  由构建脚本按上面的版本号写入，版本号不在界面代码里硬编码。

## 运行验收与测试

`tests/Tests/` 下是可独立运行的验收脚本，全部用 `bash` 执行，例如：

| 脚本 | 覆盖内容 |
| --- | --- |
| `version.sh` | 版本号规则专项验收（规则文件、行数/轮数一致性、默认构建不递增等） |
| `repair.sh` | 修复轮综合验收（生产类聚焦断言） |
| `verify.sh` | 已移除功能的回归防护（源码与产物中不得再出现历史控件与逻辑） |
| `ui-experience.sh` | UI 体验专项（分栏比例 / 探测状态文案 / 详情标题 / 设置页稳定） |
| `unified-presentation.sh` | 统一呈现与画质变动刷新 |
| `rdlog.sh` | 统一日志（RDLog）回归 |
| `download-integrity.sh` | 下载完整性（143 字节事故回归） |
| `download-e2e.sh` | 受控本地下载的行级验收 |
| `download-page.sh` / `download-list-ui.sh` | 下载列表页面与筛选态界面回归 |
| `real-site.sh` | 真实网址现场复现/验收（真实网络，手动运行） |
| `real-webkit-redirect.sh` / `redirect-policy.sh` | 重定向策略与真实 WebKit 跳转 |
| `dns-bound.sh` / `peer-binding-unit.sh` | DNS 绑定与传输对端绑定 |
| `thumbnail.sh` / `display-matrix.sh` / `streaming-group.sh` | 缩略图、显示矩阵、流式页面回归 |
| `fix-chain.sh` / `user-feedback.sh` | 历史修复链与用户反馈项回归 |
| `audit.sh` / `bug16.sh` | 生产源码审计（ASan 下运行 AuditChecks）与 Bug16 聚焦回归 |
| `external-scripts.sh` / `performance-smoke.sh` | 外部脚本调用与性能冒烟 |
| `run-suites.sh` | 批量运行上述脚本（`bash tests/Tests/run-suites.sh <suite>...`） |

**这些脚本必须串行执行，不能并行。** 其中 `repair.sh`、`ui-experience.sh`、`version.sh` 以及
`build/settings-probe/probe.sh` 在开始时会各自重跑 `scripts/generate-version.sh`，
覆写同一个生成文件 `build/generated/RDGeneratedVersion.h`；并行运行会互相踩踏，导致
版本头内容与正在编译的源码不一致，出现难以复现的失败。一条跑完再跑下一条。

`build/` 下另有本项目自有的取证工具（`settings-probe/`、`ui-probe/`、`detail-probe/`），
用法见 `build/TOOLS.md`。这些工具脚本用 `REPO="$(cd "$(dirname "$0")/../.." && pwd)"`
反推仓库根，不依赖任何本机绝对路径。

## 版本号规则

版本号固定为 `v<src/ 代码总行数>.<修复轮数>`（首字符是小写 `v`），例如 `v24400.11`。

- 代码总行数由 `python3 scripts/count-code-lines.py` 统计，不允许人工填写。
- 修复轮数是项目历史事实，唯一来源是根目录 `PROJECT_VERSION.json` 的 `fixRound`，任何 AI
  或开发者都无权递增；只有 `--release-fix` 在构建成功后才递增一次。
- 版本号需同时出现在：设置页右下角版本控件、bundle `Info.plist`、构建日志。

完整规则与实施细则见 [`AGENTS.md`](AGENTS.md)（项目永久规则）。

## 目录结构

| 目录 | 作用 |
| --- | --- |
| `src/` | 应用源码。`App/` 主控制器与窗口、`Features/ResourceDetector/` 探测、`Features/ResourceDownload/` 下载、`Shared/` 基础设施与自绘 UI、`Packaging/Info.plist` |
| `tests/` | 自动化验收脚本与测试源码（`tests/Tests/`），含夹具服务器与 FFI 无关的纯脚本用例 |
| `scripts/` | 构建与版本辅助脚本：`build.sh`（唯一构建入口）、`build-release.sh`、`generate-version.sh`、`count-code-lines.py` 等 |
| `resources/` | 运行所需资源：应用图标、图形资源，以及 `MediaTools/` 下的预编译 ffmpeg |
| `third_party/` | 第三方组件源码：`ThirdParty/ffmpeg/`（ffmpeg 源码包与构建脚本） |
| `build/` | 构建产物目录（已被 `.gitignore` 忽略）。仅 `build/TOOLS.md` 与 `build/{settings,ui}-probe/` 下的工具源码例外，用 `git add -f` 纳入版本库 |
| `outputs/`、`work/`、`tmp/` | 本地报告、整理过程与临时文件，不纳入版本库 |

界面为纯代码构建（无 xib / storyboard）。布局以手工 frame 计算为主，
列表行 `ResourceResultRowView`、玻璃容器 `GlassSurfaceView`、顶栏 `ZZTopNavigationView`
等少数视图使用 Auto Layout 约束。

## 第三方组件与许可

- **ffmpeg 8.0**：`third_party/ThirdParty/ffmpeg/` 内含官方源码包 `ffmpeg-8.0.tar.xz`
  与构建脚本 `build.sh`；`resources/Resources/MediaTools/ffmpeg` 是由该源码包构建出的
  arm64 + x86_64 通用可执行文件（未修改源码，关闭了网络协议与自动探测）。
- 许可：**LGPL version 2.1 or later**。许可文本见
  `resources/Resources/MediaTools/COPYING.LGPLv2.1`，来源与校验信息见同目录 `NOTICE.txt`。
- 该二进制仅用于把 HLS 分片合流成 MP4 等本地操作，不对外提供 ffmpeg 的公开接口。

## 许可证

本项目使用 **MIT License**：允许使用、复制、修改和分发，但需保留版权声明与许可证文本。
协议全文见 [`LICENSE`](LICENSE)。

注意：MIT 仅覆盖本项目自身代码；`third_party/` 下的 ffmpeg 源码包与
`resources/Resources/MediaTools/ffmpeg` 二进制仍遵循 LGPL v2.1+，见上一节。

## 已知限制

- **历史修复清单中有 14 项仅改动代码、尚未取得运行时验证证据**。这些项的结论来自静态改动与
  编译通过，**不等于**已通过运行时验收；如需采信，请按上一节的脚本自行复跑。
- 测试脚本**必须串行**执行（原因见「运行验收与测试」一节），并行会因共享生成头而互相踩踏。
- `resources/Resources/MediaTools/ffmpeg` 是预编译二进制，其内部字符串包含构建时的本机路径，
  无法修改。这不影响功能，属于公开仓库中的已知例外。
- 探测与下载依赖真实网络与目标站点结构；站点改版或反爬策略变化可能导致探测结果变化，
  此类失败不代表程序缺陷。
- 构建产物为本机签名（或 ad-hoc 签名），**未做 Apple 公证**，在其他机器首次打开时
  可能需要在「系统设置 → 隐私与安全性」中手动放行。
- 界面布局为手工 frame 与少量 Auto Layout 混用，最小窗口尺寸（内容区 760×438）下的
  几何回归由 `build/settings-probe/` 与 `build/ui-probe/` 的探针脚本保障，未纳入自动化门禁。
