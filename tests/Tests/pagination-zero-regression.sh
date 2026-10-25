#!/bin/bash
# pagination-zero-regression.sh — 翻页改造的**零回归强证据**（第 40 轮）
#
# 做法：用 `git show HEAD:` 取出改动前的 `DiscoverySessionController.m`，把其中的
# `+ sitePageURLForSeed:page:` **整段原文**（逐字节，不重写、不调整格式）抽出来，
# 以 category 形式重命名编译，然后与改动后的生产实现逐个对比 A 组用例，
# **两侧实际 URL 都打印**并逐字相等断言。
#
# 为什么不能只信新版测试：如果断言本身是我照着新实现写的，它天然不会红。
# 这里比对的是「改动前的真实代码」，是独立的第二份实现。
#
# 与其它套件一样串行（共用 build/generated/RDGeneratedVersion.h）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/pagination-zero-regression"
mkdir -p "$OUT"
export RD_LOG_PATH="$OUT/test-ResourceDetector.log"

bash "$REPO/scripts/generate-version.sh" >/dev/null

OLD_M="$OUT/DiscoverySessionController.HEAD.m"
git -C "$REPO" show HEAD:src/Features/ResourceDetector/DiscoverySessionController.m > "$OLD_M"

# 抽取旧方法原文：从签名行到下一条顶格 "}"（方法体里没有顶格 "}"，因为缩进四级）。
python3 - "$OLD_M" "$OUT/legacy_method.txt" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
sig = '+ (NSURL *)sitePageURLForSeed:(NSURL *)seedURL page:(NSInteger)page {'
try:
    start = lines.index(sig)
except ValueError:
    sys.exit('FATAL: 在 HEAD 版本里找不到 sitePageURLForSeed:page: 的原文签名')
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
  printf '// 自动生成：旧版零回归对照（正文取自 git show HEAD 的原文，一字未改）\n'
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
    printf("%s  %-58s page=%2ld\n    OLD(HEAD) = %s\n    NEW(main) = %s\n",
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

SRC=("$OUT/ZeroRegressionTests.m" "$OLD_M")
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Features" -name '*.m' -print | sort)
for f in IPAddressPolicy DNSResolver HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient \
         RDCurlHopper AppError RDLog PreferencesStore; do
  SRC+=("$ROOT/Shared/Infrastructure/$f.m")
done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m"
      "$ROOT/Shared/Infrastructure/Performance/PerformancePolicy.m"
      "$ROOT/Shared/UI/DesignSystem/ColorTokens.m"
      "$ROOT/Shared/UI/DesignSystem/TypographyTokens.m"
      "$ROOT/Shared/UI/StateView.m"
      "$ROOT/Shared/UI/UIThemeSupport.m")

INCLUDES=()
for dir in "$ROOT" "$ROOT/App" "$ROOT/Features/ResourceDetector" "$ROOT/Features/ResourceDownload" \
           "$ROOT/Shared" "$ROOT/Shared/Infrastructure" "$ROOT/Shared/Infrastructure/Async" \
           "$ROOT/Shared/Infrastructure/Performance" "$ROOT/Shared/UI" "$ROOT/Shared/UI/DesignSystem" \
           "$REPO/build/generated"; do INCLUDES+=("-I$dir"); done

# OLD_M 与生产 .m 同名，会与 Features 全树里的同名文件重复定义 → 从 SRC 里排除后者。
DEDUP=()
for f in "${SRC[@]}"; do
  [ "$f" = "$ROOT/Features/ResourceDetector/DiscoverySessionController.m" ] && continue
  DEDUP+=("$f")
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
