#!/bin/bash
# pagination-zero-regression.sh — 翻页改造的**零回归强证据**（第 40 轮）
#
# 做法：取出改动前的 `DiscoverySessionController.m`，把其中的
# `+ sitePageURLForSeed:page:` **整段原文**（逐字节，不重写、不调整格式）抽出来，
# 以 category 形式重命名编译，然后与改动后的生产实现逐个对比 A 组用例，
# **两侧实际 URL 都打印**并逐字相等断言。
#
# 为什么不能只信新版测试：如果断言本身是我照着新实现写的，它天然不会红。
# 这里比对的是「改动前的真实代码」，是独立的第二份实现。
#
# ⚠ 基线必须**钉死到具体提交**，不能用 `HEAD`（2026-10-26 修）：
#   原实现取 `git show HEAD:`，靠的是「改动尚未提交」这个前提。第 44 轮一旦提交，
#   HEAD 里就是新代码，抽出来只剩一行转发壳（3 行），本套件从此**必然失败**：
#     FAIL: 抽出的旧方法不含 page 参数构造
#   基线一旦漂移，整个套件就失去意义。故钉到第 43 轮提交（bec83e0，44 轮之前
#   的最后一个仍含旧实现的提交）。这是「冻结的历史样本」，不是「随 HEAD 移动的
#   活引用」——零回归对照要的正是冻结样本。
#
# 与其它套件一样串行（共用 build/generated/RDGeneratedVersion.h）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/pagination-zero-regression"
mkdir -p "$OUT"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

# 冻结基线：第 43 轮（bec83e0）—— 第 44 轮翻页改造之前的最后一个提交。
LEGACY_BASELINE_COMMIT="bec83e0a17ae5ae7f9522537c65f47272b77196d"
LEGACY_BASELINE_LABEL="43轮/bec83e0"

bash "$REPO/scripts/generate-version.sh" >/dev/null

OLD_M="$OUT/DiscoverySessionController.legacy.m"
git -C "$REPO" cat-file -e "${LEGACY_BASELINE_COMMIT}^{commit}" 2>/dev/null || {
  echo "FAIL: 找不到冻结基线提交 $LEGACY_BASELINE_COMMIT（浅克隆请先 git fetch --unshallow）"
  exit 1
}
git -C "$REPO" show "$LEGACY_BASELINE_COMMIT":src/Features/ResourceDetector/DiscoverySessionController.m > "$OLD_M" || {
  echo "FAIL: 无法从 $LEGACY_BASELINE_COMMIT 取出 DiscoverySessionController.m"
  exit 1
}

# 抽取旧方法原文：从签名行到下一条顶格 "}"（方法体里没有顶格 "}"，因为缩进四级）。
python3 - "$OLD_M" "$OUT/legacy_method.txt" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
sig = '+ (NSURL *)sitePageURLForSeed:(NSURL *)seedURL page:(NSInteger)page {'
try:
    start = lines.index(sig)
except ValueError:
    sys.exit('FATAL: 在冻结基线版本里找不到 sitePageURLForSeed:page: 的原文签名')
end = start + 1
while lines[end] != '}':
    end += 1
body = '\n'.join(lines[start:end + 1])
open(dst, 'w', encoding='utf-8').write(body + '\n')
print('抽出的旧方法行数 =', end - start + 1)
PY

# 校验抽取确实拿到了「设置/替换 page 参数」的旧逻辑（而不是空壳）。
grep -q 'queryItemWithName:@"page"' "$OUT/legacy_method.txt" || { echo "FAIL: 抽出的旧方法不含 page 参数构造"; exit 1; }
grep -q 'c.queryItems = items.count' "$OUT/legacy_method.txt" || { echo "FAIL: 抽出的旧方法不含空数组置 nil 的处理"; exit 1; }

# 生成 harness：旧方法原文改个选择器名塞进 category，正文逐字不动。
{
  printf '// 自动生成：旧版零回归对照（正文取自冻结基线 %s 的原文，一字未改）\n' "${LEGACY_BASELINE_LABEL}"
  printf '#import <Foundation/Foundation.h>\n'
  printf '#import "DiscoverySessionController.h"\n\n'
  printf '@interface DiscoverySessionController (RDPaginationLegacy)\n'
  printf '+ (nullable NSURL *)sitePageURLForSeed_Legacy:(NSURL *)seedURL page:(NSInteger)page;\n'
  printf '@end\n\n'
  printf '@implementation DiscoverySessionController (RDPaginationLegacy)\n'
  sed 's|^+ (NSURL \*)sitePageURLForSeed:(NSURL \*)seedURL page:(NSInteger)page {|+ (NSURL *)sitePageURLForSeed_Legacy:(NSURL *)seedURL page:(NSInteger)page {|' "$OUT/legacy_method.txt"
  printf '@end\n\n'
  cat <<'HARNESS'
static int gPassed = 0, gFailed = 0;
static void Cmp(NSString *label, NSString *seed, NSInteger page) {
    NSURL *u = [NSURL URLWithString:seed];
    NSURL *oldURL = [DiscoverySessionController sitePageURLForSeed_Legacy:u page:page];
    NSURL *newURL = [DiscoverySessionController sitePageURLForSeed:u page:page];
    NSString *o = oldURL ? oldURL.absoluteString : @"<nil>";
    NSString *n = newURL ? newURL.absoluteString : @"<nil>";
    BOOL same = [o isEqualToString:n];
    if (same) gPassed++; else gFailed++;
    printf("%s  %-58s page=%2ld\n    OLD(legacy) = %s\n    NEW(main) = %s\n",
           same ? "PASS" : "FAIL", label.UTF8String, (long)page, o.UTF8String, n.UTF8String);
    if (!same) printf("    ^^^ 逐字不等 —— 零回归被破坏\n");
}
int main(void) { @autoreleasepool {
    // A 组：零回归六例（题目指定的 A1–A6）+ 四例同族加固
    Cmp(@"A1 无 query + page2", @"https://s.test/list", 2);
    Cmp(@"A2 genre 在前 + page3", @"https://s.test/list?genre=x", 3);
    Cmp(@"A3 旧 page 被替换", @"https://s.test/list?page=1", 2);
    Cmp(@"A4 page1 去掉 page", @"https://s.test/list?page=1", 1);
    Cmp(@"A5 无 query + page1（无尾部 ?）", @"https://s.test/list", 1);
    Cmp(@"A6 带 fragment + page2", @"https://s.test/list?page=1#frag", 2);
    Cmp(@"A7 端口 + 多参数 + page4", @"https://s.test:8080/l?a=1&page=1&b=2", 4);
    Cmp(@"A8 筛选参数 percent-encoding 保持", @"https://s.test/l?a=%20b&page=1", 2);
    Cmp(@"A9 大写 PAGE 归一", @"https://s.test/l?PAGE=3", 2);
    Cmp(@"A10 首页无路径 + page2", @"https://s.test", 2);
    Cmp(@"A11 根路径 + page1", @"https://s.test/", 1);
    Cmp(@"A12 尾斜杠 + 多参数 + page10", @"https://s.test/l/?a=1&b=2", 10);
    // A13/A14：种子自身页码已超 siteMaxPages 的情形。历史实现照写不误（它没有上限检查），
    // 新版必须在同一情形给出逐字相同结果——否则 `?page=15` 的种子会让整批零结果。
    Cmp(@"A13 种子 page=15 + page15", @"https://s.test/list?page=15", 15);
    Cmp(@"A14 种子 page=15 + page17", @"https://s.test/list?page=15", 17);
    // A15：种子带 query 且自身页码超限，仍必须逐字相同
    Cmp(@"A15 种子 page=12 + genre + page13", @"https://s.test/l?genre=x&page=12", 13);
    // 注意用 %s + UTF8String：NSString 直接喂 %s 会打出乱码（tagged pointer）。
    printf("ZERO-REGRESSION-%s compared=%d failed=%d\n",
           (gFailed == 0 ? @"PASSED" : @"FAILED").UTF8String, gPassed + gFailed, gFailed);
} return gFailed == 0 ? 0 : 1; }
HARNESS
} > "$OUT/ZeroRegressionTests.m"

SRC=("$OUT/ZeroRegressionTests.m")   # 注意：不含 OLD_M（旧方法正文已由 harness category 提供）
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in IPAddressPolicy DNSResolver HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient \
         RDCurlHopper AppError RDLog PreferencesStore; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m"
      "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
      "$ROOT/Shared/UI/DesignSystem/ColorTokens.m"
      "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m"
     
     )

INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" \
           "$ROOT/Shared" "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" \
           "$ROOT/Shared/Infrastructure/Performance" "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" \
           "$REPO/build/generated"; do INCLUDES+=("-I$dir"); done

# ⚠ 编译清单必须**同时**包含生产实现，不能把生产文件排除掉（2026-10-26 修）：
#   原实现把 `OLD_M`（整份旧 .m）和 `NEW`（生产 .m）都放进 SRC，二者同名同符号
#   → 链接冲突，于是代码把**生产文件 DEDUP 掉**了。后果是 `sitePageURLForSeed:page:`
#   这个选择器只能从 OLD_M 里解析——`NEW(main)` 打印的其实是**旧实现**，整套用例
#   变成「旧代码 vs 旧代码」，**永远恒绿**（实测：把生产实现改成 `page+1` 仍 PASS）。
#   正确做法是利用 harness 里已有的 category：旧方法正文已经以
#   `sitePageURLForSeed_Legacy:page:` 的形式逐字塞进 ZeroRegressionTests.m，
#   故 OLD_M 根本不需要参与编译。只编译生产实现 + harness，两侧才是两份真实现。
DEDUP=("${SRC[@]}")

# 防假绿前置断言：生产文件必须在编译清单里，否则本套件无意义。
PROD_M="$ROOT/Features/ResourceDetector/DiscoverySessionController.m"
_found=0
for f in "${DEDUP[@]}"; do [ "$f" = "$PROD_M" ] && _found=1; done
[ "$_found" = 1 ] || { echo "FAIL: 生产实现未进入编译清单（零回归对照会退化为旧代码自比）"; exit 1; }
# 反向断言：旧文件不得参与编译，否则会与生产实现重复定义同一符号。
for f in "${DEDUP[@]}"; do
  [ "$f" = "$OLD_M" ] && { echo "FAIL: 旧实现整份文件混入编译清单（与生产类重复定义，会遮蔽新实现）"; exit 1; }
done

xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework WebKit -framework AVKit -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
  -lsqlite3 \
  "${INCLUDES[@]}" "${DEDUP[@]}" -o "$OUT/ZeroRegressionTests" > "$OUT/compile.log" 2>&1 || {
    cat "$OUT/compile.log"; echo "FAIL: 编译失败"; exit 1
  }

"$OUT/ZeroRegressionTests"
printf 'PASS: 零回归对照（旧版原文 vs 新版实现逐字比对）通过\n'
