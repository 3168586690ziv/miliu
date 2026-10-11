// PreviewEligibilityTests.m — 预览可用性判定专项（第 35 轮）
// 覆盖：判定矩阵每个拒绝分支（含可读理由）、每个放行分支、扩展名兜底、
//       URLPolicy 事前校验入口（桩对象，不链接真实 URLPolicy，与预览套件
//       preview-playback.sh 的最小链接集一致：本测试 + RDPreviewEligibility.m
//       + DetectedMedia.m）。
// 纯函数测试：无网络、无 NSApplication、无文件 IO。
#import <Foundation/Foundation.h>
#import "RDPreviewEligibility.h"

static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

// ── 测试桩：对接字段与 URLPolicyDecision / URLPolicy 同名（allowed / userMessage /
//    evaluateTextURL:），运行时按 selector 分发，无需链接 URLPolicy.m ──
@interface PreviewTestDecision : NSObject
- (instancetype)initWithAllowed:(BOOL)allowed message:(NSString *)message;
@property (nonatomic, assign) BOOL allowed;
@property (nonatomic, copy) NSString *userMessage;
@end
@implementation PreviewTestDecision
- (instancetype)initWithAllowed:(BOOL)allowed message:(NSString *)message {
    self = [super init];
    if (self) { self.allowed = allowed; self.userMessage = message; }
    return self;
}
@end

@interface PreviewTestPolicy : NSObject
- (instancetype)initWithAllowed:(BOOL)allowed message:(NSString *)message;
@end
@implementation PreviewTestPolicy {
    BOOL _allowed;
    NSString *_message;
}
- (instancetype)initWithAllowed:(BOOL)allowed message:(NSString *)message {
    self = [super init];
    if (self) { _allowed = allowed; _message = message; }
    return self;
}
- (id)evaluateTextURL:(NSString *)urlString {
    return [[PreviewTestDecision alloc] initWithAllowed:_allowed message:_message];
}
@end

@interface PreviewTestNilPolicy : NSObject
@end
@implementation PreviewTestNilPolicy
- (id)evaluateTextURL:(NSString *)urlString { return nil; }
@end

static DetectedMedia *MakeMedia(NSString *urlString, NSString *format) {
    DetectedMedia *media = [[DetectedMedia alloc] init];
    media.mediaURL = urlString;
    media.format = format;
    media.resourceKind = RDResourceKindVideo;
    return media;
}

static BOOL IsRefused(RDPreviewVerdict *verdict) {
    return verdict != nil && verdict.decision == RDPreviewDecisionRefused && verdict.refusalReason.length > 0;
}

static BOOL Decided(RDPreviewDecision expected, RDPreviewVerdict *verdict) {
    return verdict != nil && verdict.decision == expected && verdict.refusalReason == nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSLog(@"== 预览可用性判定专项（第 35 轮）==");
        RDPreviewVerdict *v = nil;

        // ── 1. 基础拒绝：nil / 空地址 / 图片 ──
        {
            Check(IsRefused([RDPreviewEligibility verdictForMedia:nil]), @"nil 条目拒绝并给出理由");
            Check(IsRefused([RDPreviewEligibility verdictForMedia:MakeMedia(nil, @"mp4")]), @"媒体地址为 nil 拒绝并给出理由");
            Check(IsRefused([RDPreviewEligibility verdictForMedia:MakeMedia(@"", @"mp4")]), @"媒体地址为空串拒绝并给出理由");
            DetectedMedia *image = MakeMedia(@"https://cdn.example.com/pic.jpg", @"jpg");
            image.resourceKind = RDResourceKindImage;
            Check(IsRefused([RDPreviewEligibility verdictForMedia:image]), @"图片条目拒绝并给出理由");
        }

        // ── 2. DRM 拒绝：条目级标记（WebKit 侧信号）──
        {
            DetectedMedia *widevine = MakeMedia(@"https://cdn.example.com/a.mp4", @"mp4");
            widevine.drmType = RDDrmWidevine;
            v = [RDPreviewEligibility verdictForMedia:widevine];
            Check(IsRefused(v) && [v.refusalReason containsString:@"Widevine"], @"DRM-Widevine 拒绝并带可读理由");

            DetectedMedia *fairplay = MakeMedia(@"https://cdn.example.com/a.mp4", @"mp4");
            fairplay.drmType = RDDrmFairPlay;
            v = [RDPreviewEligibility verdictForMedia:fairplay];
            Check(IsRefused(v) && [v.refusalReason containsString:@"FairPlay"], @"DRM-FairPlay 拒绝并带可读理由");

            DetectedMedia *playready = MakeMedia(@"https://cdn.example.com/a.mp4", @"mp4");
            playready.drmType = RDDrmPlayReady;
            v = [RDPreviewEligibility verdictForMedia:playready];
            Check(IsRefused(v) && [v.refusalReason containsString:@"PlayReady"], @"DRM-PlayReady 拒绝并带可读理由");

            DetectedMedia *unknown = MakeMedia(@"https://cdn.example.com/a.mp4", @"mp4");
            unknown.drmType = RDDrmUnknownProtected;
            v = [RDPreviewEligibility verdictForMedia:unknown];
            Check(IsRefused(v) && [v.refusalReason containsString:@"受保护内容信号"], @"DRM-未知受保护信号拒绝且理由与明确 DRM 区分");
        }

        // ── 3. 清单自述加密（manifestInfo 结构化字段）──
        {
            DetectedMedia *drmManifest = MakeMedia(@"https://cdn.example.com/hls/master.m3u8", @"hls");
            drmManifest.manifestInfo = @{@"isDrmProtected": @YES, @"encryptionMethod": @"SAMPLE-AES"};
            v = [RDPreviewEligibility verdictForMedia:drmManifest];
            Check(IsRefused(v) && [v.refusalReason containsString:@"DRM"], @"清单自述 DRM 拒绝并带可读理由");

            DetectedMedia *aes = MakeMedia(@"https://cdn.example.com/hls/media.m3u8", @"hls");
            aes.manifestInfo = @{@"isDrmProtected": @YES, @"isSoftwareDecryptable": @YES, @"isEncrypted": @YES, @"encryptionMethod": @"AES-128"};
            Check(Decided(RDPreviewDecisionHLSMedia, [RDPreviewEligibility verdictForMedia:aes]),
                  @"AES-128+identity 软件可解：不按 DRM 拒（判 media 直连）");

            DetectedMedia *sample = MakeMedia(@"https://cdn.example.com/hls/media.m3u8", @"hls");
            sample.manifestInfo = @{@"isEncrypted": @YES, @"encryptionMethod": @"SAMPLE-AES"};
            v = [RDPreviewEligibility verdictForMedia:sample];
            Check(IsRefused(v) && [v.refusalReason containsString:@"SAMPLE-AES"], @"SAMPLE-AES 加密拒绝且理由带具体方式");

            aes.manifestInfo = @{@"isEncrypted": @YES, @"encryptionMethod": @"AES-128"};
            Check(Decided(RDPreviewDecisionHLSMedia, [RDPreviewEligibility verdictForMedia:aes]),
                  @"AES-128 加密不拒（AVPlayer 原生支持）");

            aes.manifestInfo = @{@"isEncrypted": @YES, @"encryptionMethod": @"NONE"};
            Check(Decided(RDPreviewDecisionHLSMedia, [RDPreviewEligibility verdictForMedia:aes]),
                  @"METHOD=NONE 明确不加密不拒");
        }

        // ── 4. 容器与格式拒绝 ──
        {
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/manifest.mpd", @"dash")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"DASH"], @"DASH 清单拒绝并带可读理由");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/a.webm", @"webm")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"WebM"], @"WebM 拒绝并带可读理由");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/a.mkv", @"mkv")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"MKV"], @"MKV 容器拒绝并带可读理由");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/index.ts", @"ts")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"TS"], @"TS 直链拒绝并带可读理由");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/index.m2ts", @"m2ts")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"TS"], @"M2TS 按 MPEG-2 传输流同口径拒绝");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/a.flv", @"flv")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"FLV"], @"FLV 容器拒绝并带可读理由");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/a.avi", @"avi")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"AVI"], @"AVI 容器拒绝并带可读理由");

            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/media", @"xyz")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"未识别"], @"未知 format 且无扩展名拒绝（未识别）");
            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/media", @"")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"未识别"], @"format 为空且无扩展名拒绝（未识别）");

            v = [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/a.flac", @"flac")];
            Check(IsRefused(v) && [v.refusalReason containsString:@"flac"] && ![v.refusalReason containsString:@"未识别"],
                  @"探测器认识的白名单外格式具名拒绝（flac），不冒充未识别");
        }

        // ── 5. 放行：直链渐进式白名单 ──
        {
            for (NSString *format in @[@"mp4", @"m4v", @"mov", @"m4a", @"mp3", @"aac"]) {
                v = [RDPreviewEligibility verdictForMedia:MakeMedia(
                         [NSString stringWithFormat:@"https://cdn.example.com/media.%@", format], format)];
                Check(Decided(RDPreviewDecisionDirectFile, v),
                      [NSString stringWithFormat:@"直链放行：%@ 判 DirectFile 且无拒绝理由", format]);
            }
        }

        // ── 6. 放行：HLS master / media ──
        {
            DetectedMedia *two = MakeMedia(@"https://cdn.example.com/hls/master.m3u8", @"hls");
            two.declaredVariants = @[@{@"height": @1080}, @{@"height": @720}];
            Check(Decided(RDPreviewDecisionHLSMaster, [RDPreviewEligibility verdictForMedia:two]),
                  @"HLS 双变体判 master（走环回钉选）");

            DetectedMedia *three = MakeMedia(@"https://cdn.example.com/hls/master.m3u8", @"hls");
            three.declaredVariants = @[@{@"height": @1080}, @{@"height": @720}, @{@"height": @360}];
            Check(Decided(RDPreviewDecisionHLSMaster, [RDPreviewEligibility verdictForMedia:three]),
                  @"HLS 三变体判 master");

            DetectedMedia *one = MakeMedia(@"https://cdn.example.com/hls/media.m3u8", @"hls");
            one.declaredVariants = @[@{@"height": @720}];
            Check(Decided(RDPreviewDecisionHLSMedia, [RDPreviewEligibility verdictForMedia:one]),
                  @"HLS 单变体判 media（直连）");

            DetectedMedia *zero = MakeMedia(@"https://cdn.example.com/hls/media.m3u8", @"hls");
            Check(Decided(RDPreviewDecisionHLSMedia, [RDPreviewEligibility verdictForMedia:zero]),
                  @"HLS 零变体判 media（单码率直连）");
        }

        // ── 7. 直播流与状态字段不触发拒绝 ──
        {
            DetectedMedia *live = MakeMedia(@"https://cdn.example.com/live.mp4", @"mp4");
            live.isLive = YES;
            Check(Decided(RDPreviewDecisionDirectFile, [RDPreviewEligibility verdictForMedia:live]),
                  @"isLive 直链直播条目放行");

            DetectedMedia *liveManifest = MakeMedia(@"https://cdn.example.com/live.m3u8", @"hls");
            liveManifest.manifestInfo = @{@"isLive": @YES};
            Check(Decided(RDPreviewDecisionHLSMedia, [RDPreviewEligibility verdictForMedia:liveManifest]),
                  @"清单 isLive 直播清单放行");

            DetectedMedia *state = MakeMedia(@"https://cdn.example.com/a.mp4", @"mp4");
            state.availabilityState = @"downloadable";
            Check(Decided(RDPreviewDecisionDirectFile, [RDPreviewEligibility verdictForMedia:state]),
                  @"availabilityState 不影响判定");
        }

        // ── 8. 未知/空白 format 的扩展名兜底 ──
        {
            Check(Decided(RDPreviewDecisionDirectFile,
                          [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/video.mp4", @"")]),
                  @"format 为空按扩展名放行（mp4）");
            Check(Decided(RDPreviewDecisionDirectFile,
                          [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/audio.m4a?token=sig", @"")]),
                  @"扩展名兜底忽略 query（m4a）");
            Check(Decided(RDPreviewDecisionDirectFile,
                          [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/VIDEO.MP4", @"")]),
                  @"扩展名大小写不敏感");
            Check(Decided(RDPreviewDecisionDirectFile,
                          [RDPreviewEligibility verdictForMedia:MakeMedia(@"https://cdn.example.com/clip.mov", @"xyz")]),
                  @"未知 format 按扩展名放行（mov）");
        }

        // ── 9. URLPolicy 事前校验入口（桩对象）──
        {
            PreviewTestPolicy *block = [[PreviewTestPolicy alloc] initWithAllowed:NO
                                                                          message:@"拒绝访问本地与内网地址"];
            v = [RDPreviewEligibility verdictIfURLAllowed:[NSURL URLWithString:@"http://127.0.0.1:8911/v.mp4"]
                                                   policy:(URLPolicy *)block];
            Check(IsRefused(v), @"URLPolicy 拒绝时返回 Refused 且给理由");
            Check([v.refusalReason isEqualToString:@"拒绝访问本地与内网地址"], @"拒绝理由保持 URLPolicy 的原话");

            PreviewTestPolicy *pass = [[PreviewTestPolicy alloc] initWithAllowed:YES message:@""];
            Check([RDPreviewEligibility verdictIfURLAllowed:[NSURL URLWithString:@"https://cdn.example.com/v.mp4"]
                                                     policy:(URLPolicy *)pass] == nil,
                  @"URLPolicy 放行返回 nil（无拒绝）");

            PreviewTestPolicy *empty = [[PreviewTestPolicy alloc] initWithAllowed:NO message:@""];
            v = [RDPreviewEligibility verdictIfURLAllowed:[NSURL URLWithString:@"https://cdn.example.com/v.mp4"]
                                                   policy:(URLPolicy *)empty];
            Check(IsRefused(v), @"URLPolicy 决定无文案时仍给兜底理由");

            Check([RDPreviewEligibility verdictIfURLAllowed:[NSURL URLWithString:@"https://cdn.example.com/v.mp4"]
                                                     policy:(URLPolicy *)PreviewTestNilPolicy.new] == nil,
                  @"URLPolicy 决定为 nil 视为无拒绝");
        }

        NSLog(@"预览可用性判定：%d 过 / %d 挂（共 %d 项）", gPassed, gFailed, gPassed + gFailed);
        if (gFailed == 0) NSLog(@"PREVIEW-ELIGIBILITY-PASSED checks=%d", gPassed);
        else NSLog(@"PREVIEW-ELIGIBILITY-FAILED passed=%d failed=%d", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
