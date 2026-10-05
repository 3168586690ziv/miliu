// AESEncryptionTests.m — AES-128 加密流专项（第 30 轮）
// 覆盖：显式 IV / 隐式 IV / 密钥轮换 / KEYFORMAT 判定 / DRM 拒绝 / 分片顺序。
// 纯函数测试：只调 RDManifestParser 与 RDStreamPlan，无网络、无 NSApplication。
#import <Foundation/Foundation.h>
#import "RDManifestParser.h"
#import "RDStreamPlan.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

static NSURL *Base(void) { return [NSURL URLWithString:@"https://cdn.example.com/hls/index.m3u8"]; }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSLog(@"== AES-128 加密流专项（第 30 轮）==");

        // ── 1. 显式 IV：解析出 METHOD/KEYFORMAT，plan 保留 IV 原文 ──
        {
            NSString *m3u8 =
                @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:0\n"
                @"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x0123456789ABCDEF0123456789ABCDEF\n"
                @"#EXTINF:4.0,\nseg0.ts\n#EXTINF:4.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
            NSDictionary *parsed = [RDManifestParser parseManifest:m3u8 baseURL:Base()];
            Check([parsed[@"isEncrypted"] boolValue], @"显式 IV：识别为加密流");
            Check([parsed[@"encryptionMethod"] isEqualToString:@"AES-128"], @"显式 IV：METHOD=AES-128");
            Check([parsed[@"isSoftwareDecryptable"] boolValue], @"显式 IV：判定为软件可解");
            Check(![parsed[@"isDrmProtected"] boolValue], @"显式 IV：不判为 DRM");

            NSError *err = nil;
            NSDictionary *plan = [RDStreamPlan HLSPlaylist:m3u8 baseURL:Base() error:&err];
            Check(plan != nil, @"显式 IV：plan 生成成功（不被误拒）");
            Check([plan[@"playlist"] containsString:@"IV=0x0123456789ABCDEF0123456789ABCDEF"], @"显式 IV：IV 原文保留在重写清单");
            Check([plan[@"playlist"] containsString:@"URI=\"resource-00000.key\""], @"显式 IV：密钥 URI 改写为本地名");
            BOOL keyFlagged = NO;
            for (NSDictionary *r in plan[@"resources"]) if ([r[@"key"] boolValue]) keyFlagged = YES;
            Check(keyFlagged, @"显式 IV：密钥被登记为独立资源");
            Check([plan[@"resources"] count] == 3, @"显式 IV：资源数 = 1 密钥 + 2 分片");
        }

        // ── 2. 隐式 IV：无 IV 属性时保留 MEDIA-SEQUENCE（ffmpeg 按标准推导）──
        {
            NSString *m3u8 =
                @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:7\n"
                @"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n"
                @"#EXTINF:4.0,\nseg0.ts\n#EXTINF:4.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
            NSError *err = nil;
            NSDictionary *plan = [RDStreamPlan HLSPlaylist:m3u8 baseURL:Base() error:&err];
            Check(plan != nil, @"隐式 IV：plan 生成成功");
            Check([plan[@"playlist"] containsString:@"#EXT-X-MEDIA-SEQUENCE:7"], @"隐式 IV：MEDIA-SEQUENCE 保留（推导依据不丢）");
            Check(![plan[@"playlist"] containsString:@"IV=0x"], @"隐式 IV：不虚构 IV 属性");
        }

        // ── 3. 密钥轮换：两把密钥都被下载，URI 各自改写 ──
        {
            NSString *m3u8 =
                @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:0\n"
                @"#EXT-X-KEY:METHOD=AES-128,URI=\"k1.bin\",IV=0x00000000000000000000000000000000\n"
                @"#EXTINF:4.0,\nseg0.ts\n"
                @"#EXT-X-KEY:METHOD=AES-128,URI=\"k2.bin\",IV=0x00000000000000000000000000000000\n"
                @"#EXTINF:4.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
            NSError *err = nil;
            NSDictionary *plan = [RDStreamPlan HLSPlaylist:m3u8 baseURL:Base() error:&err];
            Check(plan != nil, @"密钥轮换：plan 生成成功");
            NSUInteger keyCount = 0;
            for (NSDictionary *r in plan[@"resources"]) if ([r[@"key"] boolValue]) keyCount++;
            Check(keyCount == 2, [NSString stringWithFormat:@"密钥轮换：两把密钥都登记（实际 %lu）", (unsigned long)keyCount]);
            NSString *pl = plan[@"playlist"];
            Check([pl containsString:@"resource-00000.key"] && [pl containsString:@"resource-00002.key"],
                  @"密钥轮换：两处 URI 分别改写为不同本地名");
        }

        // ── 4. KEYFORMAT：identity 放行；非 identity 明确拒绝且提示可读 ──
        {
            NSString *identity =
                @"#EXTM3U\n#EXT-X-VERSION:5\n#EXT-X-TARGETDURATION:5\n"
                @"#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\",KEYFORMAT=\"identity\"\n"
                @"#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n";
            NSDictionary *parsed = [RDManifestParser parseManifest:identity baseURL:Base()];
            Check([parsed[@"isSoftwareDecryptable"] boolValue], @"KEYFORMAT=identity：判定软件可解");
            NSError *err = nil;
            Check([RDStreamPlan HLSPlaylist:identity baseURL:Base() error:&err] != nil, @"KEYFORMAT=identity：plan 放行");

            NSString *fairplay =
                @"#EXTM3U\n#EXT-X-VERSION:5\n#EXT-X-TARGETDURATION:5\n"
                @"#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n"
                @"#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n";
            NSDictionary *fp = [RDManifestParser parseManifest:fairplay baseURL:Base()];
            Check([fp[@"isDrmProtected"] boolValue], @"FairPlay：判定为 DRM 保护");
            Check(![fp[@"isSoftwareDecryptable"] boolValue], @"FairPlay：判定为软件不可解");
            NSError *err2 = nil;
            NSDictionary *plan2 = [RDStreamPlan HLSPlaylist:fairplay baseURL:Base() error:&err2];
            Check(plan2 == nil, @"FairPlay：plan 拒绝（不产出半成品）");
            Check(err2.localizedDescription.length > 0 && [err2.localizedDescription containsString:@"DRM"],
                  @"FairPlay：拒绝理由含可读的 DRM 说明");
        }

        // ── 5. METHOD=NONE：不加密，正常放行 ──
        {
            NSString *m3u8 =
                @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n"
                @"#EXT-X-KEY:METHOD=NONE\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n";
            NSDictionary *parsed = [RDManifestParser parseManifest:m3u8 baseURL:Base()];
            Check(![parsed[@"isDrmProtected"] boolValue], @"METHOD=NONE：不判为 DRM");
            NSError *err = nil;
            Check([RDStreamPlan HLSPlaylist:m3u8 baseURL:Base() error:&err] != nil, @"METHOD=NONE：plan 放行");
        }

        // ── 6. DASH：ContentProtection 一律判 DRM ──
        {
            NSString *mpd =
                @"<?xml version=\"1.0\"?><MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\""
                @" mediaPresentationDuration=\"PT10S\"><Period><AdaptationSet mimeType=\"video/mp4\">"
                @"<ContentProtection schemeIdUri=\"urn:uuid:EDEF8BA9-79D6-4ACE-A3C8-27DCD51D21ED\"/>"
                @"<Representation id=\"v\" bandwidth=\"1000000\" width=\"1280\" height=\"720\">"
                @"<SegmentTemplate media=\"seg$Number$.m4s\" initialization=\"init.mp4\" duration=\"5000\"/>"
                @"</Representation></AdaptationSet></Period></MPD>";
            NSDictionary *parsed = [RDManifestParser parseManifest:mpd baseURL:Base()];
            Check([parsed[@"isDrmProtected"] boolValue], @"DASH ContentProtection：判定为 DRM");
            NSError *err = nil;
            Check([RDStreamPlan DASHTracks:mpd baseURL:Base() error:&err] == nil, @"DASH ContentProtection：拒绝导出");
        }

        // ── 7. 零回归：未加密流不受影响 ──
        {
            NSString *m3u8 =
                @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n"
                @"#EXTINF:4.0,\nseg0.ts\n#EXTINF:4.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
            NSDictionary *parsed = [RDManifestParser parseManifest:m3u8 baseURL:Base()];
            Check(![parsed[@"isEncrypted"] boolValue], @"零回归：未加密流 isEncrypted=NO");
            NSError *err = nil;
            NSDictionary *plan = [RDStreamPlan HLSPlaylist:m3u8 baseURL:Base() error:&err];
            Check(plan != nil && [plan[@"resources"] count] == 2, @"零回归：未加密流正常出计划（2 分片）");
        }

        if (gFailed == 0) NSLog(@"AES-ENCRYPTION-PASSED checks=%d", gPassed);
        else NSLog(@"AES-ENCRYPTION-FAILED passed=%d failed=%d", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
