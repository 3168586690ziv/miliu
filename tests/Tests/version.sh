#!/bin/bash
# 版本号规则专项验收（规则见根目录 AGENTS.md）：
#   0) AGENTS.md 存在且写明版本规则；PROJECT_VERSION.json 存在且 fixRound 为非负整数；
#      修复轮数唯一来源是 PROJECT_VERSION.json（scripts 内不得再引用 version.conf）；
#      版本脚本不得依赖时间/随机数/用户偏好/AI 上下文（换 AI 不改变轮数）；
#   1) 构建期版本生成幂等、与运行环境无关，重复执行不改变 FIX_ROUND；
#   2) 工作区 Z 字图标校验和与基线一致（未被修改）；
#   3) 设置页版本号 UI 断言（tests/Tests/VersionTests.m）；
#   4) 默认构建（不带 --release-fix）不改变 PROJECT_VERSION.json 的任何字节；
#      构建日志 CODE_LINES / FIX_ROUND / DISPLAY_VERSION 三行与生成值一致；
#   5) App 二进制、Info.plist（CFBundleShortVersionString / CFBundleVersion）、
#      构建日志三者版本一致，且均为小写 v 格式；lastReleaseVersion 规则校验；
#   6) 隔离沙盒（项目副本）验证 --release-fix 纪律：默认不递增 / 发布恰好递增一次 /
#      同一轮重复执行不递增 / 构建失败自动恢复 —— 全程不触碰真实 PROJECT_VERSION.json。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/version-tests"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
printf '版本号规则专项测试: %s\n' "$(date -u)"

fail() { echo "FAIL: $*"; exit 1; }

JSON_REAL="$REPO/PROJECT_VERSION.json"
PYV="$REPO/scripts/project-version.py"

# ── 0. 规则文件 / 版本文件 / 唯一来源 ──
[ -f "$REPO/AGENTS.md" ] || fail "缺少 $REPO/AGENTS.md（永久版本规则）"
grep -q 'v<代码总行数>.<修复轮数>' "$REPO/AGENTS.md" || fail "AGENTS.md 未写明版本号格式 v<代码总行数>.<修复轮数>"
grep -q 'PROJECT_VERSION.json' "$REPO/AGENTS.md" || fail "AGENTS.md 未指明修复轮数来源 PROJECT_VERSION.json"
grep -q -- '--release-fix' "$REPO/AGENTS.md" || fail "AGENTS.md 未写明正式发布参数 --release-fix"
grep -q '小写' "$REPO/AGENTS.md" || fail "AGENTS.md 未写明小写 v 规则"
grep -q 'AppIcon' "$REPO/AGENTS.md" || fail "AGENTS.md 未写明不得修改 Z 字图标"
[ -f "$JSON_REAL" ] || fail "缺少 $JSON_REAL（修复轮数唯一来源，属于项目永久记录）"
python3 - "$JSON_REAL" <<'PY' || fail "PROJECT_VERSION.json 校验失败（fixRound 必须为非负整数、lastReleaseVersion 必须为 v数字.数字）"
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
r = d.get("fixRound")
assert isinstance(r, int) and not isinstance(r, bool) and r >= 0, "fixRound 必须是非负整数: %r" % (r,)
last = d.get("lastReleaseVersion", "")
assert re.fullmatch(r"v[0-9]+\.[0-9]+", last), "lastReleaseVersion 必须匹配 ^v[0-9]+\\.[0-9]+$: %r" % (last,)
PY
if grep -rn "version\.conf" "$REPO/scripts/" >/dev/null 2>&1; then
  fail "scripts/ 内仍引用 version.conf（修复轮数唯一来源必须是 PROJECT_VERSION.json）"
fi
for VSCRIPT in "$REPO/scripts/build.sh" "$REPO/scripts/generate-version.sh" \
               "$REPO/scripts/count-code-lines.py" "$REPO/scripts/release-digest.py" "$PYV"; do
  [ -f "$VSCRIPT" ] || fail "缺少版本脚本 $VSCRIPT"
  if grep -nE '\$RANDOM|\$SECONDS|`date|date \+%|osascript|defaults (read|write)|whoami|logger|ttyname' "$VSCRIPT" >/dev/null 2>&1; then
    fail "$VSCRIPT 依赖时间/随机数/用户偏好/本机身份计算版本（违反换 AI 不变规则）"
  fi
done
echo "PASS: AGENTS.md 与 PROJECT_VERSION.json 规则文件齐备，修复轮数来源唯一且与环境无关"

# ── 1. 生成构建期版本（幂等；与 AI/上下文无关；不递增修复轮数） ──
JSON_BEFORE="$(cat "$JSON_REAL")"
bash "$REPO/scripts/generate-version.sh" > "$OUT/generate-1.log"
bash "$REPO/scripts/generate-version.sh" > "$OUT/generate-2.log"
cmp -s "$OUT/generate-1.log" "$OUT/generate-2.log" || fail "重复执行 generate-version.sh 改变了版本输出"
env -i PATH="$PATH" bash "$REPO/scripts/generate-version.sh" > "$OUT/generate-3.log" || fail "干净环境下 generate-version.sh 失败"
cmp -s "$OUT/generate-1.log" "$OUT/generate-3.log" || fail "干净环境（env -i，无 AI/上下文变量）下版本输出不同"
[ "$(cat "$JSON_REAL")" = "$JSON_BEFORE" ] || fail "generate-version.sh 修改了 PROJECT_VERSION.json（只许读，不许写）"
# shellcheck disable=SC1091
. "$BUILD/generated/version.env"
[ -n "${CODE_LINES:-}" ] && [ -n "${FIX_ROUND:-}" ] && [ -n "${DISPLAY_VERSION:-}" ] || fail "version.env 不完整"
case "$DISPLAY_VERSION" in
  v[0-9]*.[0-9]*) ;;
  *) fail "DISPLAY_VERSION 不是小写 v 格式：$DISPLAY_VERSION" ;;
esac
JSON_ROUND="$(python3 "$PYV" read-round)"
[ "$JSON_ROUND" = "$FIX_ROUND" ] || fail "构建 FIX_ROUND($FIX_ROUND) 与 PROJECT_VERSION.json fixRound($JSON_ROUND) 不一致"
echo "生成版本：CODE_LINES=$CODE_LINES FIX_ROUND=$FIX_ROUND DISPLAY_VERSION=$DISPLAY_VERSION"

# ── 2. Z 字图标基线（不得被修改） ──
ICON_BASELINE_FILE="$REPO/tests/Tests/icon-checksum.txt"
[ -f "$ICON_BASELINE_FILE" ] || fail "缺少图标基线 $ICON_BASELINE_FILE"
ICON_EXPECT="$(tr -d ' \n' < "$ICON_BASELINE_FILE")"
ICON_WORKSPACE="$(shasum -a 256 "$REPO/resources/Resources/AppIcon.icns" | awk '{print $1}')"
[ "$ICON_WORKSPACE" = "$ICON_EXPECT" ] || fail "工作区 Z 字图标 AppIcon.icns 校验和变化：$ICON_WORKSPACE != $ICON_EXPECT"
echo "PASS: 工作区 Z 字图标校验和未变（${ICON_WORKSPACE}）"

# ── 3. 编译并运行设置页 UI 断言 ──
SRC=("$REPO/tests/Tests/VersionTests.m" "$ROOT/App/ResourceResultRowView.m")
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in AppError DNSResolver HTTPPrivacyPolicy IPAddressPolicy HTTPRequest HTTPResult HTTPClient PreferencesStore RDLog; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m" "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
      "$ROOT/Shared/UI/DesignSystem/ColorTokens.m" "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m"
      "$ROOT/Shared/UI/StateView.m" "$ROOT/Shared/UI/UIThemeSupport.m")
INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" "$ROOT/Shared" \
           "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" "$ROOT/Shared/Infrastructure/Performance" \
           "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" "$BUILD/generated"; do INCLUDES+=("-I$dir"); done
xcrun clang -fobjc-arc -g -O1 -fsanitize=address -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/VersionTests" >"$OUT/compile.log" 2>&1
if grep -E "error:" "$OUT/compile.log" >/dev/null; then cat "$OUT/compile.log"; fail "版本号测试编译失败"; fi
BAD=$(grep -E "warning:" "$OUT/compile.log" | grep -v "nullability" | grep -v "arc-retain-cycles" || true)
if [ -n "$BAD" ]; then printf '%s\n' "$BAD"; fail "版本号测试编译出现新增警告"; fi
ASAN_OPTIONS=detect_leaks=0 \
  ZZ_EXPECT_CODE_LINES="$CODE_LINES" ZZ_EXPECT_FIX_ROUND="$FIX_ROUND" ZZ_EXPECT_DISPLAY_VERSION="$DISPLAY_VERSION" \
  "$OUT/VersionTests" "$@"

# ── 4. 默认构建（不带 --release-fix，不递增轮数，不改动 PROJECT_VERSION.json） ──
bash "$REPO/scripts/build.sh" "$BUILD/资源探测.app" > "$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; fail "默认构建失败"; }
grep -qx "CODE_LINES=$CODE_LINES" "$OUT/build.log" || fail "构建日志缺少/不匹配 CODE_LINES=$CODE_LINES"
grep -qx "FIX_ROUND=$FIX_ROUND" "$OUT/build.log" || fail "构建日志缺少/不匹配 FIX_ROUND=$FIX_ROUND"
grep -qx "DISPLAY_VERSION=$DISPLAY_VERSION" "$OUT/build.log" || fail "构建日志缺少/不匹配 DISPLAY_VERSION=$DISPLAY_VERSION"
[ "$(cat "$JSON_REAL")" = "$JSON_BEFORE" ] || fail "默认构建修改了 PROJECT_VERSION.json（默认构建绝不递增/改动轮数）"

# ── 5. App 二进制 / Info.plist / 构建日志 / lastReleaseVersion 一致性 ──
APP="$BUILD/资源探测.app"; BIN="$APP/Contents/MacOS/SevenZZResourceDetector"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$SHORT" = "$DISPLAY_VERSION" ] || fail "CFBundleShortVersionString($SHORT) != DISPLAY_VERSION($DISPLAY_VERSION)"
[ "$BUILDNO" = "$DISPLAY_VERSION" ] || fail "CFBundleVersion($BUILDNO) != DISPLAY_VERSION($DISPLAY_VERSION)"
strings -a "$BIN" | grep -Fx "$DISPLAY_VERSION" >/dev/null || fail "App 二进制内未找到版本串 $DISPLAY_VERSION"
cmp -s "$APP/Contents/Resources/AppIcon.icns" "$REPO/resources/Resources/AppIcon.icns" || fail "App 内 AppIcon.icns 与工作区图标不一致"
ICON_APP="$(shasum -a 256 "$APP/Contents/Resources/AppIcon.icns" | awk '{print $1}')"
[ "$ICON_APP" = "$ICON_EXPECT" ] || fail "App 内图标校验和与基线不一致：$ICON_APP != $ICON_EXPECT"
LAST_REL="$(python3 "$PYV" read-last)"
case "$LAST_REL" in v[0-9]*.[0-9]*) ;; *) fail "lastReleaseVersion 格式非法：$LAST_REL" ;; esac
LAST_DIG="$(python3 "$PYV" read-digest)"
NOW_DIG="$(python3 "$REPO/scripts/release-digest.py")"
if [ -n "$LAST_DIG" ] && [ "$LAST_DIG" = "$NOW_DIG" ]; then
  [ "$LAST_REL" = "$DISPLAY_VERSION" ] || fail "src 与上次正式发布一致，但 lastReleaseVersion($LAST_REL) != 最终版本($DISPLAY_VERSION)"
  echo "PASS: lastReleaseVersion($LAST_REL) 与最终版本一致"
else
  echo "NOTE: src 相对上次正式发布有改动（或尚无摘要记录），lastReleaseVersion 仅校验格式：$LAST_REL"
fi
# 设置页源码不得写死版本串（行数必须来自构建期生成）
if rg -q 'v[0-9]+\.[0-9]+' "$ROOT/App/ResourceDetectorApp.m"; then
  fail "设置页源码出现写死的版本串（应由构建期生成头提供）"
fi

# ── 6. 隔离沙盒：--release-fix 递增纪律（项目副本上验证，不触碰真实 PROJECT_VERSION.json） ──
SB="$OUT/sandbox"; rm -rf "$SB"; mkdir -p "$SB"
rsync -a --exclude build --exclude outputs --exclude tests --exclude .git --exclude .zcode --exclude .DS_Store "$REPO/" "$SB/"
# 沙盒使用独立的合成初始状态，保证断言与真实轮数无关、可重复
printf '{\n  "fixRound": 41,\n  "lastReleaseVersion": "v1.41"\n}\n' > "$SB/PROJECT_VERSION.json"
SB_LINES="$(python3 "$SB/scripts/count-code-lines.py")"

# 6a. 默认构建：json 逐字节不变
cp "$SB/PROJECT_VERSION.json" "$SB/json.a-before"
bash "$SB/scripts/build.sh" "$SB/build/app-a.app" > "$SB/a-default.log" 2>&1 || { cat "$SB/a-default.log"; fail "沙盒默认构建失败"; }
cmp -s "$SB/json.a-before" "$SB/PROJECT_VERSION.json" || fail "沙盒默认构建修改了 PROJECT_VERSION.json"
[ "$(python3 "$SB/scripts/project-version.py" read-round)" = "41" ] || fail "沙盒默认构建后 fixRound 应仍为 41"
grep -qx "DISPLAY_VERSION=v${SB_LINES}.41" "$SB/a-default.log" || fail "沙盒默认构建版本号应为 v${SB_LINES}.41"

# 6b. --release-fix（经 build-release.sh 包装入口）：恰好递增一次，成功后写回 lastReleaseVersion 与同轮摘要
bash "$SB/scripts/build-release.sh" --release-fix "$SB/build/app-b.app" > "$SB/b-release.log" 2>&1 || { cat "$SB/b-release.log"; fail "沙盒 --release-fix 构建失败"; }
[ "$(python3 "$SB/scripts/project-version.py" read-round)" = "42" ] || fail "--release-fix 后 fixRound 应为 42（实际 $(python3 "$SB/scripts/project-version.py" read-round)）"
[ "$(python3 "$SB/scripts/project-version.py" read-last)" = "v${SB_LINES}.42" ] || fail "lastReleaseVersion 应为 v${SB_LINES}.42"
[ -n "$(python3 "$SB/scripts/project-version.py" read-digest)" ] || fail "--release-fix 成功后未记录同轮摘要"
grep -qx "DISPLAY_VERSION=v${SB_LINES}.42" "$SB/b-release.log" || fail "沙盒 release 构建日志版本号错误"
SB_PL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SB/build/app-b.app/Contents/Info.plist")"
[ "$SB_PL" = "v${SB_LINES}.42" ] || fail "沙盒产物 Info.plist 版本错误：$SB_PL"

# 6c. 同一轮（src 未变）重复执行 --release-fix：识别为同一轮，不重复递增
bash "$SB/scripts/build.sh" --release-fix "$SB/build/app-c.app" > "$SB/c-repeat.log" 2>&1 || { cat "$SB/c-repeat.log"; fail "沙盒重复 --release-fix 构建失败"; }
[ "$(python3 "$SB/scripts/project-version.py" read-round)" = "42" ] || fail "同一轮重复执行不应递增（实际 $(python3 "$SB/scripts/project-version.py" read-round)）"
[ "$(python3 "$SB/scripts/project-version.py" read-last)" = "v${SB_LINES}.42" ] || fail "同一轮重复执行改变了 lastReleaseVersion"
grep -q "同一轮重复执行" "$SB/c-repeat.log" || fail "重复执行未被识别为同一轮"
grep -qx "DISPLAY_VERSION=v${SB_LINES}.42" "$SB/c-repeat.log" || fail "重复执行构建版本号应仍为 v${SB_LINES}.42"

# 6d. 构建失败：递增被恢复、不保存错误版本
cp "$SB/PROJECT_VERSION.json" "$SB/json.d-before"
printf '\nBREAK_SYNTAX_CHECK !!! (((\n' >> "$SB/src/App/ResourceDetectorApp.m"
set +e
bash "$SB/scripts/build.sh" --release-fix "$SB/build/app-d.app" > "$SB/d-fail.log" 2>&1
RC_FAIL=$?
set -e
[ "$RC_FAIL" -ne 0 ] || fail "注入语法错误后构建应失败"
cmp -s "$SB/json.d-before" "$SB/PROJECT_VERSION.json" || fail "构建失败后 PROJECT_VERSION.json 未恢复原状"
grep -q "已恢复" "$SB/d-fail.log" || fail "构建失败日志缺少恢复说明"
rm -rf "$SB"

# 整轮测试（含多次构建、沙盒）后真实 PROJECT_VERSION.json 必须保持不变
[ "$(cat "$JSON_REAL")" = "$JSON_BEFORE" ] || fail "整轮测试改变了真实 PROJECT_VERSION.json"

echo "PASS: --release-fix 纪律（默认不递增 / 发布恰好递增一次 / 同轮重复不递增 / 失败恢复原计数）"
echo "PASS: 设置页版本号与构建产物、Info.plist、构建日志一致（${DISPLAY_VERSION}），Z 字图标未修改"
