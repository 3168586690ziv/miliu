// Retry-After 策略的受控验证（不联网、无真实 WebKit 导航、不读 Cookie/凭据）。
//
// 被测对象是**生产源码** src/Features/ResourceDetector/StaticHTMLDiscoveryPageProbe.m
// （由 retry-after.sh 作为编译单元直接编入，而不是复制算法）。测试只使用两类替身：
//   1) NSURLProtocol 夹具（记录请求时刻、按脚本返回状态/头/体）—— 既有模式，见
//      tests/Tests/ExternalScriptTests.m 的 ScriptProtocol；
//   2) 安全 gate 替身 SHPTestGate（文本判定 + 主线程回调，不做 DNS、不开网络）—— 沿用
//      tests/Tests/ExternalScriptTests.m 的 ScriptGate 模式。**不关闭生产 SSRF 边界**：
//      生产 ResourceURLGate 的校验逻辑不在生产代码里被改动，只是测试实例换了实现。
//   3) 内核回退替身 SHPFakeMediaProbe，经类扩展里的私有注入点
//      rd_mediaResponseProbeFactory（KVC 设置）注入，替代真实 WKWebView 导航。
//
// 策略断言（本阶段要确立的规则）：
//   · 不得早于服务端 Retry-After 再次请求；
//   · 要求等待超过 24s 总预算时直接收尾，不重试、也不发起内核回退；
//   · 内核回退与静态重试都受同一条等待/预算规则约束。
//
// 编译/运行：bash tests/Tests/retry-after.sh

#import <Foundation/Foundation.h>
#import "StaticHTMLDiscoveryPageProbe.h"
#import "ResourceURLGate.h"

// ─────────────────────────── 断言 / 时钟 / 泵 ───────────────────────────
static int gFailures = 0;
static void Check(BOOL ok, NSString *message) {
    printf("%s %s\n", ok ? "PASS" : "FAIL", message.UTF8String);
    if (!ok) gFailures++;
}
static double Now(void) { return [NSDate date].timeIntervalSince1970; }
static void Pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}
// 条件等待：满足即返回，绝不为了“等够”而空转，避免长 Pump 把后续请求也等进来。
static BOOL PumpUntil(BOOL (^condition)(void), double timeout) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (end.timeIntervalSinceNow > 0) {
        if (condition()) return YES;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}
static NSString *RFC1123(double offset) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
    return [f stringFromDate:[NSDate dateWithTimeIntervalSinceNow:offset]];
}
// 把 HTTP-date 解析回时间戳：HTTP-date 只有 1 秒粒度，断言必须对齐“服务端指定时刻”，
// 而不是对齐“生成时刻 + N 秒”（后者会因截断而少最多 1 秒）。
static double ParseRFC1123Epoch(NSString *value) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
    return [[f dateFromString:value] timeIntervalSince1970];
}
static NSHTTPURLResponse *HTTPResp(NSURL *url, NSInteger status, NSDictionary *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status
                                      HTTPVersion:@"HTTP/1.1" headerFields:headers ?: @{}];
}

// ─────────────────── 安全 gate 替身（文本判定，不联网） ───────────────────
@interface SHPTestGate : ResourceURLGate @end
@implementation SHPTestGate
- (void)verifyURLAsync:(NSURL *)url completion:(void (^)(URLPolicyDecision *))completion {
    URLPolicyDecision *d = [self.policy evaluateTextURL:url.absoluteString];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(d); });
}
@end

// ─────────────────── NSURLProtocol 夹具（脚本化响应 + 请求时刻） ───────────────────
// gScripts[path] = 响应字典数组，按到达顺序弹出；字典字段：
//   status (NSNumber) / headers (NSDictionary) / body (NSString) / fail (NSNumber: NSURLError 码)
// 队列为空时按「连不上」失败。gRequestLog 记录每次请求的 path 与时刻。
@interface SHPFixtureProtocol : NSURLProtocol @end
static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *gScripts;
static NSMutableArray<NSDictionary *> *gRequestLog;

@implementation SHPFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSString *path = self.request.URL.path ?: @"";
    NSDictionary *entry = nil;
    @synchronized (gScripts) {
        NSMutableArray *q = gScripts[path];
        if (q.count) { entry = q.firstObject; [q removeObjectAtIndex:0]; }
    }
    @synchronized (gRequestLog) {
        [gRequestLog addObject:@{@"path": path, @"t": @(Now())}];
    }
    if (!entry) {
        [self.client URLProtocol:self didFailWithError:
            [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]];
        return;
    }
    NSNumber *fail = entry[@"fail"];
    if (fail) {
        [self.client URLProtocol:self didFailWithError:
            [NSError errorWithDomain:NSURLErrorDomain code:fail.integerValue userInfo:nil]];
        return;
    }
    NSInteger status = entry[@"status"] ? [entry[@"status"] integerValue] : 200;
    NSData *body = [(entry[@"body"] ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *resp = HTTPResp(self.request.URL, status, entry[@"headers"]);
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length) [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static void ResetFixture(NSDictionary *script) {
    @synchronized (gScripts) {
        [gScripts removeAllObjects];
        for (NSString *key in script) gScripts[key] = [script[key] mutableCopy];
    }
    @synchronized (gRequestLog) { [gRequestLog removeAllObjects]; }
}
static NSUInteger CountPath(NSString *path) {
    NSUInteger n = 0;
    @synchronized (gRequestLog) {
        for (NSDictionary *e in gRequestLog) if ([e[@"path"] isEqual:path]) n++;
    }
    return n;
}
static double TimeOfRequest(NSString *path, NSUInteger index) {
    NSUInteger seen = 0;
    @synchronized (gRequestLog) {
        for (NSDictionary *e in gRequestLog) {
            if (![e[@"path"] isEqual:path]) continue;
            if (seen++ == index) return [e[@"t"] doubleValue];
        }
    }
    return -1;
}

// ─────────────────── 内核回退替身（无真实 WKWebView） ───────────────────
// 生产在 rd_mediaResponseProbeFactory 存在时直接使用工厂返回的对象，并要求工厂自行启动。
// 这里异步回调，避免在生产把 probe 写回 ctx.mediaResponseProbe 之前就完成。
@interface SHPFakeMediaProbe : NSObject
@property (nonatomic, copy) void (^completion)(NSHTTPURLResponse *, NSError *);
@property (nonatomic, copy) NSHTTPURLResponse *(^httpProvider)(void);
@property (nonatomic, copy) NSError *(^errorProvider)(void);
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) NSUInteger startCount;
@property (nonatomic, assign) double lastStartTime;
@property (nonatomic, assign) NSTimeInterval lastTimeout;
@end
@implementation SHPFakeMediaProbe
- (void)startWithURL:(NSURL *)url referer:(NSURL *)referer timeout:(NSTimeInterval)timeout {
    self.startCount += 1;
    self.lastStartTime = Now();
    self.lastTimeout = timeout;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        void (^cb)(NSHTTPURLResponse *, NSError *) = self.completion;
        self.completion = nil;
        if (cb) cb(self.httpProvider ? self.httpProvider() : nil,
                   self.errorProvider ? self.errorProvider() : nil);
    });
}
- (void)cancel { self.cancelled = YES; }
@end

// ─────────────────── 记录器 + 统一驱动 ───────────────────
@interface SHPRecorder : NSObject
@property (nonatomic, assign) NSUInteger completions;
@property (nonatomic, strong) NSArray *media;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) double firstCompletionTime;
@end
@implementation SHPRecorder @end

static SHPRecorder *Run(NSDictionary *script, NSURL *url,
                        SHPFakeMediaProbe **outFake,
                        id *outToken,
                        StaticHTMLDiscoveryPageProbe **outProbe) {
    ResetFixture(script);
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.protocolClasses = @[SHPFixtureProtocol.class];
    StaticHTMLDiscoveryPageProbe *probe =
        [[StaticHTMLDiscoveryPageProbe alloc] initWithPolicy:[URLPolicy new] sessionConfiguration:cfg];
    [probe setValue:[SHPTestGate new] forKey:@"gate"];

    SHPFakeMediaProbe *fake = [SHPFakeMediaProbe new];
    id (^factory)(NSURL *, NSURL *, NSTimeInterval, void (^)(NSHTTPURLResponse *, NSError *)) =
        ^id(NSURL *u, NSURL *r, NSTimeInterval t, void (^cb)(NSHTTPURLResponse *, NSError *)) {
            fake.completion = cb;
            [fake startWithURL:u referer:r timeout:t];
            return (id)fake;
        };
    [probe setValue:factory forKey:@"rd_mediaResponseProbeFactory"];

    SHPRecorder *rec = [SHPRecorder new];
    id token = [probe probePageURL:url completion:^(NSArray *media, NSError *error) {
        rec.completions += 1;
        if (!rec.media) rec.media = media;
        if (!rec.error) rec.error = error;
        if (rec.firstCompletionTime <= 0) rec.firstCompletionTime = Now();
    }];
    if (outFake) *outFake = fake;
    if (outToken) *outToken = token;
    if (outProbe) *outProbe = probe;
    return rec;
}

// 便捷脚本构造
static NSDictionary *ScriptPage(NSArray *entries) { return @{@"/page": [entries mutableCopy]}; }
static NSString *const kHTMLWithVideo = @"<html><body><video src='/v.mp4'></video></body></html>";

int main(void) {
    @autoreleasepool {
        gScripts = [NSMutableDictionary dictionary];
        gRequestLog = [NSMutableArray array];
        NSURL *pageURL = [NSURL URLWithString:@"https://example.com/page"];
        NSURL *mediaURL = [NSURL URLWithString:@"https://example.com/clip.mp4"];

        // T1 数值 60s 超过 24s 预算 → 不重试，直接收尾
        {
            SHPRecorder *rec = Run(ScriptPage(@[@{@"status": @429, @"headers": @{@"Retry-After": @"60"}}]),
                                   pageURL, NULL, NULL, NULL);
            Pump(1.5);
            Check(rec.completions == 1, @"T1 Retry-After 60（超预算）只收尾一次");
            Check(rec.error.code == 429, @"T1 最终错误仍为 HTTP 429");
            Check(CountPath(@"/page") == 1, @"T1 超预算不得再次请求");
        }

        // T2 未来 HTTP-date（+60s）超过预算 → 不重试
        {
            NSString *future = RFC1123(60);
            SHPRecorder *rec = Run(ScriptPage(@[@{@"status": @503, @"headers": @{@"Retry-After": future}}]),
                                   pageURL, NULL, NULL, NULL);
            Pump(1.5);
            Check(rec.completions == 1, @"T2 未来 HTTP-date(+60s) 超预算只收尾一次");
            Check(rec.error.code == 503, @"T2 最终错误仍为 HTTP 503");
            Check(CountPath(@"/page") == 1, @"T2 超预算不得再次请求");
        }

        // T3 Retry-After 2s：窗口内不得再请求，之后重试一次并成功
        {
            SHPRecorder *rec = Run(ScriptPage(@[
                @{@"status": @429, @"headers": @{@"Retry-After": @"2"}},
                @{@"status": @200, @"headers": @{@"Content-Type": @"text/html"}, @"body": kHTMLWithVideo}
            ]), pageURL, NULL, NULL, NULL);
            Pump(0.6);
            Check(CountPath(@"/page") == 1, @"T3 2s 等待窗口内不得再次请求");
            Pump(6.5);   // 2s 等待 + HTML 解析后的 4s 脚本窗口
            Check(CountPath(@"/page") == 2, @"T3 等待 2s 后重试一次");
            Check(rec.completions == 1 && rec.media.count >= 1, @"T3 重试成功后拿到资源且只收尾一次");
        }

        // T4 重试等待期间取消：不回调、不再请求
        {
            id token = nil; StaticHTMLDiscoveryPageProbe *probe = nil;
            SHPRecorder *rec = Run(ScriptPage(@[@{@"status": @429, @"headers": @{@"Retry-After": @"2"}}]),
                                   pageURL, NULL, &token, &probe);
            Pump(0.3);
            Check(rec.completions == 0, @"T4 取消前尚未收尾（前置条件）");
            [probe cancelProbe:token];
            Pump(3.0);
            Check(rec.completions == 0, @"T4 取消后不回调");
            Check(CountPath(@"/page") == 1, @"T4 取消后不再发起重试请求");
        }

        // T5 非媒体 404：确定性答复，不重试
        {
            SHPRecorder *rec = Run(ScriptPage(@[@{@"status": @404}]), pageURL, NULL, NULL, NULL);
            Pump(1.0);
            Check(CountPath(@"/page") == 1 && rec.completions == 1 && rec.error.code == 404,
                  @"T5 非媒体 404 只请求一次且错误码 404");
        }

        // T6 媒体型 404：走一次内核回退，但静态腿不重试
        {
            SHPFakeMediaProbe *fake = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @404}]}, mediaURL, &fake, NULL, NULL);
            Pump(1.5);
            Check(fake.startCount == 1, @"T6 媒体型 404 触发一次内核回退");
            Check(CountPath(@"/clip.mp4") == 1, @"T6 确定性 404 不重试静态腿");
            Check(rec.completions == 1 && rec.error.code == 404, @"T6 最终错误码 404");
        }

        // T7 网络超时：按瞬时类重试一次后成功
        {
            SHPRecorder *rec = Run(ScriptPage(@[
                @{@"fail": @(NSURLErrorTimedOut)},
                @{@"status": @200, @"headers": @{@"Content-Type": @"text/html"}, @"body": kHTMLWithVideo}
            ]), pageURL, NULL, NULL, NULL);
            Pump(6.5);
            Check(CountPath(@"/page") == 2, @"T7 网络超时按瞬时类重试一次");
            Check(rec.completions == 1 && rec.media.count >= 1, @"T7 重试成功后拿到资源");
        }

        // T8 取消回声：结论已定的任务随后收到 NSURLErrorCancelled，不得再次收尾
        {
            SHPRecorder *rec = nil; id token = nil; StaticHTMLDiscoveryPageProbe *probe = nil; SHPFakeMediaProbe *fake = nil;
            rec = Run(ScriptPage(@[@{@"status": @429, @"headers": @{@"Retry-After": @"60"}}]),
                      pageURL, &fake, &token, &probe);
            Pump(1.5);
            Check(rec.completions == 1, @"T8 前置：已收尾一次");
            NSURLSessionTask *task = [token valueForKey:@"task"];
            NSError *echo = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            [(id<NSURLSessionTaskDelegate>)probe URLSession:NSURLSession.sharedSession
                                                      task:task didCompleteWithError:echo];
            Pump(0.4);
            Check(rec.completions == 1, @"T8 取消回声不产生第二次收尾");
        }

        // T8b 取消回声（ctx 仍在 contexts 映射内、pendingOutcomeHandled=YES 期间）：
        //     手动注入 NSURLErrorCancelled，不得提前收尾，也不得取消在途的回退。
        //     删除生产里的 pendingOutcomeHandled guard 后，本用例必然失败（见 mutation-check.sh）。
        {
            SHPFakeMediaProbe *fake = nil; id token = nil; StaticHTMLDiscoveryPageProbe *probe = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @429, @"headers": @{@"Retry-After": @"2"}}]},
                                   mediaURL, &fake, &token, &probe);
            fake.errorProvider = ^NSError *{
                return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
            };
            Check(PumpUntil(^BOOL { return TimeOfRequest(@"/clip.mp4", 0) > 0; }, 2.0),
                  @"T8b 首次请求已记录");
            Pump(0.2);   // 让非 2xx 结论落地（pendingOutcomeHandled=YES）且 ctx 仍在映射内
            NSURLSessionTask *task = [token valueForKey:@"task"];
            Check(task != nil && rec.completions == 0 && fake.startCount == 0,
                  @"T8b 前置：ctx 在等待期、尚未收尾、回退未发起");
            NSError *echo = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            [(id<NSURLSessionTaskDelegate>)probe URLSession:NSURLSession.sharedSession
                                                      task:task didCompleteWithError:echo];
            Pump(0.3);
            Check(rec.completions == 0, @"T8b 取消回声不得提前收尾");
            Check(PumpUntil(^BOOL { return fake.startCount >= 1; }, 4.0),
                  @"T8b 取消回声不得取消在途回退（回退仍按 2s 发起）");
            Check(fake.lastStartTime - TimeOfRequest(@"/clip.mp4", 0) >= 1.9,
                  @"T8b 回退仍不早于服务端 Retry-After 2s");
            Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 5.0) && rec.completions == 1,
                  @"T8b 最终只收尾一次");
        }

        // T9 回退不得提前于服务端 Retry-After；回退后按“内核新答复/默认退避”走，
        //    不对同一个静态答复重复等待（协议只要求「不早于」，不要求把 2s 再等一遍）。
        {
            SHPFakeMediaProbe *fake = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[
                @{@"status": @429, @"headers": @{@"Retry-After": @"2"}},
                @{@"status": @429, @"headers": @{@"Retry-After": @"2"}}
            ]}, mediaURL, &fake, NULL, NULL);
            // 回退是异步的：Run 返回后、Pump 之前设置替身行为仍然有效。
            fake.errorProvider = ^NSError *{
                return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
            };
            Check(PumpUntil(^BOOL { return TimeOfRequest(@"/clip.mp4", 0) > 0; }, 2.0),
                  @"T9 首次请求已记录");
            double t0 = TimeOfRequest(@"/clip.mp4", 0);
            Pump(1.0);   // 只在“2s 窗口内”这一明确区间内观察
            Check(fake.startCount == 0 && CountPath(@"/clip.mp4") == 1,
                  @"T9 2s 窗口内不得发起回退、不得重试");
            Check(PumpUntil(^BOOL { return fake.startCount >= 1; }, 4.0),
                  @"T9 等待 2s 后发起内核回退");
            double fallbackDelta = fake.lastStartTime - t0;
            Check(fallbackDelta >= 1.9, @"T9 回退发起时刻 >= 失败时刻 + 2s");
            Check(PumpUntil(^BOOL { return CountPath(@"/clip.mp4") >= 2; }, 3.0),
                  @"T9 回退失败后发起一次静态重试");
            double retryDelta = TimeOfRequest(@"/clip.mp4", 1) - t0;
            printf("  [T9] fallbackΔ=%.3fs  retryΔ=%.3fs（fallback>=2；retry>=2 且不要求 >=4）\n",
                   fallbackDelta, retryDelta);
            Check(retryDelta >= 2.7, @"T9 重试不早于「回退时刻 + 默认退避 1s」");
            Check(TimeOfRequest(@"/clip.mp4", 1) - fake.lastStartTime >= 0.7,
                  @"T9 重试发生在回退之后，而非与回退同时");
            Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 5.0), @"T9 最终收尾");
            Check(rec.completions == 1, @"T9 最终只收尾一次");
        }

        // T10 回退也受预算约束：Retry-After 超预算时不得发起内核回退
        {
            SHPFakeMediaProbe *fake = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @429, @"headers": @{@"Retry-After": @"60"}}]},
                                   mediaURL, &fake, NULL, NULL);
            Pump(1.5);
            Check(fake.startCount == 0, @"T10 要求等待超预算时不得发起内核回退");
            Check(CountPath(@"/clip.mp4") == 1 && rec.completions == 1 && rec.error.code == 429,
                  @"T10 超预算直接收尾，不导航不重试");
        }

        // T11 无 Retry-After 时维持立即回退（回归：不能把回退本身关掉）
        {
            SHPFakeMediaProbe *fake = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @403}]}, mediaURL, &fake, NULL, NULL);
            // 回退是异步的：Run 返回后、Pump 之前设置替身行为仍然有效。
            fake.httpProvider = ^NSHTTPURLResponse *{
                return HTTPResp(mediaURL, 200, @{@"Content-Type": @"video/mp4", @"Content-Length": @"1000"});
            };
            Pump(1.5);
            Check(fake.startCount == 1, @"T11 无 Retry-After 时维持立即回退");
            Check(rec.completions == 1 && rec.media.count == 1 &&
                  [[(DetectedMedia *)rec.media.firstObject discoverySource] isEqual:@"direct-url"],
                  @"T11 回退 200 媒体生成 direct-url 条目");
        }

        // T12 401 非媒体：确定性答复，只请求一次
        {
            SHPRecorder *rec = Run(ScriptPage(@[@{@"status": @401}]), pageURL, NULL, NULL, NULL);
            Pump(1.0);
            Check(CountPath(@"/page") == 1 && rec.completions == 1 && rec.error.code == 401,
                  @"T12 非媒体 401 只请求一次且错误码 401");
        }

        // T13 401 媒体：走一次内核回退，静态腿不重试
        {
            SHPFakeMediaProbe *fake = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @401}]}, mediaURL, &fake, NULL, NULL);
            Pump(1.5);
            Check(fake.startCount == 1, @"T13 媒体型 401 触发一次内核回退");
            Check(CountPath(@"/clip.mp4") == 1, @"T13 确定性 401 不重试静态腿");
            Check(rec.completions == 1 && rec.error.code == 401, @"T13 最终错误码 401");
        }

        // T14 未来 HTTP-date(+2s)：等待窗口内不请求；重试不得早于「服务端指定的那个时刻」
        {
            NSString *soon = RFC1123(2);
            double targetEpoch = ParseRFC1123Epoch(soon);
            SHPRecorder *rec = Run(ScriptPage(@[
                @{@"status": @429, @"headers": @{@"Retry-After": soon}},
                @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}, @"body": @"x"}
            ]), pageURL, NULL, NULL, NULL);
            Pump(0.6);
            Check(CountPath(@"/page") == 1, @"T14 HTTP-date(+2s) 窗口内不得再次请求");
            Pump(2.8);
            double t1 = TimeOfRequest(@"/page", 1);
            printf("  [T14] serverEpoch-t0=%.3fs  retryAt-serverEpoch=%.3fs（<=0.15 表示不早于服务端时刻）\n",
                   targetEpoch - TimeOfRequest(@"/page", 0), t1 - targetEpoch);
            Check(CountPath(@"/page") == 2 && t1 >= targetEpoch - 0.15,
                  @"T14 重试不早于 HTTP-date 指定的服务端时刻");
            Check(rec.completions == 1 && rec.media.count == 1, @"T14 重试后按直链媒体收尾");
        }

        // T15 非法文本 delta-seconds（含 inf/nan/科学计数/小数）：按「无此头」处理 → 默认退避重试；
        //     同时验证不会因为非有限值进入 dispatch_time 而崩溃/溢出。
        //     第二跳用 video/mp4，使成功路径立即收尾（不进入 4s 脚本窗口）。
        {
            NSArray *garbage = @[@"inf", @"-inf", @"nan", @"1e999", @"1.5", @"abc"];
            for (NSString *bad in garbage) {
                SHPRecorder *rec = Run(ScriptPage(@[
                    @{@"status": @429, @"headers": @{@"Retry-After": bad}},
                    @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}, @"body": @"x"}
                ]), pageURL, NULL, NULL, NULL);
                Pump(1.8);
                Check(CountPath(@"/page") == 2 && rec.completions == 1,
                      [NSString stringWithFormat:@"T15 非法 Retry-After「%@」按无等待处理并默认退避重试", bad]);
            }
        }

        // T15b 合法但巨大的 delta-seconds：仍有限 → 压到预算 → 超预算不重试（不得提前请求）
        {
            NSArray *huge = @[@"9999999999", @"999999999999", @"1000000000000000000000000000000"];
            for (NSString *big in huge) {
                SHPRecorder *rec = Run(ScriptPage(@[
                    @{@"status": @429, @"headers": @{@"Retry-After": big}},
                    @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}, @"body": @"x"}
                ]), pageURL, NULL, NULL, NULL);
                Pump(1.5);
                Check(CountPath(@"/page") == 1 && rec.completions == 1 && rec.error.code == 429,
                      [NSString stringWithFormat:@"T15b 合法巨值 Retry-After「%@」超预算不重试", big]);
            }
        }

        // T16 生产实例未注入 gate/替身时，安全校验仍启用（不联网即可验证）
        {
            NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            cfg.protocolClasses = @[SHPFixtureProtocol.class];
            ResetFixture(@{@"/blocked.mp4": @[@{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}}]});
            StaticHTMLDiscoveryPageProbe *plain =
                [[StaticHTMLDiscoveryPageProbe alloc] initWithPolicy:[URLPolicy new] sessionConfiguration:cfg];
            ResourceURLGate *gate = [plain valueForKey:@"gate"];
            Check(gate.rd_checksEnabled == YES, @"T16 未注入时生产 gate 的 rd_checksEnabled 仍为 YES");
            SHPRecorder *rec = [SHPRecorder new];
            [plain probePageURL:[NSURL URLWithString:@"http://127.0.0.1/blocked.mp4"]
                     completion:^(NSArray *media, NSError *error) {
                rec.completions += 1;
                if (!rec.media) rec.media = media;
                if (!rec.error) rec.error = error;
            }];
            Pump(1.0);
            Check(rec.completions == 1 && rec.error.code == ZZResourceDiscoveryErrorInvalidURL,
                  @"T16 回环地址在文本阶段被安全校验拒绝");
            Check(CountPath(@"/blocked.mp4") == 0, @"T16 被拒地址未发出任何请求（安全边界生效）");
        }

        // T17 Retry-After 头名大小写：受控验证，不凭字典语法猜测解析器行为
        {
            for (NSString *name in @[@"Retry-After", @"retry-after", @"RETRY-AFTER"]) {
                SHPRecorder *rec = Run(ScriptPage(@[
                    @{@"status": @429, @"headers": @{name: @"2"}},
                    @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}, @"body": @"x"}
                ]), pageURL, NULL, NULL, NULL);
                Check(PumpUntil(^BOOL { return TimeOfRequest(@"/page", 0) > 0; }, 2.0), @"T17 首请求");
                double t0 = TimeOfRequest(@"/page", 0);
                Check(PumpUntil(^BOOL { return CountPath(@"/page") >= 2; }, 3.0),
                      [NSString stringWithFormat:@"T17 头名「%@」被识别并重试", name]);
                double d = TimeOfRequest(@"/page", 1) - t0;
                printf("  [T17] header=%-12s retryΔ=%.3fs\n", name.UTF8String, d);
                Check(d >= 1.8, [NSString stringWithFormat:@"T17 头名「%@」的重试不早于 2s", name]);
                Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 2.0) && rec.completions == 1,
                      [NSString stringWithFormat:@"T17 头名「%@」只收尾一次", name]);
            }
        }

        // T18 等待到期时重算预算：媒体回退等待期间预算被耗尽 → 不得发起内核回退（零新请求）
        {
            SHPFakeMediaProbe *fake = nil; id token = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @429, @"headers": @{@"Retry-After": @"2"}}]},
                                   mediaURL, &fake, &token, NULL);
            Check(PumpUntil(^BOOL { return TimeOfRequest(@"/clip.mp4", 0) > 0; }, 2.0), @"T18 首请求");
            Pump(0.2);   // 等待 2s 已调度，尚未到期
            [token setValue:@([NSDate date].timeIntervalSince1970 - 30.0) forKey:@"startedAt"];
            Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 4.0), @"T18 到期后收尾");
            Check(fake.startCount == 0, @"T18 到期时预算已耗尽：不得发起内核回退（零新请求）");
            Check(CountPath(@"/clip.mp4") == 1 && rec.completions == 1 && rec.error.code == 429,
                  @"T18 除首次静态请求外无新请求，且按原错误收尾");
        }

        // T19 重试到期时重算预算：等待期间预算被耗尽 → 不得发起重试请求
        {
            id token = nil;
            SHPRecorder *rec = Run(ScriptPage(@[
                @{@"status": @429, @"headers": @{@"Retry-After": @"2"}},
                @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}, @"body": @"x"}
            ]), pageURL, NULL, &token, NULL);
            Check(PumpUntil(^BOOL { return TimeOfRequest(@"/page", 0) > 0; }, 2.0), @"T19 首请求");
            Pump(0.2);
            [token setValue:@([NSDate date].timeIntervalSince1970 - 30.0) forKey:@"startedAt"];
            Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 4.0), @"T19 到期后收尾");
            Check(CountPath(@"/page") == 1, @"T19 到期时预算已耗尽：不得发起重试请求");
            Check(rec.completions == 1 && rec.error.code == 429, @"T19 按原错误收尾");
        }

        // T20 立即回退（无 Retry-After）同样受预算约束：预算耗尽时零新请求
        {
            SHPFakeMediaProbe *fake = nil; id token = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[@{@"status": @404}]}, mediaURL, &fake, &token, NULL);
            [token setValue:@([NSDate date].timeIntervalSince1970 - 30.0) forKey:@"startedAt"];
            Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 2.5), @"T20 收尾");
            Check(fake.startCount == 0, @"T20 预算耗尽时立即回退也不导航（零新请求）");
            Check(CountPath(@"/clip.mp4") == 1 && rec.completions == 1 && rec.error.code == 404,
                  @"T20 除首次静态请求外无新请求，按原错误收尾");
        }

        // T21 回退收到的 timeout 受剩余预算约束（不因 requestTimeout 放大而突破预算）
        {
            SHPFakeMediaProbe *fake = nil; StaticHTMLDiscoveryPageProbe *probe = nil;
            SHPRecorder *rec = Run(@{@"/clip.mp4": @[
                @{@"status": @403},
                @{@"status": @200, @"headers": @{@"Content-Type": @"video/mp4"}, @"body": @"x"}
            ]}, mediaURL, &fake, NULL, &probe);
            probe.requestTimeout = 30.0;   // 故意放大：实际应被 MIN(·, 剩余预算) 压回
            Check(PumpUntil(^BOOL { return fake.startCount >= 1; }, 3.0), @"T21 回退已发起");
            printf("  [T21] requestTimeout=30  probeTimeout=%.3fs\n", fake.lastTimeout);
            Check(fake.lastTimeout >= 1.0 && fake.lastTimeout <= 24.0,
                  @"T21 回退 timeout 受剩余预算约束（<=24，而非 requestTimeout=30）");
            Check(PumpUntil(^BOOL { return rec.completions >= 1; }, 3.0) && rec.completions == 1,
                  @"T21 最终收尾一次");
        }

        printf("FAILURES=%d\n", gFailures);
        return gFailures ? 1 : 0;
    }
}
