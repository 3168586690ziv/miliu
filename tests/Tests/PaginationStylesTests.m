// PaginationStylesTests.m — 列表页多形态分页专项（纯函数，无网络、无 WebKit 窗口）
//
// 背景：站点模式翻页此前只认 `?page=N`。分页是 `/page/2`、`/page2`、`_p2`、`-2`、
// `?p=2`、`?pg=2`、`?paged=2`、`/index_2.html` 的站点填了页数也只会重复请求同一页
// （甚至 404），翻页形同虚设。
//
// 本套件的断言分五组：
//   A 零回归（历史 `?page=N` 行为的输出必须逐字不变）
//   B 各风格生成（每风格：生成 page 2 与回到 page 1 两个方向）
//   C 自动探测（从 URL 自身推断风格与当前页号，用户不需要手动选）
//   D 边界与恶意输入（非法页码 / 非 http / 缺 host / userinfo / 超长路径 / 点段）
//   E 幂等（前进再后退不产生 page/2/page/1 这类垃圾路径；同输入两次结果相同）
#import <Foundation/Foundation.h>
#import "DiscoverySessionController.h"

static int gPassed = 0, gFailed = 0;

static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

static NSString *S(NSURL *u) { return u.absoluteString ?: @"<nil>"; }

/// 断言「构造结果字符串逐字等于期望」。
static void CheckURL(NSURL *got, NSString *expected, NSString *msg) {
    NSString *actual = got ? S(got) : @"<nil>";
    Check([actual isEqualToString:expected],
          [NSString stringWithFormat:@"%@ → 期望 %@，实际 %@", msg, expected, actual]);
}

/// 断言「构造结果为 nil」。
static void CheckNil(NSURL *got, NSString *msg) {
    Check(got == nil, [NSString stringWithFormat:@"%@ → 期望 nil，实际 %@",
                       msg, got ? S(got) : @"<nil>"]);
}

static NSURL *U(NSString *s) { return [NSURL URLWithString:s]; }

int main(void) {
    @autoreleasepool {
        Class C = [DiscoverySessionController class];

        // ══════════════════════════════════════════════════════════════════
        // A. 零回归：`?page=N` 与无标记 URL 的输出必须与改动前逐字相同
        // ══════════════════════════════════════════════════════════════════

        // A1 无 query 的种子 + page 2 → `?page=2`
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list") page:2],
                 @"https://s.test/list?page=2", @"A1 无 query + page2");

        // A2 已有筛选参数：保留并追加 page，参数顺序不变（genre 在前）
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?genre=x") page:3],
                 @"https://s.test/list?genre=x&page=3", @"A2 genre 保留且顺序不变");

        // A3 旧 page 被替换而不是重复追加
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?page=1") page:2],
                 @"https://s.test/list?page=2", @"A3 旧 page 被替换（不重复）");

        // A4 page=1 去掉 page 参数（回到首页形态）
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?page=1") page:1],
                 @"https://s.test/list", @"A4 page=1 去掉 page 参数");

        // A5 无 query 时不得出现尾部 "?"
        NSURL *a5 = [C sitePageURLForSeed:U(@"https://s.test/list") page:1];
        CheckURL(a5, @"https://s.test/list", @"A5a 无 query + page1 无尾部问号");
        Check(![S(a5) hasSuffix:@"?"], @"A5b 输出不以 '?' 结尾");

        // A6 带 fragment 的输入 → 输出 fragment 为 nil
        NSURL *a6 = [C sitePageURLForSeed:U(@"https://s.test/list?page=1#frag") page:2];
        CheckURL(a6, @"https://s.test/list?page=2", @"A6a 输出去掉 fragment");
        Check(a6.fragment == nil, @"A6b 输出 fragment 属性为 nil");

        // A7 带 port 与多参数：历史行为的顺序（非 page 参数原序，page 追加末尾）
        CheckURL([C sitePageURLForSeed:U(@"https://s.test:8080/l?a=1&page=1&b=2") page:4],
                 @"https://s.test:8080/l?a=1&b=2&page=4", @"A7 多参数 + 端口顺序保持");

        // A8 默认探测结果必须是 QueryPage（无标记的 URL 不得被误判成别的风格）
        Check([C detectPaginationStyleForURL:U(@"https://s.test/list")]
              == RDPaginationStyleQueryPage, @"A8 无标记 → QueryPage（默认风格）");

        // ══════════════════════════════════════════════════════════════════
        // B. 各风格生成：每种风格都测「生成 page 2」与「回到 page 1」
        // ══════════════════════════════════════════════════════════════════

        // ── QueryPage ──
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list") page:2
                                 style:RDPaginationStyleQueryPage],
                 @"https://s.test/list?page=2", @"B QueryPage page2");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?page=2") page:1
                                 style:RDPaginationStyleQueryPage],
                 @"https://s.test/list", @"B QueryPage page1（去掉 page）");

        // ── QueryP ──
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?p=1") page:2
                                 style:RDPaginationStyleQueryP],
                 @"https://s.test/list?p=2", @"B QueryP page2");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?p=5") page:1
                                 style:RDPaginationStyleQueryP],
                 @"https://s.test/list", @"B QueryP page1（去掉 p）");

        // ── QueryPg ──
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?pg=1") page:3
                                 style:RDPaginationStyleQueryPg],
                 @"https://s.test/list?pg=3", @"B QueryPg page3");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?pg=7") page:1
                                 style:RDPaginationStyleQueryPg],
                 @"https://s.test/list", @"B QueryPg page1（去掉 pg）");

        // ── QueryPaged ──
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?paged=1") page:2
                                 style:RDPaginationStyleQueryPaged],
                 @"https://s.test/list?paged=2", @"B QueryPaged page2");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?paged=9") page:1
                                 style:RDPaginationStyleQueryPaged],
                 @"https://s.test/list", @"B QueryPaged page1（去掉 paged）");

        // ── PathSlash ── 保留父目录，query 全部保留
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list") page:2
                                 style:RDPaginationStylePathSlash],
                 @"https://s.test/list/page/2", @"B PathSlash page2");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/page/4") page:1
                                 style:RDPaginationStylePathSlash],
                 @"https://s.test/list", @"B PathSlash page1（去掉 /page/N 段）");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/a/b/list/page/4") page:2
                                 style:RDPaginationStylePathSlash],
                 @"https://s.test/a/b/list/page/2", @"B PathSlash 保留父目录");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list?genre=x") page:2
                                 style:RDPaginationStylePathSlash],
                 @"https://s.test/list/page/2?genre=x", @"B PathSlash query 全部保留");
        // 末尾斜杠形态 /page/N/ 归一为不带尾斜杠
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/page/3/") page:2
                                 style:RDPaginationStylePathSlash],
                 @"https://s.test/list/page/2", @"B PathSlash 末尾斜杠形态归一");

        // ── PathConcat ──
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list") page:5
                                 style:RDPaginationStylePathConcat],
                 @"https://s.test/list/page5", @"B PathConcat page5");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/page9") page:1
                                 style:RDPaginationStylePathConcat],
                 @"https://s.test/list", @"B PathConcat page1（去掉 /pageN 段）");

        // ── SuffixP ── 末段 name_pN.ext
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name_p1.html") page:7
                                 style:RDPaginationStyleSuffixP],
                 @"https://s.test/list/name_p7.html", @"B SuffixP page7");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name_p7.html") page:1
                                 style:RDPaginationStyleSuffixP],
                 @"https://s.test/list/name.html", @"B SuffixP page1（去掉 _pN）");
        // 无扩展名形态
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name") page:3
                                 style:RDPaginationStyleSuffixP],
                 @"https://s.test/list/name_p3", @"B SuffixP 无扩展名 page3");

        // ── SuffixDash ── 末段 name-N.ext
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name-1.html") page:4
                                 style:RDPaginationStyleSuffixDash],
                 @"https://s.test/list/name-4.html", @"B SuffixDash page4");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name-4.html") page:1
                                 style:RDPaginationStyleSuffixDash],
                 @"https://s.test/list/name.html", @"B SuffixDash page1（去掉 -N）");

        // ── SuffixUnderscore ── 末段 name_N.ext
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name_1.html") page:6
                                 style:RDPaginationStyleSuffixUnderscore],
                 @"https://s.test/list/name_6.html", @"B SuffixUnderscore page6");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/name_6.html") page:1
                                 style:RDPaginationStyleSuffixUnderscore],
                 @"https://s.test/list/name.html", @"B SuffixUnderscore page1（去掉 _N）");

        // ── IndexHtml ── 末段 index_N.html
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/index.html") page:2
                                 style:RDPaginationStyleIndexHtml],
                 @"https://s.test/list/index_2.html", @"B IndexHtml 从 index.html 出发 page2");
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list/index_8.html") page:1
                                 style:RDPaginationStyleIndexHtml],
                 @"https://s.test/list/index.html", @"B IndexHtml page1（回到 index.html）");

        // ══════════════════════════════════════════════════════════════════
        // C. 自动探测：风格与当前页号都从 URL 自身推断
        // ══════════════════════════════════════════════════════════════════
        {
            NSURL *u = U(@"https://s.test/list?page=5");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPage
                  && [C sitePageNumberFromURL:u] == 5,
                  @"C1 ?page=5 → QueryPage 且当前页 5");
        }
        {
            NSURL *u = U(@"https://s.test/list?p=3");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryP
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleQueryP] == 3,
                  @"C2 ?p=3 → QueryP 且当前页 3");
        }
        {
            NSURL *u = U(@"https://s.test/list?pg=6");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPg
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleQueryPg] == 6,
                  @"C3 ?pg=6 → QueryPg 且当前页 6");
        }
        {
            NSURL *u = U(@"https://s.test/list?paged=2");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPaged
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleQueryPaged] == 2,
                  @"C4 ?paged=2 → QueryPaged 且当前页 2");
        }
        {
            NSURL *u = U(@"https://s.test/list/page/4");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStylePathSlash
                  && [C sitePageNumberFromURL:u style:RDPaginationStylePathSlash] == 4,
                  @"C5 /list/page/4 → PathSlash 且当前页 4");
        }
        {
            NSURL *u = U(@"https://s.test/list/page9");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStylePathConcat
                  && [C sitePageNumberFromURL:u style:RDPaginationStylePathConcat] == 9,
                  @"C6 /list/page9 → PathConcat 且当前页 9");
        }
        // ── 护栏：数字不像页码时不得被认成分页标记（否则比不改更糟）──
        // 依据：WordPress 的 ?p=<post id>、图库的 photo_2024.html（年份）、
        // name-1080 / clip_2160p（分辨率）。认错的后果是生成器把真名剥掉 → 404。
        {
            NSURL *u = U(@"https://s.test/?p=12345");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPage,
                  @"C13 ?p=12345（WordPress 文章 ID，超翻页上限）→ 不认作 QueryP");
            CheckURL([C sitePageURLForSeed:u page:2], @"https://s.test/?p=12345&page=2",
                     @"C14 ?p=12345 种子：走默认 page 参数，不剥掉 p");
        }
        {
            NSURL *u = U(@"https://s.test/gallery/photo_2024.html");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPage,
                  @"C15 photo_2024.html（年份）→ 不认作 SuffixUnderscore");
            CheckURL([C sitePageURLForSeed:u page:2],
                     @"https://s.test/gallery/photo_2024.html?page=2",
                     @"C16 photo_2024.html 种子：文件名原样保留");
        }
        {
            NSURL *u = U(@"https://s.test/v/name-1080.mp4");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPage,
                  @"C17 name-1080.mp4（分辨率）→ 不认作 SuffixDash");
        }
        {
            // 上限内的真分页标记仍必须被认出来（护栏不得把正常站点一起挡掉）
            Check([C detectPaginationStyleForURL:U(@"https://s.test/list/page10")]
                  == RDPaginationStylePathConcat, @"C18 /list/page10（上限内）→ 仍认作 PathConcat");
            Check([C detectPaginationStyleForURL:U(@"https://s.test/list?p=10")]
                  == RDPaginationStyleQueryP, @"C19 ?p=10（上限内）→ 仍认作 QueryP");
        }
        {
            NSURL *u = U(@"https://s.test/list/name_p7.html");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleSuffixP
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleSuffixP] == 7,
                  @"C7 /list/name_p7.html → SuffixP 且当前页 7");
        }
        {
            NSURL *u = U(@"https://s.test/list/name-3");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleSuffixDash
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleSuffixDash] == 3,
                  @"C8 /list/name-3 → SuffixDash 且当前页 3");
        }
        {
            NSURL *u = U(@"https://s.test/list/index_9.html");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleIndexHtml
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleIndexHtml] == 9,
                  @"C9 /list/index_9.html → IndexHtml 且当前页 9");
        }
        {
            // 无标记 → 默认风格且当前页 1（既有单参方法与探测都不许漂移）
            NSURL *u = U(@"https://s.test/list");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPage
                  && [C sitePageNumberFromURL:u] == 1
                  && [C sitePageNumberFromURL:u style:RDPaginationStyleQueryPage] == 1,
                  @"C10 无标记 → QueryPage 且当前页 1");
        }
        {
            // index.html 本身（未翻页）不得被误判成 IndexHtml 风格
            NSURL *u = U(@"https://s.test/list/index.html");
            Check([C detectPaginationStyleForURL:u] == RDPaginationStyleQueryPage,
                  @"C11 index.html（无页码）→ 不误判为 IndexHtml，退回默认");
        }
        {
            // 带筛选参数的 ?page 不得因为顺序在后面而被漏判
            Check([C detectPaginationStyleForURL:U(@"https://s.test/l?genre=x&page=2")]
                  == RDPaginationStyleQueryPage, @"C12 genre 在前、page 在后仍识别 page");
        }

        // ══════════════════════════════════════════════════════════════════
        // D. 边界与恶意输入
        // ══════════════════════════════════════════════════════════════════
        CheckNil([C sitePageURLForSeed:U(@"https://s.test/list") page:0], @"D1 page=0 → nil");
        CheckNil([C sitePageURLForSeed:U(@"https://s.test/list") page:-1], @"D2 page=-1 → nil");
        CheckNil([C sitePageURLForSeed:U(@"https://s.test/list") page:11], @"D3 page=11（超过上限）→ nil");
        // 上限是**相对种子起始页**算的（调用点 388-390 用 pageNumber = firstPage + index，
        // 第 373 行夹紧的是页数不是页码绝对值）。故种子自身已在第 12 页时，12..21 合法、22 越界。
        // 这条同时守住零回归：?page=15 的种子若被绝对上限判 nil，整批会在第一页就以 0 结果结束。
        Check([C sitePageURLForSeed:U(@"https://s.test/l?page=12") page:21] != nil,
              @"D3b 种子 page=12：page=21（相对 10 页内）→ 仍生成");
        CheckNil([C sitePageURLForSeed:U(@"https://s.test/l?page=12") page:22],
                 @"D3c 种子 page=12：page=22（相对越界）→ nil");
        CheckNil([C sitePageURLForSeed:U(@"file:///x") page:2], @"D4 file:// → nil");
        CheckNil([C sitePageURLForSeed:U(@"ftp://h/x") page:2], @"D5 ftp:// → nil");
        CheckNil([C sitePageURLForSeed:U(@"https:///x") page:2], @"D6 缺 host → nil");
        CheckNil([C sitePageURLForSeed:U(@"https://u:p@h/x") page:2], @"D7 带 userinfo → nil");
        // nil 种子：生产方法声明为非空入参，测试一律经 NSURL* 变量传入，避免 -Wnonnull 噪声。
        NSURL *nilSeed = nil;
        CheckNil([C sitePageURLForSeed:nilSeed page:2], @"D8 种子为 nil → nil");

        // 上限本身可用：page=10 必须是合法输入
        CheckURL([C sitePageURLForSeed:U(@"https://s.test/list") page:10],
                 @"https://s.test/list?page=10", @"D9 page=10（等于上限）→ 正常生成");
        Check([C siteMaxPages] == 10, @"D10 siteMaxPages 仍为 10");

        // 极长路径（4000 字符）不崩，且返回合理值
        {
            NSString *longName = [@"" stringByPaddingToLength:4000 withString:@"a" startingAtIndex:0];
            NSURL *seed = U([NSString stringWithFormat:@"https://s.test/list/w_1.html?x=%@", longName]);
            NSURL *got = [C sitePageURLForSeed:seed page:2 style:RDPaginationStyleSuffixUnderscore];
            Check(got != nil, @"D11 极长 query（4000 字符）不崩且返回非 nil");
            Check([S(got) containsString:@"/list/w_2.html"],
                  @"D12 极长 query 下末段仍正确改写（其余参数原样保留）");
        }

        // 路径含 ".." / "." 段：不崩、不产生非法 URL（不做规范化，只要求不炸）
        {
            NSURL *seed = U(@"https://s.test/a/../b/./list");
            NSURL *got = [C sitePageURLForSeed:seed page:2 style:RDPaginationStylePathSlash];
            Check(got != nil && got.scheme.length > 0 && got.host.length > 0,
                  @"D13 路径含 .. / . 段不崩且仍是合法 URL");
            Check([S(got) hasSuffix:@"/page/2"], @"D14 点段路径仍正确追加 /page/2");
        }

        // 空 query 种子（尾部问号）不得把 "?" 带进结果
        {
            NSURL *got = [C sitePageURLForSeed:U(@"https://s.test/list?") page:1
                                          style:RDPaginationStyleQueryPage];
            Check(![S(got) hasSuffix:@"?"], @"D15 种子带空 query：page1 结果不留尾部问号");
        }

        // 非查询型风格同样必须丢 fragment
        {
            NSURL *got = [C sitePageURLForSeed:U(@"https://s.test/list#sec") page:2
                                          style:RDPaginationStylePathSlash];
            CheckURL(got, @"https://s.test/list/page/2", @"D16 PathSlash 输出丢 fragment");
        }

        // 非法页码在非默认风格下同样拒绝
        CheckNil([C sitePageURLForSeed:U(@"https://s.test/list") page:0
                                  style:RDPaginationStylePathSlash], @"D17 style 版 page=0 → nil");
        CheckNil([C sitePageURLForSeed:U(@"https://s.test/list") page:12
                                  style:RDPaginationStyleIndexHtml], @"D18 style 版 page=12 → nil");

        // ══════════════════════════════════════════════════════════════════
        // E. 幂等 / 一致性：前进再后退必须回到基形，不得叠出垃圾路径
        // ══════════════════════════════════════════════════════════════════
        {
            struct { RDPaginationStyle style; NSString *seed; NSString *base; NSString *p2; } cases[] = {
                { RDPaginationStyleQueryPage,        @"https://s.test/list",             @"https://s.test/list",             @"https://s.test/list?page=2" },
                { RDPaginationStyleQueryP,           @"https://s.test/list",             @"https://s.test/list",             @"https://s.test/list?p=2" },
                { RDPaginationStyleQueryPg,          @"https://s.test/list",             @"https://s.test/list",             @"https://s.test/list?pg=2" },
                { RDPaginationStyleQueryPaged,       @"https://s.test/list",             @"https://s.test/list",             @"https://s.test/list?paged=2" },
                { RDPaginationStylePathSlash,        @"https://s.test/list",             @"https://s.test/list",             @"https://s.test/list/page/2" },
                { RDPaginationStylePathConcat,       @"https://s.test/list",             @"https://s.test/list",             @"https://s.test/list/page2" },
                { RDPaginationStyleSuffixP,          @"https://s.test/list/name.html",   @"https://s.test/list/name.html",   @"https://s.test/list/name_p2.html" },
                { RDPaginationStyleSuffixDash,       @"https://s.test/list/name.html",   @"https://s.test/list/name.html",   @"https://s.test/list/name-2.html" },
                { RDPaginationStyleSuffixUnderscore, @"https://s.test/list/name.html",   @"https://s.test/list/name.html",   @"https://s.test/list/name_2.html" },
                { RDPaginationStyleIndexHtml,        @"https://s.test/list/index.html",  @"https://s.test/list/index.html",  @"https://s.test/list/index_2.html" },
            };
            size_t n = sizeof(cases) / sizeof(cases[0]);
            for (size_t i = 0; i < n; i++) {
                NSURL *seed = U(cases[i].seed);
                // 前进：seed → page2
                NSURL *fwd = [C sitePageURLForSeed:seed page:2 style:cases[i].style];
                Check([S(fwd) isEqualToString:cases[i].p2],
                      [NSString stringWithFormat:@"E1.%zu style %ld 前进到 page2 = %@",
                       i, (long)cases[i].style, cases[i].p2]);
                // 再前进：page2 → page3（旧标记必须被替换，不得叠加）
                NSURL *fwd3 = [C sitePageURLForSeed:fwd page:3 style:cases[i].style];
                Check(fwd3 != nil && ![S(fwd3) containsString:@"page/2"] &&
                      ![S(fwd3) containsString:@"page2"] && ![S(fwd3) containsString:@"_p2"] &&
                      ![S(fwd3) containsString:@"-2."] && ![S(fwd3) containsString:@"_2."],
                      [NSString stringWithFormat:@"E2.%zu style %ld page2→page3 不叠加旧标记（%@）",
                       i, (long)cases[i].style, S(fwd3)]);
                // 后退：page2 → page1 回到基形（不是基形+page/1 之类）
                NSURL *back = [C sitePageURLForSeed:fwd page:1 style:cases[i].style];
                Check([S(back) isEqualToString:cases[i].base],
                      [NSString stringWithFormat:@"E3.%zu style %ld 后退回基形 = %@（实际 %@）",
                       i, (long)cases[i].style, cases[i].base, S(back)]);
            }
        }

        // 同输入两次调用输出相同（无隐藏状态）
        {
            NSURL *seed = U(@"https://s.test/list?genre=x&page=1");
            NSURL *r1 = [C sitePageURLForSeed:seed page:3];
            NSURL *r2 = [C sitePageURLForSeed:seed page:3];
            Check([S(r1) isEqualToString:S(r2)], @"E4 同输入两次调用结果相同（默认入口）");
            NSURL *s1 = [C sitePageURLForSeed:seed page:3 style:RDPaginationStylePathSlash];
            NSURL *s2 = [C sitePageURLForSeed:seed page:3 style:RDPaginationStylePathSlash];
            Check([S(s1) isEqualToString:S(s2)], @"E5 同输入两次调用结果相同（显式风格入口）");
            // 护栏与生成器一致：不认作标记的 URL，两种入口必须给出同一结果
            NSURL *guarded = U(@"https://s.test/gallery/photo_2024.html");
            NSURL *viaDefault = [C sitePageURLForSeed:guarded page:2];
            NSURL *viaExplicit = [C sitePageURLForSeed:guarded page:2
                                                  style:[C detectPaginationStyleForURL:guarded]];
            Check([S(viaDefault) isEqualToString:S(viaExplicit)],
                  @"E7 护栏判定与默认入口一致（同输入两条路径同输出）");
            // 探测同样是纯函数：反复调用结果不变
            RDPaginationStyle st1 = [C detectPaginationStyleForURL:seed];
            RDPaginationStyle st2 = [C detectPaginationStyleForURL:seed];
            Check(st1 == st2 && st1 == RDPaginationStyleQueryPage,
                  @"E6 探测结果稳定且为 QueryPage");
        }

        NSLog(@"PAGINATION-STYLES-%@ checks=%d failed=%d",
              gFailed == 0 ? @"PASSED" : @"FAILED", gPassed, gFailed);
    }
    return gFailed == 0 ? 0 : 1;
}
