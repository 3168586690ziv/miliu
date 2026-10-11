// MediaDiscoveryTests.m — 抓取能力升级专项（第 29 轮）
// 覆盖：og:video / twitter:player:stream meta、JSON-LD VideoObject、
// HTML 全文直链兜底、扩展名白名单（mkv/ts/flv/音频）、旧结构零回归。
// 纯函数测试：只调 RDProbeAnalyzer.analyzeHTML / RDStaticScriptAnalyzer，
// 无网络、无 NSApplication、无窗口。
#import <Foundation/Foundation.h>
#import "WebProbe.h"
#import "RDStaticScriptAnalyzer.h"
#import "DetectedMedia.h"
#import "RDURLUtilities.h"

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

        // ── 9. 音频扩展名路径（2026-10-06 语料实测缺口回归）──
        {
            // formatFromURL 必须认识常见音频扩展名，否则懒加载/直链路径全漏
            Check([[RDProbeAnalyzer formatFromURL:@"https://cdn.example.com/a/song.mp3"] isEqualToString:@"mp3"],
                  @"formatFromURL 认识 .mp3");
            Check([[RDProbeAnalyzer formatFromURL:@"https://cdn.example.com/a/song.m4a"] isEqualToString:@"m4a"],
                  @"formatFromURL 认识 .m4a");
            Check([[RDProbeAnalyzer formatFromURL:@"https://cdn.example.com/a/song.flac"] isEqualToString:@"flac"],
                  @"formatFromURL 认识 .flac");
            Check([RDProbeAnalyzer isDownloadableMediaFormat:@"mp3"], @"mp3 在可下载白名单");
            Check([RDProbeAnalyzer isDownloadableMediaFormat:@"flac"], @"flac 在可下载白名单");
            // 音频属性写法也必须被静态腿接住
            NSString *html = @"<html><body>"
                @"<audio src=\"https://cdn.example.com/audio/track.mp3\"></audio>"
                @"</body></html>";
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/"]];
            Check(ContainsURL(r, @"https://cdn.example.com/audio/track.mp3"), @"<audio src> 的 mp3 被发现");
        }

        // ── 10. 同族画质变体聚合（2026-10-10 主人实测回归）──
        // 主人现场：X 推文的一段视频被拆成 3 份（视频内容一致、音频与码率不同）。
        // 根因：三个 mp4 变体由接口响应体扫描得到，不带播放器身份、也不在任何
        // <video> 块内，于是每条各占一行。这里用真实变体地址钉住行为。
        {
            NSArray *realVariants = @[
                @"https://video.twimg.com/amplify_video/2106365084197081089/vid/avc1/320x568/LVeXB7POqVg1M4xm.mp4?tag=29",
                @"https://video.twimg.com/amplify_video/2106365084197081089/vid/avc1/480x852/YCTMYGMAGuFCPErk.mp4?tag=29",
                @"https://video.twimg.com/amplify_video/2106365084197081089/vid/avc1/720x1280/ZEvOVjJWQ42yPPF-.mp4?tag=29",
            ];
            NSMutableString *dyn = [NSMutableString string];
            for (NSString *u in realVariants) {
                [dyn appendString:[RDBridgeEventSynthesizer syntheticHTMLForEvent:
                    @{@"action":@"resource", @"url":u, @"kind":@"video", @"source":@"fetch_body"}]];
            }
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:dyn
                                                    baseURL:[NSURL URLWithString:@"https://x.com/kng308054331091/status/2107362612174627211"]];
            Check(r.media.count == 3, [NSString stringWithFormat:@"三个变体都被发现（实际 %lu）", (unsigned long)r.media.count]);
            NSString *family = nil;
            BOOL allShare = YES;
            for (DetectedMedia *m in r.media) {
                if (!m.videoFamilyID.length) { allShare = NO; break; }
                if (!family) family = m.videoFamilyID;
                else if (![family isEqualToString:m.videoFamilyID]) { allShare = NO; break; }
            }
            Check(allShare && family.length > 0, @"三个变体共享同一 family（同一视频一行）");
            NSArray *labels = r.media.firstObject.declaredVariants.count
                ? [r.media.firstObject.declaredVariants valueForKey:@"label"] : @[];
            Check([labels containsObject:@"480p"] && [labels containsObject:@"720p"],
                  [NSString stringWithFormat:@"档位表含 480p 与 720p（实际 %@）", [labels componentsJoinedByString:@","]]);
            // 320x568 短边 568 距 480 偏差 88 > 48（10% 容差）→ 按既有产品规则不归档。
            Check(labels.count == 2, [NSString stringWithFormat:@"非标准档 320x568 不伪造档位（档位数 %lu）", (unsigned long)labels.count]);
        }
        // 10b) 清单与直链同族（HLS master + 同片 mp4 直链 → 同一行）
        {
            Check(RDSameQualityVariantFamily(
                      @"https://video.twimg.com/amplify_video/2106365084197081089/pl/0RrrnsRoDY-PUyiQ.m3u8?tag=29",
                      @"https://video.twimg.com/amplify_video/2106365084197081089/vid/avc1/720x1280/ZEvOVjJWQ42yPPF-.mp4?tag=29"),
                  @"同一媒体 ID 下 m3u8 与 mp4 判为同族");
            Check(!RDSameQualityVariantFamily(
                      @"https://cdn.example.com/a/playlist.m3u8",
                      @"https://cdn.example.com/b/movie.mp4"),
                  @"仅 1 段共同前缀的清单与直链不误判同族");
        }
        // 10c) 判据不得误合并：目录号不同 / 文件名主干不同 / 跨 host → 仍是不同视频
        {
            Check(!RDSameQualityVariantFamily(
                      @"https://cdn.example.com/series/1/ep.mp4",
                      @"https://cdn.example.com/series/2/ep.mp4"),
                  @"目录号不同（1/ vs 2/）不误判同族");
            Check(!RDSameQualityVariantFamily(
                      @"https://cdn.example.com/a/ep01.mp4",
                      @"https://cdn.example.com/a/ep02.mp4"),
                  @"文件名主干不同（ep01 vs ep02）不误判同族");
            Check(!RDSameQualityVariantFamily(
                      @"https://cdn.example.com/v/movie1-480p.mp4",
                      @"https://cdn.example.com/v/movie2-720p.mp4"),
                  @"不同主干同档位后缀（movie1-480p vs movie2-720p）不误判同族");
            Check(!RDSameQualityVariantFamily(
                      @"https://cdn.example.com/720p/a.mp4",
                      @"https://cdn.example.com/1080p/b.mp4"),
                  @"第一段即分辨率目录（共同前缀为空）不误判同族");
            Check(RDSameQualityVariantFamily(
                      @"https://cdn.example.com/vid/avc1/320x568/a.mp4",
                      @"https://cdn.example.com/vid/avc1/720x1280/b.mp4"),
                  @"同目录仅分辨率分量不同 → 同族");
            Check(RDSameQualityVariantFamily(
                      @"https://cdn.example.com/v/a-480p.mp4",
                      @"https://cdn.example.com/v/a-720p.mp4"),
                  @"文件名主干尾部 -480p/-720p → 同族");
            Check(!RDSameQualityVariantFamily(
                      @"https://a.example.com/v/720x1280/a.mp4",
                      @"https://b.example.com/v/720x1280/a.mp4"),
                  @"跨 host 不误判同族");
        }
        // 10d) 无变体关系的两条媒体仍各自成行（不获得 family）
        {
            NSString *dyn = [NSString stringWithFormat:@"%@%@",
                [RDBridgeEventSynthesizer syntheticHTMLForEvent:
                    @{@"action":@"resource", @"url":@"https://cdn.example.com/a/first.mp4", @"kind":@"video", @"source":@"fetch_body"}],
                [RDBridgeEventSynthesizer syntheticHTMLForEvent:
                    @{@"action":@"resource", @"url":@"https://cdn.example.com/b/second.mp4", @"kind":@"video", @"source":@"fetch_body"}]];
            RDProbeResult *r = [RDProbeAnalyzer analyzeHTML:dyn baseURL:[NSURL URLWithString:@"https://example.com/"]];
            BOOL anyFamily = NO;
            for (DetectedMedia *m in r.media) if (m.videoFamilyID.length) anyFamily = YES;
            Check(!anyFamily, @"无变体关系的两条媒体不获得 family（各自成行）");
        }
        // 10e) 规模边界：同族聚合不得是 O(n²)（第 32 轮同类性能教训）
        // 构造最坏形态：900 条互不同族的地址（逐对全量比较时每条都要扫完所有簇，
        // 实测 800 条要 2.8 秒）+ 100 组三档变体。分桶实现应远低于 3 秒。
        {
            NSMutableArray<DetectedMedia *> *media = [NSMutableArray array];
            for (NSUInteger i = 0; i < 900; i++) {
                DetectedMedia *m = [DetectedMedia new];
                m.mediaURL = [NSString stringWithFormat:@"https://agg.example.com/video/%lu/clip-%lu.mp4", (unsigned long)i, (unsigned long)i];
                m.resourceKind = RDResourceKindVideo;
                [media addObject:m];
            }
            for (NSUInteger i = 0; i < 100; i++) {
                for (NSString *q in @[@"480x854", @"720x1280", @"1080x1920"]) {
                    DetectedMedia *m = [DetectedMedia new];
                    m.mediaURL = [NSString stringWithFormat:@"https://agg.example.com/t/%lu/vid/%@/part.mp4", (unsigned long)i, q];
                    m.resourceKind = RDResourceKindVideo;
                    [media addObject:m];
                }
            }
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            [RDProbeAnalyzer groupQualityVariantFamilies:media];
            double dt = CFAbsoluteTimeGetCurrent() - t0;
            NSUInteger groupedCount = 0;
            for (DetectedMedia *m in media) if (m.videoFamilyID.length) groupedCount++;
            Check(media.count == 1200, [NSString stringWithFormat:@"规模用例：1200 条全部参与（实际 %lu）", (unsigned long)media.count]);
            Check(groupedCount == 300, [NSString stringWithFormat:@"规模用例：100 组三档各归一族（实际带族 %lu 条）", (unsigned long)groupedCount]);
            Check(dt < 3.0, [NSString stringWithFormat:@"规模用例：1200 条聚合 %.3f 秒（须 < 3 秒，防 O(n²) 回归）", dt]);
        }

        if (gFailed == 0) NSLog(@"GRAB-UPGRADE-PASSED checks=%d", gPassed);
        else NSLog(@"GRAB-UPGRADE-FAILED passed=%d failed=%d", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
