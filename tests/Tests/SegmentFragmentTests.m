//
//  SegmentFragmentTests.m — HLS/DASH 分片收口专项（第 47 轮）
//
//  背景（用户实测报障）：jav.guru 这类站点探测后列表出现几十上百个「视频」，
//  点任何一个下载到的只是碎片。根因：HLS 播放时 hls.js 逐片 fetch，
//  动态腿把每个分片（seg-000.ts…）都当独立媒体上报。本套件锁定判据双向正确：
//  分片必须被收口，而**整段 .ts 直链必须保留**（项目既有用例明确要求）。
//
#import <Foundation/Foundation.h>
#import "RDURLUtilities.h"

static int gPassed = 0, gFailed = 0;
static void Chk(BOOL ok, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    printf("  %s %s\n", ok ? "PASS" : "FAIL", m.UTF8String);
    if (ok) gPassed++; else gFailed++;
}
static NSURL *U(NSString *s) { return [NSURL URLWithString:s]; }

int main(void) { @autoreleasepool {
    printf("== T1 分片形态识别（URL 自身）==\n");
    Chk(RDURLResemblesSegment(U(@"https://c.test/hls/1/seg-000.ts")), @"seg-000.ts 是分片形态");
    Chk(RDURLResemblesSegment(U(@"https://c.test/hls/1/chunk_12.ts")), @"chunk_12.ts 是分片形态");
    Chk(RDURLResemblesSegment(U(@"https://c.test/hls/1/part.3.ts")), @"part.3.ts 是分片形态");
    Chk(RDURLResemblesSegment(U(@"https://c.test/hls/1/out=5.ts")), @"out=5.ts 是分片形态");
    Chk(RDURLResemblesSegment(U(@"https://c.test/hls/1/0.ts")), @"0.ts（纯数字主干）是分片形态");
    Chk(RDURLResemblesSegment(U(@"https://c.test/hls/1/seg-1.m4s")), @"seg-1.m4s 是分片形态");

    printf("\n== T2 整段媒体不得被判为分片（关键防回归）==\n");
    Chk(!RDURLResemblesSegment(U(@"https://c.test/plain/ep01.ts")), @"ep01.ts 不是分片（字母数字连写=作品编号）");
    Chk(!RDURLResemblesSegment(U(@"https://c.test/plain/live.ts")), @"live.ts 不是分片");
    Chk(!RDURLResemblesSegment(U(@"https://c.test/plain/show1080.ts")), @"show1080.ts 不是分片");
    Chk(!RDURLResemblesSegment(U(@"https://c.test/v/a.mp4")), @"a.mp4 不是分片");
    Chk(!RDURLResemblesSegment(U(@"https://c.test/hls/index.m3u8")), @"index.m3u8 不是分片");

    printf("\n== T3 完整判据：必须同批有清单 + 同 host 同目录 ==\n");
    NSArray *mans = @[U(@"https://c.test/hls/633996/index.m3u8")];
    Chk(RDIsHLSPlaylistFragment(U(@"https://c.test/hls/633996/seg-000.ts"), mans), @"同目录 seg-000.ts → 收口");
    Chk(RDIsHLSPlaylistFragment(U(@"https://c.test/hls/633996/seg-599.ts"), mans), @"同目录 seg-599.ts → 收口");
    Chk(RDIsHLSPlaylistFragment(U(@"https://c.test/hls/633996/seg-0.m4s"), mans), @"同目录 m4s 分片 → 收口");
    Chk(!RDIsHLSPlaylistFragment(U(@"https://c.test/plain/ep01.ts"), mans), @"不同目录 → 保留");
    Chk(!RDIsHLSPlaylistFragment(U(@"https://other.test/hls/633996/seg-000.ts"), mans), @"跨 host → 保留");
    Chk(!RDIsHLSPlaylistFragment(U(@"https://c.test/hls/633996/seg-000.ts"), @[]), @"无清单在场 → 保留（单独 .ts 永远是媒体）");
    Chk(!RDIsHLSPlaylistFragment(U(@"https://c.test/hls/OTHER/index.m3u8"), mans), @"清单自身永不被收口");

    printf("\n== T4 多清单/目录边界 ==\n");
    NSArray *two = @[U(@"https://c.test/hls/a/index.m3u8"), U(@"https://c.test/hls/b/index.m3u8")];
    Chk(RDIsHLSPlaylistFragment(U(@"https://c.test/hls/a/seg-3.ts"), two), @"目录 a 的分片命中清单 a");
    Chk(RDIsHLSPlaylistFragment(U(@"https://c.test/hls/b/seg-7.ts"), two), @"目录 b 的分片命中清单 b");
    Chk(!RDIsHLSPlaylistFragment(U(@"https://c.test/hls/c/seg-1.ts"), two), @"目录 c 无对应清单 → 保留");

    printf("\nSEGMENT-FILTER-%s passed=%d failed=%d\n",
           gFailed == 0 ? "PASSED" : "FAILED", gPassed, gFailed);
} return gFailed == 0 ? 0 : 1; }
