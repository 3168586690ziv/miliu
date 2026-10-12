#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"; RES="$REPO/resources/Resources"
APP="$BUILD/Miliu.app"
BIN="$APP/Contents/MacOS/SevenZZResourceDetector"

if ! command -v rg >/dev/null 2>&1; then
  rg() {
    python3 - "$@" <<'PY'
import fnmatch
import os
import re
import sys

multiline = False
globs = []
positional = []
args = sys.argv[1:]
i = 0
while i < len(args):
    arg = args[i]
    if arg == "-q":
        pass
    elif arg == "-U":
        multiline = True
    elif arg == "-g":
        i += 1
        if i >= len(args):
            sys.exit(2)
        globs.append(args[i])
    elif arg.startswith("-"):
        print(f"rg fallback: unsupported option {arg}", file=sys.stderr)
        sys.exit(2)
    else:
        positional.append(arg)
    i += 1

if len(positional) < 2:
    sys.exit(2)
pattern, roots = positional[0], positional[1:]
rx = re.compile(pattern)

paths = []
for root in roots:
    if os.path.isfile(root):
        paths.append(root)
    elif os.path.isdir(root):
        for base, dirs, names in os.walk(root):
            dirs.sort()
            for name in sorted(names):
                paths.append(os.path.join(base, name))

if globs:
    paths = [path for path in paths
             if any(fnmatch.fnmatch(os.path.basename(path), g) for g in globs)]

for path in paths:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            if multiline:
                if rx.search(handle.read()):
                    sys.exit(0)
            else:
                if any(rx.search(line) for line in handle):
                    sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
  }
fi

"$REPO/scripts/build.sh" "$APP" >/tmp/sevenzz-resource-detector-build.log
test -x "$BIN"
file "$BIN" | grep -q 'universal binary with 2 architectures'
lipo -archs "$BIN" | grep -q 'x86_64'
lipo -archs "$BIN" | grep -q 'arm64'
otool -l "$BIN" | grep -A4 LC_BUILD_VERSION | grep -q 'minos 13.0'
plutil -lint "$APP/Contents/Info.plist" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "com.sevenzz.resource-detector"
test -f "$APP/Contents/Resources/logo.png"
test -f "$APP/Contents/Resources/ResourceDetectorGlyph.png"
# 应用图标验收：配置、存在、内容一致、可解码
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" = "AppIcon.icns"
test -s "$APP/Contents/Resources/AppIcon.icns"
cmp -s "$APP/Contents/Resources/AppIcon.icns" "$RES/AppIcon.icns"
sips -g pixelWidth -g pixelHeight "$APP/Contents/Resources/AppIcon.icns" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" = "Miliu"
codesign --verify --deep --strict "$APP"

# 机器独立性：不允许再引用 SevenZZ 主 App 的偏好套件
if rg -q 'com\.sevenzz\.toolbox|initWithSuiteName' "$ROOT/App" "$ROOT/Features" "$ROOT/Shared" -g '*.m' -g '*.h'; then
  echo "FAIL: main-app preference suite dependency remains" >&2
  exit 1
fi

# 雷达特效与裸 cell 复用必须彻底移除
if rg -q 'ResourceRadarView|radar' "$ROOT/App" -g '*.m' -g '*.h'; then
  echo "FAIL: radar control remains" >&2
  exit 1
fi
if rg -q 'makeViewWithIdentifier|@"cell"' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: bare cell reuse remains in results table" >&2
  exit 1
fi

# 历史功能保持不接入
if rg -q '探测历史|showHistory|ResourceDetectorLastHistory' "$ROOT/App" "$ROOT/Shared/Infrastructure/PreferencesStore.h" "$ROOT/Shared/Infrastructure/PreferencesStore.m"; then
  echo "FAIL: history feature remains wired" >&2
  exit 1
fi

# 画质展示只保留简洁档位，实际像素分辨率元数据仍可在内部读取但不出现在界面
if rg -q '清晰度|qualityLabel|qualityText' "$ROOT/App/ResourceDetectorApp.m" "$ROOT/App/ResourceResultRowView.m"; then
  printf 'FAIL: quality UI remains\n' >&2
  exit 1
fi
rg -q 'text:@"分辨率"' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'm.pixelWidth > 0 && m.pixelHeight > 0' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'dimensionTitle.hidden = YES' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'dimensionValue.hidden = YES' "$ROOT/App/ResourceDetectorApp.m"

# 元数据必须由生产服务统一处理；App 不得回退远程 AV / URLSession 私有读取。
if rg -q 'AVURLAsset|NSURLSession|fetchDurationForMedia|fetchImageDimensionsForMedia|fetchSizeForMedia' "$ROOT/App/ResourceDetectorApp.m"; then
  printf 'FAIL: App bypasses metadata service\n' >&2
  exit 1
fi
rg -q 'subscribeMedia:m reload:reload' "$ROOT/App/ResourceDetectorApp.m"
if rg -q 'reloadCurrentMetadata:|重新读取|metadataRetryButton' "$ROOT/App/ResourceDetectorApp.m"; then
  printf 'FAIL: manual metadata reload remains\n' >&2
  exit 1
fi
rg -q 'evaluateResolvedURL:url resolvedIPs:ips' "$ROOT/Features/ResourceDetector/RDMetadataTransport.m"
rg -q 'URLAssetWithURL:local' "$ROOT/Features/ResourceDetector/RDMetadataService.m"

# 功能接线与行视图
rg -q 'startSiteBatchWithURL' "$ROOT/App/ResourceDetectorApp.m"

# 重新扫描结果重建后选中项必须被安全处置（BUG-011：reloadData 会按索引保留选中，
# 残留的旧索引会让 ⌘D 下载到与新结果对不上的"错行"资源）。探测期间列表还会先被
# 临时结果重建一次（顺序可能与最终结果不同），因此按下标保留更不可靠：现在统一在
# applyDiscoveryResult: 里重建，并按「资源身份」恢复选中，找不到就清空选中。
rg -q 'applyDiscoveryResult:r final:YES' "$ROOT/App/ResourceDetectorApp.m"
rg -U -q 'applyDiscoveryResult:\(ZZResourceDiscoveryResult \*\)result final:[\s\S]{0,2000}reloadData[\s\S]{0,800}visibleRowMatchingMedia[\s\S]{0,1200}deselectAll' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'downloadSelected' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'ResourceResultRowView' "$ROOT/App/ResourceDetectorApp.m"

# 编辑链接后旧结果必须立即失效（删除或输入不完整地址不能继续显示上一轮内容）。
rg -q 'controlTextDidChange:' "$ROOT/App/ResourceDetectorApp.m"
rg -U -q 'controlTextDidChange:[\s\S]{0,1800}removeAllObjects[\s\S]{0,500}reloadData[\s\S]{0,300}showDetailEmpty' "$ROOT/App/ResourceDetectorApp.m"

# 主页探测不使用百分比进度条；仅保留 statusNote 多阶段文字状态。
if rg -q 'discoveryProgress|discoveryProgressLabel|updateDiscoveryProgress|advanceDiscoveryProgress|stopDiscoveryProgressAnimation' "$ROOT/App/ResourceDetectorApp.m"; then
  printf 'FAIL: discovery progress bar or animation logic remains\n' >&2
  exit 1
fi
rg -q '准备读取网址' "$ROOT/App/ResourceDetectorApp.m"
rg -q '正在读取网址' "$ROOT/App/ResourceDetectorApp.m"
rg -q '正在分析页面内容' "$ROOT/App/ResourceDetectorApp.m"
rg -q '正在寻找媒体资源' "$ROOT/App/ResourceDetectorApp.m"
rg -q '正在读取详细信息' "$ROOT/App/ResourceDetectorApp.m"
rg -q '正在整理下载选项' "$ROOT/App/ResourceDetectorApp.m"
rg -q '正在准备呈现' "$ROOT/App/ResourceDetectorApp.m"
rg -q '已取消探测' "$ROOT/App/ResourceDetectorApp.m"
rg -q '探测完成 · 发现' "$ROOT/App/ResourceDetectorApp.m"
rg -q '未发现可下载资源' "$ROOT/App/ResourceDetectorApp.m"
rg -q '探测失败：' "$ROOT/App/ResourceDetectorApp.m"
# 旧探次不得覆盖新探次状态：每个探次捕获自己的 generation
rg -q 'installSessionHandlersForGeneration' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'sself.scanGeneration != generation' "$ROOT/App/ResourceDetectorApp.m"
if rg -q 'RDProgressRingView|self\.ring|setRingProgress|rd-ring' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: circular progress control remains" >&2
  exit 1
fi
# 旧"模式切换"分段控件已移除；当前设置页有三个分段控件：
# 1. 左右栏比例三档（identifier = RDPaneRatioPopup）
# 2. 探测模式「当前页/总站」（identifier = RDProbeModeControl）
# 3. 下载性能「省电/标准」（identifier = RDPerformanceModeControl，2026-10-02 第16轮新增）
# 三者都是已知的合理控件；除此以外出现任何分段控件即失败。
OTHER_SEG="$(rg -n 'NSSegmentedControl' "$ROOT/App/ResourceDetectorApp.m" \
  | grep -v 'settingsPaneRatioControl' | grep -v 'changePaneRatio' | grep -v 'ratioControl' \
  | grep -v 'settingsProbeModeControl' | grep -v 'changeProbeMode' | grep -v 'probeModeControl' \
  | grep -v 'settingsPerformanceControl' | grep -v 'changePerformanceMode' | grep -v 'perfControl' \
  | grep -v 'NSSegmentedControl segmentedControlWithLabels' || true)"
if [ -n "$OTHER_SEG" ]; then
  echo "FAIL: unexpected segmented control remains (not a whitelisted settings control):" >&2
  printf '%s\n' "$OTHER_SEG" >&2
  exit 1
fi
rg -q 'identifier = @"RDPaneRatioPopup"' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'NSSegmentedControl \*settingsPaneRatioControl' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'identifier = @"RDProbeModeControl"' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'NSSegmentedControl \*settingsProbeModeControl' "$ROOT/App/ResourceDetectorApp.m"
# 下载进度条（NSProgressIndicator）为当前合理用途，确认已接入
rg -q 'RDThinProgressView' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'metricsStringForJob:' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'self\.progressView\.progress' "$ROOT/App/ResourceDetectorApp.m"

# 危险清除操作必须先弹「是否清除」确认框（2026-09-19 定案：防误触，且清除后
# 设置页内要有就地反馈）。两个清除入口都必须经由 confirmClearWithMessage 并携带各自
# 的确认文案；确认框默认键必须是「取消」（回车绝不触发清除）。
rg -q 'confirmClearWithMessage' "$ROOT/App/ResourceDetectorApp.m"
rg -U -q 'clearDownloadRecords:[\s\S]{0,400}confirmClearWithMessage[\s\S]{0,400}是否清除下载记录' "$ROOT/App/ResourceDetectorApp.m"
rg -U -q 'clearSiteSession:[\s\S]{0,400}confirmClearWithMessage[\s\S]{0,400}是否清除网站会话' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'confirm.keyEquivalent = @""' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'cancel.keyEquivalent = @"\\r"' "$ROOT/App/ResourceDetectorApp.m"
# 清除结果就地写进设置页本行说明（statusNote 在首页，设置页里看不到）
rg -q 'clearDownloadRecordsHint.stringValue = @"已清除' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'clearSiteSessionHint.stringValue = @"已清除' "$ROOT/App/ResourceDetectorApp.m"

# ── 追更 v1（WATCH-V1-CONTRACT §1/§3.1/§3.2/§3.4）：助手 bundle 产物与双端接线（只增不改） ──
# 1) 助手 bundle 产物存在、可执行就位、其中 Info.plist LSUIElement=true（契约 §3.2：
#    LSUIElement 后台进程），且内嵌 LaunchAgent plist（契约 §3.2 固定路径，SMAppService.agent 注册用）。
HELPER_APP="$APP/Contents/Helpers/Miliu追更助手.app"
if ! test -d "$HELPER_APP"; then
  echo "FAIL: helper bundle missing: $HELPER_APP" >&2
  exit 1
fi
if ! test -x "$HELPER_APP/Contents/MacOS/SevenZZWatchAgent"; then
  echo "FAIL: helper executable missing: $HELPER_APP/Contents/MacOS/SevenZZWatchAgent" >&2
  exit 1
fi
if ! plutil -lint "$HELPER_APP/Contents/Info.plist" >/dev/null; then
  echo "FAIL: helper Info.plist is not a valid plist" >&2
  exit 1
fi
if ! test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$HELPER_APP/Contents/Info.plist")" = "true"; then
  echo "FAIL: helper Info.plist LSUIElement must be true (contract §3.2)" >&2
  exit 1
fi
if ! test -f "$HELPER_APP/Contents/Library/LaunchAgents/com.sevenzz.resource-detector.watchlist.plist"; then
  echo "FAIL: embedded LaunchAgent plist missing in helper bundle (contract §3.2)" >&2
  exit 1
fi
# SMAppService 实测（2026-10-03 安装后验收）：LimitLoadToSessionType 会令注册报
# "plist content is invalid"（Aqua 会话由系统管理），禁止再引入。
if grep -q "LimitLoadToSessionType" "$HELPER_APP/Contents/Library/LaunchAgents/com.sevenzz.resource-detector.watchlist.plist"; then
  echo "FAIL: agent plist must not contain LimitLoadToSessionType (breaks SMAppService registration)" >&2
  exit 1
fi

# 2) RDWatchlistStore 双端命中（契约 §1：App 侧与助手侧共用唯一存储，禁止第二套）。
#    App 侧：ResourceDetectorApp.m 或 RDWatchlistPage.m 至少其一；助手侧：src/Helpers 至少其一。
if ! rg -q 'RDWatchlistStore' "$ROOT/App/ResourceDetectorApp.m" "$ROOT/App/RDWatchlistPage.m"; then
  echo "FAIL: app side does not reference RDWatchlistStore (ResourceDetectorApp.m / RDWatchlistPage.m)" >&2
  exit 1
fi
if ! rg -q 'RDWatchlistStore' "$ROOT/Helpers" -g '*.m'; then
  echo "FAIL: helper side does not reference RDWatchlistStore (src/Helpers)" >&2
  exit 1
fi

# 3) 主程序追更接线：添加当前页按钮标识与跨进程唤醒通知名（契约 §3.1/§3.4）。
#    原断言把两个符号都指向 ResourceDetectorApp.m；集成裁决：按契约 §3.4，AX 标识
#    RDWatchAddCurrentPageButton 由页面主体 RDWatchlistPage.m 创建（App.m 只做切页接线），
#    通知名字面值定死在 RDWatchlistPage.m 的契约常量区、App.m 经常量 RDWatchNotificationOpenAndScan
#    接线（原断言在 App.m 只会被注释行命中，属弱断言）。新断言 = 定义处 + 接线处双命中，
#    仍是追更接线必须同时存在的两个符号，无放宽。
if ! rg -q 'RDWatchAddCurrentPageButton' "$ROOT/App/RDWatchlistPage.m"; then
  echo "FAIL: RDWatchAddCurrentPageButton not built in RDWatchlistPage.m (contract §3.4)" >&2
  exit 1
fi
if ! rg -q 'com\.sevenzz\.miliu\.openAndScan' "$ROOT/App/RDWatchlistPage.m"; then
  echo "FAIL: contract constant com.sevenzz.miliu.openAndScan not defined in RDWatchlistPage.m" >&2
  exit 1
fi
if ! rg -q 'RDWatchNotificationOpenAndScan' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: ResourceDetectorApp.m does not wire RDWatchNotificationOpenAndScan (contract §3.1)" >&2
  exit 1
fi

# 4) 第 36 轮（2026-10-12）：证书信任容错 + 下载列表深浅统一 + 排队语义。
#
# 4a. 容错层必须存在，且必须被**全部**自行发起 HTTPS 请求的链路真正接线。
#     只断言"文件存在"是弱断言——真正要防的是"容错层写了却没人用"。
#     2026-10-12 核查补漏：初版只列了元数据/下载/能力探测/预览四条，**恰好漏掉探测
#     主链最先发请求的静态腿**（RDHybridPageProbe 腿 1）——它在主人报障站点上同样会
#     -1200 随机失败（第 33 轮 P1-④「测试没覆盖生产路径」的同型复发）。现把静态腿
#     一并纳入断言，避免下次再加会话时重演同一缺口。
if [ ! -f "$ROOT/Shared/Infrastructure/RDTLSTrust.h" ]; then
  echo "FAIL: RDTLSTrust.h 缺失（第 36 轮证书容错层）" >&2
  exit 1
fi
for f in \
  "src/Features/ResourceDetector/RDMetadataTransport.m" \
  "src/Features/ResourceDownload/DownloadManager.m" \
  "src/Features/ResourceDownload/DownloadCapabilityProbe.m" \
  "src/Features/ResourceDetector/RDPreviewController.m" \
  "src/Features/ResourceDetector/StaticHTMLDiscoveryPageProbe.m" ; do
  if ! rg -q 'RDTLSTrust\.h' "$REPO/$f"; then
    echo "FAIL: $f 未引入 RDTLSTrust.h（容错层未接线）" >&2
    exit 1
  fi
done
if ! rg -q 'RDTLSHandleServerTrustChallenge' "$ROOT/Features/ResourceDetector/RDMetadataTransport.m"; then
  echo "FAIL: 元数据会话未接管 ServerTrust 挑战" >&2
  exit 1
fi
if ! rg -q 'RDTLSHandleServerTrustChallenge' "$ROOT/Features/ResourceDownload/DownloadManager.m"; then
  echo "FAIL: 下载会话未接管 ServerTrust 挑战" >&2
  exit 1
fi
if ! rg -q 'RDTLSHandleServerTrustChallenge' "$ROOT/Features/ResourceDownload/DownloadCapabilityProbe.m"; then
  echo "FAIL: 能力探测未接管 ServerTrust 挑战（会导致下载降级成单连接）" >&2
  exit 1
fi
if ! rg -q 'RDTLSHandleServerTrustChallenge' "$ROOT/Features/ResourceDetector/StaticHTMLDiscoveryPageProbe.m"; then
  echo "FAIL: 探测主链静态腿未接管 ServerTrust 挑战（该腿是最先发请求的一条）" >&2
  exit 1
fi

# 4b. 放行判据必须收敛在"吊销是唯一失败项 + SAN 涵盖 host"，
#     不得退化成"只要评估失败就放行"。
if rg -q 'credentialForTrust' "$ROOT/Shared/Infrastructure/RDTLSTrust.h"; then
  if ! rg -q 'RDTLSTrustRevocationIsOnlyFailure' "$ROOT/Shared/Infrastructure/RDTLSTrust.h" ||
     ! rg -q 'RDTLSTrustHostCoveredByCertificate' "$ROOT/Shared/Infrastructure/RDTLSTrust.h"; then
    echo "FAIL: 放行路径缺少吊销唯一性判据或 SAN 复核（容错被放宽成任意放行）" >&2
    exit 1
  fi
fi

# 4c. 下载列表不得再有逐行透明度弱化（主人点名"颜色深度统一到深色那一档"）。
#     2026-10-12 核查修订：恒返回 NO 是「半成品」形态——判据死了、方法名还在撒谎、
#     调用点 13 行三元分支成了永不可达的死代码。要求彻底删除，而不是留一个恒假壳。
if rg -q 'shouldWeakenJob' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: 仍残留 shouldWeakenJob（第 36 轮已取消行内弱化，不得留恒假壳）" >&2
  exit 1
fi
if rg -q 'weakened \?' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: 仍残留 weakened 三元分支（恒假死代码）" >&2
  exit 1
fi
# 类型防护必须仍在（弱化判据删除后，防线迁到列表排序的时间比较处）。
if ! rg -q 'isKindOfClass:\[NSDate class\]' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: 列表排序缺少 NSDate 类型防护（弱化判据删除时防线一并丢了）" >&2
  exit 1
fi

# 4d. 新任务只等预检时必须如实显示"准备中"，不能再一律说"排队中"。
if ! rg -q 'hasFreeDownloadSlotForJob' "$ROOT/App/ResourceDetectorApp.m"; then
  echo "FAIL: 缺少 hasFreeDownloadSlotForJob（排队语义未区分预检与真排队）" >&2
  exit 1
fi

# 4e. 队尾任务不得无限期停在 Queued（窗口收缩时必须有有限性兜底）。
if ! rg -q 'kRDQueueStarvationGrace' "$ROOT/Features/ResourceDownload/DownloadManager.m"; then
  echo "FAIL: 缺少排队饥饿超时兜底（队尾任务可能无限期显示排队中）" >&2
  exit 1
fi

# 4f. 链接依赖纪律（2026-10-12 第 36 轮核查新增）。
#     本项目的复发型失效：生产文件新增框架依赖后，**编译它们的脚本没跟着补**——
#     脚本从此编译不过，等于它自那一刻起再没真正跑过，而日志里还留着旧日的 PASS。
#     已发生四次：第 28 轮缺 -lsqlite3、第 35 轮缺 -framework AVKit（**两处几何探针**）、
#     第 36 轮接 TLS 容错层后 retry-after / external-scripts / preview-playback 缺 Security。
#     这里不再逐个补，而是按「生产引用关系」反推依赖，做成长效看门人。
#
#     2026-10-12 复核修复（本看门人自身的盲区）：首版只遍历 `tests/Tests/*.sh`，
#     而第 35 轮 AVKit 的两个复发点都在 `build/*-probe/*.sh`（设置页几何探针 probe.sh、
#     详情面板探针 detail-probe.sh）——**看门人全绿而探针已死**。现在扫描集合扩到两处，
#     并补一条同族断言：凡编译 `src/Features` 全树的脚本都必须链接 AVKit
#     （该目录含 RDPreviewWindow.m，它 import AVKit）。
#     请勿删除——它是这条纪律唯一的自动化看门人。
_rd_scan_scripts=$(ls "$REPO"/tests/Tests/*.sh "$REPO"/build/*-probe/*.sh 2>/dev/null)
for _suite in $_rd_scan_scripts; do
  _b="$(basename "$_suite")"
  [ "$_b" = "verify.sh" ] && continue    # verify 走 build.sh，生产构建自带全部框架
  _hit=""
  for _u in RDMetadataTransport DownloadManager DownloadCapabilityProbe RDPreviewController StaticHTMLDiscoveryPageProbe; do
    grep -qE "(^|[^A-Za-z])${_u}([^A-Za-z]|\$)" "$_suite" 2>/dev/null || continue
    if grep -q 'RDTLSTrust\.h' "$ROOT/Features/ResourceDetector/${_u}.m" 2>/dev/null ||
       grep -q 'RDTLSTrust\.h' "$ROOT/Features/ResourceDownload/${_u}.m" 2>/dev/null; then
      _hit="$_hit $_u"
    fi
  done
  if [ -n "$_hit" ] && ! grep -q '\-framework Security' "$_suite"; then
    echo "FAIL: $_b 编译了 TLS 容错层使用者($_hit) 但未链接 -framework Security（该脚本编译不过）" >&2
    exit 1
  fi
  # 同族：编译 Features 全树 ⇒ 必然收进 RDPreviewWindow.m ⇒ 必须链接 AVKit
  if grep -q 'find "\$ROOT/Features"' "$_suite" 2>/dev/null &&
     ! grep -q '\-framework AVKit' "$_suite"; then
    echo "FAIL: $_b 编译 Features 全树（含 import AVKit 的 RDPreviewWindow.m）但未链接 -framework AVKit" >&2
    exit 1
  fi
done

echo "PASS: build, universal binary, macOS 13 target, bundle signing, app icon packaged and decodable, machine independence, no radar, view-based rows, slash-line UI with thin progress, download progress, site-mode, TLS trust tolerance, download-row uniform tint, and download wiring checks"
