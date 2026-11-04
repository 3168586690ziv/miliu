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
# 4g TLS 容错不被 ATS 架空（2026-10-13 真机 P0）：bundle 进程里 ATS 会独立于 delegate 的
# 信任结论再做一次系统信任评估并否决（实测日志 "ATS failed system trust" → -9802 → -1200），
# 第 36 轮的容错层因此对静态腿完全失效——站点证书被 Apple 判「已吊销」时 0 资源。
# 裸二进制无主 bundle、不加载 ATS 策略，其它套件照不出此缺陷，故这里做成结构性断言。
# 安全边界不变：scheme/SSRF/file:// 仍由 URLPolicy 拦截，证书信任仍由 RDTLSTrust 窄容错把关。
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$APP/Contents/Info.plist")" = "true"
# 同族：源 Packaging/Info.plist 必须同步携带（build.sh 直接拷贝该文件，漏源文件则下次构建回退）
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$ROOT/Packaging/Info.plist")" = "true"
# 4h 站点模式批次进度必须真被读取（2026-10-13 第 42 轮）。协调器一直在算
# requested/completedListingPageCount 与 usedCurrentPageFallback，但全项目**没有任何
# 读取点**——完成文案只写「发现 N 个资源」，用户分不清 12 个列表页成了几个还是只成了 3 个；
# 而且批次层从不设置 usedCurrentPageFallback（只写到单页结果），算出来等于不存在。
# 四条断言守**真实读取/写入点**（带 `result.` / `batch.` 前缀 —— 注释里裸写类名或
# 字段名不能满足它们；首版只写字段名，注释即可顶替，属假绿，已收紧）。
# 变异验证：把任一处读取点删掉 ⇒ 本套件立即红；恢复 ⇒ 绿。
rg -q 'result\.requestedListingPageCount' "$ROOT/App/ResourceDetectorApp.m" || { echo "FAIL: 站点模式完成文案未读列表页请求数（有数据无出口）" >&2; exit 1; }
rg -q 'result\.completedListingPageCount' "$ROOT/App/ResourceDetectorApp.m" || { echo "FAIL: 站点模式完成文案未读列表页完成数（有数据无出口）" >&2; exit 1; }
rg -q 'result\.usedCurrentPageFallback' "$ROOT/App/ResourceDetectorApp.m" || { echo "FAIL: 站点模式完成文案未读回退标志（有数据无出口）" >&2; exit 1; }
rg -q 'batch\.usedCurrentPageFallback = YES' "$ROOT/Features/ResourceDetector/DiscoverySessionController.m" || { echo "FAIL: 批次结果未汇入回退标志（批次层永不设置）" >&2; exit 1; }
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
# 旧"模式切换"分段控件已移除；当前设置页有四个分段控件：
# 1. 左右栏比例三档（identifier = RDPaneRatioPopup）
# 2. 探测模式「当前页/总站」（identifier = RDProbeModeControl）
# 3. 下载性能「省电/标准」（identifier = RDPerformanceModeControl，2026-10-02 第16轮新增）
# 4. Referer 强度「仅域名/完整地址/不发送」（identifier = RDRefererModeControl，热链保护站点救回）
# 四者都是已知的合理控件；除此以外出现任何分段控件即失败。
OTHER_SEG="$(rg -n 'NSSegmentedControl' "$ROOT/App/ResourceDetectorApp.m" \
  | grep -v 'settingsPaneRatioControl' | grep -v 'changePaneRatio' | grep -v 'ratioControl' \
  | grep -v 'settingsProbeModeControl' | grep -v 'changeProbeMode' | grep -v 'probeModeControl' \
  | grep -v 'settingsPerformanceControl' | grep -v 'changePerformanceMode' | grep -v 'perfControl' \
  | grep -v 'settingsRefererModeControl' | grep -v 'changeRefererMode' | grep -v 'refererModeControl' \
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
rg -q 'identifier = @"RDRefererModeControl"' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'NSSegmentedControl \*settingsRefererModeControl' "$ROOT/App/ResourceDetectorApp.m"
# Referer 档位必须真的接线到策略层（只画控件不注入 = 假功能）
rg -q 'setRefererModeOverride' "$ROOT/App/ResourceDetectorApp.m"
rg -q 'SevenZZKeyRefererMode' "$ROOT/App/ResourceDetectorApp.m"
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

# 4e-2. 队列 WAL 接线（本轮新增）。纯逻辑正确不等于生产在用：
#       三个调用点缺任意一个，WAL 就退化成「写了个文件但没人读」的死代码。
for _pair in \
  "src/Features/ResourceDownload/DownloadManager.m|appendEnqueuedRecord" \
  "src/Features/ResourceDownload/DownloadManager.m|appendTerminal" \
  "src/Features/ResourceDownload/DownloadManager.m|recoverJobsFromWALExcluding" \
  "src/Features/ResourceDownload/DownloadManager.m|appendProgress"; do
  _f="${_pair%%|*}"; _sym="${_pair##*|}"
  if ! rg -q "$_sym" "$REPO/$_f"; then
    echo "FAIL: WAL 未接线（$_f 缺少 $_sym，崩溃恢复会退化成死代码）" >&2
    exit 1
  fi
done
# 恢复必须先于孤儿清理：顺序反了会把即将恢复的任务目录当孤儿删掉（同一类事故已出现过一次）。
# 只看**调用点**（消息发送形式），不看方法定义——定义在文件后半部分，
# 首版按裸符号匹配，把方法定义当成了「调用」，实测误报。
if ! awk '/\[self recoverJobsFromWALExcluding:/{w=NR} /\[self cleanupOrphanTempDirs\]/{c=NR} END{exit !(w>0 && c>0 && w<c)}' \
     "$ROOT/Features/ResourceDownload/DownloadManager.m"; then
  echo "FAIL: WAL 恢复必须发生在孤儿清理之前（否则恢复的任务目录会被当孤儿删除）" >&2
  exit 1
fi

# 4e-2b. WAL 只能在生产路径装配（本轮实测踩过：首版让每个 DownloadManager
#        惰性落到共享文件，隔离测试写进去的任务会被真实 App 恢复出来，
#        用户凭空多出 "cdn.example.com" 的下载行）。sharedManager 之外
#        任何位置都不得 new/shared 出 WAL。
# 只看生产源码（tests/ 里用独立临时文件是刻意的隔离手段，不算违规）。
# 判据：允许装配的文件只能是 DownloadManager.m（生产实例在 sharedManager 内装配），
# 其它任何源文件出现装配即违规。
_WAL_OFFENDERS=$(rg -l 'RDQueueWAL (shared|alloc)' "$ROOT" 2>/dev/null \
  | grep -v '/RDQueueWAL\.m$' | grep -v '/DownloadManager\.m$' || true)
if [ -n "$_WAL_OFFENDERS" ]; then
  echo "FAIL: WAL 在 DownloadManager 之外被装配（隔离测试/其它模块会污染真实队列）：$_WAL_OFFENDERS" >&2
  exit 1
fi
# DownloadManager 内也只允许一处装配（sharedManager 里给生产实例）。
_WAL_SITES=$(rg -c 'RDQueueWAL shared\]' "$ROOT/Features/ResourceDownload/DownloadManager.m" 2>/dev/null | tr -dc '0-9')
[ "${_WAL_SITES:-0}" = "1" ] || {
  echo "FAIL: WAL 装配点应恰好 1 处（实际 ${_WAL_SITES:-0}）" >&2; exit 1; }

# 4e-3. 失败原因必须带一个可点的动作（本轮新增）。
if ! rg -q 'RDFailureMessageWithAdvice' "$ROOT/Features/ResourceDownload/DownloadManager.m"; then
  echo "FAIL: 失败路径未接 RDFailureMessageWithAdvice（用户只会看到一句原因，不知道点哪儿）" >&2
  exit 1
fi

# 4e-4. HLS 分片图片外壳必须在合流前剥掉（本轮新增）。
if ! rg -q 'RDImageWrapperPayloadOffset' "$ROOT/Features/ResourceDownload/RDStreamDownloadTask.m"; then
  echo "FAIL: 流任务未剥分片图片外壳（防盗链站点会「分片全齐、合流必炸」）" >&2
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
    # 只认**非注释行**（2026-10-13 第 42 轮）：注释里提到类名不等于「编译了它」。
    # download-page.sh 是纯静态源码检查脚本、根本不编译任何东西，仅因注释里写了
    # DownloadManager 就被判「未链接 Security」——首版实测误报，已按注释剥离修正。
    grep -vE '^[[:space:]]*#' "$_suite" 2>/dev/null | grep -qE "(^|[^A-Za-z])${_u}([^A-Za-z]|\$)" || continue
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
  if grep -vE '^[[:space:]]*#' "$_suite" 2>/dev/null | grep -q 'find "\$ROOT/Features"' &&
     ! grep -q '\-framework AVKit' "$_suite"; then
    echo "FAIL: $_b 编译 Features 全树（含 import AVKit 的 RDPreviewWindow.m）但未链接 -framework AVKit" >&2
    exit 1
  fi
done

# 同族第三例（2026-10-12 第 38 轮）：有些套件**直接 `#import` 生产 App.m**，于是
# App.m **直接引用**的每个 App 层源都必须被它们一并编译——漏一个就
# `Undefined symbols: _OBJC_CLASS_$_<新类>` 链接失败。本轮新增
# `RDMetadataRecoveryCoordinator` 后一次命中 **12 个脚本**，而它们的失败只写进各自
# compile.log，套件日志里只留一行标题——最容易被当成「跑过了」。
#
# 只对「App.m 里以 `[[X alloc]`／`[X new]`／`X.class` 直接引用」的类要求：
# 经 `NSClassFromString` 运行时装配的（RDAdaptiveTransport／RDCurlFallbackBackend）
# 本就不该被套件编译，故排除；App.m 自身由 #import 引入，同样排除。
# 只匹配真正的 `#import ... ResourceDetectorApp.m`（version.sh 只是 grep 它做语法
# 破坏测试、并不编译，首版把它误判成需要，已修正）。
#
# 2026-10-13 第 41 轮扩展（第 40 轮自查登记的盲区）：原实现只看 .sh **自身文本**里的
# `#import`，而几何探针把 `#import` 写在 **harness .m** 里、由 .sh 编译——盲区正好落在
# 第 35 轮 AVKit 复发过的那两个探针（build/*-probe/*.m）上。现在按「探针 .m 的
# **仓库相对路径**」把 .m 归到真正编译它的 .sh，再对那个 .sh 逐源检查（实测覆盖 15 个脚本）。
# 必须用相对路径而非 basename：`tests/Tests/RealSiteProbe.m`（仓库文件）与
# `tls-trust-real-site.sh` 运行时生成的 `$OUT/RealSiteProbe.m` 同名不同物，
# 用 basename 会把后者误判成前者（首版实测误报，已改）。
# verify.sh 自身含该模式字符串但不编译生产 App 源，必须排除，否则自触发。
_rd_app_srcs=$(grep -m1 '^SRC=(' "$REPO/scripts/build.sh" | grep -o 'App/[A-Za-z0-9_]*\.m' | sed 's|App/||' | sort -u)
_rd_app_importing=""
for _imp in $(grep -rl '#import.*ResourceDetectorApp\.m' "$REPO"/tests/Tests/*.m "$REPO"/build/*-probe/*.m 2>/dev/null || true); do
  _rel="${_imp#"$REPO"/}"
  for _suite in $_rd_scan_scripts; do
    [ "$(basename "$_suite")" = "verify.sh" ] && continue
    if grep -qF "$_rel" "$_suite" 2>/dev/null; then
      _rd_app_importing="$_rd_app_importing $_suite"
    fi
  done
done
_rd_app_importing=$(printf '%s\n' $_rd_app_importing | sort -u | grep -v '^$' || true)
for _suite in $_rd_app_importing; do
  _b="$(basename "$_suite")"
  for _m in $_rd_app_srcs; do
    [ "$_m" = "ResourceDetectorApp.m" ] && continue
    _cls="${_m%.m}"
    grep -qE "\[\[${_cls} alloc\]|\[${_cls} new\]|${_cls}\.class" "$ROOT/App/ResourceDetectorApp.m" 2>/dev/null || continue
    grep -qF "$_m" "$_suite" 2>/dev/null || {
      echo "FAIL: $_b 编译了 import 生产 App.m 的探针，但未编译 App 层源 ${_m}（会 Undefined symbols 链接失败）" >&2
      exit 1
    }
  done
done

# ── 关窗驻留（第 44 轮）：红叉只隐藏窗口，下载继续；托盘可恢复或显式退出 ──
grep -q 'applicationShouldTerminateAfterLastWindowClosed:(NSApplication \*)sender { return NO; }' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 关最后一个窗口不得退出 App（会中断在途下载），应驻留托盘" >&2; exit 1; }
grep -q -- '- (BOOL)windowShouldClose:(NSWindow \*)sender' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 主窗口未实现 windowShouldClose：关红叉无法只隐藏窗口" >&2; exit 1; }
grep -q '\[self.window orderOut:nil\];' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: windowShouldClose 未隐藏主窗口" >&2; exit 1; }
grep -q '\[\[NSStatusBar systemStatusBar\] statusItemWithLength:' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 未创建托盘图标，窗口隐藏后无法恢复" >&2; exit 1; }
grep -q 'addItemWithTitle:@"退出密流" action:@selector(quitFromStatusItem:)' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 托盘缺少显式退出入口" >&2; exit 1; }
grep -q 'forceQuitRequested' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 托盘退出未绕过「有任务则驻留」的拦截" >&2; exit 1; }
grep -q '\[DownloadManager activeJobsForJobs:\[self.downloadManager allJobs\]\].count > 0' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 退出前未检查在途任务（会把下载打断）" >&2; exit 1; }

# ── 下载位置显示（第 44 轮）：行内必须显示「当前选的是哪个位置」，且失效自定义目录真正回退 ──
grep -q 'self.settingsDownloadLocationValue = locationValue;' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 下载位置行未接入常驻值控件（用户看不到当前选择）" >&2; exit 1; }
grep -q 'stringValue = self.downloadSettings.downloadDirectoryDisplayName' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 下载位置常驻值未取 downloadDirectoryDisplayName" >&2; exit 1; }
grep -q 'return \[self validCustomDirectoryURL\] ?: self.downloadsURL;' "$ROOT/Features/ResourceDownload/ResourceDownloadSettings.m" \
  || { echo "FAIL: 自定义下载目录失效时未真正回退下载文件夹" >&2; exit 1; }
grep -q 'fileExistsAtPath:custom.path isDirectory:&isDir' "$ROOT/Features/ResourceDownload/ResourceDownloadSettings.m" \
  || { echo "FAIL: 自定义下载目录未校验存在性" >&2; exit 1; }
# build/ 是本地测试产物，不得成为系统搜索里的第二个「密流」App
grep -q 'touch "$ROOT/build/.metadata_never_index"' "$REPO/scripts/build.sh" \
  || { echo "FAIL: build.sh 未排除 build/ 的 Spotlight 索引（会出现两个 Miliu）" >&2; exit 1; }
[ -f "$BUILD/.metadata_never_index" ] \
  || { echo "FAIL: build/.metadata_never_index 缺失（构建产物会被 Spotlight 索引）" >&2; exit 1; }

# ── 偏好键无死键（第 46 轮）：规格表里的每个键必须真有消费者 ──
# 历史问题：26 个 Seven zz 时代遗留键（MarketCache*/Delta*/Mood*/AppTheme…）只存在于
# allKeySpecs、零消费者，仍被当作在用偏好维护。本断言对每个「已登记键」反查 src/
# 非规格表引用，为零即判死键。新增键时若不接消费者，这里会立刻红。
_PS_H="$ROOT/Shared/Infrastructure/PreferencesStore.h"
_PS_M="$ROOT/Shared/Infrastructure/PreferencesStore.m"
_dead=0
for _k in $(grep -oE 'specWithKey:SevenZZKey[A-Za-z]+' "$_PS_M" | sed 's/specWithKey://' | sort -u); do
  _hits=$(grep -rl -- "$_k" "$ROOT" 2>/dev/null | grep -v 'PreferencesStore' | wc -l | tr -d ' ')
  if [ "$_hits" = "0" ]; then
    echo "FAIL: 偏好键 $_k 已登记规格表但零消费者（死键）" >&2
    _dead=$((_dead + 1))
  fi
done
[ "$_dead" = "0" ] || { echo "FAIL: 共 $_dead 个死偏好键（清理或接入消费者后再登记）" >&2; exit 1; }
# 反向：规格表审计必须真实存在，否则「审计」又退化成零调用死方法（本轮修掉的老毛病）。
grep -q 'specAuditAgainstLiveKeys' "$_PS_M" \
  || { echo "FAIL: 缺 specAuditAgainstLiveKeys（规格表审计不可断言）" >&2; exit 1; }
grep -q 'specAuditAgainstLiveKeys' "$_PS_H" \
  || { echo "FAIL: specAuditAgainstLiveKeys 未在头文件公开" >&2; exit 1; }

# 键值分叉防线（第 46 轮）：PerformancePolicy 不链接 PreferencesStore（套件依赖约束），
# 故它只能写字面量。此处核对两侧取值一致——任一侧改动而另一侧没跟，立刻红。
_PS_MODE_VAL=$(grep -oE 'SevenZZKeyPerformanceMode *= *@"[^"]+"' "$_PS_M" | sed 's/.*@"\(.*\)"/\1/')
_PP_MODE_VAL=$(grep -oE 'objectForKey:@"[^"]+"' "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m" | head -1 | sed 's/.*@"\(.*\)"/\1/')
{ [ -n "$_PS_MODE_VAL" ] && [ "$_PS_MODE_VAL" = "$_PP_MODE_VAL" ]; } \
  || { echo "FAIL: 性能模式键值分叉（PreferencesStore=$_PS_MODE_VAL / PerformancePolicy=$_PP_MODE_VAL）" >&2; exit 1; }
# ── 设置页文案必须是白话，不得回退成专业术语（第 47 轮用户要求）──
# 原话：「他现在太像专业术语了，而不是像随便拎一个普通初中生或者是小学生就能使用的工具」。
# 断言两层：① 档位标签用白话；② 行标题/说明里不得再出现裸露的「强度/热链」这类词。
grep -q 'segmentedControlWithLabels:@\[@"一般", @"带完整页面", @"不带说明", @"跨站也带"\]' \
    "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: Referer 档位标签不是白话（应为一一般/带完整页面/不带说明/跨站也带）" >&2; exit 1; }
grep -q 'addRow(@"来源说明（Referer）"' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 该行标题应为「来源说明（Referer）」而非专业术语" >&2; exit 1; }
grep -q '你是从哪一页点进来的' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 该行说明缺白话解释" >&2; exit 1; }
! grep -q 'addRow(@"Referer 强度"' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 仍在用「Referer 强度」这种术语做行标题" >&2; exit 1; }

# ── 单实例门必须存在（第 46 轮补回）──
# 历史：第 20 轮的单实例闭环住在 src/Helpers/，第 43 轮剥离追更时整目录被删，
# 主 App 从此可并存两个进程（实测 `open -n` 成功）。本断言守住它不被再次丢掉。
grep -q 'single-instance.lock' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 缺少单实例锁（open -n 会并存两个进程写同一份偏好与下载记录）" >&2; exit 1; }
grep -q 'flock(lockFD, LOCK_EX | LOCK_NB)' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 单实例锁未用 flock 独占（拿不到锁必须判为已有实例）" >&2; exit 1; }
grep -q 'RD_ALLOW_MULTI_INSTANCE' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 缺 RD_ALLOW_MULTI_INSTANCE 逃生口（套件并行起替身会被误杀）" >&2; exit 1; }

# ── 三种探测模式都必须有 UI 入口（第 46 轮）──
# 历史问题：Smart / SmartExpansion 在协调器里是完整实现，但设置页只暴露两段
#（当前页/总站），那两条分支**用户永远走不到** = 死代码。本断言要求三段控件存在，
# 且映射函数真的把索引 2 映射到 Smart。
grep -q 'segmentedControlWithLabels:@\[@"当前页", @"总站", @"智能"\]' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 探测模式控件缺「智能」档（Smart 分支不可达 = 死代码）" >&2; exit 1; }
grep -q 'case 2: return ZZResourceDiscoveryModeSmart;' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: 模式映射未把索引 2 接到 ZZResourceDiscoveryModeSmart" >&2; exit 1; }
grep -q 'case ZZResourceDiscoveryModeSmart:' "$ROOT/App/ResourceDetectorApp.m" \
  || { echo "FAIL: RDPreferenceIndexFromMode 未处理 Smart（切档后选中态会错位）" >&2; exit 1; }

# DownloadStore 的已下载键必须与 PreferencesStore 常量**取值一致**。
# 为什么不用「绑定常量」而用「取值比对」：download-integrity 等套件只编译
# DownloadStore.m、不链接 PreferencesStore.m，引用 extern 常量会 Undefined symbols
# （本轮实测踩到并已回退）。故两侧各留字面量，但在这里把「值必须相同」钉死。
_DS_DONE=$(grep -oE 'kCompletedKey *= *@"[^"]+"' "$ROOT/Features/ResourceDownload/DownloadStore.m" | sed 's/.*@"\(.*\)"/\1/')
_PS_DONE=$(grep -oE 'SevenZZKeyCompletedResourceURLs *= *@"[^"]+"' "$_PS_M" | sed 's/.*@"\(.*\)"/\1/')
{ [ -n "$_DS_DONE" ] && [ "$_DS_DONE" = "$_PS_DONE" ]; } \
  || { echo "FAIL: 已下载键值分叉（DownloadStore=$_DS_DONE / PreferencesStore=$_PS_DONE）" >&2; exit 1; }

echo "PASS: build, universal binary, macOS 13 target, bundle signing, app icon packaged and decodable, machine independence, no radar, view-based rows, slash-line UI with thin progress, download progress, site-mode, TLS trust tolerance, download-row uniform tint, download wiring, and no-dead-preference-key checks"
