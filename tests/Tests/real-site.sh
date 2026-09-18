#!/bin/bash
# real-site.sh — 真实网址现场复现/验收（编译生产源码，无网络替身、无 ASan）
# 用法：bash tests/Tests/real-site.sh <app|static|dynamic|hybrid> <url>
#       bash tests/Tests/real-site.sh download <url> <referer> <title> [expectHeight] [destDir]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; BUILD="$REPO/build"
OUT="$BUILD/real-site-probe"

# 日志隔离：本测试驱动生产代码（含 RDLog 调用），绝不能污染用户真实日志。
# 安全约束（2026-09-18 revision3）：不接受任何外部继承的 RD_LOG_PATH —— 它可能指向用户
# 真实日志路径；本脚本一律覆盖它，只认自己的专用变量 REAL_SITE_LOG_PATH，并做**结构化**
# 校验（realpath 归一 + 解析 symlink，早于任何 mkdir/写入）：允许根为项目 outputs/ 与
# build/；支持目标文件尚不存在；拒绝已存在目标为 symlink、经 .. 或目录 symlink 逸出。
LOG_TARGET="$OUT/test-ResourceDetector.log"
if [ -n "${REAL_SITE_LOG_PATH:-}" ]; then
  LOG_DECISION=$(REAL_SITE_LOG_PATH="$REAL_SITE_LOG_PATH" REPO="$REPO" BUILD="$BUILD" python3 - <<'PY'
import os
raw = os.environ["REAL_SITE_LOG_PATH"]
repo = os.path.realpath(os.environ["REPO"])
allowed = [os.path.realpath(os.path.join(repo, "outputs")),
           os.path.realpath(os.environ["BUILD"])]
# 已存在的目标本身是 symlink → 拒绝（即使它指向允许根内，也不接受间接写入）
if os.path.islink(raw):
    print("REJECT=SYMLINK"); raise SystemExit
absraw = os.path.abspath(raw)
# 只解析父目录（允许目标文件尚不存在），symlink 与 .. 都在这里归一
parent = os.path.realpath(os.path.dirname(absraw))
target = os.path.join(parent, os.path.basename(absraw))
if os.path.isdir(target):
    print("REJECT=ISDIR"); raise SystemExit
inside = any(target == r or target.startswith(r.rstrip("/") + "/") for r in allowed)
print(("ACCEPT=" + target) if inside else "REJECT=OUTSIDE")
PY
)
  case "$LOG_DECISION" in
    ACCEPT=*) LOG_TARGET="${LOG_DECISION#ACCEPT=}" ;;
    *) printf 'RS-WARN 忽略不合规的 REAL_SITE_LOG_PATH=%s（%s；仅允许项目 outputs/ 或 build/ 之下且不得 symlink/.. 逸出）\n' \
         "$REAL_SITE_LOG_PATH" "$LOG_DECISION" >&2
       LOG_TARGET="$OUT/test-ResourceDetector.log" ;;
  esac
fi
if [ -n "${RD_LOG_PATH:-}" ] && [ "$RD_LOG_PATH" != "$LOG_TARGET" ]; then
  printf 'RS-NOTE 已忽略外部继承的 RD_LOG_PATH，改用隔离日志路径 %s\n' "$LOG_TARGET" >&2
fi
export RD_LOG_PATH="$LOG_TARGET"
mkdir -p "$OUT"
mkdir -p "$(dirname "$RD_LOG_PATH")"
bash "$REPO/scripts/generate-version.sh" >/dev/null

SRC=("$REPO/tests/Tests/RealSiteProbe.m" "$ROOT/App/ResourceResultRowView.m")
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

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  "${INCLUDES[@]}" "${SRC[@]}" -o "$OUT/RealSiteProbe" >"$OUT/compile.log" 2>&1
if grep -E "error:" "$OUT/compile.log" >/dev/null; then cat "$OUT/compile.log"; exit 1; fi
BAD=$(grep -E "warning:" "$OUT/compile.log" | grep -v "nullability" | grep -v "arc-retain-cycles" || true)
if [ -n "$BAD" ]; then printf '%s\n' "$BAD"; echo "FAIL: 新增编译警告"; exit 1; fi
printf 'RS-BIN %s/RealSiteProbe\n' "$OUT"
set +e
"$OUT/RealSiteProbe" "$@"
RC=$?
set -e
printf 'RS-EXIT %d\n' "$RC"
exit $RC
