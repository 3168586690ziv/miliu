// MediaDiscoveryTests.m — 抓取能力升级专项（第 29 轮）
// 覆盖：og:video / twitter:player:stream meta、JSON-LD VideoObject、
// HTML 全文直链兜底、扩展名白名单（mkv/ts/flv/音频）、旧结构零回归。
// 纯函数测试：只调 RDProbeAnalyzer.analyzeHTML / RDStaticScriptAnalyzer，
// 无网络、无 NSApplication、无窗口。
#import <Foundation/Foundation.h>
#import "WebProbe.h"
#import "RDStaticScriptAnalyzer.h"
#import "DetectedMedia.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

static DetectedMedia *FirstVideoWithSource(RDProbeResult *r, NSString *source) {
    for (DetectedMedia *m in r.media) {
        if ([m.discoverySource isEqualToString:source]) return m;
    }
    return nil;
}

static BOOL ContainsURL(RDProbeResult *r, NSString *url) {
    for (DetectedMedia *m in r.media) {
        if ([m.mediaURL isEqualToString:url]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSLog(@"== 抓取能力升级专项（第 29 轮）==");

        // ── 1. og:video meta（分享页/嵌入页最常见声明）──
        {
            NSString *html = @"<html><head>"
                @"<meta property=\"og:title\" content=\"测试影片\">"
                @"<meta property=\"og:image\" content=\"https://cdn.example.com/cover.jpg\">"
                @"<meta property=\"og:video\" content=\"https://cdn.example.com/video/clip.mp4?token=abc\">"
                @"<meta property=\"og:video:width\" content=\"1280\">"
                @"<meta property=\"og:video:height\" content=\"720\">"
                @"</head><body></body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/watch/1"]];
            DetectedMedia *dm = FirstVideoWithSource(r, @"meta-video");
            Check(dm != nil, @"og:video 声明被发现（discoverySource=meta-video）");
            Check(dm && [dm.mediaURL isEqualToString:@"https://cdn.example.com/video/clip.mp4?token=abc"],
                  @"og:video 地址含 query 完整保留");
            Check(dm && dm.resourceKind == RDResourceKindVideo, @"og:video 归类为视频");
            Check(dm && [dm.poster isEqualToString:@"https://cdn.example.com/cover.jpg"], @"og:video 附带 og:image 作封面");
            Check(dm && [dm.title isEqualToString:@"测试影片"], @"og:video 标题取 og:title");
            // og:video:width/height 不是地址，不得误报
            NSUInteger metaCount = 0;
            for (DetectedMedia *m in r.media) if ([m.discoverySource isEqualToString:@"meta-video"]) metaCount++;
            Check(metaCount == 1, @"og:video:width/height 数值声明不误报（只 1 条 meta-video）");
        }

        // ── 2. twitter:player:stream + og:video:secure_url ──
        {
            NSString *html = @"<html><head>"
                @"<meta name=\"twitter:player:stream\" content=\"https://cdn.example.com/stream/720.mp4\">"
                @"<meta property=\"og:video:secure_url\" content=\"https://cdn.example.com/secure/master.m3u8\">"
                @"</head><body></body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/tweet/1"]];
            Check(ContainsURL(r, @"https://cdn.example.com/stream/720.mp4"), @"twitter:player:stream 直链被发现");
            DetectedMedia *m3u8 = nil;
            for (DetectedMedia *m in r.media) if ([m.mediaURL hasSuffix:@"master.m3u8"]) m3u8 = m;
            Check(m3u8 && m3u8.resourceKind == RDResourceKindManifest, @"og:video:secure_url 的 m3u8 归类为清单");
        }

        // ── 3. JSON-LD VideoObject contentUrl ──
        {
            NSString *html = @"<html><head>"
                @"<script type=\"application/ld+json\">"
                @"{\"@type\":\"VideoObject\",\"name\":\"结构化视频\","
                @"\"contentUrl\":\"https://media.example.com/ld/lesson.mp4\","
                @"\"thumbnailUrl\":\"https://media.example.com/ld/thumb.jpg\","
                @"\"embedUrl\":\"https://media.example.com/embed/9900\"}"
                @"</script></head><body></body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/news/1"]];
            DetectedMedia *dm = FirstVideoWithSource(r, @"jsonld-video");
            Check(dm != nil, @"JSON-LD contentUrl 被发现（discoverySource=jsonld-video）");
            Check(dm && [dm.mediaURL isEqualToString:@"https://media.example.com/ld/lesson.mp4"], @"JSON-LD 地址正确");
            // embedUrl 是页面地址不是媒体文件，被 format 白名单拦下
            BOOL embedLeaked = NO;
            for (DetectedMedia *m in r.media) if ([m.mediaURL hasSuffix:@"/embed/9900"]) embedLeaked = YES;
            Check(!embedLeaked, @"JSON-LD embedUrl（无媒体扩展名）不误报");
        }

        // ── 4. JSON-LD 非严格 JSON（正则兜底路径）──
        {
            NSString *html = @"<html><head>"
                @"<script type=\"application/ld+json\">"
                @"{\"@type\":\"VideoObject\",\"contentUrl\": \"https://media.example.com/sloppy/movie.mkv\",}"
                @"</script></head><body></body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/x"]];
            Check(ContainsURL(r, @"https://media.example.com/sloppy/movie.mkv"), @"非严格 JSON（尾逗号）走正则兜底仍发现 mkv");
        }

        // ── 5. HTML 全文直链兜底（无任何标签结构，只 script 配置字符串）──
        {
            NSString *html = @"<html><head><script>"
                @"var playerConfig = {sources: [{file: \"https://cdn.example.com/plain/ep01.ts\"}]};"
                @"var hlsSrc = 'https://cdn.example.com/plain/index.m3u8';"
                @"</script></head><body><div id=\"player\"></div></body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/embed/1"]];
            Check(ContainsURL(r, @"https://cdn.example.com/plain/ep01.ts"), @"全文兜底发现裸 .ts 直链");
            Check(ContainsURL(r, @"https://cdn.example.com/plain/index.m3u8"), @"全文兜底发现裸 .m3u8 直链");
        }

        // ── 6. 扩展名白名单：mkv/ts/flv/m4a 经懒加载属性 ──
        {
            NSString *html = @"<html><body>"
                @"<div data-video=\"https://cdn.example.com/attr/movie.mkv\"></div>"
                @"<div data-src=\"https://cdn.example.com/attr/live.ts\"></div>"
                @"<div data-url=\"https://cdn.example.com/attr/old.flv\"></div>"
                @"<div data-file=\"https://cdn.example.com/attr/audio.m4a\"></div>"
                @"</body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/attr"]];
            Check(ContainsURL(r, @"https://cdn.example.com/attr/movie.mkv"), @"data-video 属性发现 .mkv");
            Check(ContainsURL(r, @"https://cdn.example.com/attr/live.ts"), @"data-src 属性发现 .ts");
            Check(ContainsURL(r, @"https://cdn.example.com/attr/old.flv"), @"data-url 属性发现 .flv");
            Check(ContainsURL(r, @"https://cdn.example.com/attr/audio.m4a"), @"data-file 属性发现 .m4a（音频走视频管线）");
        }

        // ── 7. 零回归：既有结构照常工作 ──
        {
            NSString *html = @"<html><head><base href=\"https://cdn.example.com/base/\"></head><body>"
                @"<video poster=\"/p/cover.jpg\"><source src=\"v/480.mp4\" type=\"video/mp4\" size=\"480p\">"
                @"<source src=\"v/1080.mp4\" type=\"video/mp4\" size=\"1080p\"></video>"
                @"<img src=\"https://img.example.com/pic.webp\" srcset=\"https://img.example.com/pic2x.webp 2x\">"
                @"</body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/watch/regress"]];
            Check(ContainsURL(r, @"https://cdn.example.com/base/v/480.mp4"), @"回归：<video><source> 相对路径照常发现");
            Check(ContainsURL(r, @"https://cdn.example.com/base/v/1080.mp4"), @"回归：多画质 source 照常发现");
            Check(ContainsURL(r, @"https://img.example.com/pic.webp"), @"回归：图片 src 照常发现");
            NSUInteger videoCount = 0;
            for (DetectedMedia *m in r.media) if (m.resourceKind == RDResourceKindVideo || m.resourceKind == RDResourceKindManifest) videoCount++;
            Check(videoCount == 2, @"回归：两个画质成员不因全文兜底重复（仍 2 条视频）");
        }

        // ── 8. 全文兜底预算上限（巨型聚合页不爆列表）──
        {
            NSMutableString *html = [NSMutableString stringWithString:@"<html><body>"];
            for (NSUInteger i = 0; i < 500; i++) {
                [html appendFormat:@"<a href=\"/x%lu\">https://bulk.example.com/v/clip%lu.mp4</a>", (unsigned long)i, (unsigned long)i];
            }
            [html appendString:@"</body></html>"];
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/bulk"]];
            NSUInteger plainCount = 0;
            for (DetectedMedia *m in r.media) if ([m.discoverySource isEqualToString:@"plain-text"]) plainCount++;
            Check(plainCount <= 200, [NSString stringWithFormat:@"全文兜底遵守 200 条预算（实际 %lu）", (unsigned long)plainCount]);
        }

        if (gFailed == 0) NSLog(@"GRAB-UPGRADE-PASSED checks=%d", gPassed);
        else NSLog(@"GRAB-UPGRADE-FAILED passed=%d failed=%d", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
