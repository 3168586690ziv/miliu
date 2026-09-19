// Included by adaptive-transport.sh; offline unit tests via injected curl runner / DNS resolver.
// 覆盖：RDAdaptiveTransport（元数据 curl 回退）、RDCurlHopper（逐跳校验引擎）、
// RDCurlFallbackBackend（下载 curl 回退）。根因见 RDAdaptiveTransport.h 头注释。
#import <Foundation/Foundation.h>
#import "RDAdaptiveTransport.h"
#import "RDCurlFallbackBackend.h"
#import "RDCurlHopper.h"
#import "RDMetadataTransport.h"
#import "DownloadManager.h"

static int failures, checks;
static void check(BOOL ok, NSString *message) {
    checks++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", message.UTF8String);
    if (!ok) failures++;
}
static void WaitFor(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}

static NSString *ARGVValue(NSArray<NSString *> *argv, NSString *flag) {
    NSUInteger idx = [argv indexOfObject:flag];
    return (idx != NSNotFound && idx + 1 < argv.count) ? argv[idx + 1] : nil;
}
// 模拟 curl：按 URL 分流写头/体。jmpres → 302；real.mp4 → 206 + Content-Range + body。
static NSInteger (^FixtureRunner)(NSArray<NSString *> *, NSString *, NSString *) = ^NSInteger(NSArray<NSString *> *argv, NSString *headerFile, NSString *bodyFile) {
    NSString *url = argv.lastObject;
    if ([url containsString:@"jmpres"]) {
        [@"" writeToFile:bodyFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return [@"HTTP/2 302\r\nlocation: https://media.fixture.test/real.mp4?secure=x\r\ncontent-length: 0\r\n\r\n"
                writeToFile:headerFile atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : -1;
    }
    if ([url containsString:@"real.mp4"]) {
        [@"MAGIC-BYTES" writeToFile:bodyFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return [@"HTTP/2 206\r\ncontent-type: video/mp4\r\ncontent-length: 11\r\ncontent-range: bytes 0-1048575/175013039\r\n\r\n"
                writeToFile:headerFile atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : -1;
    }
    return 7;
};
static NSArray<NSString *> *(^FixedResolver)(NSString *host) = ^NSArray<NSString *> *(NSString *host) {
    return @[@"93.184.216.34"];
};

@interface MockNativeTransport : NSObject <RDMetadataTransporting>
@property (nonatomic, copy) RDMetadataResponse *(^handler)(NSURLRequest *req);
@property (nonatomic, assign) NSInteger calls;
@end
@implementation MockNativeTransport
- (RDMetadataToken *)request:(NSURLRequest *)req budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout
                  completion:(void (^)(RDMetadataResponse *))completion {
    self.calls++;
    RDMetadataResponse *r = self.handler ? self.handler(req) : nil;
    if (r) completion(r);
    return [RDMetadataToken new];
}
@end

static RDMetadataResponse *FailedResponse(RDMetadataError code, NSInteger statusCode) {
    RDMetadataResponse *r = [RDMetadataResponse new];
    r.error = [NSError errorWithDomain:RDMetadataErrorDomain code:code userInfo:nil];
    if (statusCode > 0)
        r.response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://site.fixture.test/a.mp4"]
                                                 statusCode:statusCode HTTPVersion:@"HTTP/2" headerFields:@{}];
    return r;
}

// ── 元数据复合传输 ──
static void AdaptiveTransportTests(void) {
    // A1：原生 403 拦截页 → curl 回退逐跳成功，回填响应体与终跳 URL。
    {
        MockNativeTransport *native = [MockNativeTransport new];
        native.handler = ^RDMetadataResponse *(NSURLRequest *req) { return FailedResponse(RDMetadataHTTPFailure, 403); };
        RDAdaptiveTransport *t = [RDAdaptiveTransport adaptiveWithNativeTransport:native];
        t.curlRunner = FixtureRunner;
        t.resolver = FixedResolver;
        __block RDMetadataResponse *got = nil;
        RDMetadataToken *token = [t request:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/jmpres/a.mp4?secure=x"]]
                                     budget:1024*1024 timeout:5 completion:^(RDMetadataResponse *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(got && !got.error, @"A1 原生403 → curl 回退成功无错误");
        check([got.data isEqualToData:[@"MAGIC-BYTES" dataUsingEncoding:NSUTF8StringEncoding]], @"A1 回填 curl 响应体");
        check(got.response.statusCode == 206, @"A1 终跳状态 206");
        check([got.response.URL.host isEqual:@"media.fixture.test"], @"A1 终跳 URL 为重定向目标");
        check(got.response && [[got.response valueForHTTPHeaderField:@"Content-Range"] containsString:@"175013039"], @"A1 Content-Range 头可用于大小腿");
        (void)token;
    }
    // A2：原生成功 → 绝不回退。
    {
        MockNativeTransport *native = [MockNativeTransport new];
        native.handler = ^RDMetadataResponse *(NSURLRequest *req) {
            RDMetadataResponse *r = [RDMetadataResponse new];
            r.data = [@"NATIVE" dataUsingEncoding:NSUTF8StringEncoding];
            r.response = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:200 HTTPVersion:@"HTTP/2" headerFields:@{}];
            return r;
        };
        RDAdaptiveTransport *t = [RDAdaptiveTransport adaptiveWithNativeTransport:native];
        __block BOOL runnerCalled = NO;
        t.curlRunner = ^NSInteger(NSArray *a, NSString *h, NSString *b) { runnerCalled = YES; return 0; };
        t.resolver = FixedResolver;
        __block RDMetadataResponse *got = nil;
        [t request:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/ok.mp4"]]
             budget:1024 timeout:5 completion:^(RDMetadataResponse *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(!runnerCalled && got && [got.data isEqualToData:[@"NATIVE" dataUsingEncoding:NSUTF8StringEncoding]],
              @"A2 原生成功不回退");
    }
    // A3：本地策略拦截（Blocked）绝不借道 curl（SSRF 防线不可绕）。
    {
        MockNativeTransport *native = [MockNativeTransport new];
        native.handler = ^RDMetadataResponse *(NSURLRequest *req) { return FailedResponse(RDMetadataBlocked, 0); };
        RDAdaptiveTransport *t = [RDAdaptiveTransport adaptiveWithNativeTransport:native];
        __block BOOL runnerCalled = NO;
        t.curlRunner = ^NSInteger(NSArray *a, NSString *h, NSString *b) { runnerCalled = YES; return 0; };
        __block RDMetadataResponse *got = nil;
        [t request:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/a.mp4"]]
             budget:1024 timeout:5 completion:^(RDMetadataResponse *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(!runnerCalled && got.error.code == RDMetadataBlocked, @"A3 Blocked 不回退");
    }
    // A4：原生 TimedOut 且无响应（连接被晾）→ 回退；curl 也没成功 → 保留原生结果。
    {
        MockNativeTransport *native = [MockNativeTransport new];
        native.handler = ^RDMetadataResponse *(NSURLRequest *req) { return FailedResponse(RDMetadataTimedOut, 0); };
        RDAdaptiveTransport *t = [RDAdaptiveTransport adaptiveWithNativeTransport:native];
        t.curlRunner = ^NSInteger(NSArray *a, NSString *h, NSString *b) { return 28; };  // curl 超时
        t.resolver = FixedResolver;
        __block RDMetadataResponse *got = nil;
        [t request:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/a.mp4"]]
             budget:1024 timeout:5 completion:^(RDMetadataResponse *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(got.error.code == RDMetadataTimedOut, @"A4 curl 失败保留原生 TimedOut 语义");
    }
    // A5：预算超限（BudgetExceeded）不回退。
    {
        MockNativeTransport *native = [MockNativeTransport new];
        native.handler = ^RDMetadataResponse *(NSURLRequest *req) { return FailedResponse(RDMetadataBudgetExceeded, 0); };
        RDAdaptiveTransport *t = [RDAdaptiveTransport adaptiveWithNativeTransport:native];
        __block BOOL runnerCalled = NO;
        t.curlRunner = ^NSInteger(NSArray *a, NSString *h, NSString *b) { runnerCalled = YES; return 0; };
        __block RDMetadataResponse *got = nil;
        [t request:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/a.mp4"]]
             budget:1024 timeout:5 completion:^(RDMetadataResponse *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(!runnerCalled && got.error.code == RDMetadataBudgetExceeded, @"A5 Budget 不回退");
    }
}

// ── 逐跳引擎 ──
static void CurlHopperTests(void) {
    // H1：拦截页 403 终跳 → HTTPFailure 且带 response（调用方分类用）。
    {
        RDCurlHopper *hopper = [RDCurlHopper new];
        hopper.runner = ^NSInteger(NSArray<NSString *> *argv, NSString *headerFile, NSString *bodyFile) {
            [@"" writeToFile:bodyFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return [@"HTTP/2 403\r\ncontent-type: text/html\r\n\r\n" writeToFile:headerFile atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : -1;
        };
        hopper.resolver = FixedResolver;
        __block RDCurlHopResult *got = nil;
        [hopper walkURL:[NSURL URLWithString:@"https://media.fixture.test/blocked.mp4"]
                 method:@"GET" headers:@{@"Referer": @"https://site.fixture.test/"} budget:4096
               deadline:CFAbsoluteTimeGetCurrent() + 5 bodyToFile:NO completion:^(RDCurlHopResult *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(got.error.code == RDCurlHopHTTPFailure && got.response.statusCode == 403, @"H1 403 终跳 → HTTPFailure 带响应");
    }
    // H2：重定向目标未过策略（保留 IP）→ Blocked。
    {
        RDCurlHopper *hopper = [RDCurlHopper new];
        hopper.runner = ^NSInteger(NSArray<NSString *> *argv, NSString *headerFile, NSString *bodyFile) {
            [@"" writeToFile:bodyFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return [@"HTTP/2 302\r\nlocation: http://127.0.0.1:8080/private\r\n\r\n" writeToFile:headerFile atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : -1;
        };
        hopper.resolver = FixedResolver;
        __block RDCurlHopResult *got = nil;
        [hopper walkURL:[NSURL URLWithString:@"https://media.fixture.test/jmp.mp4"]
                 method:@"GET" headers:@{} budget:4096 deadline:CFAbsoluteTimeGetCurrent() + 5 bodyToFile:NO
             completion:^(RDCurlHopResult *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(got.error.code == RDCurlHopBlocked, @"H2 重定向到保留 IP → Blocked");
    }
    // H3：预算超限。
    {
        RDCurlHopper *hopper = [RDCurlHopper new];
        hopper.runner = ^NSInteger(NSArray<NSString *> *argv, NSString *headerFile, NSString *bodyFile) {
            [[NSMutableData dataWithLength:8192] writeToFile:bodyFile atomically:YES];
            return [@"HTTP/2 200\r\ncontent-type: video/mp4\r\n\r\n" writeToFile:headerFile atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : -1;
        };
        hopper.resolver = FixedResolver;
        __block RDCurlHopResult *got = nil;
        [hopper walkURL:[NSURL URLWithString:@"https://media.fixture.test/big.mp4"]
                 method:@"GET" headers:@{} budget:1024 deadline:CFAbsoluteTimeGetCurrent() + 5 bodyToFile:NO
             completion:^(RDCurlHopResult *r) { got = r; }];
        WaitFor(^BOOL{ return got != nil; });
        check(got.error.code == RDCurlHopBudgetExceeded, @"H3 响应体超预算 → BudgetExceeded");
    }
}

// ── 下载后端回退 ──
typedef void (^RDTestDownloadCompletion)(NSURL * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable);
typedef void (^RDTestDownloadProgress)(int64_t, int64_t, int64_t);
@interface RDCurlFallbackTaskMock : NSObject <RDDownloadTask>
@end
@implementation RDCurlFallbackTaskMock
- (void)rd_cancel {}
@end
@interface MockNativeBackend : NSObject <RDDownloadBackend>
@property (nonatomic, copy) void (^onRequest)(NSURLRequest *req, NSURL *writeToURL, RDTestDownloadCompletion completion);
@property (nonatomic, assign) NSInteger calls;
@end
@implementation MockNativeBackend
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                           completion:(RDTestDownloadCompletion)completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                             progress:(RDTestDownloadProgress)progress
                           completion:(RDTestDownloadCompletion)completion {
    self.calls++;
    if (self.onRequest) self.onRequest(request, writeToURL, completion);
    return [RDCurlFallbackTaskMock new];
}
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                               progress:(RDTestDownloadProgress)progress
                             completion:(RDTestDownloadCompletion)completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:progress completion:completion];
}
@end

static void FallbackBackendTests(void) {
    // B1：原生 403 拦截页 → curl 回退把真实段写入 writeToURL。
    {
        MockNativeBackend *native = [MockNativeBackend new];
        native.onRequest = ^(NSURLRequest *req, NSURL *dst,
                             RDTestDownloadCompletion completion) {
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:403 HTTPVersion:@"HTTP/2" headerFields:@{}];
            completion(nil, resp, nil);
        };
        RDCurlFallbackBackend *backend = [RDCurlFallbackBackend backendWithNativeBackend:native];
        backend.curlRunner = FixtureRunner;
        backend.resolver = FixedResolver;
        NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *dst = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:@"seg-0.part"]];
        __block NSURL *gotURL = nil; __block NSHTTPURLResponse *gotResp = nil; __block NSError *gotErr = nil;
        [backend rd_startRequest:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/jmpres/a.mp4?secure=x"]]
                       writeToURL:dst completion:^(NSURL *u, NSHTTPURLResponse *r, NSError *e) { gotURL=u; gotResp=r; gotErr=e; }];
        WaitFor(^BOOL{ return gotURL || gotErr || gotResp; });
        check(gotErr == nil && gotResp.statusCode == 206 && [gotURL.path isEqualToString:dst.path], @"B1 原生403 → curl 回退写段成功");
        NSString *content = [NSString stringWithContentsOfFile:dst.path encoding:NSUTF8StringEncoding error:nil];
        check([content isEqual:@"MAGIC-BYTES"], @"B1 段文件内容为 curl 响应体");
    }
    // B2：原生正常 206 → 原样透传，绝不回退。
    {
        MockNativeBackend *native = [MockNativeBackend new];
        native.onRequest = ^(NSURLRequest *req, NSURL *dst,
                             RDTestDownloadCompletion completion) {
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:206 HTTPVersion:@"HTTP/2" headerFields:@{}];
            completion(dst, resp, nil);
        };
        RDCurlFallbackBackend *backend = [RDCurlFallbackBackend backendWithNativeBackend:native];
        __block BOOL runnerCalled = NO;
        backend.curlRunner = ^NSInteger(NSArray *a, NSString *h, NSString *b) { runnerCalled = YES; return 0; };
        __block NSURL *gotURL = nil;
        [backend rd_startRequest:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/a.mp4"]]
                       writeToURL:[NSURL fileURLWithPath:@"/tmp/never.part"]
                       completion:^(NSURL *u, NSHTTPURLResponse *r, NSError *e) { gotURL = u; }];
        WaitFor(^BOOL{ return gotURL != nil; });
        check(!runnerCalled && gotURL != nil, @"B2 原生 206 原样透传");
    }
    // B3：连接被晾（NSURLErrorTimedOut 无响应）→ 回退。
    {
        MockNativeBackend *native = [MockNativeBackend new];
        native.onRequest = ^(NSURLRequest *req, NSURL *dst,
                             RDTestDownloadCompletion completion) {
            completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
        };
        RDCurlFallbackBackend *backend = [RDCurlFallbackBackend backendWithNativeBackend:native];
        backend.curlRunner = FixtureRunner;
        backend.resolver = FixedResolver;
        NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *dst = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:@"seg-1.part"]];
        __block id gotURL = nil;
        [backend rd_startRequest:[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.fixture.test/jmpres/b.mp4?secure=x"]]
                       writeToURL:dst completion:^(NSURL *u, NSHTTPURLResponse *r, NSError *e) { gotURL = u ?: (u ? (id)u : (id)kCFNull); (void)r; (void)e; }];
        WaitFor(^BOOL{ return gotURL != nil; });
        check([gotURL isKindOfClass:NSURL.class] && [((NSURL *)gotURL).path isEqualToString:dst.path], @"B3 原生挂起 → curl 回退写段成功");
    }
}

int main(void){@autoreleasepool{
    AdaptiveTransportTests();
    CurlHopperTests();
    FallbackBackendTests();
    printf("== %d checks, %d failures ==\n", checks, failures);
    return failures ? 1 : 0;
}}
