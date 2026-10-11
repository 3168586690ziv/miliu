// PreviewRewriteTests.m — HLS master 钉选改写专项（第 35 轮预览播放）
// 覆盖：单变体钉选与相对路径绝对化 / 未命中与缺 base 失败回退 / 音轨与 SESSION-KEY 保留及 URI 绝对化 /
//       绝对变体不改写 / 媒体清单直通 / remoteURLs 完整性交叉验证 / 杂项标签保留 / CRLF 兼容 / 输入防御。
// 纯函数测试：只调 RDPreviewPlaylistRewrite，无网络、无 NSApplication。
#import <Foundation/Foundation.h>
#import "RDPreviewPlaylistRewrite.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

static NSString * const kBase = @"http://cdn.example.com/hls/index.m3u8";
static NSString * const kPin720 = @"http://cdn.example.com/hls/v720.m3u8";

static NSString *MasterTwoVariants(void) {
    return @"#EXTM3U\n"
           @"#EXT-X-VERSION:3\n"
           @"#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\n"
           @"v720.m3u8\n"
           @"#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x480\n"
           @"v480.m3u8\n";
}

static NSString *MasterThreeVariantsWithAudio(void) {
    return @"#EXTM3U\n"
           @"#EXT-X-VERSION:4\n"
           @"#EXT-X-INDEPENDENT-SEGMENTS\n"
           @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"EN\",DEFAULT=YES,URI=\"audio/a1.m3u8\"\n"
           @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"alt\",NAME=\"FR\",URI=\"audio/f2.m3u8\"\n"
           @"#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC\"\n"
           @"#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO=\"aud\"\n"
           @"v720.m3u8\n"
           @"#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x480,AUDIO=\"alt\"\n"
           @"v480.m3u8\n"
           @"#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x240\n"
           @"v360.m3u8\n";
}

// 简单提取函数：# 行取引号内值、其余行取整行，只保留绝对 http(s) URL（交叉验证 remoteURLs 完整性）。
static NSArray<NSString *> *ExtractHTTPSURLs(NSString *text) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length == 0) continue;
        if ([t hasPrefix:@"#"]) {
            NSUInteger start = 0;
            while (start < t.length) {
                NSRange q1 = [t rangeOfString:@"\"" options:NSLiteralSearch range:NSMakeRange(start, t.length - start)];
                if (q1.location == NSNotFound) break;
                NSRange q2 = [t rangeOfString:@"\"" options:NSLiteralSearch range:NSMakeRange(q1.location + 1, t.length - q1.location - 1)];
                if (q2.location == NSNotFound) break;
                NSString *val = [t substringWithRange:NSMakeRange(q1.location + 1, q2.location - q1.location - 1)];
                NSURL *u = [NSURL URLWithString:val];
                NSString *s = [u.scheme lowercaseString];
                if (([s isEqualToString:@"http"] || [s isEqualToString:@"https"]) && ![out containsObject:val]) [out addObject:val];
                start = q2.location + 1;
            }
        } else {
            NSURL *u = [NSURL URLWithString:t];
            NSString *s = [u.scheme lowercaseString];
            if (([s isEqualToString:@"http"] || [s isEqualToString:@"https"]) && ![out containsObject:t]) [out addObject:t];
        }
    }
    return out;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSLog(@"== HLS master 钉选改写专项（第 35 轮）==");

        NSMutableDictionary<NSString *, RDPreviewPlaylistResult *> *okResults = [NSMutableDictionary dictionary];

        NSArray<NSDictionary *> *cases = @[
            // 1. 双变体钉 v720：输出只含 v720、URL 为绝对、无 v480 残留
            @{ @"name": @"双变体钉 v720",
               @"input": MasterTwoVariants(),
               @"base": kBase,
               @"pinned": kPin720,
               @"ok": @YES,
               @"contains": @[@"#EXT-X-VERSION:3",
                              @"#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720",
                              @"http://cdn.example.com/hls/v720.m3u8"],
               @"notContains": @[@"v480", @"RESOLUTION=640x480", @"BANDWIDTH=1000000"],
               @"urls": @[@"http://cdn.example.com/hls/v720.m3u8"] },
            // 2. 钉一个不存在的变体：succeeded=NO、原文原样
            @{ @"name": @"钉不存在的变体",
               @"input": MasterTwoVariants(),
               @"base": kBase,
               @"pinned": @"http://cdn.example.com/hls/v999.m3u8",
               @"ok": @NO },
            // 3. pinned=nil：succeeded=NO
            @{ @"name": @"pinned 为 nil",
               @"input": MasterTwoVariants(),
               @"base": kBase,
               @"ok": @NO },
            // 4. baseURL=nil 且变体是相对路径：succeeded=NO
            @{ @"name": @"缺 baseURL 且变体相对",
               @"input": MasterTwoVariants(),
               @"pinned": kPin720,
               @"ok": @NO },
            // 5. 三变体 + 音轨：MEDIA 全保留（含未选变体专用组）、URI 绝对化、未选变体块丢弃
            @{ @"name": @"三变体音轨钉 v720",
               @"input": MasterThreeVariantsWithAudio(),
               @"base": kBase,
               @"pinned": kPin720,
               @"ok": @YES,
               @"contains": @[@"#EXT-X-VERSION:4",
                              @"#EXT-X-INDEPENDENT-SEGMENTS",
                              @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"EN\",DEFAULT=YES,URI=\"http://cdn.example.com/hls/audio/a1.m3u8\"",
                              @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"alt\",NAME=\"FR\",URI=\"http://cdn.example.com/hls/audio/f2.m3u8\"",
                              @"#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC\"",
                              @"#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO=\"aud\"",
                              @"http://cdn.example.com/hls/v720.m3u8"],
               @"notContains": @[@"v480.m3u8", @"v360.m3u8", @"AUDIO=\"alt\"",
                                 @"RESOLUTION=640x480", @"RESOLUTION=320x240",
                                 @"BANDWIDTH=1000000", @"BANDWIDTH=500000"],
               @"urls": @[@"http://cdn.example.com/hls/audio/a1.m3u8",
                          @"http://cdn.example.com/hls/audio/f2.m3u8",
                          @"http://cdn.example.com/hls/v720.m3u8"] },
            // 6. SESSION-KEY 行保留且 URI 绝对化、计入 remoteURLs（IV 原文不动）
            @{ @"name": @"SESSION-KEY 绝对化",
               @"input": @"#EXTM3U\n"
                         @"#EXT-X-VERSION:5\n"
                         @"#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"session.key\",IV=0xABCDEF0123456789ABCDEF0123456789\n"
                         @"#EXT-X-STREAM-INF:BANDWIDTH=800000\n"
                         @"v480.m3u8\n",
               @"base": kBase,
               @"pinned": @"http://cdn.example.com/hls/v480.m3u8",
               @"ok": @YES,
               @"contains": @[@"#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"http://cdn.example.com/hls/session.key\",IV=0xABCDEF0123456789ABCDEF0123456789",
                              @"http://cdn.example.com/hls/v480.m3u8"],
               @"urls": @[@"http://cdn.example.com/hls/session.key",
                          @"http://cdn.example.com/hls/v480.m3u8"] },
            // 7. 已是绝对 URL 的变体：不改写（原文原样进输出）但计入 remoteURLs
            @{ @"name": @"绝对变体不改写",
               @"input": @"#EXTM3U\n"
                         @"#EXT-X-STREAM-INF:BANDWIDTH=900000\n"
                         @"https://other.example.com/hls/v1080.m3u8\n"
                         @"#EXT-X-STREAM-INF:BANDWIDTH=100000\n"
                         @"v240.m3u8\n",
               @"base": kBase,
               @"pinned": @"https://other.example.com/hls/v1080.m3u8",
               @"ok": @YES,
               @"contains": @[@"#EXT-X-STREAM-INF:BANDWIDTH=900000\nhttps://other.example.com/hls/v1080.m3u8"],
               @"notContains": @[@"v240"],
               @"urls": @[@"https://other.example.com/hls/v1080.m3u8"] },
            // 8. 媒体清单（无 STREAM-INF）直通：原样返回、remoteURLs 空
            @{ @"name": @"媒体清单直通",
               @"input": @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:0\n"
                         @"#EXTINF:4.0,\nseg0.ts\n#EXTINF:4.0,\nseg1.ts\n#EXT-X-ENDLIST\n",
               @"base": kBase,
               @"pinned": kPin720,
               @"ok": @NO },
            // 10. INDEPENDENT-SEGMENTS / SESSION-DATA / 未知名行原样保留
            @{ @"name": @"杂项标签保留",
               @"input": @"#EXTM3U\n"
                         @"#EXT-X-INDEPENDENT-SEGMENTS\n"
                         @"#EXT-X-SESSION-DATA:DATA-ID=\"foo\",VALUE=\"bar\"\n"
                         @"#EXT-X-DEFINE:CONTENT-ID=\"ep1\"\n"
                         @"#EXT-X-STREAM-INF:BANDWIDTH=1\n"
                         @"v1.m3u8\n",
               @"base": kBase,
               @"pinned": @"http://cdn.example.com/hls/v1.m3u8",
               @"ok": @YES,
               @"contains": @[@"#EXT-X-INDEPENDENT-SEGMENTS",
                              @"#EXT-X-SESSION-DATA:DATA-ID=\"foo\",VALUE=\"bar\"",
                              @"#EXT-X-DEFINE:CONTENT-ID=\"ep1\"",
                              @"http://cdn.example.com/hls/v1.m3u8"],
               @"urls": @[@"http://cdn.example.com/hls/v1.m3u8"] },
            // 11. 换行兼容：\r\n 输入也能处理，输出统一 \n
            @{ @"name": @"CRLF 输入",
               @"input": @"#EXTM3U\r\n#EXT-X-STREAM-INF:BANDWIDTH=1\r\nv1.m3u8\r\n",
               @"base": kBase,
               @"pinned": @"http://cdn.example.com/hls/v1.m3u8",
               @"ok": @YES,
               @"contains": @[@"#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://cdn.example.com/hls/v1.m3u8"],
               @"urls": @[@"http://cdn.example.com/hls/v1.m3u8"] },
        ];

        for (NSDictionary *c in cases) {
            NSString *name = c[@"name"];
            NSString *input = c[@"input"];
            NSString *base = [c[@"base"] isKindOfClass:[NSString class]] ? c[@"base"] : nil;
            NSString *pinned = [c[@"pinned"] isKindOfClass:[NSString class]] ? c[@"pinned"] : nil;
            BOOL expectOK = [c[@"ok"] boolValue];
            NSString *label = [NSString stringWithFormat:@"用例「%@」", name];
            RDPreviewPlaylistResult *r = [RDPreviewPlaylistRewrite rewriteMaster:input baseURL:base pinnedVariantURL:pinned];
            Check(r != nil, [label stringByAppendingString:@"：返回结果对象"]);
            if (!r) continue;
            Check(r.succeeded == expectOK, [NSString stringWithFormat:@"%@：succeeded=%@（预期 %@）",
                  label, r.succeeded ? @"YES" : @"NO", expectOK ? @"YES" : @"NO"]);
            if (expectOK) {
                Check([r.rewrittenPlaylist hasPrefix:@"#EXTM3U"], [label stringByAppendingString:@"：#EXTM3U 开头"]);
                Check([r.rewrittenPlaylist hasSuffix:@"\n"], [label stringByAppendingString:@"：以 \\n 结尾"]);
                Check([r.rewrittenPlaylist rangeOfString:@"\r"].location == NSNotFound,
                      [label stringByAppendingString:@"：输出统一 \\n 无 \\r"]);
                for (NSString *s in c[@"contains"])
                    Check([r.rewrittenPlaylist containsString:s], [NSString stringWithFormat:@"%@：含「%@」", label, s]);
                for (NSString *s in c[@"notContains"])
                    Check([r.rewrittenPlaylist rangeOfString:s].location == NSNotFound,
                          [NSString stringWithFormat:@"%@：不含「%@」", label, s]);
                NSArray<NSString *> *urls = c[@"urls"];
                Check(r.remoteURLs.count == urls.count, [NSString stringWithFormat:@"%@：remoteURLs 数 %lu == 预期 %lu",
                      label, (unsigned long)r.remoteURLs.count, (unsigned long)urls.count]);
                BOOL allIn = YES;
                for (NSString *u in urls) if (![r.remoteURLs containsObject:u]) { allIn = NO; break; }
                Check(allIn, [label stringByAppendingString:@"：remoteURLs 覆盖全部预期 URL"]);
                okResults[name] = r;
            } else {
                Check([r.rewrittenPlaylist isEqualToString:input], [label stringByAppendingString:@"：原文原样返回"]);
                Check(r.remoteURLs.count == 0, [label stringByAppendingString:@"：remoteURLs 为空"]);
            }
        }

        // 9. remoteURLs 完整性：改写后清单里出现的每个 http(s) URL 都在 remoteURLs 里（双向交叉验证）
        for (NSString *name in okResults) {
            RDPreviewPlaylistResult *r = okResults[name];
            NSArray<NSString *> *extracted = ExtractHTTPSURLs(r.rewrittenPlaylist);
            Check(extracted.count == r.remoteURLs.count,
                  [NSString stringWithFormat:@"完整性「%@」：提取 %lu 个 == remoteURLs %lu 个",
                   name, (unsigned long)extracted.count, (unsigned long)r.remoteURLs.count]);
            BOOL allIn = YES;
            for (NSString *u in extracted) if (![r.remoteURLs containsObject:u]) { allIn = NO; break; }
            Check(allIn, [NSString stringWithFormat:@"完整性「%@」：每个提取 URL 都在 remoteURLs 中", name]);
        }
        Check(okResults.count == 6, [NSString stringWithFormat:@"完整性：成功用例共 6 个（实际 %lu）",
              (unsigned long)okResults.count]);

        // 8 补充：含绝对分片 URL 的媒体清单同样直通，remoteURLs 仍为空（不收集、不改写）
        NSString *mediaAbs = @"#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:4.0,\nhttps://cdn.example.com/seg0.ts\n#EXT-X-ENDLIST\n";
        RDPreviewPlaylistResult *rmedia = [RDPreviewPlaylistRewrite rewriteMaster:mediaAbs baseURL:kBase pinnedVariantURL:kPin720];
        Check(rmedia != nil && !rmedia.succeeded, @"媒体清单直通（绝对分片）：succeeded=NO");
        Check([rmedia.rewrittenPlaylist isEqualToString:mediaAbs], @"媒体清单直通（绝对分片）：原文原样返回");
        Check(rmedia.remoteURLs.count == 0, @"媒体清单直通（绝对分片）：remoteURLs 为空");

        // 输入防御：nil / 空串 / pinned 空串
        NSString *nilText = nil;  // 局部变量传 nil，避免字面量 nil 撞上隐式 _Nonnull 的调用侧告警
        RDPreviewPlaylistResult *rnil = [RDPreviewPlaylistRewrite rewriteMaster:nilText baseURL:kBase pinnedVariantURL:kPin720];
        Check(rnil != nil && !rnil.succeeded, @"防御：nil 输入 → succeeded=NO");
        Check(rnil.rewrittenPlaylist.length == 0, @"防御：nil 输入 → rewritten 为空");
        Check(rnil.remoteURLs.count == 0, @"防御：nil 输入 → remoteURLs 为空");

        RDPreviewPlaylistResult *rempty = [RDPreviewPlaylistRewrite rewriteMaster:@"" baseURL:kBase pinnedVariantURL:kPin720];
        Check(rempty != nil && !rempty.succeeded && rempty.rewrittenPlaylist.length == 0,
              @"防御：空串输入 → succeeded=NO 且 rewritten 为空");

        RDPreviewPlaylistResult *rnopin = [RDPreviewPlaylistRewrite rewriteMaster:MasterTwoVariants() baseURL:kBase pinnedVariantURL:@""];
        Check(rnopin != nil && !rnopin.succeeded, @"防御：pinned 空串 → succeeded=NO");
        Check([rnopin.rewrittenPlaylist isEqualToString:MasterTwoVariants()], @"防御：pinned 空串 → 原文原样返回");

        if (gFailed == 0) NSLog(@"PREVIEW-REWRITE-PASSED checks=%d", gPassed);
        else NSLog(@"PREVIEW-REWRITE-FAILED passed=%d failed=%d", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
