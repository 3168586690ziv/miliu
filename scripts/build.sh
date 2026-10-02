#!/bin/bash
set -euo pipefail
# 正式构建脚本 —— 项目唯一正式构建入口（scripts/build-release.sh 是本脚本的薄包装）。
# 版本规则见根目录 AGENTS.md：DISPLAY_VERSION = v<src 代码总行数>.<PROJECT_VERSION.json 的 fixRound>
#
# 用法：bash scripts/build.sh [--release-fix] [输出 .app 路径]
#   默认（无参数）：读取现有 fixRound 构建，绝不递增 —— 普通测试/重复编译安全。
#   --release-fix：仅当用户确认"完成一轮修复并产出可安装测试版本"时使用；
#     · src 内容摘要（scripts/release-digest.py）与上次正式发布相同 → 同一轮重复执行，不递增；
#     · 否则预递增一次供本次构建使用，构建成功后写回 lastReleaseVersion 与同轮摘要；
#     · 构建失败由父事务锁内原子恢复版本状态，不留下错误轮数/版本。
#     递增判断只依赖 PROJECT_VERSION.json 与 src 内容，不使用时间/随机数/AI 上下文。
# ROOT = 仓库根；源码在 src/，资源在 resources/Resources/，Info.plist 在 src/Packaging/
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SRCROOT="$ROOT/src"; RES="$ROOT/resources/Resources"
VERSION_JSON="$ROOT/PROJECT_VERSION.json"; PYV="$ROOT/scripts/project-version.py"

# Both modes share generated files and source plist. Lock before reading any
# version state; the parent wrapper owns rollback until final record commit.
if [ "${RD_BUILD_TRANSACTION_PID:-}" != "$PPID" ]; then
  exec python3 "$ROOT/scripts/build-transaction.py" "$@"
fi

RELEASE_FIX=0; OUT=""
for arg in "$@"; do
  case "$arg" in
    --release-fix) RELEASE_FIX=1 ;;
    -*) echo "FAIL: 未知参数：$arg（仅支持 --release-fix 与可选输出路径）" >&2; exit 2 ;;
    *) [ -z "$OUT" ] || { echo "FAIL: 多余参数：$arg" >&2; exit 2; }; OUT="$arg" ;;
  esac
done
OUT="${OUT:-$ROOT/build/觅流.app}"; BIN="$OUT/Contents/MacOS/SevenZZResourceDetector"

[ -f "$VERSION_JSON" ] || { echo "FAIL: 缺少 $VERSION_JSON（修复轮数唯一来源）" >&2; exit 1; }

# ── 发布轮次决策（在任何编译之前完成） ──
if [ "$RELEASE_FIX" = 1 ]; then
  FIX_ROUND_BEFORE="$(python3 "$PYV" read-round)"
  LAST_REL_BEFORE="$(python3 "$PYV" read-last)"
  RELEASE_DIGEST="$(python3 "$ROOT/scripts/release-digest.py")"
  LAST_DIGEST="$(python3 "$PYV" read-digest)"
  if [ -n "$LAST_DIGEST" ] && [ "$RELEASE_DIGEST" = "$LAST_DIGEST" ]; then
    RELEASE_SAME_ROUND=1
    RELEASE_NOTE="RELEASE-FIX: 同一轮重复执行（src 摘要与上次正式发布相同），修复轮数保持 $FIX_ROUND_BEFORE 不变"
  else
    RELEASE_SAME_ROUND=0
    # 锁内预递增；父事务持有锁内原始快照，任一步失败时原子恢复。
    python3 "$PYV" write "$((FIX_ROUND_BEFORE + 1))" "$LAST_REL_BEFORE" "$LAST_DIGEST"
    RELEASE_NOTE="RELEASE-FIX: 修复轮数 $FIX_ROUND_BEFORE -> $((FIX_ROUND_BEFORE + 1))（构建成功后写入正式记录）"
  fi
fi

# 构建期版本：统计 src/ 物理行数 + 读取 PROJECT_VERSION.json 的修复轮数（不递增），
# 生成 build/generated/RDGeneratedVersion.h 供 App 编译期读取，并打印三行构建日志。
GEN="$ROOT/build/generated"; mkdir -p "$GEN"
bash "$ROOT/scripts/generate-version.sh" > "$GEN/version.log"
cat "$GEN/version.log"
CODE_LINES="$(sed -n 's/^CODE_LINES=//p' "$GEN/version.log" | head -1)"
FIX_ROUND="$(sed -n 's/^FIX_ROUND=//p' "$GEN/version.log" | head -1)"
DISPLAY_VERSION="$(sed -n 's/^DISPLAY_VERSION=//p' "$GEN/version.log" | head -1)"
mkdir -p "$(dirname "$BIN")" "$OUT/Contents/Resources"
SRC=("$SRCROOT/App/ResourceDetectorApp.m" "$SRCROOT/App/RDWatchlistPage.m" "$SRCROOT/App/ResourceResultRowView.m" "$SRCROOT/App/RDAdaptiveTransport.m" "$SRCROOT/App/RDCurlFallbackBackend.m")
for d in ResourceDetector ResourceDownload; do while IFS= read -r f; do SRC+=("$ROOT/$f"); done < <(find "$SRCROOT/Features/$d" -name '*.m' -print | sed "s#^$ROOT/##" | sort); done
for f in AppError.m DNSResolver.m HTTPPrivacyPolicy.m IPAddressPolicy.m HTTPRequest.m HTTPResult.m HTTPClient.m RDLog.m RDCurlHopper.m; do SRC+=("$SRCROOT/Shared/Infrastructure/$f"); done
for f in RequestGeneration.m PerformancePolicy.m; do SRC+=("$SRCROOT/Shared/Infrastructure/$( [ "$f" = PerformancePolicy.m ] && echo Performance || echo Async )/$f"); done
SRC+=("$SRCROOT/Shared/Infrastructure/PreferencesStore.m" "$SRCROOT/Shared/UI/DesignSystem/ColorTokens.m" "$SRCROOT/Shared/UI/DesignSystem/TypographyTokens.m" "$SRCROOT/Shared/UI/StateView.m" "$SRCROOT/Shared/UI/UIThemeSupport.m")
# 通用二进制（arm64 + x86_64）+ macOS 13 部署目标（与 Info.plist LSMinimumSystemVersion 一致），换机可用
clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc -Os -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security -I"$SRCROOT" -I"$GEN" -I"$SRCROOT/App" -I"$SRCROOT/Features/ResourceDetector" -I"$SRCROOT/Features/ResourceDownload" -I"$SRCROOT/Shared" -I"$SRCROOT/Shared/Infrastructure" -I"$SRCROOT/Shared/Infrastructure/Async" -I"$SRCROOT/Shared/Infrastructure/Performance" -I"$SRCROOT/Shared/UI" -I"$SRCROOT/Shared/UI/DesignSystem" -o "$BIN" "${SRC[@]}"
cp "$SRCROOT/Packaging/Info.plist" "$OUT/Contents/Info.plist"; cp "$RES/logo.png" "$OUT/Contents/Resources/logo.png"; cp "$RES/ResourceDetectorGlyph.png" "$OUT/Contents/Resources/ResourceDetectorGlyph.png"; cp "$RES/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
# 版本一致性：bundle 内 Info.plist 与源码 Packaging/Info.plist 都写入同一次构建的版本
for PLIST in "$OUT/Contents/Info.plist" "$SRCROOT/Packaging/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DISPLAY_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DISPLAY_VERSION" "$PLIST"
done
mkdir -p "$OUT/Contents/Resources/MediaTools"
cp "$RES/MediaTools/"* "$OUT/Contents/Resources/MediaTools/"
codesign --force --sign - "$OUT/Contents/Resources/MediaTools/ffmpeg"
# 稳定身份签名（优先）：固定证书让 TCC 授权（辅助功能等）跨构建仍有效；
# 正式身份下启用 hardened runtime + 最小 entitlements（JIT/网络客户端/用户自选文件读写）。
# 证书不存在时回退 ad-hoc（每次重建授权失效）。
SIG_ID="$(security find-identity -p codesigning -v 2>/dev/null | grep 'SevenZZDev' | awk '{print $2}' | head -1)"
ENTITLEMENTS="$SRCROOT/Packaging/ResourceDetector.entitlements"
if [ -n "$SIG_ID" ]; then
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIG_ID" "$OUT"
else
  codesign --force --sign - "$OUT"
fi

# ── 构建后自检：设置页生成头 == bundle Info.plist 两键 == 本次构建日志；图标未被修改 ──
for KEY in CFBundleShortVersionString CFBundleVersion; do
  V="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$OUT/Contents/Info.plist")"
  [ "$V" = "$DISPLAY_VERSION" ] || { echo "FAIL: 构建后自检失败：$KEY=$V 与 $DISPLAY_VERSION 不一致" >&2; exit 1; }
done
grep -q "^#define RD_GENERATED_VERSION_STRING @\"$DISPLAY_VERSION\"$" "$GEN/RDGeneratedVersion.h" \
  || { echo "FAIL: 构建后自检失败：生成头版本与 $DISPLAY_VERSION 不一致" >&2; exit 1; }
cmp -s "$OUT/Contents/Resources/AppIcon.icns" "$RES/AppIcon.icns" \
  || { echo "FAIL: 构建后自检失败：App 内 AppIcon.icns 与工作区图标不一致" >&2; exit 1; }
ICON_BASELINE="$ROOT/tests/Tests/icon-checksum.txt"
if [ -f "$ICON_BASELINE" ]; then
  ICON_NOW="$(shasum -a 256 "$RES/AppIcon.icns" | awk '{print $1}')"
  ICON_EXPECT="$(tr -d ' \n' < "$ICON_BASELINE")"
  [ "$ICON_NOW" = "$ICON_EXPECT" ] || { echo "FAIL: 工作区 Z 字图标 AppIcon.icns 校验和与基线不一致（不得修改用户图标）" >&2; exit 1; }
fi

# ── 追更助手（Watch Agent）构建：在主 bundle 流程完成后追加（WATCH-V1-CONTRACT §2/§3.2）──
# 版本号逻辑、既有 codesign 段与上方构建后自检均未改动。本阶段放在 --release-fix 写轮数之前：
# 助手构建/组装/自检任何一步失败都以非零退出结束整个构建，发布轮次记录不会执行，
# build-transaction.py 会按既有事务语义回滚版本状态（不留错误轮数）。
HELPER_SRC_DIR="$SRCROOT/Helpers"
for HELPER_FILE in "$HELPER_SRC_DIR/RDWatchAgentMain.m" "$HELPER_SRC_DIR/RDWatchAgentController.m" \
                   "$HELPER_SRC_DIR/Helper-Info.plist" \
                   "$HELPER_SRC_DIR/LaunchAgent/com.sevenzz.miliu.watchlist.plist"; do
  [ -f "$HELPER_FILE" ] || { echo "FAIL: 缺少追更助手源文件 $HELPER_FILE（契约 §2：助手侧产物未就位）" >&2; exit 1; }
done
HELPER_OUT="$OUT/Contents/Helpers/觅流追更助手.app"
HELPER_BIN="$HELPER_OUT/Contents/MacOS/SevenZZWatchAgent"
mkdir -p "$HELPER_OUT/Contents/MacOS" "$HELPER_OUT/Contents/Resources" "$HELPER_OUT/Contents/Library/LaunchAgents"
# 编译清单：助手入口/控制器 + 探测引擎。探测引擎按契约 §2 参照主 bundle 的 find 写法把
# src/Features/ResourceDetector 整个目录编入助手（以 #import 实际依赖为准，宁可多含同目录
# 实现文件；RDWatchlistStore/RDHybridPageProbe/WebProbe/URLPolicy/ResourceDiscoveryCoordinator/
# DetectedMedia 均在其中），再加上与主 bundle 第 63-65 行同一组 Shared 基础件。
HELPER_SRC=("$HELPER_SRC_DIR/RDWatchAgentMain.m" "$HELPER_SRC_DIR/RDWatchAgentController.m")
while IFS= read -r f; do HELPER_SRC+=("$ROOT/$f"); done < <(find "$SRCROOT/Features/ResourceDetector" -name '*.m' -print | sed "s#^$ROOT/##" | sort)
for f in AppError.m DNSResolver.m HTTPPrivacyPolicy.m IPAddressPolicy.m HTTPRequest.m HTTPResult.m HTTPClient.m RDLog.m RDCurlHopper.m; do HELPER_SRC+=("$SRCROOT/Shared/Infrastructure/$f"); done
for f in RequestGeneration.m PerformancePolicy.m; do HELPER_SRC+=("$SRCROOT/Shared/Infrastructure/$( [ "$f" = PerformancePolicy.m ] && echo Performance || echo Async )/$f"); done
HELPER_SRC+=("$SRCROOT/Shared/Infrastructure/PreferencesStore.m" "$SRCROOT/Shared/UI/DesignSystem/ColorTokens.m" "$SRCROOT/Shared/UI/DesignSystem/TypographyTokens.m" "$SRCROOT/Shared/UI/StateView.m" "$SRCROOT/Shared/UI/UIThemeSupport.m")
# 与主 bundle 同一套编译参数：universal（arm64 + x86_64）、macOS 13 部署目标
# （集成修复：助手比主 bundle 多用 UserNotifications / ServiceManagement 两套框架，
#  缺了会在链接期报 UNUserNotificationCenter / SMAppService 未定义符号）
clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc -Os -framework Cocoa -framework WebKit -framework UserNotifications -framework ServiceManagement -framework AVFoundation -framework CoreMedia -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security -I"$SRCROOT" -I"$GEN" -I"$SRCROOT/App" -I"$HELPER_SRC_DIR" -I"$SRCROOT/Features/ResourceDetector" -I"$SRCROOT/Shared" -I"$SRCROOT/Shared/Infrastructure" -I"$SRCROOT/Shared/Infrastructure/Async" -I"$SRCROOT/Shared/Infrastructure/Performance" -I"$SRCROOT/Shared/UI" -I"$SRCROOT/Shared/UI/DesignSystem" -o "$HELPER_BIN" "${HELPER_SRC[@]}"
# 组装助手 bundle：Info.plist = 助手侧 Helper-Info.plist；LaunchAgent plist 内嵌（契约 §3.2）
cp "$HELPER_SRC_DIR/Helper-Info.plist" "$HELPER_OUT/Contents/Info.plist"
cp "$HELPER_SRC_DIR/LaunchAgent/com.sevenzz.miliu.watchlist.plist" "$HELPER_OUT/Contents/Library/LaunchAgents/com.sevenzz.miliu.watchlist.plist"
# 版本一致性（AGENTS.md §3）：助手 Info.plist 两版本键与本次构建 DISPLAY_VERSION 对齐，
# 不随 Helper-Info.plist 源文件里的历史快照漂移
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DISPLAY_VERSION" "$HELPER_OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DISPLAY_VERSION" "$HELPER_OUT/Contents/Info.plist"
# 签名助手 bundle：同一签名策略（稳定证书优先，否则 ad-hoc），照上方主 bundle codesign 段写法
if [ -n "$SIG_ID" ]; then
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIG_ID" "$HELPER_OUT"
else
  codesign --force --sign - "$HELPER_OUT"
fi
# 助手组装发生在主 bundle 签名之后：向已签名 bundle 内新增嵌套内容会破坏外层资源封印，
# 必须按同一策略重签外层，否则 verify.sh 既有断言 codesign --verify --deep --strict 会失败。
if [ -n "$SIG_ID" ]; then
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIG_ID" "$OUT"
else
  codesign --force --sign - "$OUT"
fi
# ── 追加构建后自检：助手 bundle 存在、可执行就位、Helper-Info.plist 内 LSUIElement=true，
#    bundle id 与内嵌 LaunchAgent 的 Label 符合契约 §3.2 的固定值 ──
[ -d "$HELPER_OUT" ] || { echo "FAIL: 构建后自检失败：助手 bundle 缺失 $HELPER_OUT" >&2; exit 1; }
[ -x "$HELPER_BIN" ] || { echo "FAIL: 构建后自检失败：助手可执行缺失 $HELPER_BIN" >&2; exit 1; }
if ! plutil -lint "$HELPER_OUT/Contents/Info.plist" >/dev/null; then
  echo "FAIL: 构建后自检失败：助手 Info.plist 不是合法 plist" >&2; exit 1
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$HELPER_OUT/Contents/Info.plist")" = "true" ] \
  || { echo "FAIL: 构建后自检失败：助手 Info.plist LSUIElement 必须为 true（契约 §3.2）" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HELPER_OUT/Contents/Info.plist")" = "com.sevenzz.resource-detector.watchlist" ] \
  || { echo "FAIL: 构建后自检失败：助手 bundle id 必须为 com.sevenzz.resource-detector.watchlist（契约 §3.2）" >&2; exit 1; }
[ -f "$HELPER_OUT/Contents/Library/LaunchAgents/com.sevenzz.miliu.watchlist.plist" ] \
  || { echo "FAIL: 构建后自检失败：内嵌 LaunchAgent plist 缺失（契约 §3.2）" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$HELPER_OUT/Contents/Library/LaunchAgents/com.sevenzz.miliu.watchlist.plist")" = "com.sevenzz.miliu.watchlist" ] \
  || { echo "FAIL: 构建后自检失败：LaunchAgent Label 必须为 com.sevenzz.miliu.watchlist（契约 §3.2）" >&2; exit 1; }

# ── 正式发布收尾：自检成功后才原子写正式记录；写入失败仍由锁内事务恢复 ──
if [ "$RELEASE_FIX" = 1 ]; then
  python3 "$PYV" write "$FIX_ROUND" "$DISPLAY_VERSION" "$RELEASE_DIGEST"
  echo "$RELEASE_NOTE"
  echo "RELEASE-FIX: lastReleaseVersion=$DISPLAY_VERSION 已写入 PROJECT_VERSION.json"
fi
echo "Built $OUT"
