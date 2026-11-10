// MetadataRecoveryTests.m — 元数据恢复接线专项（2026-10-12 第 38 轮）
//
// 目的：证明三个此前零引用的生产组件**真的被调用**（而不是代码里写了、运行时走不到）——
//   · RDDisplayMetadataRecoveryStore（按来源页记录标题/封面 + 持久化往返）
//   · ResourceTitleTranslator（翻译判据 + 中文标题不发起翻译）
//   · RDCoverRecoveryEngine（恢复尝试被真正发起 + 其判据纯函数）
// 并覆盖协调器自身的编排语义（规范化命中、计数、取消）。
//
// 隔离：使用独立 UserDefaults suite，绝不读写真实用户偏好。
// 无网络：所有需要网络的路径都在本测试里走「无 provider / 无封面 URL」的短路分支。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "RDMetadataRecoveryCoordinator.h"
#import "RDDisplayMetadataRecoveryStore.h"
#import "RDCoverRecoveryEngine.h"
#import "ResourceTitleTranslator.h"
#import "RDResourceDisplayMetadata.h"
#import "DetectedMedia.h"
#import "PreferencesStore.h"
#import "URLPolicy.h"

static int gPassed = 0, gFailed = 0;
static NSUInteger gNetworkAttempts = 0;
@interface MetadataNoNetworkProtocol : NSURLProtocol
@end
@implementation MetadataNoNetworkProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [@[@"http", @"https"] containsObject:request.URL.scheme.lowercaseString];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    @synchronized (MetadataNoNetworkProtocol.class) { gNetworkAttempts++; }
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"MetadataFixtureNoNetwork" code:1 userInfo:nil]];
}
- (void)stopLoading {}
@end
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

static DetectedMedia *Media(NSString *sourcePage, NSString *title, NSString *poster) {
    DetectedMedia *m = [DetectedMedia new];
    m.sourcePageURL = sourcePage;
    m.title = title;
    m.poster = poster;
    m.mediaURL = [sourcePage stringByAppendingString:@"/v.mp4"];
    return m;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSURLProtocol registerClass:MetadataNoNetworkProtocol.class];
        // 独立 suite：测试绝不触碰真实用户偏好
        NSString *suiteName = [NSString stringWithFormat:@"rd-metadata-recovery-tests-%d", getpid()];
        NSUserDefaults *isolated = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [isolated removePersistentDomainForName:suiteName];
        PreferencesStore *prefs = [[PreferencesStore alloc] initWithUserDefaults:isolated];

        RDMetadataRecoveryCoordinator *c =
            [[RDMetadataRecoveryCoordinator alloc] initWithPolicy:nil reprobeHandler:nil preferences:prefs];

        if (argc > 1 && strcmp(argv[1], "--translation-permission") == 0) {
            const char *value = getenv("RD_TITLE_TRANSLATION_NETWORK");
            BOOL expected = value && strcmp(value, "1") == 0;
            ResourceTitleTranslator *translator = [c valueForKey:@"translator"];
            Check([[translator valueForKey:@"allowsNetworkTranslation"] boolValue] == expected,
                  @"协调器仅精确环境值1允许网络翻译（不创建请求）");
            [c cancelAll];
            [isolated removePersistentDomainForName:suiteName];
            return gFailed == 0 ? 0 : 1;
        }

        // ── ① 探测结果落地 → 按来源页记录（存储组件被真正调用）──
        DetectedMedia *m = Media(@"https://site.example/work/407460", @"Some English Title", @"https://cdn.example/407460h.jpg");
        [c recordDetectedMedia:@[m]];
        Check(c.recordedMediaCount == 1, @"记录一次探测结果 → 计数 +1（存储组件确实被调用）");

        RDResourceDisplayMetadata *md = [c metadataForSourcePageURL:m.sourcePageURL];
        Check(md != nil, @"按来源页能取回记录");
        Check([md.title isEqualToString:@"Some English Title"], @"标题被记录");
        Check([md.posterURLString isEqualToString:@"https://cdn.example/407460h.jpg"], @"封面被记录");

        // 规范化：fragment / 大小写不同但同一页 → 命中同一记录
        Check([c metadataForSourcePageURL:@"https://site.example/work/407460#frag"] != nil,
              @"规范化：fragment 不影响命中");
        Check([c metadataForSourcePageURL:@"HTTPS://SITE.EXAMPLE/work/407460"] != nil,
              @"规范化：host 大小写不影响命中");

        // 无来源页的媒体不记（避免造出无法索引的垃圾记录）
        NSUInteger before = c.recordedMediaCount;
        [c recordDetectedMedia:@[Media(nil, @"t", @"p")]];
        Check(c.recordedMediaCount == before, @"无来源页的媒体不记录");

        // ── ② 列表页封面回调（原本从未挂载的那条链路）──
        [c recordListingPosters:@{@"https://site.example/work/1": @"https://cdn.example/1.jpg"}];
        Check(c.recordedMediaCount == before + 1, @"列表页封面 → 计数 +1");
        Check([[c metadataForSourcePageURL:@"https://site.example/work/1"].posterURLString
               isEqualToString:@"https://cdn.example/1.jpg"], @"列表页封面被记录且可取回");

        // ── ③ 标题翻译判据与短路（中文标题不得发起网络翻译）──
        __block NSString *out = @"<未回调>";
        [c resolvedTitleFor:@"中文标题" completion:^(NSString *t){ out = t; }];
        Check([out isEqualToString:@"中文标题"], @"中文标题原样返回（同步短路）");
        Check(c.translatedTitleCount == 0, @"中文标题不计入翻译计数（确实没有发起翻译）");

        out = @"<未回调>";
        [c resolvedTitleFor:@"" completion:^(NSString *t){ out = t; }];
        Check(out != nil && out.length == 0, @"空标题返回空串且不崩");

        out = @"<未回调>";
        __block NSUInteger localCallbacks = 0;
        [c resolvedTitleFor:@"Xylophone Quasar" completion:^(NSString *t){
            localCallbacks++;
            out = t;
            Check(NSThread.isMainThread, @"本地未命中协调器回调位于主线程");
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
        while (deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
        Check(localCallbacks == 1 && [out isEqualToString:@"Xylophone Quasar"],
              @"本地未命中保持原题且只完成一次");
        Check(c.translatedTitleCount == 0, @"原题回退不伪增翻译计数");
        [c resolvedTitleFor:@"girl story" completion:^(NSString *t){ out = t; }];
        deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
        while (deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
        Check([out isEqualToString:@"女孩故事"] && c.translatedTitleCount == 1,
              @"协调器使用本地译文并正确计数");

        // ── ④ 持久化往返（重启后仍能回补）──
        [c persist];
        RDMetadataRecoveryCoordinator *c2 =
            [[RDMetadataRecoveryCoordinator alloc] initWithPolicy:nil reprobeHandler:nil preferences:prefs];
        Check([c2 metadataForSourcePageURL:m.sourcePageURL] == nil, @"未载入前为空（确认载入确实起作用）");
        [c2 loadPersistedState];
        RDResourceDisplayMetadata *restored = [c2 metadataForSourcePageURL:m.sourcePageURL];
        Check(restored != nil, @"持久化往返：重启后能取回");
        Check([restored.title isEqualToString:@"Some English Title"], @"持久化往返：标题一致");
        Check([restored.posterURLString isEqualToString:@"https://cdn.example/407460h.jpg"], @"持久化往返：封面一致");

        // ── ⑤ 封面恢复确实被发起（恢复引擎组件被真正调用）──
        NSUInteger attemptsBefore = c.coverRecoveryAttemptCount;
        // Count the real recovery entry without a poster fetch. The original
        // m has a remote poster for storage tests, so it is not a no-network fixture.
        DetectedMedia *coverFixture = Media(@"https://site.example/no-poster", @"Local Fixture", nil);
        [c recoverCoverForMedia:coverFixture completion:^(NSImage *img){ (void)img; }];
        Check(c.coverRecoveryAttemptCount == attemptsBefore + 1, @"封面恢复尝试被计数（引擎确实被调用）");
        [c recoverCoverForMedia:nil completion:^(NSImage *img){ (void)img; }];
        Check(c.coverRecoveryAttemptCount == attemptsBefore + 1, @"nil 媒体不发起恢复");

        // ── ⑥ 恢复引擎判据纯函数（生产实现，非副本）──
        Check([RDCoverRecoveryEngine isAcceptablePosterMIME:@"image/jpeg"], @"MIME image/jpeg 可接受");
        Check([RDCoverRecoveryEngine isAcceptablePosterMIME:@"image/png"], @"MIME image/png 可接受");
        Check([RDCoverRecoveryEngine isAcceptablePosterMIME:nil], @"MIME 未声明 → 交给解码兜底");
        Check([RDCoverRecoveryEngine isAcceptablePosterMIME:@"application/octet-stream"], @"octet-stream 交给解码");
        Check(![RDCoverRecoveryEngine isAcceptablePosterMIME:@"text/html"], @"MIME text/html 拒绝");
        Check(![RDCoverRecoveryEngine isAcceptablePosterMIME:@"application/json"], @"MIME application/json 拒绝");
        Check([RDCoverRecoveryEngine isRecoverablePosterStatus:403], @"403（防盗链）可重试");
        Check([RDCoverRecoveryEngine isRecoverablePosterStatus:429], @"429 可重试");
        Check([RDCoverRecoveryEngine isRecoverablePosterStatus:503], @"503 可重试");
        Check(![RDCoverRecoveryEngine isRecoverablePosterStatus:401], @"401 不可重试");
        Check(![RDCoverRecoveryEngine isRecoverablePosterStatus:404], @"404 不可重试");
        Check(![RDCoverRecoveryEngine isRecoverablePosterStatus:410], @"410 不可重试");

        // ── ⑦ 翻译判据纯函数 ──
        Check([ResourceTitleTranslator titleNeedsChineseTranslation:@"Hello World"], @"英文标题需要翻译");
        Check(![ResourceTitleTranslator titleNeedsChineseTranslation:@"中文标题"], @"中文标题不需要翻译");
        Check(![ResourceTitleTranslator titleNeedsChineseTranslation:@""], @"空标题不需要翻译");

        // ── ⑧ 存储规范化纯函数 ──
        NSString *norm = [RDDisplayMetadataRecoveryStore normalizedSourcePageURLString:@"HTTPS://Site.Example/a/b#frag"];
        Check([norm containsString:@"site.example"], @"规范化：host 转小写");
        Check(![norm containsString:@"#frag"], @"规范化：去掉 fragment");

        // ── ⑨ 取消不崩 ──
        [c cancelAll];
        [c2 cancelAll];
        Check(YES, @"cancelAll 不崩");

        @synchronized (MetadataNoNetworkProtocol.class) {
            Check(gNetworkAttempts == 0, @"全套元数据夹具未尝试任何HTTP网络请求");
        }
        // 清理独立 suite
        [isolated removePersistentDomainForName:suiteName];

        NSLog(@"METADATA-RECOVERY-%@ checks=%d failed=%d",
              gFailed == 0 ? @"PASSED" : @"FAILED", gPassed, gFailed);
    }
    return gFailed == 0 ? 0 : 1;
}
