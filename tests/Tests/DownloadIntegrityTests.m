//
//  DownloadIntegrityTests.m — 下载完整性隔离测试（143 字节事故回归）
//
//  背景：用户下载预期几十 MB 的视频，APP 只保存了 143 字节且任务显示已完成。
//  本测试用 Mock 后端 + 本地 127.0.0.1 隔离服务器驱动同一份生产代码，锁定：
//   · 只接受 2xx；HTML/JSON/文本错误页绝不能存成视频
//   · Content-Length / Content-Range / 可信预期长度 与落盘字节交叉校验
//   · 视频文件头校验；预期几十 MB 却只收到 143 字节必须失败
//   · 失败短文件删除/隔离，任务绝不进入“已完成”
//   · 普通/分段/探测/链接刷新/重定向全程保留任务自己的 Referer
//   · 临时短响应有限重试（2 次），绝不无限重试
//
#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/file.h>
#import <signal.h>
#import "DownloadManager.h"
#import "DownloadStore.h"
#import "DownloadCapabilityProbe.h"
#import "DownloadLinkRefresher.h"
#import "DNSResolver.h"
#import "PerformancePolicy.h"
#import "DetectedMedia.h"
#import "AdaptiveTransferScheduler.h"

// MARK: - 测试基建

static int gChecks = 0;

static void Check(BOOL ok, NSString *message, ...) {
    gChecks++;
    if (!ok) {
        va_list args;
        va_start(args, message);
        NSString *formatted = [[NSString alloc] initWithFormat:message arguments:args];
        va_end(args);
        NSLog(@"FAIL: %@", formatted);
        NSLog(@"TEST-SUITE-FAILED");
        exit(1);
    }
    NSLog(@"PASS: %@", message);
}

static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}

static int64_t FileSize(NSURL *url) {
    NSNumber *size = nil;
    if (![url getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) return -1;
    return size.longLongValue;
}

static BOOL FileExists(NSURL *url) { return [[NSFileManager defaultManager] fileExistsAtPath:url.path]; }

// 143 字节 HTML 错误页（真实事故同类响应）
static NSData *HTML143(void) {
    return [@"<!DOCTYPE html><html><head><title>403 Forbidden</title></head><body><h1>403 Forbidden</h1><!-- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --></body></html>"
            dataUsingEncoding:NSUTF8StringEncoding];
}
// 143 字节垃圾（非法 MP4 头）
static NSData *Garbage143(void) {
    NSMutableData *d = [NSMutableData dataWithCapacity:143];
    for (NSInteger i = 0; i < 143; i++) {
        uint8_t b = (uint8_t)((i * 37 + 11) % 256);
        [d appendBytes:&b length:1];
    }
    return d;
}
// 以 ftyp 盒开头、总长 size 的 MP4 形状文件
static NSData *MP4Body(int64_t size) {
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)MAX(0, size)];
    if (size >= 28) {
        const uint8_t ftyp[28] = {0x00,0x00,0x00,0x1c,'f','t','y','p','m','p','4','2',0,0,0,0,'m','p','4','2','i','s','o','m','a','v','c','1'};
        [d replaceBytesInRange:NSMakeRange(0, 28) withBytes:ftyp length:28];
    }
    return d;
}

// MARK: - Mock 后端

@interface MockDownloadTask : NSObject <RDDownloadTask>
@property (nonatomic, assign) BOOL cancelled;
@end
@implementation MockDownloadTask
- (void)rd_cancel { self.cancelled = YES; }
@end

@interface MockScript : NSObject
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSData *body;
@property (nonatomic, strong) NSError *error;
+ (MockScript *)response:(NSInteger)code headers:(NSDictionary<NSString *, NSString *> *)h body:(NSData *)b;
+ (MockScript *)failure:(NSError *)e;
@end
@implementation MockScript
+ (MockScript *)response:(NSInteger)code headers:(NSDictionary<NSString *, NSString *> *)h body:(NSData *)b {
    MockScript *s = [MockScript new];
    s.statusCode = code; s.headers = h ?: @{}; s.body = b ?: [NSData data];
    return s;
}
+ (MockScript *)failure:(NSError *)e {
    MockScript *s = [MockScript new]; s.error = e; return s;
}
@end

@interface MockDownloadBackend : NSObject <RDDownloadBackend>
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *requests;
@property (nonatomic, copy) MockScript *(^script)(NSURLRequest *request, NSInteger callIndex);
@end
@implementation MockDownloadBackend
- (instancetype)init {
    self = [super init];
    if (self) _requests = [NSMutableArray array];
    return self;
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    NSInteger index = self.requests.count;
    [self.requests addObject:request];
    MockScript *s = self.script ? self.script(request, index) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s.error) { completion(nil, nil, s.error); return; }
        [s.body writeToURL:writeToURL atomically:YES];
        if (progress) progress((int64_t)s.body.length, (int64_t)s.body.length, [s.headers[@"Content-Length"] longLongValue]);
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                              statusCode:s.statusCode
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:s.headers];
        completion(writeToURL, resp, nil);
    });
    MockDownloadTask *task = [MockDownloadTask new];
    return task;
}
@end

static NSString *RefererOf(NSURLRequest *request) {
    return [request valueForHTTPHeaderField:@"Referer"] ?: @"";
}

// 解析 Range 请求头 "bytes=X-Y"
static BOOL ParseRangeHeader(NSURLRequest *request, int64_t *start, int64_t *end) {
    NSString *h = [request valueForHTTPHeaderField:@"Range"] ?: @"";
    if (![h hasPrefix:@"bytes="]) return NO;
    NSArray<NSString *> *parts = [[h substringFromIndex:6] componentsSeparatedByString:@"-"];
    if (parts.count != 2) return NO;
    *start = parts[0].longLongValue;
    *end = parts[1].longLongValue;
    return YES;
}

// MARK: - 测试上下文

static NSInteger gContextSeq = 0;

@interface TestContext : NSObject
@property (nonatomic, strong) MockDownloadBackend *backend;
@property (nonatomic, strong) DownloadManager *manager;
@property (nonatomic, strong) NSURL *destFolder;
@property (nonatomic, strong) NSURL *tmpRoot;
@property (nonatomic, strong) NSUserDefaults *ud;
@property (nonatomic, strong) NSMutableArray<DownloadJob *> *refreshCalls;
@end
@implementation TestContext
@end

static TestContext *MakeContext(void) {
    TestContext *ctx = [TestContext new];
    ctx.backend = [MockDownloadBackend new];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"zz-dl-tests-%ld", (long)(++gContextSeq)]];
    ctx.destFolder = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"dest"]];
    ctx.tmpRoot = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"tmp"]];
    [[NSFileManager defaultManager] createDirectoryAtURL:ctx.destFolder
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *suite = [NSString stringWithFormat:@"com.sevenzz.tests.download-integrity.%ld", (long)gContextSeq];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    ctx.ud = [[NSUserDefaults alloc] initWithSuiteName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:ctx.ud];
    ctx.manager = [[DownloadManager alloc] initWithBackend:ctx.backend tempRoot:ctx.tmpRoot store:store];
    ctx.manager.rd_enableEndpointResolution = NO;
    ctx.refreshCalls = [NSMutableArray array];
    NSMutableArray<DownloadJob *> *calls = ctx.refreshCalls;
    ctx.manager.linkRefreshHandler = ^(DownloadJob *job, NSString *reason) {
        [calls addObject:job];
    };
    return ctx;
}

static DownloadJob *EnqueueVideo(TestContext *ctx, NSString *path, NSString *pageReferer, int64_t expectedLength) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.example.com%@", path]];
    return [ctx.manager enqueueItemWithSourceURL:url
                                          folder:ctx.destFolder
                                   preferredName:path.stringByDeletingPathExtension ?: @"video.mp4"
                                   sourcePageURL:pageReferer
                                    resourceKind:DownloadResourceVideo
                                   expectedLength:expectedLength];
}

// 用**指定 manager**入队一个视频任务（T44/T45 需要自己控制临时根与实例数量）。
static DownloadJob *EnqueueVideoFrom(DownloadManager *manager, NSURL *folder, NSString *path) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.example.com%@", path]];
    return [manager enqueueItemWithSourceURL:url
                                      folder:folder
                               preferredName:path.stringByDeletingPathExtension ?: @"video"
                               sourcePageURL:@"https://page.example.com/watch"
                                resourceKind:DownloadResourceVideo
                              expectedLength:0];
}

static DownloadJob *StateAfter(TestContext *ctx, DownloadJob *job, DownloadJobState state, double seconds) {
    Wait(^BOOL {
        DownloadJob *current = nil;
        for (DownloadJob *candidate in ctx.manager.allJobs)
            if ([candidate.identifier isEqualToString:job.identifier]) current = candidate;
        return current && current.state == state;
    }, seconds);
    return job;
}

// MARK: - 测试用例

// T1: 143 字节 HTML 错误页（text/html）→ 失败 + 链接刷新 + 临时文件清理，绝不完成
static void TestHTML143ErrorPage(void) {
    TestContext *ctx = MakeContext();
    NSData *html = HTML143();
    Check((int64_t)html.length == 143, @"HTML 错误页夹具恰为 143 字节");
    ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"text/html; charset=utf-8",
            @"Content-Length": @"143"} body:html];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/html143.mp4", @"https://page.example.com/watch", 0);
    StateAfter(ctx, job, DownloadJobStateFailed, 10);
    Check(job.state == DownloadJobStateFailed, @"T1: 143 字节 HTML 被拒绝，任务失败");
    Check([job.errorText containsString:@"不是视频文件"], @"T1: 失败原因说明响应不是视频（实际：%@）", job.errorText);
    Check(ctx.refreshCalls.count == 1, @"T1: 伪媒体响应触发单资源链接刷新");
    Check(!FileExists(job.destinationURL), @"T1: 目标文件夹没有落盘任何文件");
    Check(!FileExists(job.tempRootURL), @"T1: 失败后临时目录已清理（短文件销毁）");
    Check(![ctx.manager.store isCompletedURL:job.sourceURL], @"T1: 完成记录未写入");
}

// T2: 200 + 伪 video/mp4 但正文是 HTML → 失败 + 刷新
static void TestHTMLWithLyingVideoMIME(void) {
    TestContext *ctx = MakeContext();
    NSData *html = HTML143();
    ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4", @"Content-Length": @"143"} body:html];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/lie143.mp4", @"https://page.example.com/watch", 0);
    StateAfter(ctx, job, DownloadJobStateFailed, 10);
    Check(job.state == DownloadJobStateFailed, @"T2: 伪装 video/mp4 的 HTML 被文件头校验拦截");
    Check([job.errorText containsString:@"网页/错误页"], @"T2: 失败原因指出网页/错误页（实际：%@）", job.errorText);
    Check(ctx.refreshCalls.count == 1, @"T2: HTML 正文触发链接刷新");
    Check(!FileExists(job.destinationURL) && !FileExists(job.tempRootURL), @"T2: 无残留文件");
}

// T3: 143 字节无效 MP4（垃圾头）→ 失败，且不误触发链接刷新
static void TestInvalid143ByteMP4(void) {
    TestContext *ctx = MakeContext();
    NSData *garbage = Garbage143();
    ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4", @"Content-Length": @"143"} body:garbage];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/garbage143.mp4", @"https://page.example.com/watch", 0);
    StateAfter(ctx, job, DownloadJobStateFailed, 10);
    Check(job.state == DownloadJobStateFailed, @"T3: 143 字节无效 MP4 被拒绝");
    Check([job.errorText containsString:@"不是有效视频"], @"T3: 失败原因说明内容不是有效视频（实际：%@）", job.errorText);
    Check(ctx.refreshCalls.count == 0, @"T3: 非链接类失败不触发链接刷新");
    Check(!FileExists(job.destinationURL) && !FileExists(job.tempRootURL), @"T3: 无残留文件");
}

// T4: 有效 MP4 → 正常完成并记录
static void TestValidMP4Completes(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(788493);
    ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/good.mp4", @"https://page.example.com/watch", 0);
    StateAfter(ctx, job, DownloadJobStateCompleted, 10);
    Check(job.state == DownloadJobStateCompleted, @"T4: 有效 MP4 正常完成");
    Check(FileSize(job.destinationURL) == 788493, @"T4: 目标文件大小正确（实际 %lld）", FileSize(job.destinationURL));
    Check([ctx.manager.store isCompletedURL:job.sourceURL], @"T4: 完成记录已写入");
}

// T5: 403/404 → 失败 + 链接刷新，错误信息包含状态码
static void TestForbiddenAndNotFound(void) {
    for (NSNumber *code in @[@403, @404]) {
        TestContext *ctx = MakeContext();
        NSData *html = HTML143();
        ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
            return [MockScript response:code.intValue headers:@{
                @"Content-Type": @"text/html", @"Content-Length": @"143"} body:html];
        };
        DownloadJob *job = EnqueueVideo(ctx, [@"/status" stringByAppendingString:code.stringValue],
                                        @"https://page.example.com/watch", 0);
        StateAfter(ctx, job, DownloadJobStateFailed, 10);
        Check(job.state == DownloadJobStateFailed, @"T5: HTTP %@ 任务失败", code);
        Check([job.errorText containsString:code.stringValue], @"T5: 错误信息包含状态码 %@（实际：%@）", code, job.errorText);
        Check(ctx.refreshCalls.count == 1, @"T5: 链接失效类失败触发链接刷新");
        Check(!FileExists(job.destinationURL) && !FileExists(job.tempRootURL), @"T5: 无残留文件");
    }
}

// T6: 预期 50MB 实际 143 字节（带合法 ftyp 头的截断 MP4）→ 短响应重试 2 次后失败
static void Test50MBExpected143BytesReceived(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(143);
    __block NSInteger attempts = 0;
    ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
        attempts = (int)idx + 1;
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4", @"Content-Length": @"143"} body:body];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/big.mp4", @"https://page.example.com/watch", 52428800LL);
    Wait(^BOOL { return attempts >= 3 && job.state == DownloadJobStateFailed; }, 20);
    Check(attempts == 3, @"T6: 短响应恰好重试 2 次、共 3 次尝试（实际 %ld 次）", (long)attempts);
    Check(job.state == DownloadJobStateFailed, @"T6: 50MB 预期只收 143 字节 → 任务失败，绝不完成");
    Check([job.errorText containsString:@"下载不完整"], @"T6: 失败原因说明下载不完整（实际：%@）", job.errorText);
    Check([job.errorText containsString:@"52428800"] && [job.errorText containsString:@"143"],
          @"T6: 失败原因包含预期与实际字节数（实际：%@）", job.errorText);
    Check(!FileExists(job.destinationURL), @"T6: 目标文件夹没有 143 字节残缺文件");
    Check(!FileExists(job.tempRootURL), @"T6: 临时短文件已删除隔离");
    Check(![ctx.manager.store isCompletedURL:job.sourceURL], @"T6: 完成记录未写入");
}

// T7: 不同任务 Referer 不串用
static void TestRefererIsolationBetweenJobs(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *req, NSInteger idx) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *a = EnqueueVideo(ctx, @"/a.mp4", @"https://site-a.example.com/watch", 0);
    DownloadJob *b = EnqueueVideo(ctx, @"/b.mp4", @"https://site-b.example.com/watch", 0);
    StateAfter(ctx, a, DownloadJobStateCompleted, 10);
    StateAfter(ctx, b, DownloadJobStateCompleted, 10);
    Check(ctx.backend.requests.count >= 2, @"T7: 两个任务各发出一次请求");
    NSString *refererA = RefererOf(ctx.backend.requests[0]);
    NSString *refererB = RefererOf(ctx.backend.requests[1]);
    Check([refererA isEqualToString:@"https://site-a.example.com/watch"], @"T7: 任务 A 使用自己的 Referer（实际：%@）", refererA);
    Check([refererB isEqualToString:@"https://site-b.example.com/watch"], @"T7: 任务 B 使用自己的 Referer（实际：%@）", refererB);
}

// 分段脚本工具：按 Range 请求头返回 206 响应
typedef MockScript *(^SegmentScriptBlock)(NSURLRequest *request, NSInteger index);

static SegmentScriptBlock CorrectSegmentScript(int64_t total, NSData * (^bodyForRange)(int64_t start, int64_t end)) {
    return ^MockScript *(NSURLRequest *request, NSInteger index) {
        int64_t start = 0, end = 0;
        if (!ParseRangeHeader(request, &start, &end)) return nil;
        int64_t len = end - start + 1;
        return [MockScript response:206 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total],
            @"Content-Length": [NSString stringWithFormat:@"%lld", len]
        } body:bodyForRange(start, end)];
    };
}

// 建立一个分段任务（24MB 阈值之上、acceptRanges 开启、带专属 Referer）
static DownloadJob *EnqueueSegmented(TestContext *ctx, NSString *path, int64_t total) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.example.com%@", path]];
    ctx.manager.defaultReferer = @"https://page.example.com/watch";
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:url
                                                      folder:ctx.destFolder
                                               preferredName:path.stringByDeletingPathExtension
                                                        etag:@"ETAG-1"
                                                lastModified:@"LM-1"
                                                acceptRanges:YES
                                              expectedLength:total];
    return job;
}

// T8: 分段下载：每段带任务自己的 Referer、Range 精确平铺、合并成功
static void TestSegmentedRefererAndMerge(void) {
    TestContext *ctx = MakeContext();
    int64_t total = 25165824; // 24MB
    ctx.backend.script = CorrectSegmentScript(total, ^NSData *(int64_t start, int64_t end) {
        return MP4Body(end - start + 1);
    });
    DownloadJob *job = EnqueueSegmented(ctx, @"/segmented.mp4", total);
    Check(job.acceptRanges && job.etag.length > 0, @"T8: acceptRanges 入队变体不再丢弃探测参数");
    StateAfter(ctx, job, DownloadJobStateCompleted, 15);
    Check(job.state == DownloadJobStateCompleted, @"T8: 分段下载合并后完成");
    Check(job.segmented && job.segmentCount >= 2, @"T8: 任务确实以分段模式运行（%ld 段）", (long)job.segmentCount);
    Check(FileSize(job.destinationURL) == total, @"T8: 合并文件长度与预期一致（实际 %lld）", FileSize(job.destinationURL));
    // Range 平铺校验
    int64_t covered = 0;
    NSInteger partRequests = 0;
    for (NSURLRequest *request in ctx.backend.requests) {
        int64_t start = 0, end = 0;
        if (!ParseRangeHeader(request, &start, &end)) continue;
        Check(start == covered, @"T8: 第 %ld 段起点 %lld 与已覆盖长度 %lld 衔接（无重叠无遗漏）",
              (long)partRequests, start, covered);
        covered = end + 1;
        partRequests++;
        Check([RefererOf(request) isEqualToString:@"https://page.example.com/watch"],
              @"T8: 每个分段请求都保留任务自己的 Referer");
    }
    Check(covered == total, @"T8: 全部分段恰好覆盖 0..%lld", total);
    Check(partRequests == job.segmentCount, @"T8: 分段请求数与段数一致");
}

// T9: 分段返回错误 Content-Range → 回退单连接重下并完成
static void TestSegmentWrongContentRangeFallsBack(void) {
    TestContext *ctx = MakeContext();
    int64_t total = 25165824;
    NSData *full = MP4Body(total);
    __block BOOL fallbackRequested = NO;
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        int64_t start = 0, end = 0;
        if (ParseRangeHeader(request, &start, &end)) {
            if (start > 0 && !fallbackRequested) {   // 任一非首段返回错误总长 → 必须回退（段数可调）
                fallbackRequested = YES;
                int64_t len = end - start + 1;
                return [MockScript response:206 headers:@{
                    @"Content-Type": @"video/mp4",
                    @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/12345", start, end],
                    @"Content-Length": [NSString stringWithFormat:@"%lld", len]} body:MP4Body(len)];
            }
            int64_t len = end - start + 1;
            return [MockScript response:206 headers:@{
                @"Content-Type": @"video/mp4",
                @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total],
                @"Content-Length": [NSString stringWithFormat:@"%lld", len]} body:MP4Body(len)];
        }
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)full.length]} body:full];
    };
    DownloadJob *job = EnqueueSegmented(ctx, @"/wrongrange.mp4", total);
    StateAfter(ctx, job, DownloadJobStateCompleted, 15);
    Check(fallbackRequested, @"T9: 错误 Content-Range 的分段被识别");
    Check(job.state == DownloadJobStateCompleted, @"T9: 回退单连接后重新完整下载并完成");
    Check(job.fallbackUsed, @"T9: fallback 语义生效（单连接重下，非分段续拼）");
    Check(FileSize(job.destinationURL) == total, @"T9: 最终文件长度正确");
}

// T10: 短分段（Content-Range 正确但字节不足）→ 回退单连接并完成
static void TestShortSegmentFallsBack(void) {
    TestContext *ctx = MakeContext();
    int64_t total = 25165824;
    NSData *full = MP4Body(total);
    __block BOOL shortPartSeen = NO;
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        int64_t start = 0, end = 0;
        if (ParseRangeHeader(request, &start, &end)) {
            int64_t len = end - start + 1;
            if (start > 0 && !shortPartSeen) {
                shortPartSeen = YES;
                // Content-Range 声明完整区间，但正文只给 100 字节
                return [MockScript response:206 headers:@{
                    @"Content-Type": @"video/mp4",
                    @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total],
                    @"Content-Length": @"100"} body:MP4Body(100)];
            }
            return [MockScript response:206 headers:@{
                @"Content-Type": @"video/mp4",
                @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total],
                @"Content-Length": [NSString stringWithFormat:@"%lld", len]} body:MP4Body(len)];
        }
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)full.length]} body:full];
    };
    DownloadJob *job = EnqueueSegmented(ctx, @"/shortpart.mp4", total);
    StateAfter(ctx, job, DownloadJobStateCompleted, 15);
    Check(shortPartSeen, @"T10: 短分段响应已注入");
    Check(job.state == DownloadJobStateCompleted, @"T10: 短分段触发回退，单连接重新完整下载");
    Check(job.fallbackUsed, @"T10: fallback 语义生效");
    Check(FileSize(job.destinationURL) == total, @"T10: 最终文件长度正确（残缺片段未进入合并）");
}

// T11: 分段全部“合法”但第一段内容是垃圾 → 最终合并文件内容校验拦截
static void TestMergedGarbageRejected(void) {
    TestContext *ctx = MakeContext();
    int64_t total = 25165824;
    ctx.backend.script = CorrectSegmentScript(total, ^NSData *(int64_t start, int64_t end) {
        if (start == 0) {
            // 第一段：长度完全正确，但开头不是 ftyp（垃圾内容）
            NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(end - start + 1)];
            NSData *g = Garbage143();
            [d replaceBytesInRange:NSMakeRange(0, g.length) withBytes:g.bytes];
            return d;
        }
        return MP4Body(end - start + 1);
    });
    DownloadJob *job = EnqueueSegmented(ctx, @"/mergedgarbage.mp4", total);
    StateAfter(ctx, job, DownloadJobStateFailed, 15);
    Check(job.state == DownloadJobStateFailed, @"T11: 合并后内容不是有效视频 → 失败");
    Check([job.errorText containsString:@"不是有效视频"], @"T11: 失败原因指向合并文件内容（实际：%@）", job.errorText);
    Check(!FileExists(job.destinationURL), @"T11: 目标文件夹没有垃圾合并文件");
    Check(!FileExists(job.tempRootURL), @"T11: 合并失败后临时文件已清理");
}

// T12: 网络瞬断 → 原有瞬态重试路径仍然成功
static void TestTransientErrorRetryStillWorks(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        if (index == 0) {
            return [MockScript failure:[NSError errorWithDomain:NSURLErrorDomain
                                                           code:NSURLErrorNetworkConnectionLost
                                                       userInfo:@{}]];
        }
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/flaky.mp4", @"https://page.example.com/watch", 0);
    StateAfter(ctx, job, DownloadJobStateCompleted, 15);
    Check(job.state == DownloadJobStateCompleted, @"T12: 瞬断重试后正常完成");
    Check(ctx.backend.requests.count == 2, @"T12: 恰好重试一次（实际 %lu 次）", (unsigned long)ctx.backend.requests.count);
}

// MARK: - 重定向（真实 SessionDownloadBackend，delegate 级验证）

@interface SessionDownloadBackend : NSObject <RDDownloadBackend, NSURLSessionDownloadDelegate>
@end

static NSArray<NSString *> *(*gOriginalResolveIPs)(id, SEL, NSString *);
static NSArray<NSString *> *StubResolveIPs(id self, SEL _cmd, NSString *host) {
    return @[@"8.8.8.8"];   // 固定公网 IP，测试离线确定性
}

// RDValidateNetworkURL 的默认路径带 status 出参（BUG-006：区分超时/失败/保留地址），
// 离线桩必须同时覆盖两个选择器，否则真实 DNS 会把重定向测试变成不确定结果。
static NSArray<NSString *> *(*gOriginalResolveIPsWithStatus)(id, SEL, NSString *, DNSResolutionStatus *);
static NSArray<NSString *> *StubResolveIPsWithStatus(id self, SEL _cmd, NSString *host, DNSResolutionStatus *status) {
    if (status) *status = DNSResolutionSucceeded;
    return @[@"8.8.8.8"];
}

static void SwizzleDNSStubs(void) {
    Method plain = class_getClassMethod([DNSResolver class], @selector(resolveIPsForHost:));
    gOriginalResolveIPs = (NSArray<NSString *> *(*)(id, SEL, NSString *))method_getImplementation(plain);
    method_setImplementation(plain, (IMP)StubResolveIPs);
    Method withStatus = class_getClassMethod([DNSResolver class], @selector(resolveIPsForHost:status:));
    gOriginalResolveIPsWithStatus = (NSArray<NSString *> *(*)(id, SEL, NSString *, DNSResolutionStatus *))method_getImplementation(withStatus);
    method_setImplementation(withStatus, (IMP)StubResolveIPsWithStatus);
}

static void RestoreDNSStubs(void) {
    Method plain = class_getClassMethod([DNSResolver class], @selector(resolveIPsForHost:));
    method_setImplementation(plain, (IMP)gOriginalResolveIPs);
    Method withStatus = class_getClassMethod([DNSResolver class], @selector(resolveIPsForHost:status:));
    method_setImplementation(withStatus, (IMP)gOriginalResolveIPsWithStatus);
}

static void TestRedirectKeepsReferer(void) {
    // 固定 DNS 结果，避免测试依赖外网
    SwizzleDNSStubs();

    SessionDownloadBackend *backend = [SessionDownloadBackend new];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:backend delegateQueue:nil];

    // a) 允许的公网目标：重定向请求必须带回任务自己的 Referer/UA/Accept-Encoding
    NSMutableURLRequest *original = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://origin.example.com/a.mp4"]];
    [original setValue:@"https://origin.example.com/watch" forHTTPHeaderField:@"Referer"];
    [original setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [original setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:original];   // 不 resume
    NSMutableURLRequest *newRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://cdn.example.org/b.mp4"]];
    __block NSURLRequest *handed = nil;
    __block BOOL done = NO;
    void (^handler)(NSURLRequest *) = ^(NSURLRequest *request) { handed = request; done = YES; };
    SEL sel = @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:);
    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSHTTPURLResponse *, NSURLRequest *, void (^)(NSURLRequest *)))
     [backend methodForSelector:sel])(backend, sel, session, task,
        [[NSHTTPURLResponse alloc] initWithURL:original.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}],
        newRequest, handler);
    Check(Wait(^BOOL { return done; }, 10), @"T13a: 允许的重定向回调到达");
    Check(handed != nil, @"T13a: 重定向请求未被安全策略拒绝");
    Check([handed.URL.absoluteString isEqualToString:@"https://cdn.example.org/b.mp4"], @"T13a: 目标 URL 保持不变");
    Check([[handed valueForHTTPHeaderField:@"Referer"] isEqualToString:@"https://origin.example.com"],
          @"T13a: 重定向请求保留任务自己的 Referer（实际：%@）", [handed valueForHTTPHeaderField:@"Referer"] ?: @"（无）");
    Check([[handed valueForHTTPHeaderField:@"User-Agent"] length] > 0, @"T13a: 重定向请求保留 User-Agent");
    Check([[handed valueForHTTPHeaderField:@"Accept-Encoding"] isEqualToString:@"identity"], @"T13a: 重定向请求保留 Accept-Encoding");

    // b) 回环目标：SSRF 策略必须拦截重定向
    done = NO; handed = nil;
    NSMutableURLRequest *toLoopback = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1/steal.mp4"]];
    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSHTTPURLResponse *, NSURLRequest *, void (^)(NSURLRequest *)))
     [backend methodForSelector:sel])(backend, sel, session, task,
        [[NSHTTPURLResponse alloc] initWithURL:original.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}],
        toLoopback, handler);
    Check(Wait(^BOOL { return done; }, 10) && handed == nil, @"T13b: 重定向到回环地址被 SSRF 策略拦截");

    // 恢复 DNS
    RestoreDNSStubs();
}

// MARK: - 本地隔离服务器（真实网络栈）测试

static NSString *TestServerBase(void) {
    NSString *base = [[[NSProcessInfo processInfo] environment] objectForKey:@"ZZ_DL_TEST_SERVER"];
    return base.length ? base : nil;
}

// The exception is confined to this test server's exact host and ephemeral port.
@interface LocalFixturePolicy : URLPolicy
@end
@implementation LocalFixturePolicy
- (BOOL)isFixture:(NSURL *)url { NSURL *base=[NSURL URLWithString:TestServerBase()];return [url.host isEqual:@"127.0.0.1"] && [url.port isEqual:base.port]; }
- (URLPolicyDecision *)evaluateTextURL:(NSString *)text { return [self isFixture:[NSURL URLWithString:text]] ? [URLPolicyDecision allow] : [super evaluateTextURL:text]; }
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray *)ips { return [self isFixture:url] ? [URLPolicyDecision allow] : [super evaluateResolvedURL:url resolvedIPs:ips]; }
@end

static void TestProbeDoesNotTrustErrorPages(void) {
    NSString *base = TestServerBase();
    if (!base) { NSLog(@"SKIP: T14/T15 需要 ZZ_DL_TEST_SERVER"); return; }
    DownloadCapabilityProbe *probe = [DownloadCapabilityProbe new]; probe.urlPolicy=[LocalFixturePolicy new];
    __block ZZDownloadCapability *cap = nil;
    [probe probeURL:[NSURL URLWithString:[base stringByAppendingString:@"/html-error"]]
              referer:@"https://page.example.com/watch"
           completion:^(ZZDownloadCapability *c) { cap = c; }];
    Check(Wait(^BOOL { return cap != nil; }, 15), @"T14: 探测错误页返回");
    Check(cap.contentLength == 0, @"T14: HTML 错误页的 Content-Length 不回填（实际 %lld）", cap.contentLength);
    Check(!cap.rangeSupported, @"T14: 错误页不开启分段");

    __block ZZDownloadCapability *cap2 = nil;
    [probe probeURL:[NSURL URLWithString:[base stringByAppendingString:@"/range-ok"]]
              referer:@"https://page.example.com/watch"
           completion:^(ZZDownloadCapability *c) { cap2 = c; }];
    Check(Wait(^BOOL { return cap2 != nil; }, 15), @"T14: 探测 Range 端点返回");
    Check(cap2.contentLength == 788493, @"T14: Range 探测得到正确总长（实际 %lld）", cap2.contentLength);
    Check(cap2.rangeSupported, @"T14: 正确 206 响应开启分段");
}

static void TestRealBackendAgainstLocalServer(void) {
    NSString *base = TestServerBase();
    if (!base) { NSLog(@"SKIP: T15 需要 ZZ_DL_TEST_SERVER"); return; }
    SessionDownloadBackend *backend = [SessionDownloadBackend new]; [backend setValue:[LocalFixturePolicy new] forKey:@"urlPolicy"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:backend delegateQueue:nil];

    // a) 完整视频 → didFinishDownloadingToURL 正常落盘
    __block NSURL *written = nil; __block NSHTTPURLResponse *resp = nil; __block NSError *err = nil; __block BOOL done = NO;
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"zz-e2e-full.mp4"]];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/full-video"]]];
    [backend rd_startRequest:req writeToURL:tmp completion:^(NSURL *w, NSHTTPURLResponse *r, NSError *e) {
        written = w; resp = r; err = e; done = YES;
    }];
    Check(Wait(^BOOL { return done; }, 20), @"T15a: 完整视频回调到达");
    Check(err == nil && FileSize(written) == 788493, @"T15a: 完整视频落盘 788493 字节（err=%@ size=%lld）", err, FileSize(written));
    Check(resp.statusCode == 200, @"T15a: 状态码 200");

    // b) 截断响应（声明 1000 只发 143 后断开）→ 绝不能静默当作完整文件
    done = NO; written = nil; resp = nil; err = nil;
    NSURL *tmp2 = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"zz-e2e-trunc.mp4"]];
    NSURLRequest *req2 = [NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/truncated-video"]]];
    [backend rd_startRequest:req2 writeToURL:tmp2 completion:^(NSURL *w, NSHTTPURLResponse *r, NSError *e) {
        written = w; resp = r; err = e; done = YES;
    }];
    Check(Wait(^BOOL { return done; }, 20), @"T15b: 截断响应回调到达");
    if (err != nil) {
        NSLog(@"INFO: T15b 传输层以错误结束（%@）——管理器瞬态重试路径会接手", err.localizedDescription);
    } else {
        int64_t size = FileSize(written);
        NSLog(@"INFO: T15b 传输层干净结束，落盘 %lld 字节——管理器完整性校验会拦截", size);
        Check(size != 1000, @"T15b: 截断响应绝不会被当作完整 1000 字节文件");
    }

    // c) 初始请求的 Referer 真实到达服务器
    done = NO; written = nil; err = nil;
    NSURL *tmp3 = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"zz-e2e-ref.txt"]];
    NSMutableURLRequest *req3 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/referer-echo"]]];
    [req3 setValue:@"https://page.example.com/watch" forHTTPHeaderField:@"Referer"];
    [backend rd_startRequest:req3 writeToURL:tmp3 completion:^(NSURL *w, NSHTTPURLResponse *r, NSError *e) {
        written = w; err = e; done = YES;
    }];
    Check(Wait(^BOOL { return done; }, 20), @"T15c: Referer 回显回调到达");
    NSString *echo = [[NSString alloc] initWithContentsOfURL:written encoding:NSUTF8StringEncoding error:nil];
    Check([echo isEqualToString:@"https://page.example.com"], @"T15c: 服务器实际收到任务 Referer（实际：%@）", echo ?: @"（空）");

    // d) 重定向到回环 → SSRF 拦截，任务不得跟随
    done = NO; written = nil; err = nil;
    NSURL *tmp4 = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"zz-e2e-redir.mp4"]];
    NSMutableURLRequest *req4 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/redirect-referer"]]];
    [req4 setValue:@"https://page.example.com/watch" forHTTPHeaderField:@"Referer"];
    [backend rd_startRequest:req4 writeToURL:tmp4 completion:^(NSURL *w, NSHTTPURLResponse *r, NSError *e) {
        written = w; resp = r; err = e; done = YES;
    }];
    Check(Wait(^BOOL { return done; }, 20), @"T15d: 重定向回环回调到达");
    // completionHandler(nil) 时 NSURLSession 把 302 本体（空 body）作为结果而不是报错：
    // 关键是绝不能跟随到目标（否则会收到 /referer-echo 的 200 内容）。
    Check(resp.statusCode == 302, @"T15d: 重定向被拦截，未跟随（实际状态码 %ld）", (long)resp.statusCode);
    Check(err != nil || FileSize(written) == 0, @"T15d: 拦截后没有拿到目标内容");
}

// MARK: - 链接刷新保留 Referer

static void TestLinkRefreshKeepsReferer(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        if (index == 0) {
            return [MockScript response:403 headers:@{
                @"Content-Type": @"text/html", @"Content-Length": @"143"} body:HTML143()];
        }
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    __block NSURL *reprobePage = nil;
    __block void (^pendingDone)(NSArray<DetectedMedia *> *, NSError *) = nil;
    DownloadLinkRefresher *refresher = [[DownloadLinkRefresher alloc] initWithManager:ctx.manager
                                                                       reprobeHandler:^(NSURL *page, void (^done)(NSArray<DetectedMedia *> *, NSError *)) {
        reprobePage = page;
        pendingDone = done;
    }];
    ctx.manager.linkRefreshHandler = ^(DownloadJob *job, NSString *reason) {
        [refresher handleJobDidFail:job reason:reason linkExpired:YES];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/refresh.mp4", @"https://page.example.com/watch", 0);
    StateAfter(ctx, job, DownloadJobStateFailed, 10);
    Check(Wait(^BOOL { return reprobePage != nil; }, 10), @"T16: 失败后自动重探测");
    Check([reprobePage.absoluteString isEqualToString:@"https://page.example.com/watch"],
          @"T16: 重探测使用任务自己的 Referer/来源页（实际：%@）", reprobePage.absoluteString);

    // 模拟重探测成功：同一资源、新地址
    DetectedMedia *media = [DetectedMedia new];
    media.mediaURL = @"https://cdn.example.com/refresh.mp4?token=NEW";
    media.title = job.fileName ?: @"";
    media.sizeBytes = 4096;
    pendingDone(@[media], nil);

    StateAfter(ctx, job, DownloadJobStateCompleted, 15);
    Check(job.state == DownloadJobStateCompleted, @"T16: 链接刷新后原地重启并完成");
    NSURLRequest *secondRequest = ctx.backend.requests.count > 1 ? ctx.backend.requests[1] : nil;
    Check(secondRequest != nil, @"T16: 刷新后重新发起了下载请求");
    Check([RefererOf(secondRequest) isEqualToString:@"https://page.example.com/watch"],
          @"T16: 刷新后的下载请求仍保留任务自己的 Referer（实际：%@）", RefererOf(secondRequest) ?: @"（无）");
}

// MARK: - 2026-09-08 落盘路径与任务追溯回归

// 列表中是否能找到指定任务
static BOOL JobIsListed(DownloadManager *manager, DownloadJob *job) {
    for (DownloadJob *candidate in manager.allJobs)
        if ([candidate.identifier isEqualToString:job.identifier]) return YES;
    return NO;
}

// 等待指定 manager 中某任务到达指定状态
static BOOL WaitForState(DownloadManager *manager, DownloadJob *job, DownloadJobState state, double seconds) {
    return Wait(^BOOL {
        for (DownloadJob *candidate in manager.allJobs)
            if ([candidate.identifier isEqualToString:job.identifier]) return candidate.state == state;
        return NO;
    }, seconds);
}

// 从 store 的终态历史里找指定任务
static NSDictionary *FinishedRecord(DownloadStore *store, NSString *identifier) {
    for (NSDictionary *record in [store finishedJobRecords])
        if ([record[@"identifier"] isEqualToString:identifier]) return record;
    return nil;
}

// T17: 下载成功 → 文件真实落盘、路径等于 destinationURL、列表可见、
//      终态历史持久化；重启（新 manager 同一 store）后仍可追溯。
static void TestCompletionPersistsFinalPath(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(8192);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/persist.mp4", @"https://page.example.com/watch", (int64_t)body.length);
    StateAfter(ctx, job, DownloadJobStateCompleted, 10);
    Check(job.state == DownloadJobStateCompleted, @"T17: 下载完成（实际 %ld）", (long)job.state);
    Check(job.destinationURL != nil && [job.destinationURL.path hasPrefix:ctx.destFolder.path],
          @"T17: destinationURL 已设置且位于目标目录内（%@）", job.destinationURL.path ?: @"（空）");
    Check(FileExists(job.destinationURL), @"T17: 最终文件真实落盘于 %@", job.destinationURL.path ?: @"（空）");
    Check(FileSize(job.destinationURL) == (int64_t)body.length, @"T17: 落盘大小 %lld == 预期 %lu",
          FileSize(job.destinationURL), (unsigned long)body.length);
    Check(JobIsListed(ctx.manager, job), @"T17: 下载列表包含该任务");

    NSArray<NSDictionary<NSString *, id> *> *history = [ctx.manager.store finishedJobRecords];
    Check(history.count == 1, @"T17: 终态历史恰好 1 条（实际 %lu）", (unsigned long)history.count);
    NSDictionary *record = FinishedRecord(ctx.manager.store, job.identifier);
    Check(record != nil, @"T17: 终态历史包含该任务");
    Check([record[@"state"] integerValue] == DownloadJobStateCompleted, @"T17: 历史状态为已完成");
    Check([record[@"destinationURL"] isEqualToString:job.destinationURL.absoluteString],
          @"T17: 历史最终路径与 destinationURL 一致");

    // 模拟 APP 重启：同一 store 新建 manager → 历史仍可追溯
    DownloadStore *restoredStore = [[DownloadStore alloc] initWithUserDefaults:ctx.ud];
    DownloadManager *restored = [[DownloadManager alloc] initWithBackend:ctx.backend tempRoot:ctx.tmpRoot store:restoredStore];
    restored.rd_enableEndpointResolution = NO;
    __block DownloadJob *historical = nil;
    for (DownloadJob *candidate in restored.allJobs)
        if ([candidate.identifier isEqualToString:job.identifier]) historical = candidate;
    Check(historical != nil, @"T17: 重启后列表仍显示历史任务");
    Check(historical.state == DownloadJobStateCompleted, @"T17: 重启后历史任务状态为已完成");
    Check([historical.destinationURL.absoluteString isEqualToString:job.destinationURL.absoluteString],
          @"T17: 重启后显示的最终路径一致");
    Check(FileExists(historical.destinationURL), @"T17: 重启后最终路径上的文件仍在");

    // 文件存在时同源去重；用户删除文件后允许重新下载
    NSURL *sameURL = [NSURL URLWithString:@"https://cdn.example.com/persist.mp4"];
    DownloadJob *deduped = [restored enqueueItemWithSourceURL:sameURL folder:ctx.destFolder
                                               preferredName:@"persist" sourcePageURL:nil
                                                resourceKind:DownloadResourceVideo expectedLength:(int64_t)body.length];
    Check([deduped.identifier isEqualToString:job.identifier], @"T17: 文件仍在时同源任务被去重");
    [[NSFileManager defaultManager] removeItemAtURL:historical.destinationURL error:nil];
    DownloadJob *retried = [restored enqueueItemWithSourceURL:sameURL folder:ctx.destFolder
                                               preferredName:@"persist" sourcePageURL:nil
                                                resourceKind:DownloadResourceVideo expectedLength:(int64_t)body.length];
    Check(retried != nil && ![retried.identifier isEqualToString:job.identifier], @"T17: 文件被删后允许重新下载（新任务）");
    WaitForState(restored, retried, DownloadJobStateCompleted, 10);
    Check(retried.state == DownloadJobStateCompleted, @"T17: 重新下载完成");
    Check(FileExists(retried.destinationURL), @"T17: 重新下载真实落盘");
}

// T18: 失败任务绝不报成功：无落盘文件、历史记录为失败态并带原因。
static void TestFailureNotReportedAsSuccess(void) {
    TestContext *ctx = MakeContext();
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:403 headers:@{@"Content-Type": @"text/html", @"Content-Length": @"143"} body:HTML143()];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/forbidden.mp4", @"https://page.example.com/watch", 4096);
    StateAfter(ctx, job, DownloadJobStateFailed, 10);
    Check(job.state == DownloadJobStateFailed, @"T18: 任务失败");
    Check(!FileExists(job.destinationURL), @"T18: 目标路径没有留下文件");
    Check(JobIsListed(ctx.manager, job), @"T18: 失败任务仍在下载列表中（不丢任务）");
    NSDictionary *record = FinishedRecord(ctx.manager.store, job.identifier);
    Check(record != nil, @"T18: 失败任务已写入终态历史");
    Check([record[@"state"] integerValue] == DownloadJobStateFailed, @"T18: 历史状态为失败");
    Check([record[@"errorText"] length] > 0, @"T18: 历史记录带失败原因");
    Check([record[@"destinationURL"] isEqualToString:job.destinationURL.absoluteString],
          @"T18: 历史记录最终目标路径与任务一致");
}

// T19: 入队即被拒（SSRF 保留地址）的任务必须留在下载列表中，绝不静默消失。
static void TestRejectedEnqueueStaysInList(void) {
    TestContext *ctx = MakeContext();
    NSURL *bad = [NSURL URLWithString:@"http://127.0.0.1/video.mp4"];
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:bad folder:ctx.destFolder
                                              preferredName:@"video.mp4" sourcePageURL:nil
                                               resourceKind:DownloadResourceVideo expectedLength:0];
    Check(job.state == DownloadJobStateFailed, @"T19: 保留地址入队被拒绝");
    Check(JobIsListed(ctx.manager, job), @"T19: 被拒任务在列表中可见");
    NSDictionary *record = FinishedRecord(ctx.manager.store, job.identifier);
    Check(record != nil && [record[@"state"] integerValue] == DownloadJobStateFailed, @"T19: 被拒任务写入终态历史");
}

// T31（真实现场驱动）：目标目录不存在（或卷信息暂时读不到）时，App 把“剩余空间
// 未知”当成 0，于是明明磁盘有 146Gi 可用却报“磁盘剩余空间不足，已停止下载”，
// 入队即被拒。现场证据（2026-09-10）：目标目录 /tmp/dl_new_2 不存在 → statvfs 失败，
// App 立即 state=failed error=磁盘剩余空间不足，而 df 显示可用 146Gi。
// 正确语义：只有“确实读到剩余空间且低于阈值”才拒绝；未知时不得凭空拒绝
// （与运行期检查的 `free && …` 语义保持一致）。
static void TestUnknownFreeSpaceDoesNotReject(void) {
    TestContext *ctx = MakeContext();
    NSString *missing = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"rd-missing-%ld/absent", (long)(++gContextSeq)]];
    [[NSFileManager defaultManager] removeItemAtPath:missing error:nil];
    Check(!FileExists([[NSURL alloc] initFileURLWithPath:missing]),
          @"T31: 前置条件——目标目录确实不存在（路径复用不覆盖已存在目录）");
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": @"4096"} body:MP4Body(4096)];
    };
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://cdn.example.com/unknown-free.mp4"]
                                                     folder:[[NSURL alloc] initFileURLWithPath:missing]
                                              preferredName:@"unknown-free.mp4"
                                               sourcePageURL:nil
                                                resourceKind:DownloadResourceVideo
                                              expectedLength:4096];
    Check(![job.errorText containsString:@"磁盘剩余空间不足"],
          @"T31: 剩余空间未知时不得误报“磁盘剩余空间不足”（实际：%@）",
          job.errorText.length ? job.errorText : @"(未拒绝)");
}

// T20: 退出持久化 + 幽灵中断清理：Queued 任务经 markInterruptedOnTerminate
//      持久化 → 新 manager 恢复为 Interrupted → resume 后完成 →
//      中断记录被清除（不得复活为幽灵中断任务），历史更新为完成。
static void TestTerminatePersistsAndClearsInterrupted(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    [ctx.manager beginBatchEnqueue];   // 入队不启动，保持 Queued
    DownloadJob *job = EnqueueVideo(ctx, @"/resume.mp4", @"https://page.example.com/watch", (int64_t)body.length);
    [ctx.manager endBatchEnqueue];
    [ctx.manager markInterruptedOnTerminate];
    Check(job.state == DownloadJobStateInterrupted, @"T20: 退出时任务标记为中断");
    Check([ctx.manager.store interruptedRecords][job.identifier] != nil, @"T20: 中断记录已持久化");
    Check(!FileExists(job.destinationURL), @"T20: 中断时不落盘半成品");

    // 模拟重启
    DownloadStore *restoredStore = [[DownloadStore alloc] initWithUserDefaults:ctx.ud];
    DownloadManager *restored = [[DownloadManager alloc] initWithBackend:ctx.backend tempRoot:ctx.tmpRoot store:restoredStore];
    restored.rd_enableEndpointResolution = NO;
    __block DownloadJob *restoredJob = nil;
    for (DownloadJob *candidate in restored.allJobs)
        if ([candidate.identifier isEqualToString:job.identifier]) restoredJob = candidate;
    Check(restoredJob != nil && restoredJob.state == DownloadJobStateInterrupted, @"T20: 重启后恢复为中断任务");
    [restored resumeJob:restoredJob.identifier];
    WaitForState(restored, restoredJob, DownloadJobStateCompleted, 10);
    Check(restoredJob.state == DownloadJobStateCompleted, @"T20: 中断任务续传后完成");
    Check(FileExists(restoredJob.destinationURL), @"T20: 续传结果真实落盘");
    Check([restoredStore interruptedRecords][job.identifier] == nil, @"T20: 完成后中断记录被清除（无幽灵任务）");
    NSDictionary *record = FinishedRecord(restoredStore, job.identifier);
    Check(record != nil && [record[@"state"] integerValue] == DownloadJobStateCompleted, @"T20: 历史更新为已完成");
}

// T21: 文件名清洗与扩展名（2026-09-08 事故回归：标题含 `/` 与 &nbsp;，
// 最终 move 把目标拆成不存在的嵌套目录，225MB 已合并文件被丢弃）。
static void TestFileNameSanitizationAndExtension(void) {
    NSString *sanitized = [DownloadJob sanitizedFileNameFromPreferred:
                           @"屈辱2 The Animation 下巻 [中文字幕]&nbsp;-&nbsp;H動漫/裏番/線上看&nbsp;-&nbsp;hanime2.org"];
    Check(sanitized != nil, @"T21: 清洗结果非空");
    Check(![sanitized containsString:@"/"], @"T21: 不含路径分隔符 /（%@）", sanitized);
    Check(![sanitized containsString:@"&"], @"T21: HTML 实体已解码（%@）", sanitized);
    Check(![sanitized containsString:@"\u00A0"], @"T21: 不含不换行空格");
    Check([sanitized hasSuffix:@"hanime2.org"], @"T21: 标题内容保留（%@）", sanitized);

    Check([[DownloadJob sanitizedFileNameFromPreferred:@"a/b:c"] isEqualToString:@"a-b-c"],
          @"T21: `/` 与 `:` 替换为 -");
    Check([[DownloadJob sanitizedFileNameFromPreferred:@"&#65;&#x42;C"] isEqualToString:@"ABC"],
          @"T21: 数字/十六进制实体解码");
    Check([[DownloadJob sanitizedFileNameFromPreferred:@"&amp;x"] isEqualToString:@"&x"],
          @"T21: &amp; 解码");
    Check([[DownloadJob sanitizedFileNameFromPreferred:@"&unknownzz;x"] isEqualToString:@"&unknownzz;x"],
          @"T21: 未识别实体原样保留");
    Check([[DownloadJob sanitizedFileNameFromPreferred:@"  x\x01y  "] isEqualToString:@"xy"],
          @"T21: 控制字符删除并去除首尾空白");
    Check([DownloadJob sanitizedFileNameFromPreferred:@""] == nil, @"T21: 空名返回 nil");

    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"电影 hanime2.org" fallbackExtension:@"mp4"]
           isEqualToString:@"电影 hanime2.org.mp4"], @"T21: 域名尾巴补媒体扩展名");
    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"movie.mp4" fallbackExtension:@"mp4"]
           isEqualToString:@"movie.mp4"], @"T21: 已有媒体扩展名不动");
    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"movie" fallbackExtension:@"mp4"]
           isEqualToString:@"movie.mp4"], @"T21: 无扩展名补默认");
    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"clip.jpg" fallbackExtension:@"mp4"]
           isEqualToString:@"clip.jpg"], @"T21: 其他媒体扩展名不动");
    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"电影 上巻" fallbackExtension:@"unknown"]
           isEqualToString:@"电影 上巻.mp4"], @"T21: unknown 兜底扩展名替换为 mp4（否则 Finder 显示为“文档”）");
    Check([[DownloadJob fileNameByEnsuringMediaExtension:@"电影" fallbackExtension:@"mp4"]
           isEqualToString:@"电影.mp4"], @"T21: 正常兜底扩展名保留");

    // 入队端到端：恶意标题必须落盘到目标目录本层（无嵌套），并真实完成
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://cdn.example.com/hostile.mp4"]
                                                      folder:ctx.destFolder
                                               preferredName:@"屈辱2&nbsp;-&nbsp;H動漫/裏番/線上看&nbsp;-&nbsp;hanime2.org"
                                               sourcePageURL:@"https://page.example.com/watch"
                                                resourceKind:DownloadResourceVideo
                                               expectedLength:(int64_t)body.length];
    StateAfter(ctx, job, DownloadJobStateCompleted, 10);
    Check(job.state == DownloadJobStateCompleted, @"T21: 恶意标题任务完成");
    Check([job.destinationURL.path.stringByDeletingLastPathComponent isEqualToString:ctx.destFolder.path],
          @"T21: 目标路径没有嵌套子目录（%@）", job.destinationURL.path ?: @"");
    Check(![job.destinationURL.lastPathComponent containsString:@"&nbsp;"],
          @"T21: 文件名不含未解码实体（%@）", job.destinationURL.lastPathComponent);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == (int64_t)body.length,
          @"T21: 文件真实落盘且大小正确");

    // 入队层双保险：调用方没加扩展名时，下载层自动用源 URL 的媒体扩展名兜底
    DownloadJob *noext = [ctx.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://cdn.example.com/noext.mp4"]
                                                        folder:ctx.destFolder
                                                 preferredName:@"无扩展名标题"
                                                 sourcePageURL:nil
                                                  resourceKind:DownloadResourceVideo
                                                expectedLength:(int64_t)body.length];
    Check([noext.fileName hasSuffix:@".mp4"], @"T21: 入队层自动补媒体扩展名（%@）", noext.fileName);
    WaitForState(ctx.manager, noext, DownloadJobStateCompleted, 10);
    Check(noext.state == DownloadJobStateCompleted && FileExists(noext.destinationURL),
          @"T21: 双保险任务正常完成并落盘");
}

// T22: DNS 间歇性故障（-1003）重试预算：站点 DNS 常以几十秒周期抖动，
// 普通 2 次小预算必然失败。DNS 类错误应有 5 次预算、5 秒间隔。
static void TestDNSFlapRetryBudget(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        if (index < 4) {
            return [MockScript failure:[NSError errorWithDomain:NSURLErrorDomain
                                                           code:NSURLErrorCannotFindHost
                                                       userInfo:@{}]];
        }
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:[NSURL URLWithString:@"https://cdn.example.com/dnsflap.mp4"]
                                                      folder:ctx.destFolder
                                               preferredName:@"dnsflap" etag:@"" lastModified:@""
                                                acceptRanges:YES expectedLength:(int64_t)body.length];
    StateAfter(ctx, job, DownloadJobStateCompleted, 90);
    Check(job.state == DownloadJobStateCompleted, @"T22: DNS 连续 4 次失败后重试成功（实际 %ld）", (long)job.state);
    Check(ctx.backend.requests.count == 5, @"T22: DNS 类错误重试 4 次而非 2 次（实际 %lu 次请求）",
          (unsigned long)ctx.backend.requests.count);
    Check(FileExists(job.destinationURL), @"T22: 结果真实落盘");
}

// T23: 进度条聚合只统计进行中任务（2026-09-08 用户报告回归：恢复一条
// 236.7MB 失败历史后，新下载 241.3MB 的进度条总量显示 400 多 MB、从 50% 起步）。
static void TestProgressIgnoresFinishedHistory(void) {
    DownloadJob *done = [DownloadJob new];
    [done restoreTerminalState:DownloadJobStateCompleted];
    done.expectedContentLength = 236673346;
    done.progress = 1.0;
    done.transferredBytes = 236673346;
    DownloadJob *running = [DownloadJob new];
    [running transitionTo:DownloadJobStateRunning];
    running.expectedContentLength = 241259423;
    running.progress = 0.0;
    running.transferredBytes = 0;

    NSArray *active = [DownloadManager activeJobsForJobs:@[done, running]];
    Check(active.count == 1 && active.firstObject == running, @"T23: 终态历史被排除出进度聚合（剩 %lu 个）",
          (unsigned long)active.count);
    Check([DownloadManager overallProgressForJobs:active] == 0.0,
          @"T23: 新下载从 0%% 起步（而非 49.5%%“半途起步”）");
    Check([DownloadManager aggregateMetricsForJobs:active][@"expectedBytes"].longLongValue == 241259423,
          @"T23: 总大小只含新任务（400 多 MB 事故回归）");

    // 错误行为的锁定：若把历史计入聚合，起步进度正是用户看到的 49.5%
    double wrongStart = [DownloadManager overallProgressForJobs:@[done, running]];
    Check(fabs(wrongStart - (236673346.0 / (236673346.0 + 241259423.0))) < 1e-12,
          @"T23: 佐证旧进度条“一半开始”的来源");

    // Paused 任务仍计入（暂停时进度条保持可见）
    DownloadJob *paused = [DownloadJob new];
    [paused transitionTo:DownloadJobStateRunning];
    [paused transitionTo:DownloadJobStatePaused];
    paused.expectedContentLength = 1000;
    Check([DownloadManager activeJobsForJobs:@[paused]].count == 1, @"T23: 暂停任务计入进度聚合");
    // 取消中任务计入，中断/取消不计入
    DownloadJob *cancelling = [DownloadJob new];
    [cancelling transitionTo:DownloadJobStateCancelling];
    cancelling.expectedContentLength = 1000;
    DownloadJob *interrupted = [DownloadJob new];
    [interrupted restoreTerminalState:DownloadJobStateInterrupted];
    interrupted.expectedContentLength = 1000;
    DownloadJob *cancelled = [DownloadJob new];
    [cancelled restoreTerminalState:DownloadJobStateCancelled];
    cancelled.expectedContentLength = 1000;
    NSArray *mixed = [DownloadManager activeJobsForJobs:@[paused, cancelling, interrupted, cancelled]];
    Check(mixed.count == 2, @"T23: 取消中计入、中断/取消排除（实际 %lu）", (unsigned long)mixed.count);
}

// MARK: - 可挂起后端（分段重试/看门狗回归：需要让传输停在在途状态占住槽位）

@interface HoldableDownloadTask : NSObject <RDDownloadTask>
@property (nonatomic, assign) BOOL cancelled;
@end
@implementation HoldableDownloadTask
- (void)rd_cancel { self.cancelled = YES; }
@end

@interface HeldTransfer : NSObject
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURL *writeToURL;
@property (nonatomic, copy) void (^progress)(int64_t, int64_t, int64_t);
@property (nonatomic, copy) void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *);
@property (nonatomic, assign) NSInteger callIndex;
@end
@implementation HeldTransfer
@end

@interface HoldableBackend : NSObject <RDDownloadBackend>
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *requests;
@property (nonatomic, copy) MockScript *(^script)(NSURLRequest *request, NSInteger callIndex);
// 返回 YES：请求进入挂起区，直到 releaseHeld 才按脚本应答（用于占住连接槽位）
@property (nonatomic, copy) BOOL (^shouldHold)(NSURLRequest *request);
@property (nonatomic, strong) NSMutableArray<HeldTransfer *> *held;
- (void)releaseHeld;
@end
@implementation HoldableBackend
- (instancetype)init {
    self = [super init];
    if (self) { _requests = [NSMutableArray array]; _held = [NSMutableArray array]; }
    return self;
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    NSInteger index = self.requests.count;
    [self.requests addObject:request];
    if (self.shouldHold && self.shouldHold(request)) {
        HeldTransfer *held = [HeldTransfer new];
        held.request = request; held.writeToURL = writeToURL;
        held.progress = progress; held.completion = completion; held.callIndex = index;
        [self.held addObject:held];
        return [HoldableDownloadTask new];
    }
    MockScript *s = self.script ? self.script(request, index) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s.error) { completion(nil, nil, s.error); return; }
        [s.body writeToURL:writeToURL atomically:YES];
        if (progress) progress((int64_t)s.body.length, (int64_t)s.body.length, [s.headers[@"Content-Length"] longLongValue]);
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:s.statusCode HTTPVersion:@"HTTP/1.1" headerFields:s.headers];
        completion(writeToURL, resp, nil);
    });
    return [HoldableDownloadTask new];
}
- (void)releaseHeld {
    NSArray<HeldTransfer *> *batch = [self.held copy];
    [self.held removeAllObjects];
    for (HeldTransfer *held in batch) {
        MockScript *s = self.script ? self.script(held.request, held.callIndex) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s.error) { held.completion(nil, nil, s.error); return; }
            [s.body writeToURL:held.writeToURL atomically:YES];
            if (held.progress) held.progress((int64_t)s.body.length, (int64_t)s.body.length, [s.headers[@"Content-Length"] longLongValue]);
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:held.request.URL statusCode:s.statusCode HTTPVersion:@"HTTP/1.1" headerFields:s.headers];
            held.completion(held.writeToURL, resp, nil);
        });
    }
}
@end

// MARK: - 「连接代次生病」后端（T32/T33/T34：整池被晾 vs 单段被晾）

// 语义：正常路径 rd_startRequest: 代表“与旧请求共用连接池的那条连接”；
//      换新连接路径 rd_reissueRequest: 代表“新会话 ⇒ 新 TCP 连接”。
// 现场症状（2026-09-10 19:38 样本，720p 8 段总长 49,565,560）：段 0/1/2/4/5/6/7 上
// 停滞重发反复触发直到 3/3 用尽，总耗时 108.4s——服务器把整池连接一起晾住，
// 而旧代码把重发发回同一条生病的连接池，额度在约 9–12s 内烧光，只能干等看门狗。
@interface GenerationSickBackend : NSObject <RDDownloadBackend>
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *poolRequests;      // 正常路径
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *reissuedRequests;  // 换新连接路径
@property (nonatomic, copy) MockScript *(^script)(NSURLRequest *request, NSInteger callIndex);
// 正常路径（旧连接）上该请求是否被晾住：YES = 永不返回任何字节
@property (nonatomic, copy) BOOL (^isSick)(NSURLRequest *request);
// 换新连接是否健康：YES = 立刻按脚本应答；NO = 新连接也被晾住（站点永不恢复）
@property (nonatomic, assign) BOOL reissueHealthy;
@end

@implementation GenerationSickBackend
- (instancetype)init {
    self = [super init];
    if (self) {
        _poolRequests = [NSMutableArray array];
        _reissuedRequests = [NSMutableArray array];
        _reissueHealthy = YES;
    }
    return self;
}
- (void)serveRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
            progress:(void (^)(int64_t, int64_t, int64_t))progress
          completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion
               index:(NSInteger)index {
    MockScript *s = self.script ? self.script(request, index) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s.error) { completion(nil, nil, s.error); return; }
        [s.body writeToURL:writeToURL atomically:YES];
        if (progress) progress((int64_t)s.body.length, (int64_t)s.body.length, [s.headers[@"Content-Length"] longLongValue]);
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:s.statusCode
                                                            HTTPVersion:@"HTTP/1.1" headerFields:s.headers];
        completion(writeToURL, resp, nil);
    });
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self.poolRequests addObject:request];
    if (self.isSick && self.isSick(request)) return [HoldableDownloadTask new]; // 被晾住：永不回调
    [self serveRequest:request writeToURL:writeToURL progress:progress completion:completion
                 index:(NSInteger)self.poolRequests.count - 1];
    return [HoldableDownloadTask new];
}
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request
                             writeToURL:(NSURL *)writeToURL
                               progress:(void (^)(int64_t, int64_t, int64_t))progress
                             completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self.reissuedRequests addObject:request];
    if (!self.reissueHealthy) return [HoldableDownloadTask new]; // 新连接也被晾住
    [self serveRequest:request writeToURL:writeToURL progress:progress completion:completion
                 index:(NSInteger)self.reissuedRequests.count - 1];
    return [HoldableDownloadTask new];
}
@end

// Range 请求起点（"bytes=X-Y" 的 X）；非 Range 请求返回 -1
static int64_t RangeStart(NSURLRequest *request) {
    int64_t start = 0, end = 0;
    return ParseRangeHeader(request, &start, &end) ? start : -1;
}

static TestContext *MakeHoldableContext(id<RDDownloadBackend> backend) {
    TestContext *ctx = [TestContext new];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"zz-dl-tests-hold-%ld", (long)(++gContextSeq)]];
    ctx.destFolder = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"dest"]];
    ctx.tmpRoot = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"tmp"]];
    [[NSFileManager defaultManager] createDirectoryAtURL:ctx.destFolder
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *suite = [NSString stringWithFormat:@"com.sevenzz.tests.download-integrity.hold.%ld", (long)gContextSeq];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    ctx.ud = [[NSUserDefaults alloc] initWithSuiteName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:ctx.ud];
    ctx.manager = [[DownloadManager alloc] initWithBackend:backend tempRoot:ctx.tmpRoot store:store];
    ctx.manager.rd_enableEndpointResolution = NO;
    ctx.refreshCalls = [NSMutableArray array];
    NSMutableArray<DownloadJob *> *calls = ctx.refreshCalls;
    ctx.manager.linkRefreshHandler = ^(DownloadJob *job, NSString *reason) { [calls addObject:job]; };
    return ctx;
}

// T24（BUG-003 回归）：分段瞬态错误 + 连接槽位占满。等槽位的顺延绝不消耗
// 重试预算；预算内该段最终补齐，任务完成，绝不静默丢段挂死在 Running。
static void TestSegmentRetrySurvivesSlotStarvation(void) {
    HoldableBackend *backend = [HoldableBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    int64_t total = 25165824; // 24MB，达到分段门槛
    __block NSInteger rangeZeroRequests = 0;
    backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        int64_t start = RangeStart(request);
        if (start < 0) return nil;
        if (start == 0) {
            rangeZeroRequests++;
            if (rangeZeroRequests <= 2) {
                // 前两次瞬态断连：非 DNS 类瞬态错误预算恰为 2 次重试
                return [MockScript failure:[NSError errorWithDomain:NSURLErrorDomain
                                                              code:NSURLErrorNetworkConnectionLost userInfo:@{}]];
            }
        }
        int64_t s = 0, e = 0;
        ParseRangeHeader(request, &s, &e);
        int64_t len = e - s + 1;
        return [MockScript response:206 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", s, e, total],
            @"Content-Length": [NSString stringWithFormat:@"%lld", len]
        } body:MP4Body(len)];
    };
    // 挂起 seg1/seg2：占住连接槽位，让 seg0 的重试到期时无空槽可用
    backend.shouldHold = ^BOOL(NSURLRequest *request) { return RangeStart(request) > 0; };
    DownloadJob *job = EnqueueSegmented(ctx, @"/segretry.mp4", total);
    Check(job.acceptRanges, @"T24: 分段任务入队（acceptRanges）");
    Wait(^BOOL { return rangeZeroRequests == 1; }, 10);
    Check(backend.held.count >= 1, @"T24: 其余分段在途占住槽位（挂起 %lu 个）", (unsigned long)backend.held.count);
    // 把连接窗口压到 1（KVC 写调度器 ivar）：制造“槽位已满”的顺延场景
    id scheduler = [ctx.manager valueForKey:@"transferScheduler"];
    Check(scheduler != nil, @"T24: 可访问连接窗口调度器");
    [(id)scheduler setValue:@(1) forKey:@"window"];
    // 等待若干个顺延周期。旧缺陷在顺延时消耗重试预算：2 次顺延后预算耗尽，
    // 该分段会被静默丢弃（任务永远等不到 finishedSegments == segmentCount）。
    Wait(^BOOL { return NO; }, 2.5);
    Check(job.state == DownloadJobStateRunning,
          @"T24: 槽位占满期间任务保持等待而非失败（实际 %ld）", (long)job.state);
    // 释放挂起的分段：槽位空出，顺延中的重试必须最终补齐该段
    [backend releaseHeld];
    StateAfter(ctx, job, DownloadJobStateCompleted, 30);
    Check(job.state == DownloadJobStateCompleted,
          @"T24: 分段重试最终补齐，任务完成（实际 %ld，错误：%@）", (long)job.state, job.errorText);
    Check(rangeZeroRequests == 3,
          @"T24: 失败段恰为首次 + 2 次重试，顺延未消耗预算（实际 %ld 次）", (long)rangeZeroRequests);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T24: 合并结果完整落盘（实际 %lld）", FileSize(job.destinationURL));
}

// T25（BUG-004 回归）：暂停时 tick 注销进度看门狗；恢复存活传输必须重建，
// 且恢复即刷新进度基准——恢复后断流 45 秒内必须失败，绝不无限等待底层
// 7 天资源超时。
static void TestResumeRebuildsProgressWatchdog(void) {
    HoldableBackend *backend = [HoldableBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    NSData *body = MP4Body(4096);
    backend.shouldHold = ^BOOL(NSURLRequest *request) { return YES; }; // 传输存活但永不完成
    backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/watchdog.mp4", @"https://page.example.com/watch", (int64_t)body.length);
    Wait(^BOOL { return backend.requests.count == 1 && job.state == DownloadJobStateRunning; }, 10);
    Check(job.state == DownloadJobStateRunning, @"T25: 单连接任务在途");
    Check([(NSDictionary *)[ctx.manager valueForKey:@"progressWatchdogs"] objectForKey:job.identifier] != nil,
          @"T25: 运行中存在进度看门狗");

    [ctx.manager pauseJob:job.identifier];
    Check(Wait(^BOOL { return [(NSDictionary *)[ctx.manager valueForKey:@"progressWatchdogs"] count] == 0; }, 3),
          @"T25: 暂停后 tick 注销看门狗");

    [ctx.manager resumeJob:job.identifier];
    Check(job.state == DownloadJobStateRunning, @"T25: 恢复后任务回到 Running");
    Check([(NSDictionary *)[ctx.manager valueForKey:@"progressWatchdogs"] objectForKey:job.identifier] != nil,
          @"T25: 恢复存活传输必须重建进度看门狗（BUG-004）");
    Check([(NSDictionary *)[ctx.manager valueForKey:@"lastProgressAt"] objectForKey:job.identifier] != nil,
          @"T25: 恢复时刷新进度基准，避免刚恢复就误判超时");

    // 断流验证：把进度基准回拨 50 秒（等价于恢复后 45 秒无任何数据），
    // 看门狗 tick 必须在 1-2 秒内让任务失败，绝不挂在 Running。
    NSMutableDictionary *lastProgress = [ctx.manager valueForKey:@"lastProgressAt"];
    lastProgress[job.identifier] = [NSDate dateWithTimeIntervalSinceNow:-50];
    Check(Wait(^BOOL { return job.state == DownloadJobStateFailed; }, 5),
          @"T25: 恢复后断流触发 45 秒看门狗失败（实际 %ld）", (long)job.state);
    Check([job.errorText containsString:@"45"], @"T25: 失败原因指向 45 秒无数据看门狗（实际：%@）", job.errorText);
}

// T26（BUG-010 回归）：链接刷新重启必须清掉任务的能力探测完成标记，
// 让重启任务重新经过 capability probe，绝不永久降级为单连接。
@interface DownloadManager (RestartTestPrivateAPI)
- (void)failJob:(DownloadJob *)job reason:(NSString *)reason linkExpired:(BOOL)linkExpired;
@end

@interface DownloadManager (PerformancePlanningTestAPI)
- (NSInteger)fairSegmentCapForProspectiveVideos:(NSInteger)prospectiveVideos;
- (NSInteger)plannedTransferCountForJob:(DownloadJob *)job segmentCap:(NSInteger)segmentCap;
@end

static void TestLargeVideoPlansEightTransfers(void) {
    TestContext *ctx = MakeContext();
    DownloadJob *job = [DownloadJob new];
    job.resourceKind = DownloadResourceVideo;
    job.acceptRanges = YES;
    job.expectedContentLength = 49565560;
    NSInteger cap = [ctx.manager fairSegmentCapForProspectiveVideos:1];
    NSInteger planned = [ctx.manager plannedTransferCountForJob:job segmentCap:cap];
    Check(cap >= 8 && planned >= 8,
          @"性能回归：单个约 49MB Range 视频规划至少 8 段（cap=%ld planned=%ld）",
          (long)cap, (long)planned);
}

static void TestLinkRefreshRestartReprobesCapability(void) {
    TestContext *ctx = MakeContext();
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    DownloadJob *job = EnqueueVideo(ctx, @"/expire.mp4", @"https://page.example.com/watch", 0);
    // 让任务停在 Failed 终态，并伪造成“已完成能力探测”的旧任务
    [ctx.manager failJob:job reason:@"服务器返回 403，下载中止" linkExpired:YES];
    NSMutableSet *completed = [ctx.manager valueForKey:@"capabilityProbeCompleted"];
    [completed addObject:job.identifier];
    NSURL *newURL = [NSURL URLWithString:@"https://cdn.example.com/expire.mp4?token=NEW"];
    BOOL restarted = [ctx.manager restartFailedJobWithIdentifier:job.identifier
                                                       sourceURL:newURL
                                                  expectedLength:(int64_t)body.length
                                                            etag:@"ETAG-2"
                                                    lastModified:@"LM-2"
                                                    acceptRanges:NO];
    Check(restarted, @"T26: 链接刷新重启成功");
    Check(![completed containsObject:job.identifier], @"T26: 重启清除了能力探测完成标记（BUG-010）");
    Check(![(NSMutableSet *)[ctx.manager valueForKey:@"capabilityProbePending"] containsObject:job.identifier],
          @"T26: 探测进行中标记同样清除");
    StateAfter(ctx, job, DownloadJobStateCompleted, 10);
    Check(job.state == DownloadJobStateCompleted, @"T26: 重启后任务完成（实际 %ld）", (long)job.state);
}

// T27（BUG-006 回归）：DNS 超时/解析失败/保留地址三者独立归类；
// 端点复查遇 DNS 超时做有限次顺延重查；耗尽后按“解析超时”失败，
// 绝不误报保留地址；真正解析到保留地址仍 fail-closed。
static int gDNSStatusCalls = 0;
static NSInteger gDNSStatusFailFirst = 0;
static NSArray<NSString *> *(*gRealResolveStatus)(id, SEL, NSString *, DNSResolutionStatus *);

static NSArray<NSString *> *FakeResolveStatus(id self, SEL _cmd, NSString *host, DNSResolutionStatus *status) {
    gDNSStatusCalls++;
    if (gDNSStatusCalls <= gDNSStatusFailFirst) {
        if (status) *status = DNSResolutionTimedOut;
        return @[];
    }
    if (status) *status = DNSResolutionSucceeded;
    return @[@"8.8.8.8"];
}

static void SwizzleDNSStatusStub(NSInteger failFirst) {
    Method m = class_getClassMethod([DNSResolver class], @selector(resolveIPsForHost:status:));
    if (!gRealResolveStatus) {
        gRealResolveStatus = (NSArray<NSString *> *(*)(id, SEL, NSString *, DNSResolutionStatus *))method_getImplementation(m);
    }
    gDNSStatusCalls = 0;
    gDNSStatusFailFirst = failFirst;
    method_setImplementation(m, (IMP)FakeResolveStatus);
}

static void RestoreDNSStatusStub(void) {
    Method m = class_getClassMethod([DNSResolver class], @selector(resolveIPsForHost:status:));
    method_setImplementation(m, (IMP)gRealResolveStatus);
}

static void TestDNSTimeoutClassification(void) {
    URLPolicy *policy = [URLPolicy new];
    NSURL *target = [NSURL URLWithString:@"https://media.example.com/a.mp4"];
    URLPolicyDecision *timeout = [policy evaluateResolvedURL:target resolvedIPs:@[] resolutionStatus:DNSResolutionTimedOut];
    Check(!timeout.allowed && timeout.verdict == URLPolicyBlockedDNSTimeout,
          @"T27a: DNS 超时是独立 verdict（实际 %ld）", (long)timeout.verdict);
    Check([timeout.userMessage containsString:@"解析超时"], @"T27a: 超时文案正确（%@）", timeout.userMessage);
    URLPolicyDecision *dnsFail = [policy evaluateResolvedURL:target resolvedIPs:@[] resolutionStatus:DNSResolutionFailed];
    Check(!dnsFail.allowed && dnsFail.verdict == URLPolicyBlockedDNSError && [dnsFail.userMessage containsString:@"解析失败"],
          @"T27a: DNS 解析失败独立归类（实际 %ld）", (long)dnsFail.verdict);
    URLPolicyDecision *reserved = [policy evaluateResolvedURL:target resolvedIPs:@[] resolutionStatus:DNSResolutionSucceeded];
    Check(!reserved.allowed && reserved.verdict == URLPolicyBlockedReserved,
          @"T27a: 无状态信息的空列表维持 fail-closed 保留地址语义");
    URLPolicyDecision *hitReserved = [policy evaluateResolvedURL:target resolvedIPs:@[@"240.0.0.1"] resolutionStatus:DNSResolutionSucceeded];
    Check(!hitReserved.allowed && hitReserved.verdict == URLPolicyBlockedReserved && [hitReserved.userMessage containsString:@"保留"],
          @"T27a: 真正解析到保留地址仍被拦截且文案不变（%@）", hitReserved.userMessage);
    Check([policy evaluateResolvedURL:target resolvedIPs:@[@"8.8.8.8"] resolutionStatus:DNSResolutionSucceeded].allowed,
          @"T27a: 公网 IP 放行");
    DNSResolutionStatus status = DNSResolutionFailed;
    NSArray<NSString *> *ips = [DNSResolver resolveIPsForHost:@"127.0.0.1" status:&status];
    Check(ips.count == 1 && status == DNSResolutionSucceeded, @"T27b: IP 字面量解析并报告 Succeeded");
}

static void TestEndpointDNSTimeoutDefersThenSucceeds(void) {
    TestContext *ctx = MakeContext();
    ctx.manager.rd_enableEndpointResolution = YES;   // 生产默认；MakeContext 为隔离而关闭
    NSData *body = MP4Body(4096);
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:200 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} body:body];
    };
    SwizzleDNSStatusStub(2);   // 前两次解析超时，第三次成功
    DownloadJob *job = EnqueueVideo(ctx, @"/dnstimeout.mp4", @"https://page.example.com/watch", (int64_t)body.length);
    StateAfter(ctx, job, DownloadJobStateCompleted, 30);
    RestoreDNSStatusStub();
    Check(job.state == DownloadJobStateCompleted,
          @"T27c: DNS 超时顺延重查后任务完成（实际 %ld，错误：%@）", (long)job.state, job.errorText);
    Check(gDNSStatusCalls == 3, @"T27c: 初始 1 次 + 顺延重查 2 次（实际 %ld 次）", (long)gDNSStatusCalls);
    Check(FileExists(job.destinationURL), @"T27c: 结果真实落盘");
}

static void TestEndpointDNSTimeoutExhaustionReportsTimeout(void) {
    TestContext *ctx = MakeContext();
    ctx.manager.rd_enableEndpointResolution = YES;
    SwizzleDNSStatusStub(NSIntegerMax);   // 一直超时
    DownloadJob *job = EnqueueVideo(ctx, @"/dnsdead.mp4", @"https://page.example.com/watch", 4096);
    StateAfter(ctx, job, DownloadJobStateFailed, 30);
    RestoreDNSStatusStub();
    Check(job.state == DownloadJobStateFailed, @"T27d: 重试耗尽后任务失败（实际 %ld）", (long)job.state);
    Check([job.errorText containsString:@"解析超时"], @"T27d: 失败原因报告 DNS 解析超时（实际：%@）", job.errorText);
    Check(![job.errorText containsString:@"保留"], @"T27d: 不得误报保留地址（实际：%@）", job.errorText);
    Check(gDNSStatusCalls == 3, @"T27d: 恰好初始 + 2 次重查（实际 %ld 次）", (long)gDNSStatusCalls);
}

static void TestReservedAddressStillBlockedViaEndpoint(void) {
    TestContext *ctx = MakeContext();
    ctx.manager.rd_enableEndpointResolution = YES;
    ctx.manager.rd_resolver = ^NSArray<NSString *> *(NSString *host) { return @[@"240.0.0.1"]; };
    DownloadJob *job = EnqueueVideo(ctx, @"/reserved.mp4", @"https://page.example.com/watch", 4096);
    StateAfter(ctx, job, DownloadJobStateFailed, 10);
    Check(job.state == DownloadJobStateFailed && [job.errorText containsString:@"保留"],
          @"T27e: 真正命中保留地址仍 fail-closed（实际 %ld，%@）", (long)job.state, job.errorText);
}


// T28（BUG-017 回归）：分段大小明显不等（900 + 100）且大段先完成时，
// 进度口径统一为“已下载字节 / 总预期字节”：分段完成只推进 finishedSegments
// 并落账字节，绝不允许把进度从 90% 覆盖回完成段数比例（1/2 = 50%）；
// 全部段齐、合并完成后进度必须是 1.0。
@interface DownloadManager (SegmentProgressTestAPI)
- (NSMutableDictionary<NSString *, DownloadJob *> *)jobs;
- (void)updateSegmentProgressForJob:(DownloadJob *)job
                              index:(NSInteger)index
                 totalBytesWritten:(int64_t)written
                      expectedBytes:(int64_t)expected;
- (BOOL)handlePartCompletion:(DownloadJob *)job
                       index:(NSInteger)idx
                       start:(int64_t)start
                         end:(int64_t)end
                         gen:(NSInteger)gen
                  writtenURL:(NSURL *)written
                    response:(NSHTTPURLResponse *)resp
                       error:(NSError *)err;
@end

static void TestSegmentProgressNeverRegresses(void) {
    TestContext *ctx = MakeContext();
    DownloadJob *job = [DownloadJob new];
    job.sourceURL = [NSURL URLWithString:@"https://cdn.example.com/unequal.mp4"];
    job.referer = @"https://page.example.com/watch";
    job.expectedContentLength = 1000;
    job.authoritativeExpectedLength = 1000;
    job.destinationURL = [ctx.destFolder URLByAppendingPathComponent:@"unequal.mp4"];
    [[NSFileManager defaultManager] createDirectoryAtURL:ctx.tmpRoot
                             withIntermediateDirectories:YES attributes:nil error:nil];
    job.tempRootURL = [ctx.tmpRoot URLByAppendingPathComponent:
                       [NSString stringWithFormat:@"t28-%@", job.identifier]];
    [[NSFileManager defaultManager] createDirectoryAtURL:job.tempRootURL
                             withIntermediateDirectories:YES attributes:nil error:nil];
    [job transitionTo:DownloadJobStateRunning];
    job.segmented = YES;
    job.segmentCount = 2;          // 段 0 = 900 字节，段 1 = 100 字节（明显不等）
    job.finishedSegments = 0;
    [ctx.manager.jobs setObject:job forKey:job.identifier];

    // 字节口径进度：段 0 已下载 900/1000 → 90%
    [ctx.manager updateSegmentProgressForJob:job index:0 totalBytesWritten:900 expectedBytes:900];
    double progressBefore = job.progress;
    Check(fabs(progressBefore - 0.9) < 0.001,
          @"T28: 完成前字节口径进度为 90%%（实际 %.3f）", progressBefore);

    // 大段（900 字节）先完成：90% 的进度绝不允许被覆盖回 1/2 = 50%
    NSURL *part0 = [job partFileURLForIndex:0];
    Check([MP4Body(900) writeToURL:part0 atomically:YES], @"T28: 段 0 落盘 900 字节");
    NSHTTPURLResponse *resp0 = [[NSHTTPURLResponse alloc] initWithURL:job.sourceURL
                                                           statusCode:206
                                                         HTTPVersion:@"HTTP/1.1"
                                                         headerFields:@{@"Content-Range": @"bytes 0-899/1000",
                                                                        @"Content-Type": @"video/mp4"}];
    [ctx.manager handlePartCompletion:job index:0 start:0 end:899 gen:job.generation
                           writtenURL:part0 response:resp0 error:nil];
    Check(job.finishedSegments == 1, @"T28: finishedSegments 推进为 1（实际 %ld）", (long)job.finishedSegments);
    Check(job.progress >= progressBefore - 1e-9,
          @"T28: 大段完成后进度不回退（完成前 %.3f → 完成后 %.3f）", progressBefore, job.progress);

    // 小段（100 字节）完成 → 合并 → finalizeCompleted → 进度必须为 1.0
    NSURL *part1 = [job partFileURLForIndex:1];
    Check([MP4Body(100) writeToURL:part1 atomically:YES], @"T28: 段 1 落盘 100 字节");
    NSHTTPURLResponse *resp1 = [[NSHTTPURLResponse alloc] initWithURL:job.sourceURL
                                                           statusCode:206
                                                         HTTPVersion:@"HTTP/1.1"
                                                         headerFields:@{@"Content-Range": @"bytes 900-999/1000",
                                                                        @"Content-Type": @"video/mp4"}];
    [ctx.manager handlePartCompletion:job index:1 start:900 end:999 gen:job.generation
                           writtenURL:part1 response:resp1 error:nil];
    Check(job.state == DownloadJobStateCompleted, @"T28: 两段齐后合并完成（实际 %ld，%@）",
          (long)job.state, job.errorText);
    Check(fabs(job.progress - 1.0) < 1e-9, @"T28: 最终完成进度为 1.0（实际 %.3f）", job.progress);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == 1000,
          @"T28: 合并文件 1000 字节真实落盘（实际 %lld）", FileSize(job.destinationURL));
}

// T30（性能回归，真实现场驱动）：真实网址 720p 8 段下载实测 7 段 6.9s 完成、
// 第 8 段被服务器晾住 57s（总耗时 64.2s）。生产代码对“其余段正常推进、单段
// 停滞”没有任何感知：看门狗只看全任务 45s 无进展。此测试用可挂起后端把最后
// 一段晾住（其余段立即完成），断言：①该段被重新发起（换连接）；②任务在远小于
// 45s 看门狗的时间内完成且合并落盘完整。旧代码：被晾住的分段永不重发，任务
// 永远停在 Running（或 45s 后才失败）。
static void TestStalledSegmentReissued(void) {
    HoldableBackend *backend = [HoldableBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    int64_t total = 25165824;               // 24MB → 4 段（每段 6MB）
    int64_t lastStart = total - total / 4;  // 第 4 段起点 = 18874368
    __block NSInteger lastRangeRequests = 0;
    // 只挂住该段范围的“第一次”请求：模拟单段连接被晾住；重发后的请求正常应答。
    backend.shouldHold = ^BOOL(NSURLRequest *request) {
        if (RangeStart(request) == lastStart) return (lastRangeRequests++ == 0);
        return NO;
    };
    backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        int64_t s = 0, e = 0;
        if (!ParseRangeHeader(request, &s, &e)) return nil;
        int64_t len = e - s + 1;
        return [MockScript response:206 headers:@{
            @"Content-Type": @"video/mp4",
            @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", s, e, total],
            @"Content-Length": [NSString stringWithFormat:@"%lld", len]
        } body:MP4Body(len)];
    };
    DownloadJob *job = EnqueueSegmented(ctx, @"/stalled.mp4", total);
    Check(job.segmented && job.segmentCount >= 4,
          @"T30: 分段任务启动（%ld 段）", (long)job.segmentCount);
    StateAfter(ctx, job, DownloadJobStateCompleted, 12);
    Check(job.state == DownloadJobStateCompleted,
          @"T30: 被晾住的分段被重新发起并完成（实际 state=%ld，错误：%@）",
          (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T30: 合并结果完整落盘（实际 %lld）", FileSize(job.destinationURL));
    Check(lastRangeRequests >= 2,
          @"T30: 被晾住的分段确实被重新发起（该段范围请求 %ld 次）", (long)lastRangeRequests);
}

// T32（性能回归，真实现场驱动）：整池被同时晾住时必须换新连接重发。
// 旧代码：重发走同一个 NSURLSession（同一条生病连接池），每段 3 次额度在约 9–12s
// 内用尽后只能干等 45s 看门狗（现场样本 108.4s）。修复后：判为“整池被晾”，
// 一轮换新连接就把全部停滞段搬到健康连接上，远早于看门狗完成。
static void TestWholePoolStallRotatesConnections(void) {
    GenerationSickBackend *backend = [GenerationSickBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    int64_t total = 25165824; // 24MB（与 T30 同量级）→ 多段任务
    backend.script = CorrectSegmentScript(total, ^NSData *(int64_t start, int64_t end) {
        return MP4Body(end - start + 1);
    });
    backend.isSick = ^BOOL(NSURLRequest *request) { return RangeStart(request) >= 0; }; // 整池同时被晾
    backend.reissueHealthy = YES;                                                      // 新连接健康
    NSDate *startedAt = [NSDate date];
    DownloadJob *job = EnqueueSegmented(ctx, @"/poolstall.mp4", total);
    Check(job.segmented && job.segmentCount >= 4,
          @"T32: 分段任务启动（%ld 段）", (long)job.segmentCount);
    StateAfter(ctx, job, DownloadJobStateCompleted, 30);
    NSTimeInterval elapsed = -[startedAt timeIntervalSinceNow];
    Check(job.state == DownloadJobStateCompleted,
          @"T32: 整池被晾后经换新连接完成（实际 state=%ld，错误：%@）", (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T32: 合并结果完整落盘（实际 %lld）", FileSize(job.destinationURL));
    Check(backend.reissuedRequests.count == (NSUInteger)job.segmentCount,
          @"T32: 每个停滞段恰好换新连接重发一次（实际 %lu 次 / %ld 段）",
          (unsigned long)backend.reissuedRequests.count, (long)job.segmentCount);
    Check(elapsed < 25.0, @"T32: 一轮换连接即恢复（实际 %.2fs，远小于 45s 看门狗）", elapsed);
}

// T33（性能回归）：只有一段被晾、其余段正常推进 → 必须立刻换连接重发该段，
// 不等池级分层退避（3/6/12/24s）。旧代码在同一连接池上重发 → 三次额度烧光后假死。
static void TestSingleSegmentStallReissuedImmediately(void) {
    GenerationSickBackend *backend = [GenerationSickBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    int64_t total = 25165824;
    backend.script = CorrectSegmentScript(total, ^NSData *(int64_t start, int64_t end) {
        return MP4Body(end - start + 1);
    });
    backend.isSick = ^BOOL(NSURLRequest *request) { return RangeStart(request) == 0; }; // 只有第 0 段被晾
    backend.reissueHealthy = YES;
    NSDate *startedAt = [NSDate date];
    DownloadJob *job = EnqueueSegmented(ctx, @"/singlestall.mp4", total);
    Check(job.segmented && job.segmentCount >= 4,
          @"T33: 分段任务启动（%ld 段）", (long)job.segmentCount);
    StateAfter(ctx, job, DownloadJobStateCompleted, 25);
    NSTimeInterval elapsed = -[startedAt timeIntervalSinceNow];
    Check(job.state == DownloadJobStateCompleted,
          @"T33: 单段被晾后立刻换连接完成（实际 state=%ld，错误：%@）", (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T33: 合并结果完整落盘（实际 %lld）", FileSize(job.destinationURL));
    Check(backend.reissuedRequests.count == 1,
          @"T33: 只对该段换连接一次（实际 %lu 次）", (unsigned long)backend.reissuedRequests.count);
    Check(elapsed < 20.0, @"T33: 未等待池级退避（实际 %.2fs）", elapsed);
}

// T34（有界性回归）：整池永不恢复 → 换连接轮次有界（4 轮，3/6/12/24s），
// 绝无重试风暴；轮次耗尽后交回 45s 任务级看门狗有限失败，不许假死。
static void TestPoolStallNeverRecoversFailsBounded(void) {
    GenerationSickBackend *backend = [GenerationSickBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    int64_t total = 25165824;
    backend.script = CorrectSegmentScript(total, ^NSData *(int64_t start, int64_t end) {
        return MP4Body(end - start + 1);
    });
    backend.isSick = ^BOOL(NSURLRequest *request) { return RangeStart(request) >= 0; };
    backend.reissueHealthy = NO; // 站点永不恢复：新连接也被晾住
    DownloadJob *job = EnqueueSegmented(ctx, @"/deadpool.mp4", total);
    // 4 轮 × 全部段。注意：第 4 轮调度落在 45s，与任务级 45s 看门狗存在固有竞速，
    // 因此不能用"恰好等于上限"做断言（负载抖动时会得到 14 或 16）。这里守住两个
    // 方向的不变式：**总数不得超过上限**（无重试风暴），且**至少完成 3 轮**
    //（3+6+12=21s，远早于看门狗，证明换连接确实在有界推进而非停摆）。
    NSInteger expected = job.segmentCount * 4; // 4 轮 × 全部段
    NSInteger atLeast = job.segmentCount * 3;
    Wait(^BOOL { return (NSInteger)backend.reissuedRequests.count >= expected; }, 80);
    Check((NSInteger)backend.reissuedRequests.count <= expected,
          @"T34: 换连接重发不得超过 4 轮上限、无重试风暴（实际 %lu 次，上限 %ld 次）",
          (unsigned long)backend.reissuedRequests.count, (long)expected);
    Check((NSInteger)backend.reissuedRequests.count >= atLeast,
          @"T34: 换连接至少完成 3 轮有界推进（实际 %lu 次，下限 %ld 次）",
          (unsigned long)backend.reissuedRequests.count, (long)atLeast);
    Check(job.state == DownloadJobStateRunning,
          @"T34: 轮次未耗尽前不假死也不误判失败（实际 state=%ld）", (long)job.state);
    // 观察窗 12s：足以覆盖“轮次被自己重置 → 每 9s 又来一轮”的假修复
    [NSThread sleepForTimeInterval:12.0];
    Check((NSInteger)backend.reissuedRequests.count <= expected,
          @"T34: 轮次耗尽后不再发起新的换连接（12s 观察窗内实际 %lu 次，上限 %ld）",
          (unsigned long)backend.reissuedRequests.count);
    // 钉死绝对上限：轮次耗尽后由既有 45s 任务级看门狗收口（回拨基准等价于已断流 50s）
    NSMutableDictionary *lastProgress = [ctx.manager valueForKey:@"lastProgressAt"];
    lastProgress[job.identifier] = [NSDate dateWithTimeIntervalSinceNow:-50];
    Check(Wait(^BOOL { return job.state == DownloadJobStateFailed; }, 5),
          @"T34: 轮次耗尽后由 45s 看门狗有限失败（实际 state=%ld）", (long)job.state);
    Check([job.errorText containsString:@"45"],
          @"T34: 失败原因指向 45 秒看门狗（实际：%@）", job.errorText);
}

// MARK: - 「探测瞬时失败」后端 + 探针替身（T38/T39：超时不得永久降级为单连接）
//
// 现场事实（2026-09-11 交接记录 + 本轮复现）：能力探测固定 10s 超时
// （DownloadCapabilityProbe.m 的 timeoutIntervalForRequest 与 10s 兜底定时器）。
// 站点劣化时 TCP 建连 20–86s、TTFB 21s，探测必然超时；而旧代码在**任何**失败上
// 都做两件永久的事：①把任务标记 capabilityProbeCompleted（同代次内永不再探测）；
// ②acceptRanges = NO ⇒ 任务退化单连接，实测 1.67–2.01 MB/s，直接封死 5 MB/s 目标。
// 超时是**瞬时**故障（与 403/404 这类“资源确实不支持分段”的确定性答复不同），
// 必须有限重试，而不是永久降级。

// 探针替身：按脚本返回预设的能力结果，并记录调用次数。
@interface StubCapabilityProbe : DownloadCapabilityProbe
@property (nonatomic, strong) NSMutableArray<NSNumber *> *callCountsByLength;
// 第 n 次调用（0 基）返回的能力；返回 nil 表示返回 nil 能力
@property (nonatomic, copy) ZZDownloadCapability *(^capabilityForCall)(NSInteger callIndex);
@property (nonatomic, assign) NSInteger calls;
@property (nonatomic, assign) BOOL cancelled;
// 每次回调后抓一次“探测已完成”集合大小，用于断言“瞬时失败当场未被标记为已完成”。
@property (nonatomic, copy) NSInteger (^completedCountProvider)(void);
@property (nonatomic, strong) NSMutableArray<NSNumber *> *completedCountAfterCall;
@end

@implementation StubCapabilityProbe
- (NSMutableArray<NSNumber *> *)callCountsByLength {
    if (!_callCountsByLength) _callCountsByLength = [NSMutableArray array];
    return _callCountsByLength;
}
- (NSMutableArray<NSNumber *> *)completedCountAfterCall {
    if (!_completedCountAfterCall) _completedCountAfterCall = [NSMutableArray array];
    return _completedCountAfterCall;
}
- (void)probeURL:(NSURL *)url referer:(NSString *)referer completion:(void (^)(ZZDownloadCapability *))completion {
    NSInteger idx = self.calls++;
    ZZDownloadCapability *cap = self.capabilityForCall ? self.capabilityForCall(idx) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(cap);
        if (self.completedCountProvider) {
            [self.completedCountAfterCall addObject:@(self.completedCountProvider())];
        }
    });
}
- (void)cancel { self.cancelled = YES; }
@end

// 一个可控的传输替身：按 Range 返回 206，非 Range 返回完整 200。
// T38/T39 只关心“探测失败后的排队决策”，因此这里不做任何连接计费模拟
// （曾经用于 T36/T37 的“每连接 5MB/s 计费”变体已被真实站点实测否定，见
// outputs/分段独占连接5MB每秒修复报告-2026-09-11.md）。
@interface ConnectionBilledBackend : NSObject <RDDownloadBackend>
@property (nonatomic, assign) int64_t total;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *servedStarts;
@end

@implementation ConnectionBilledBackend
- (instancetype)init {
    self = [super init];
    if (self) _servedStarts = [NSMutableArray array];
    return self;
}
- (NSMutableArray<NSNumber *> *)servedStarts {
    if (!_servedStarts) _servedStarts = [NSMutableArray array];
    return _servedStarts;
}
- (void)serve:(NSURLRequest *)request writeTo:(NSURL *)writeToURL
     progress:(void (^)(int64_t, int64_t, int64_t))progress
   completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    int64_t start = 0, end = 0;
    NSData *body = nil;
    NSDictionary *headers = nil;
    if (ParseRangeHeader(request, &start, &end)) {
        int64_t len = end - start + 1;
        [self.servedStarts addObject:@(start)];
        body = MP4Body(len);
        headers = @{@"Content-Type": @"video/mp4",
                    @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, self.total],
                    @"Content-Length": [NSString stringWithFormat:@"%lld", len]};
    } else {
        int64_t len = self.total > 0 ? self.total : 4096;
        body = MP4Body(len);
        headers = @{@"Content-Type": @"video/mp4",
                    @"Accept-Ranges": @"bytes",
                    @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]};
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [body writeToURL:writeToURL atomically:YES];
        if (progress) progress((int64_t)body.length, (int64_t)body.length, (int64_t)body.length);
        completion(writeToURL, [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                          statusCode:headers[@"Content-Range"] ? 206 : 200
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:headers], nil);
    });
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self serve:request writeTo:writeToURL progress:progress completion:completion];
    return [HoldableDownloadTask new];
}
- (id<RDDownloadTask>)rd_startIsolatedRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                                     progress:(void (^)(int64_t, int64_t, int64_t))progress
                                   completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self serve:request writeTo:writeToURL progress:progress completion:completion];
    return [HoldableDownloadTask new];
}
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
                               progress:(void (^)(int64_t, int64_t, int64_t))progress
                             completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self serve:request writeTo:writeToURL progress:progress completion:completion];
    return [HoldableDownloadTask new];
}
@end

// 一个“自称 SessionDownloadBackend”的后端：把分段请求交给内部持有者处理。
// 之所以要伪装类名：DownloadManager 只在真实 NSURLSession 后端上做能力探测
// （nativeBackend 判断），而本用例要测的正是探测失败后的排队决策。
@interface ProbePathBackend : ConnectionBilledBackend
@end

@implementation ProbePathBackend
// 伪装类名：DownloadManager 只在真实 NSURLSession 后端上做能力探测（nativeBackend 判断），
// 而本用例要测的正是“探测瞬时失败后的排队决策”，因此让替身在类名上冒充生产后端。
- (Class)class { return NSClassFromString(@"SessionDownloadBackend") ?: [super class]; }
@end

static ZZDownloadCapability *ProbeTimeoutCapability(void) {
    ZZDownloadCapability *c = [ZZDownloadCapability new];
    c.statusCode = 0;
    c.contentLength = 0;
    c.rangeSupported = NO;
    c.bodyResponsive = NO;
    c.firstByteLatency = 10.0;
    c.failureReason = @"能力探测超时";
    return c;
}

static ZZDownloadCapability *ProbeSuccessCapability(int64_t total) {
    ZZDownloadCapability *c = [ZZDownloadCapability new];
    c.statusCode = 206;
    c.contentLength = total;
    c.rangeSupported = YES;
    c.bodyResponsive = YES;
    c.firstByteLatency = 0.05;
    c.etag = @"ETAG-P";
    return c;
}

// 建立一个走“能力探测路径”的上下文：后端自称 SessionDownloadBackend，
// 探针替换为可控替身。
static TestContext *MakeProbePathContext(StubCapabilityProbe *probe, ProbePathBackend **outBackend) {
    ProbePathBackend *backend = [ProbePathBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    [ctx.manager setValue:probe forKey:@"capabilityProbe"];
    if (outBackend) *outBackend = backend;
    return ctx;
}

// T38（性能 RED → GREEN）：能力探测**超时**后必须有限重试，绝不能永久降级为单连接。
// 旧代码：探测失败即 capabilityProbeCompleted + acceptRanges=NO ⇒ 任务单连接跑完，
// 既拿不到分段提速，也不会再探测（同代次内永久）。
static void TestCapabilityProbeTimeoutRetriesInsteadOfPermanentFallback(void) {
    StubCapabilityProbe *probe = [StubCapabilityProbe new];
    ProbePathBackend *backend = nil;
    TestContext *ctx = MakeProbePathContext(probe, &backend);
    int64_t total = 49565560;                       // 与现场样本同量级（8 段）
    backend.total = total;
    // 第 0 次探测超时；第 1 次起返回健康能力
    probe.capabilityForCall = ^ZZDownloadCapability *(NSInteger idx) {
        return idx == 0 ? ProbeTimeoutCapability() : ProbeSuccessCapability(total);
    };
    probe.completedCountProvider = ^NSInteger {
        return (NSInteger)((NSSet *)[ctx.manager valueForKey:@"capabilityProbeCompleted"]).count;
    };

    NSURL *url = [NSURL URLWithString:@"https://cdn.example.com/probe-timeout.mp4"];
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:url
                                                      folder:ctx.destFolder
                                               preferredName:@"probe-timeout"
                                                        etag:nil
                                                lastModified:nil
                                                acceptRanges:NO
                                              expectedLength:0];
    StateAfter(ctx, job, DownloadJobStateCompleted, 60);

    NSLog(@"T38 计数：探测次数=%ld 段数=%ld 已服务分段请求=%lu",
          (long)probe.calls, (long)job.segmentCount, (unsigned long)backend.servedStarts.count);
    Check(probe.calls >= 2,
          @"T38: 探测超时后必须重试探测（实际只调用了 %ld 次；旧实现在同代次内永不再探测）",
          (long)probe.calls);
    NSSet *completedSet = [NSMutableSet setWithSet:(NSMutableSet *)[ctx.manager valueForKey:@"capabilityProbeCompleted"]];
    NSInteger completedAtFirstCall = probe.completedCountAfterCall.count
        ? probe.completedCountAfterCall.firstObject.integerValue : -1;
    // 关键断言：第一次（超时）探测回调**当场**没有把任务标记为“探测已完成”——
    // 旧代码正是在这里立刻 capabilityProbeCompleted + acceptRanges=NO ⇒ 永久单连接。
    // 重试耗尽后允许标记（T39 覆盖有界性），但瞬时失败当场不得标记。
    Check(completedAtFirstCall == 0,
          @"T38: 瞬时失败当场不得标记探测已完成（第 1 次回调后 completed=%ld，期望 0）",
          (long)completedAtFirstCall);
    Check(job.state == DownloadJobStateCompleted,
          @"T38: 重试成功后任务完成（实际 state=%ld，错误：%@）", (long)job.state, job.errorText);
    Check(job.segmented && job.segmentCount >= 2,
          @"T38: 重试成功的那次探测让任务真正分段（实际 segmented=%d 段数=%ld）",
          (int)job.segmented, (long)job.segmentCount);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T38: 合并结果完整落盘（实际 %lld / %lld）", FileSize(job.destinationURL), total);
}

// T39（有界性）：探测**永远**超时时不得无界重试——重试次数必须有上限，
// 且耗尽后仍要能落地成单连接完成任务（绝不能因为探测失败而卡死或失败）。
static void TestCapabilityProbeTimeoutRetriesAreBounded(void) {
    StubCapabilityProbe *probe = [StubCapabilityProbe new];
    ProbePathBackend *backend = nil;
    TestContext *ctx = MakeProbePathContext(probe, &backend);
    int64_t total = 49565560;
    backend.total = total;
    probe.capabilityForCall = ^ZZDownloadCapability *(NSInteger idx) { return ProbeTimeoutCapability(); };

    NSURL *url = [NSURL URLWithString:@"https://cdn.example.com/probe-always-timeout.mp4"];
    DownloadJob *job = [ctx.manager enqueueItemWithSourceURL:url
                                                      folder:ctx.destFolder
                                               preferredName:@"probe-dead"
                                                        etag:nil
                                                lastModified:nil
                                                acceptRanges:NO
                                              expectedLength:0];
    StateAfter(ctx, job, DownloadJobStateCompleted, 90);

    NSLog(@"T39 计数：探测次数=%ld 段数=%ld 单连接=%d", (long)probe.calls,
          (long)job.segmentCount, (int)!job.segmented);
    Check(probe.calls <= 4,
          @"T39: 探测重试有界、无重试风暴（实际 %ld 次，期望 ≤4）", (long)probe.calls);
    Check(job.state == DownloadJobStateCompleted,
          @"T39: 重试耗尽后仍以单连接完成任务，不得卡死或失败（实际 state=%ld，错误：%@）",
          (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T39: 单连接兜底结果完整落盘（实际 %lld / %lld）", FileSize(job.destinationURL), total);
}

// T41（性能 RED → GREEN）：未拿到首字节的段，停滞判定窗口必须更快。
//
// 现场数据（2026-09-11 真实站点，408113/408157 各 5 轮交替对照）：
//   首字节窗口 8s（现状）：408113 中位 4.81 MB/s、2/5 达标；408157 中位 4.96、2/4
//   首字节窗口 6s（对照）：408113 中位 12.51 MB/s、**5/5 达标**；408157 中位 6.22、**5/5**
//   首字节窗口 3s（对照）：出现过 58.8s + 6 次重发 ⇒ 过于激进会招致连接 churn，不用
// 机理：被晾住的段要等满窗口才被发现；8s 窗口意味着每次被晾白等 8 秒。
// 「有字节」的段仍是 3s 窗口（RDSegmentStallThreshold 不动），只有「一个字节都没收到」
// 的段从 8s 收紧到 6s。
//
// 本用例：一段被晾、其余段健康，断言该段按 6 秒窗口被换连接重发。
// 量测口径：停滞检测挂在 1 秒粒度看门狗上（既有设计），"窗口 6s" 的合法触发
// 时刻 = 第一个 elapsed ≥ 6.0 的 tick，即 6.0–7.2s（实测 6.08s / 7.04s 两种相位
// 都出现过）；"窗口 8s" 则 ≥ 8.0s（历史 RED 实测 8.08s）。阈值取 7.5s 同时满足：
// 区分 6s/8s 窗口，且不受 tick 相位摆动的干扰（此前 6.8s 阈值卡在量化边缘会抖动）。
// 旧实现要等满 8 秒 ⇒ RED；6 秒窗口 ⇒ 6.0–7.2s ⇒ GREEN。
static void TestFirstByteStallWindowIsSixSeconds(void) {
    HoldableBackend *backend = [HoldableBackend new];
    TestContext *ctx = MakeHoldableContext(backend);
    int64_t total = 25165824;               // 24MB → 4 段
    int64_t lastStart = total - total / 4;  // 第 4 段起点
    __block NSInteger lastRangeRequests = 0;
    // 第一次请求该段：挂起（永远收不到首字节）；重发后的请求正常应答
    backend.shouldHold = ^BOOL(NSURLRequest *request) {
        if (RangeStart(request) == lastStart) return (lastRangeRequests++ == 0);
        return NO;
    };
    backend.script = CorrectSegmentScript(total, ^NSData *(int64_t start, int64_t end) {
        return MP4Body(end - start + 1);
    });

    NSDate *startedAt = [NSDate date];
    DownloadJob *job = EnqueueSegmented(ctx, @"/fbwindow.mp4", total);
    Check(job.segmented && job.segmentCount >= 4,
          @"T41: 前置——分段任务启动（%ld 段）", (long)job.segmentCount);

    // 等该段被换连接重发（第二、三次请求该段范围）或超时
    __block NSTimeInterval reissueAt = -1;
    BOOL ok = Wait(^BOOL {
        if (lastRangeRequests >= 2) {
            if (reissueAt < 0) reissueAt = -[startedAt timeIntervalSinceNow];
            return YES;
        }
        return NO;
    }, 12);
    Check(ok, @"T41: 被晾住的段被换连接重发（实际该段请求 %ld 次）", (long)lastRangeRequests);
    NSLog(@"T41 计数：重发时刻=%.2fs 该段请求=%ld 次", reissueAt, (long)lastRangeRequests);
    // 关键：必须在 6 秒窗口（+ 1 秒 tick 量化余量）内重发，而不是 8 秒窗口
    Check(reissueAt > 0 && reissueAt < 7.5,
          @"T41: 无首字节段的停滞窗口为 6 秒（实际在 %.2fs 才换连接；8 秒窗口会 ≥8.0s）",
          reissueAt);

    StateAfter(ctx, job, DownloadJobStateCompleted, 20);
    Check(job.state == DownloadJobStateCompleted,
          @"T41: 收紧窗口后任务仍正常完成（实际 state=%ld，错误：%@）", (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T41: 合并结果完整落盘（实际 %lld / %lld）", FileSize(job.destinationURL), total);
}

// 自适应吞吐回归：连续低速但没有 HTTP 错误时，也必须收缩并发窗口，
// 否则 CDN 只是“慢传”而非报错时，调度器永远维持 20 条连接。
static void TestAdaptiveSchedulerShrinksOnSustainedLowThroughput(void) {
    AdaptiveTransferScheduler *scheduler = [[AdaptiveTransferScheduler alloc] initWithInitialWindow:20 maximumWindow:20];
    for (NSInteger i = 0; i < 4; i++) [scheduler recordThroughput:400000.0 error:NO throttled:NO];
    Check(scheduler.window < 20,
          @"自适应调度：连续低吞吐样本应收缩连接窗口（实际 %ld）", (long)scheduler.window);
}

// MARK: - 「持续低速但仍有数据」后端（T42/T43：分段级自适应换连接）
//
// 慢段语义：以**高频**回调极小字节增量（每窗口有效速率 ≈ 1.9KB/s，远低于阈值）——
// 它"活着"，既不触发 3s 无字节 idle，也没有任何 HTTP 错误；只有按时间窗口统计
// 字节增量得到的有效速率能识别它。这正是真实现场"CDN 慢传"的形态（回调整密集、
// 速率极低）。其余段健康推进（0.9s 回调、约 800KB/s），用于断言：只重发慢段、
// 不误取消健康段、健康段各只请求一次。

@interface TrickleDelivery : NSObject
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURL *writeToURL;
@property (nonatomic, copy) void (^progress)(int64_t, int64_t, int64_t);
@property (nonatomic, copy) void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *);
@property (nonatomic, strong) HoldableDownloadTask *task;
@property (nonatomic, assign) int64_t rangeStart;
@property (nonatomic, assign) int64_t rangeLength;
@property (nonatomic, assign) int64_t delivered;
@property (nonatomic, assign) BOOL finished;
@end
@implementation TrickleDelivery
@end

@interface TrickleBackend : NSObject <RDDownloadBackend>
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *requests;         // 共享池路径
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *reissuedRequests; // 换连接路径
@property (nonatomic, assign) int64_t total;
@property (nonatomic, assign) int64_t slowRangeStart;        // 该 Range 起点为"慢段"
@property (nonatomic, assign) NSTimeInterval slowInterval;   // 慢段回调间隔（<3s，绝不触发 idle）
@property (nonatomic, assign) int64_t slowIncrement;         // 慢段每次回调增量
@property (nonatomic, assign) NSTimeInterval healthyInterval;
@property (nonatomic, assign) int64_t healthyIncrement;
@property (nonatomic, assign) BOOL reissueHealthy;     // 换连接后的新连接是否健康
@property (nonatomic, assign) BOOL releaseSlowSegment; // 置 YES：在途慢段下次回调直接补齐完成
@property (nonatomic, assign) NSInteger healthyInFlightCount;
// 每次慢段换连接重发发生时，"已启动但未完成"的健康段数量（顺延判定证据）
@property (nonatomic, strong) NSMutableArray<NSNumber *> *healthyInFlightAtSlowReissue;
@property (nonatomic, strong) NSMutableArray<HoldableDownloadTask *> *healthyTasks;
@property (nonatomic, strong) NSMutableArray<HoldableDownloadTask *> *slowTasks;
@end
@implementation TrickleBackend
- (instancetype)init {
    self = [super init];
    if (self) {
        _requests = [NSMutableArray array];
        _reissuedRequests = [NSMutableArray array];
        _total = 25165824;
        _slowInterval = 1.05; _slowIncrement = 2000;
        _healthyInterval = 0.9; _healthyIncrement = 720000;
        _reissueHealthy = YES;
        _healthyInFlightAtSlowReissue = [NSMutableArray array];
        _healthyTasks = [NSMutableArray array];
        _slowTasks = [NSMutableArray array];
    }
    return self;
}
- (BOOL)isSlowRequest:(NSURLRequest *)request { return RangeStart(request) == self.slowRangeStart; }
- (TrickleDelivery *)makeDelivery:(NSURLRequest *)request
                       writeToURL:(NSURL *)writeToURL
                         progress:(void (^)(int64_t, int64_t, int64_t))progress
                       completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    TrickleDelivery *d = [TrickleDelivery new];
    d.request = request; d.writeToURL = writeToURL; d.progress = progress; d.completion = completion;
    d.task = [HoldableDownloadTask new];
    int64_t start = 0, end = 0;
    if (ParseRangeHeader(request, &start, &end)) { d.rangeStart = start; d.rangeLength = end - start + 1; }
    return d;
}
- (void)finishDelivery:(TrickleDelivery *)d {
    if (d.finished) return;
    d.finished = YES;
    [MP4Body(d.rangeLength) writeToURL:d.writeToURL atomically:YES];
    if (d.progress) d.progress(d.rangeLength, d.rangeLength, d.rangeLength);
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:d.request.URL statusCode:206
                                                        HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{
        @"Content-Type": @"video/mp4",
        @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld",
                           d.rangeStart, d.rangeStart + d.rangeLength - 1, self.total],
        @"Content-Length": [NSString stringWithFormat:@"%lld", d.rangeLength]}];
    if (![self isSlowRequest:d.request]) self.healthyInFlightCount -= 1;
    d.completion(d.writeToURL, resp, nil);
}
- (void)pumpDelivery:(TrickleDelivery *)d
            interval:(NSTimeInterval)interval
           increment:(int64_t)increment
           completes:(BOOL)completes {
    if (d.finished || d.task.cancelled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (d.finished || d.task.cancelled) return;
        if (self.releaseSlowSegment && [self isSlowRequest:d.request]) { [self finishDelivery:d]; return; }
        int64_t remaining = d.rangeLength - d.delivered;
        int64_t step = MIN(increment, completes ? remaining : MAX((int64_t)1, remaining - 1));
        d.delivered += step;
        if (d.progress) d.progress(d.delivered, d.delivered, d.rangeLength);
        if (completes && d.delivered >= d.rangeLength) { [self finishDelivery:d]; return; }
        [self pumpDelivery:d interval:interval increment:increment completes:completes];
    });
}
- (void)runDelivery:(TrickleDelivery *)d healthy:(BOOL)healthy {
    if ([self isSlowRequest:d.request]) {
        [self.slowTasks addObject:d.task];
    } else {
        self.healthyInFlightCount += 1;
        [self.healthyTasks addObject:d.task];
    }
    [self pumpDelivery:d
              interval:(healthy ? self.healthyInterval : self.slowInterval)
             increment:(healthy ? self.healthyIncrement : self.slowIncrement)
             completes:healthy];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}
- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self.requests addObject:request];
    TrickleDelivery *d = [self makeDelivery:request writeToURL:writeToURL progress:progress completion:completion];
    [self runDelivery:d healthy:![self isSlowRequest:request]];
    return d.task;
}
- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request
                             writeToURL:(NSURL *)writeToURL
                               progress:(void (^)(int64_t, int64_t, int64_t))progress
                             completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    [self.reissuedRequests addObject:request];
    if ([self isSlowRequest:request]) [self.healthyInFlightAtSlowReissue addObject:@(self.healthyInFlightCount)];
    TrickleDelivery *d = [self makeDelivery:request writeToURL:writeToURL progress:progress completion:completion];
    [self runDelivery:d healthy:(![self isSlowRequest:request] || self.reissueHealthy)];
    return d.task;
}
@end

// T42（分段级自适应 RED → GREEN）：「连续低速但仍有数据」的段。
//
// 契约（现场形态：CDN 慢传——回调整密集、每窗口有效速率远低于阈值、无任何错误）：
//  · 只有该段被换连接重发；其余健康段不得被取消、各只请求一次；
//  · 池已超出全局连接预算时（没有空闲连接）重发必须顺延，等池回到预算内再做；
//  · 新连接健康时恰好重发 1 次（不得用陈旧低速计数在无新窗口证据时再重发）；
//  · 单段换连接次数有上限（3 次）；
//  · 最终文件完整合并。
static void TestSustainedSlowSegmentAdaptiveReissue(void) {
    TrickleBackend *backend = [TrickleBackend new];
    backend.slowRangeStart = backend.total - backend.total / 4; // 第 4 段（24MB → 4 段）
    backend.reissueHealthy = YES; // 换连接后的新连接健康：把该段按健康节奏送完
    TestContext *ctx = MakeHoldableContext(backend);

    DownloadJob *job = EnqueueSegmented(ctx, @"/slowseg.mp4", backend.total);
    Check(job.segmented && job.segmentCount >= 4,
          @"T42: 前置——分段任务启动（%ld 段）", (long)job.segmentCount);
    Check(Wait(^BOOL { return backend.requests.count == 4; }, 10),
          @"T42: 前置——4 个分段全部在途（实际 %lu）", (unsigned long)backend.requests.count);
    // 压缩全局连接窗口到 1：制造「没有空闲连接」的池超预算状态（4 段在途 > 窗口 1）。
    // 注意：自适应调度器会因健康段的高吞吐把窗口自动扩张回去（既有生产行为，
    // 有自己的回归测试），因此等待期间必须持续把窗口压回 1，维持被测的
    // 「池超预算」状态；两次压制之间至多翻倍一次（1→2），4 段在途仍超预算。
    id scheduler = [ctx.manager valueForKey:@"transferScheduler"];
    Check(scheduler != nil, @"T42: 可访问连接窗口调度器");
    [(id)scheduler setValue:@(1) forKey:@"window"];
    // 顺延观察：池超预算期间（健康段在途）不得重发；健康段完成、池回到预算内
    // 后才允许重发。循环退出条件＝重发已发生（或 15s 超时）。
    Wait(^BOOL {
        [(id)scheduler setValue:@(1) forKey:@"window"]; // 维持「池超预算」状态
        return backend.reissuedRequests.count >= 1;
    }, 15);
    NSLog(@"T42 计数：换连接=%lu 顺延记录=%lu 健康段任务=%lu 慢段任务=%lu",
          (unsigned long)backend.reissuedRequests.count,
          (unsigned long)backend.healthyInFlightAtSlowReissue.count,
          (unsigned long)backend.healthyTasks.count,
          (unsigned long)backend.slowTasks.count);
    // 没有空闲连接时顺延：慢段重发发生时，池必须已回到预算内（健康段全部完成）
    Check(backend.healthyInFlightAtSlowReissue.count == 1 &&
          [backend.healthyInFlightAtSlowReissue.firstObject integerValue] == 0,
          @"T42: 池超预算期间重发被顺延（重发时在途健康段数=%@，期望 0＝等池回到预算内才重发）",
          backend.healthyInFlightAtSlowReissue.firstObject);

    StateAfter(ctx, job, DownloadJobStateCompleted, 40);
    Check(job.state == DownloadJobStateCompleted,
          @"T42: 低速段经「顺延 + 恰好一次换连接」后任务完成（实际 state=%ld，错误：%@）",
          (long)job.state, job.errorText);

    Check(backend.reissuedRequests.count == 1,
          @"T42: 新连接健康时慢段恰好换连接 1 次，无陈旧计数驱动的重试风暴（实际 %ld 次）",
          (long)backend.reissuedRequests.count);
    BOOL onlySlow = YES;
    for (NSURLRequest *request in backend.reissuedRequests)
        if (RangeStart(request) != backend.slowRangeStart) onlySlow = NO;
    Check(onlySlow, @"T42: 换连接只发生在慢段（实际 %lu 次中含非慢段）",
          (unsigned long)backend.reissuedRequests.count);
    NSInteger healthyRequests = 0;
    for (NSURLRequest *request in backend.requests)
        if (RangeStart(request) != backend.slowRangeStart) healthyRequests++;
    Check(healthyRequests == 3,
          @"T42: 健康段各只请求一次、未被取消重发（实际 %ld 次）", (long)healthyRequests);
    NSInteger cancelledHealthy = 0;
    for (HoldableDownloadTask *task in backend.healthyTasks) if (task.cancelled) cancelledHealthy++;
    Check(cancelledHealthy == 0,
          @"T42: 其余健康分段的在途任务从未被取消（实际取消 %ld 个）", (long)cancelledHealthy);

    Check((NSInteger)backend.reissuedRequests.count <= 3,
          @"T42: 单段换连接次数有上限（实际 %ld ≤ 3）", (long)backend.reissuedRequests.count);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == backend.total,
          @"T42: 合并结果完整落盘（实际 %lld / %lld）", FileSize(job.destinationURL), backend.total);
}

// T43（有界性）：新连接无改善时必须停止继续重试——慢段换连接次数恰为上限 3，
// 耗尽后即使持续低速也不再重发（无重试风暴）；释放后在途连接仍能把任务完整合并
//（有界停试 ≠ 卡死用户下载）。
static void TestSustainedSlowSegmentReissueCapAndNoStorm(void) {
    TrickleBackend *backend = [TrickleBackend new];
    backend.slowRangeStart = backend.total - backend.total / 4;
    backend.reissueHealthy = NO; // 新连接无改善：依旧慢速涓流
    TestContext *ctx = MakeHoldableContext(backend);
    NSDate *startedAt = [NSDate date];
    DownloadJob *job = EnqueueSegmented(ctx, @"/slowcap.mp4", backend.total);
    Check(job.segmented && job.segmentCount >= 4,
          @"T43: 前置——分段任务启动（%ld 段）", (long)job.segmentCount);

    // 与 T34 同理：换连接的调度与任务级看门狗存在竞速，不能断言"恰好等于上限 3"。
    // 守住两个方向：**不得超过上限 3**（有界停试），且**至少发生过 1 次**（确实在推进）。
    Wait(^BOOL { return backend.reissuedRequests.count >= 3; }, 60);
    NSLog(@"T43 计数：换连接=%lu（%.1fs 时）",
          (unsigned long)backend.reissuedRequests.count, -[startedAt timeIntervalSinceNow]);
    Check(backend.reissuedRequests.count <= 3,
          @"T43: 慢段换连接次数不得超过上限 3（实际 %ld）", (long)backend.reissuedRequests.count);
    Check(backend.reissuedRequests.count >= 1,
          @"T43: 慢段确实发生过换连接（实际 %ld）", (long)backend.reissuedRequests.count);
    Wait(^BOOL { return NO; }, 8.0); // 观察窗
    Check(backend.reissuedRequests.count <= 3,
          @"T43: 上限耗尽后停止重试，8s 观察窗内无第 4 次换连接（实际 %ld 次，上限 3）",
          (long)backend.reissuedRequests.count);
    backend.releaseSlowSegment = YES;
    StateAfter(ctx, job, DownloadJobStateCompleted, 30);
    Check(job.state == DownloadJobStateCompleted,
          @"T43: 停止重试后在途连接完成任务（实际 state=%ld，错误：%@）", (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == backend.total,
          @"T43: 合并结果完整落盘（实际 %lld / %lld）", FileSize(job.destinationURL), backend.total);
}

// MARK: - T46「换连接后的首字节窗口」后端
//
// 代码级缺陷：`updateSegmentProgressForJob` 把每段字节以 MAX(旧值, written) 累计进
// `segmentBytes[job][idx]`，而换连接重发的入口 `recordSegmentStartForJob` **只重置时间基准、
// 不重置字节**。于是 `detectStalledSegmentsForJob` 里
//     received = segmentBytes[job][idx]; limit = received>0 ? 3s : 6s
// 对**刚换上、其实一个字节都没收到的新连接**也判定为 3s「有字节」窗口 ⇒ 新连接被提前取消，
// 每段 3 次重发额度在无证据的情况下被烧掉（正是"不要在换连接后自我否定"要防的那件事）。
//
// 本用例：目标段旧尝试已收到字节后被晾（走 3s 有字节判定 → 合理换连接）；
// 换新连接后首字节故意延迟 4.6s 才到（落在 3s 与 6s 之间）。断言新连接在 4.4s 内
// **不得**被再次取消——旧实现会在约 3.0–3.6s 就发第 3 次请求 ⇒ RED。

@interface FirstByteAttempt : NSObject
@property (nonatomic, strong) HoldableDownloadTask *task;
@property (nonatomic, assign) int64_t rangeStart;
@property (nonatomic, assign) int64_t rangeLength;
@property (nonatomic, assign) BOOL finished;
@end
@implementation FirstByteAttempt
@end

@interface FirstByteAfterReissueBackend : NSObject <RDDownloadBackend>
@property (nonatomic, assign) int64_t total;
// 全部请求数（含第一次尝试与所有重发）：目标段的请求计数就是"该段被取消了几次"的直接证据
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *targetRequests;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *targetRequestTimes;   // 相对首个请求
@property (nonatomic, strong) NSDate *firstRequestAt;
@property (nonatomic, assign) int64_t targetStart;
@property (nonatomic, assign) NSTimeInterval reissueFirstByteDelay;   // 换连接后首字节延迟（默认 4.6s）
@property (nonatomic, assign) int64_t targetFirstAttemptBytes;        // 旧尝试先收到的字节（默认 200KB）
@end

@implementation FirstByteAfterReissueBackend
- (instancetype)init {
    self = [super init];
    if (self) {
        _total = 25165824;
        _targetRequests = [NSMutableArray array];
        _targetRequestTimes = [NSMutableArray array];
        _reissueFirstByteDelay = 5.0;
        _targetFirstAttemptBytes = 200000;
    }
    return self;
}
- (BOOL)isTarget:(NSURLRequest *)request { return RangeStart(request) == self.targetStart; }

- (void)respond:(NSURLRequest *)request writeToURL:(NSURL *)writeToURL
       progress:(void (^)(int64_t, int64_t, int64_t))progress
     completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion
        attempt:(FirstByteAttempt *)attempt {
    int64_t start = 0, end = 0;
    ParseRangeHeader(request, &start, &end);
    int64_t length = end - start + 1;
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:206
                                                        HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{
        @"Content-Type": @"video/mp4",
        @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, self.total],
        @"Content-Length": [NSString stringWithFormat:@"%lld", length]}];
    void (^finish)(void) = ^{
        if (attempt.finished) return;
        attempt.finished = YES;
        [MP4Body(length) writeToURL:writeToURL atomically:YES];
        if (progress) progress(length, length, length);
        completion(writeToURL, resp, nil);
    };
    // 分段推进：把区间在 steps 次回调内送完（速率远高于 250KB/s 低速阈值，不会触发低速换连接）
    NSInteger steps = 4;
    __block NSInteger step = 0;
    __block int64_t delivered = 0;
    // 注意：tick 必须是 __block，否则块字面量在初始化前就捕获自身 → dispatch_after 拷贝到野指针
    __block void (^tick)(void) = ^{
        if (attempt.finished || attempt.task.cancelled) return;
        step += 1;
        delivered = length * step / steps;
        if (progress) progress(delivered, delivered, length);
        if (delivered >= length) { finish(); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), tick);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), tick);
}

- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}

- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    FirstByteAttempt *attempt = [FirstByteAttempt new];
    attempt.task = [HoldableDownloadTask new];
    int64_t start = 0, end = 0;
    ParseRangeHeader(request, &start, &end);
    attempt.rangeStart = start;
    attempt.rangeLength = end - start + 1;
    if (![self isTarget:request]) {
        // 健康段：0.9s 一次进度（低于 3s idle 窗口），速率 300KB/s（高于 250KB/s 低速阈值）
        // 注意：必须强持有 attempt——manager 只保留 task，弱引用会在回调前被释放。
        __block int64_t delivered = 0;
        __block void (^pump)(void);
        FirstByteAttempt *strongAttempt = attempt;
        pump = ^{
            FirstByteAttempt *a = strongAttempt;
            if (!a || a.finished || a.task.cancelled) return;
            delivered += 300000;
            if (delivered >= a.rangeLength) {
                if (progress) progress(a.rangeLength, a.rangeLength, a.rangeLength);
                NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:206
                                                                    HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{
                    @"Content-Type": @"video/mp4",
                    @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lld",
                                       a.rangeStart, a.rangeStart + a.rangeLength - 1, self.total],
                    @"Content-Length": [NSString stringWithFormat:@"%lld", a.rangeLength]}];
                [MP4Body(a.rangeLength) writeToURL:writeToURL atomically:YES];
                a.finished = YES;
                completion(writeToURL, resp, nil);
                return;
            }
            if (progress) progress(delivered, delivered, a.rangeLength);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), pump);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), pump);
        return attempt.task;
    }
    // 目标段：记录请求次数与相对时刻（次数 = 该段被取消了几次）
    if (!self.firstRequestAt) self.firstRequestAt = [NSDate date];
    [self.targetRequests addObject:request];
    [self.targetRequestTimes addObject:@(-[self.firstRequestAt timeIntervalSinceNow])];
    if (self.targetRequests.count == 1) {
        // 旧尝试：先给一小段字节（让它落入 3s「有字节」判定），随后永久停住
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (attempt.finished || attempt.task.cancelled) return;
            if (progress) progress(self.targetFirstAttemptBytes, self.targetFirstAttemptBytes, attempt.rangeLength);
        });
        return attempt.task;
    }
    // 换连接后的新连接：首字节延迟 reissueFirstByteDelay 才到，之后正常送完
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(self.reissueFirstByteDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self respond:request writeToURL:writeToURL progress:progress completion:completion attempt:attempt];
    });
    return attempt.task;
}

- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request
                             writeToURL:(NSURL *)writeToURL
                               progress:(void (^)(int64_t, int64_t, int64_t))progress
                             completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    // 换连接通道与共享池走同一套语义：目标段第 2 次及以后的请求都视为"新连接"
    return [self rd_startRequest:request writeToURL:writeToURL progress:progress completion:completion];
}
@end

static void TestFreshConnectionGetsFirstByteWindow(void) {
    FirstByteAfterReissueBackend *backend = [FirstByteAfterReissueBackend new];
    int64_t total = backend.total;
    backend.targetStart = 0;                 // 目标段 = 第 0 段（起点 0）
    TestContext *ctx = MakeHoldableContext(backend);
    NSDate *startedAt = [NSDate date];
    DownloadJob *job = EnqueueSegmented(ctx, @"/firstbyte-window.mp4", total);
    Check(job.segmented && job.segmentCount >= 2,
          @"T46: 前置——分段任务启动（%ld 段）", (long)job.segmentCount);

    BOOL reissued = Wait(^BOOL { return backend.targetRequests.count >= 2; }, 15);
    Check(reissued, @"T46: 目标段旧尝试已有字节后被晾，按 3s「有字节」窗口换连接重发（实际 %ld 次请求）",
          (long)backend.targetRequests.count);
    NSTimeInterval reissueAt = backend.targetRequestTimes.lastObject.doubleValue;
    NSLog(@"T46 计数：重发时刻=%.2fs 请求数=%ld", reissueAt, (long)backend.targetRequests.count);

    // 换新连接后首字节要 5.0s 才到（介于 3s 与 6s 之间）。判定口径必须看"本次尝试"：
    //  · 正确（本次尝试零字节 ⇒ 6s 首字节窗口）：新连接在 6s 内不得被取消，且 5.0s 的
    //    首字节会刷新进度基准 ⇒ 永远不会再被取消；
    //  · 错误（沿用旧尝试累计字节 ⇒ 3s 窗口）：新连接会在重发后约 3.0–4.5s 被再次取消
    //    （停滞检测挂在 1s 粒度看门狗上，实测有约 1s 的 tick 漂移，故取 5.0s 为界）。
    // 断言写法对 tick 漂移鲁棒：要么根本没有第 3 次请求，要么第 3 次请求距重发 ≥5.0s。
    Wait(^BOOL { return NO; }, 6.0);
    NSLog(@"T46 计数：观察窗结束 %.2fs，目标段请求=%ld 次（时刻 %@）",
          -[startedAt timeIntervalSinceNow], (long)backend.targetRequests.count,
          [backend.targetRequestTimes componentsJoinedByString:@","]);
    NSInteger targetCalls = backend.targetRequests.count;
    BOOL windowRespected = (targetCalls == 2) ||
        (targetCalls >= 3 &&
         backend.targetRequestTimes[2].doubleValue - backend.targetRequestTimes[1].doubleValue >= 5.0);
    Check(windowRespected,
          @"T46: 新连接必须按「本次尝试零字节」用 6s 首字节窗口，不得沿用旧尝试累计字节提前取消"
          @"（实际请求时刻 %@；旧实现第 3 次请求出现在重发后约 3.0–4.5s）",
          [backend.targetRequestTimes componentsJoinedByString:@","]);

    StateAfter(ctx, job, DownloadJobStateCompleted, 40);
    Check(job.state == DownloadJobStateCompleted,
          @"T46: 目标段随后正常收完，任务完成（实际 state=%ld，错误：%@）", (long)job.state, job.errorText);
    Check(FileExists(job.destinationURL) && FileSize(job.destinationURL) == total,
          @"T46: 合并结果完整落盘（实际 %lld / %lld）", FileSize(job.destinationURL), total);
}

// MARK: - T44/T45 临时目录归属（跨实例误删在途分段的确定性复现与保护）
//
// 现实缺陷（2026-09-11 实测，4 进程并发下载 3/4 失败）：
//   `cleanupOrphanTempDirs`（DownloadManager.m）只以**本实例** self.jobs 判断目录是否存活，
//   于是同用户另一个实例启动时，会把仍在传输中的分段目录当孤儿删掉，在途任务随即以
//   `分段 N 重试失败："CFNetworkDownload_*.tmp" couldn't be moved to "<job-id>" …` 失败。
// 本用例用**本地受控服务 + 独立子进程 + 专用临时根**确定性复现，并对修复后的归属规则做断言。
// 绝不对用户真实下载目录做破坏性操作：临时根固定在仓库 build/ 下。

static NSString *RDBuildTestsRoot(void) {
    NSString *exe = [[NSProcessInfo processInfo] arguments].firstObject ?: @"";
    NSString *buildDir = [[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    if (buildDir.length == 0) buildDir = NSTemporaryDirectory();
    return [buildDir stringByAppendingPathComponent:@"tests-crossinstance"];
}

@interface RDChildProcess : NSObject
@property (nonatomic, strong) NSTask *task;
@property (nonatomic, strong) NSMutableString *output;
@property (nonatomic, assign) BOOL ended;
@end
@implementation RDChildProcess
@end

static RDChildProcess *RDSpawnTestChild(NSArray<NSString *> *args) {
    RDChildProcess *child = [RDChildProcess new];
    child.output = [NSMutableString string];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:[[NSProcessInfo processInfo] arguments].firstObject];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    RDChildProcess *c = child;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length) @synchronized (c) { [c.output appendString:text]; }
    };
    task.terminationHandler = ^(NSTask *t) { c.ended = YES; };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"FAIL: 测试子进程启动失败：%@", error.localizedDescription);
        return nil;
    }
    child.task = task;
    return child;
}

static NSString *RDChildOutput(RDChildProcess *child) {
    @synchronized (child) { return [child.output copy]; }
}

static NSString *RDWaitForChildLine(RDChildProcess *child, NSString *prefix, double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) {
        for (NSString *line in [RDChildOutput(child) componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:prefix]) return [line substringFromIndex:prefix.length];
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return nil;
}

static void RDWaitForChildExit(RDChildProcess *child, double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!child.ended && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

// 子进程模式 A：用**生产** SessionDownloadBackend + 生产 DownloadManager 做真实分段下载。
// 参数：--rd-child-download <tempRoot> <url> <destDir> <storeSuite>
static int RDRunChildDownload(NSArray<NSString *> *args) {
    if (args.count < 6) { printf("RD-CHILD-ARGS-MISSING\n"); return 2; }
    NSString *root = args[2], *urlString = args[3], *destDir = args[4], *suite = args[5];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:defaults];
    SessionDownloadBackend *backend = [SessionDownloadBackend new];
    [backend setValue:[LocalFixturePolicy new] forKey:@"urlPolicy"];
    DownloadManager *manager = [[DownloadManager alloc] initWithBackend:backend
                                                              tempRoot:[NSURL fileURLWithPath:root]
                                                                 store:store];
    manager.rd_enableEndpointResolution = NO;
    manager.urlPolicy = [LocalFixturePolicy new];
    // 能力探测持有**独立**的 URLPolicy 实例，必须一并放行本地夹具。
    id probe = [manager valueForKey:@"capabilityProbe"];
    if (probe) [probe setValue:[LocalFixturePolicy new] forKey:@"urlPolicy"];
    DownloadJob *job = [manager enqueueItemWithSourceURL:[NSURL URLWithString:urlString]
                                                  folder:[NSURL fileURLWithPath:destDir]
                                           preferredName:@"cross"
                                           sourcePageURL:@"https://page.example.com/watch"
                                            resourceKind:DownloadResourceVideo
                                          expectedLength:0];
    printf("RD-CHILD-JOBDIR %s\n", job.tempRootURL.path.UTF8String);
    fflush(stdout);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
    while (job.state != DownloadJobStateCompleted && job.state != DownloadJobStateFailed &&
           job.state != DownloadJobStateCancelled && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    int64_t size = FileSize(job.destinationURL);
    printf("RD-CHILD-STATE %ld bytes=%lld error=%s\n", (long)job.state, size,
           (job.errorText ?: @"-").UTF8String);
    fflush(stdout);
    return (job.state == DownloadJobStateCompleted && size > 0) ? 0 : 1;
}

// 子进程模式 B：只做一件事——用同一个临时根构造 DownloadManager（init 会执行孤儿清理）。
static int RDRunChildCleanup(NSArray<NSString *> *args) {
    if (args.count < 4) { printf("RD-CHILD-ARGS-MISSING\n"); return 2; }
    NSString *root = args[2], *suite = args[3];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:defaults];
    DownloadManager *manager = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                              tempRoot:[NSURL fileURLWithPath:root]
                                                                 store:store];
    manager.rd_enableEndpointResolution = NO;
    printf("RD-CHILD-CLEANUP-DONE\n");
    fflush(stdout);
    return 0;
}

static DownloadManager *MakeOwnershipManager(NSURL *root, NSURL *dest, id<RDDownloadBackend> backend, NSString *suite) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:defaults];
    DownloadManager *manager = [[DownloadManager alloc] initWithBackend:backend
                                                               tempRoot:root
                                                                  store:store];
    manager.rd_enableEndpointResolution = NO;
    return manager;
}

// T44：跨实例清理不得删除另一实例在途的分段目录（受控服务 + 独立子进程 + 专用临时根）
static void TestCrossInstanceCleanupKeepsInFlightTempDir(void) {
    NSString *base = TestServerBase();
    if (!base) { NSLog(@"SKIP: T44 需要 ZZ_DL_TEST_SERVER"); return; }
    NSString *root = [RDBuildTestsRoot() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"t44-%d", (int)getpid()]];
    NSString *dest = [root stringByAppendingPathComponent:@"dest"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    // 清掉上次运行残留（仅限本用例自己的专用根）
    for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil])
        [[NSFileManager defaultManager] removeItemAtPath:[root stringByAppendingPathComponent:entry] error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *url = [base stringByAppendingString:@"/slow-range-video"];
    RDChildProcess *a = RDSpawnTestChild(@[@"--rd-child-download", root, url, dest,
                                           @"com.sevenzz.tests.t44a"]);
    Check(a != nil, @"T44: 子进程 A 启动（受控本地服务，专用临时根 %@）", root);
    NSString *jobDir = RDWaitForChildLine(a, @"RD-CHILD-JOBDIR ", 20);
    Check(jobDir.length > 0 && FileExists([NSURL fileURLWithPath:jobDir]),
          @"T44: 子进程 A 已在途并创建自己的分段目录（%@）", jobDir ?: @"（未报告）");
    NSInteger partsBefore = 0;
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:jobDir error:nil])
        if ([f hasSuffix:@".part"] || [f hasSuffix:@".tmp"]) partsBefore++;
    NSLog(@"T44 计数：A 的在途目录内容 %ld 项", (long)partsBefore);

    // 子进程 B：同用户同临时根的**另一个实例**启动 → init 执行孤儿清理
    RDChildProcess *b = RDSpawnTestChild(@[@"--rd-child-cleanup", root, @"com.sevenzz.tests.t44b"]);
    Check(b != nil, @"T44: 子进程 B 启动（另一实例）");
    RDWaitForChildExit(b, 60);
    NSLog(@"T44 计数：B 退出码=%d，输出=%@", b.task.terminationStatus,
          [RDChildOutput(b) stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);

    // 核心断言：A 仍在传输，其目录绝不能被 B 的清理删除
    Check(FileExists([NSURL fileURLWithPath:jobDir]),
          @"T44: 另一实例启动清理后，A 的在途分段目录仍存在（现实缺陷：会被当孤儿误删）");

    RDWaitForChildExit(a, 150);
    NSString *aOut = RDChildOutput(a);
    Check([aOut containsString:@"RD-CHILD-STATE 6"] ,
          @"T44: 子进程 A 的下载未被跨实例清理破坏，正常完成（输出：%@）",
          [aOut stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    Check(a.task.terminationStatus == 0,
          @"T44: 子进程 A 退出码为 0（实际 %d）", a.task.terminationStatus);
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
}

// T45：临时目录归属规则（进程内确定性；含活跃保留 / 孤儿回收 / 启动竞争 / 路径边界 /
//      单进程多任务 / 中断恢复）
static void TestTempDirOwnershipRules(void) {
    NSString *base = [RDBuildTestsRoot() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"t45-%d", (int)getpid()]];
    NSString *rootPath = [base stringByAppendingPathComponent:@"tmp"];
    NSString *destPath = [base stringByAppendingPathComponent:@"dest"];
    NSString *externalPath = [base stringByAppendingPathComponent:@"external"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:base error:nil];
    for (NSString *dir in @[rootPath, destPath, externalPath])
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    // 1) 活跃目录保留：实例 A 有在途任务 → 另一实例 B 构造（触发清理）→ A 的目录必须还在
    HoldableBackend *holdA = [HoldableBackend new];
    holdA.shouldHold = ^BOOL(NSURLRequest *request) { return YES; };   // 永久在途
    DownloadManager *a = MakeOwnershipManager(root, dest, holdA, @"com.sevenzz.tests.t45a");
    DownloadJob *jobA1 = EnqueueVideoFrom(a, dest, @"/own-a1.mp4");
    DownloadJob *jobA2 = EnqueueVideoFrom(a, dest, @"/own-a2.mp4");
    Check(FileExists(jobA1.tempRootURL) && FileExists(jobA2.tempRootURL),
          @"T45-1: 实例 A 的两个任务各自创建了分段目录");
    DownloadManager *b = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t45b");
    Check(b != nil, @"T45-1: 实例 B 构造完成（init 已执行孤儿清理）");
    Check(FileExists(jobA1.tempRootURL) && FileExists(jobA2.tempRootURL),
          @"T45-1: 活跃实例的在途目录不被另一实例删除（单进程多任务不回退）");

    // 2) 崩溃孤儿回收：无归属锁且年龄超过宽限期的目录，必须可被回收
    NSString *orphan = [rootPath stringByAppendingPathComponent:
                        @"0BADC0DE-0000-4000-8000-00000000C0DE"];
    [fm createDirectoryAtPath:orphan withIntermediateDirectories:YES attributes:nil error:nil];
    [@"stale" writeToFile:[orphan stringByAppendingPathComponent:@"000.part"] atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
    [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-600]}
         ofItemAtPath:orphan error:nil];
    DownloadManager *c = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t45c");
    Check(c != nil, @"T45-2: 实例 C 构造完成");
    Check(!FileExists([NSURL fileURLWithPath:orphan]),
          @"T45-2: 崩溃失主的陈旧目录被安全回收（否则磁盘永远不回收）");

    // 3) 启动竞争：刚创建、尚未取得归属锁的目录必须保留（不得与创建/恢复竞态）
    NSString *racing = [rootPath stringByAppendingPathComponent:
                        @"0BADC0DE-0000-4000-8000-0000000000FF"];
    [fm createDirectoryAtPath:racing withIntermediateDirectories:YES attributes:nil error:nil];
    DownloadManager *d = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t45d");
    Check(d != nil, @"T45-3: 实例 D 构造完成");
    Check(FileExists([NSURL fileURLWithPath:racing]),
          @"T45-3: 疑似“创建/认领进行中”的新目录被保留（不与创建竞态）");
    Check(FileExists(jobA1.tempRootURL) && FileExists(jobA2.tempRootURL),
          @"T45-3: 反复清理不误删活跃实例目录");

    // 4) 路径边界与符号链接：根外的兄弟目录、根内的符号链接、普通文件一律不动
    NSString *linkPath = [rootPath stringByAppendingPathComponent:@"escape-link"];
    [fm createSymbolicLinkAtPath:linkPath withDestinationPath:externalPath error:nil];
    NSString *plain = [rootPath stringByAppendingPathComponent:@"plain.txt"];
    [@"x" writeToFile:plain atomically:YES encoding:NSUTF8StringEncoding error:nil];
    DownloadManager *e = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t45e");
    Check(e != nil, @"T45-4: 实例 E 构造完成");
    Check(FileExists([NSURL fileURLWithPath:externalPath]),
          @"T45-4: 临时根之外的目录不被触碰（路径边界）");
    Check(FileExists([NSURL fileURLWithPath:linkPath]),
          @"T45-4: 根内指向外部的符号链接不被删除（不跟随、不越界）");
    Check(FileExists([NSURL fileURLWithPath:plain]),
          @"T45-4: 根内普通文件不被当作孤儿目录删除");

    // 5) 中断恢复：退出时标记中断 → 新实例恢复该任务 → 其分段目录不得在恢复前被清理
    NSString *suiteF = @"com.sevenzz.tests.t45f";
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suiteF];
    NSUserDefaults *defaultsF = [[NSUserDefaults alloc] initWithSuiteName:suiteF];
    DownloadStore *storeF = [[DownloadStore alloc] initWithUserDefaults:defaultsF];
    DownloadManager *f1 = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                          tempRoot:root store:storeF];
    f1.rd_enableEndpointResolution = NO;
    [f1 beginBatchEnqueue];
    DownloadJob *resumable = EnqueueVideoFrom(f1, dest, @"/resume-me.mp4");
    [f1 endBatchEnqueue];
    [f1 markInterruptedOnTerminate];
    Check(FileExists(resumable.tempRootURL), @"T45-5: 中断任务的分段目录存在待恢复");
    DownloadStore *restoredStore = [[DownloadStore alloc] initWithUserDefaults:defaultsF];
    DownloadManager *f2 = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                          tempRoot:root store:restoredStore];
    f2.rd_enableEndpointResolution = NO;
    __block DownloadJob *restored = nil;
    for (DownloadJob *candidate in f2.allJobs)
        if ([candidate.identifier isEqualToString:resumable.identifier]) restored = candidate;
    Check(restored != nil, @"T45-5: 新实例恢复了中断任务（清理必须先于恢复完成时也不误删）");
    Check(FileExists(resumable.tempRootURL),
          @"T45-5: 中断恢复任务的分段目录未被启动清理删除（清理与恢复并发安全）");

    [[NSFileManager defaultManager] removeItemAtPath:base error:nil];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.sevenzz.tests.t45a"];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.sevenzz.tests.t45b"];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.sevenzz.tests.t45c"];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.sevenzz.tests.t45d"];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.sevenzz.tests.t45e"];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suiteF];
}

// MARK: - 第四阶段：独立验收 R1–R4 正式行为回归
//
// 独立验收（outputs/第三阶段独立验收与返工要求-2026-09-12.md）用隔离探针复现四类缺陷：
//   R1 归属检查与删除不原子 —— 检查后另一实例认领，目录仍被删
//   R2 认领失败仍恢复任务，公共取消/恢复路径会动他人目录与共享恢复记录
//   R3 manager 析构不关闭所有权文件描述符（长期运行进程内锁泄漏）
//   R4 旧尝试迟到 progress 污染新尝试的 attempt 字节 / last-progress / 累计口径
// 这里把同样的行为强度转成正式回归：先在当前代码取 RED（真实 exit=1），修复后 GREEN。
// 只使用专用测试沙盒目录与内存 store 替身，绝不触碰用户下载记录；跨进程用例用自建子进程。

// 仅本测试文件使用的访问通道（不改变任何生产可见接口）
@interface DownloadManager (Phase4TestAccess)
- (BOOL)claimTempDirectoryForJob:(DownloadJob *)job;
- (void)releaseTempDirClaimForPath:(NSString *)path;
- (BOOL)ownsTempDirectoryAtPath:(NSString *)path;
- (BOOL)tempDirectoryIsClaimedByAnotherInstance:(NSURL *)directory;
- (void)cleanupOrphanTempDirs;
- (void)removeTempRootForJob:(DownloadJob *)job;
- (void)reissueSegmentOnFreshConnectionForJob:(DownloadJob *)job index:(NSInteger)index reason:(NSString *)reason;
@end

// 可在「归属检查点」注入另一实例认领的清理器：可控交错，不靠 sleep / 宽限期碰运气
@interface Phase4CheckingManager : DownloadManager
@property (nonatomic, copy) void (^afterOwnershipCheck)(void);
@end
@implementation Phase4CheckingManager
- (BOOL)tempDirectoryIsClaimedByAnotherInstance:(NSURL *)directory {
    BOOL held = [super tempDirectoryIsClaimedByAnotherInstance:directory];
    if (!held && self.afterOwnershipCheck) self.afterOwnershipCheck();
    return held;
}
@end

// 内存中断记录 + 删除/落盘调用计数（验证"不得清除/改写另一实例的恢复记录"）
@interface Phase4RecordingStore : DownloadStore
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *records;
@property (nonatomic, assign) NSInteger removedInterruptedCount;
@property (nonatomic, assign) NSInteger finishedRecordCount;
@property (nonatomic, assign) NSInteger setInterruptedCount;
@end
@implementation Phase4RecordingStore
- (NSDictionary<NSString *, NSDictionary *> *)interruptedRecords { return self.records; }
- (NSArray<NSDictionary<NSString *, id> *> *)finishedJobRecords { return @[]; }
- (void)recordFinishedJob:(NSDictionary<NSString *, id> *)record { self.finishedRecordCount += 1; }
- (void)removeInterruptedRecord:(NSString *)identifier { self.removedInterruptedCount += 1; }
- (void)setInterruptedRecords:(NSDictionary<NSString *, NSDictionary *> *)records { self.setInterruptedCount += 1; }
@end

static NSString *RDPhase4Root(NSString *tag) {
    NSString *exe = [[NSProcessInfo processInfo] arguments].firstObject ?: @"";
    NSString *buildDir = [[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    if (buildDir.length == 0) buildDir = NSTemporaryDirectory();
    return [[buildDir stringByAppendingPathComponent:@"tests-crossinstance"]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"p4-%@-%d", tag, (int)getpid()]];
}

static Phase4RecordingStore *MakeOwnershipStore(NSString *suite) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    return [Phase4RecordingStore new];
}

// 测试观测口：三类字节口径 + last-progress（经 KVC 读取生产私有容器，不改变生产接口）
static NSNumber *RDAttemptByte(DownloadManager *manager, DownloadJob *job, NSNumber *index) {
    NSDictionary *all = [manager valueForKey:@"segmentAttemptBytes"];
    NSDictionary *perJob = all[job.identifier];
    return perJob[index];
}
static int64_t RDAttemptByteValue(DownloadManager *manager, DownloadJob *job, NSNumber *index) {
    NSNumber *value = RDAttemptByte(manager, job, index);
    return value ? value.longLongValue : 0;
}
static int64_t RDCumulativeBytes(DownloadManager *manager, DownloadJob *job, NSNumber *index) {
    NSDictionary *all = [manager valueForKey:@"segmentBytes"];
    NSDictionary *perJob = all[job.identifier];
    NSNumber *value = perJob[index];
    return value ? value.longLongValue : 0;
}
static NSDate *RDProgressAt(DownloadManager *manager, DownloadJob *job, NSNumber *index) {
    NSDictionary *all = [manager valueForKey:@"segmentProgressAt"];
    NSDictionary *perJob = all[job.identifier];
    return perJob[index];
}

static DownloadJob *RDPhase4Job(NSURL *root) {
    DownloadJob *job = [DownloadJob new];
    job.identifier = NSUUID.UUID.UUIDString;
    job.tempRootURL = [root URLByAppendingPathComponent:job.identifier];
    return job;
}

static BOOL RDFdOpen(int fd) { return fd >= 0 && fcntl(fd, F_GETFD) != -1; }

static NSDictionary<NSString *, NSNumber *> *RDClaims(DownloadManager *manager) {
    return [manager valueForKey:@"tempDirClaimDescriptors"];
}

static BOOL RDClaimHeld(DownloadManager *manager, DownloadJob *job) {
    // 调用认领后用描述符表判断是否真的取得所有权（不依赖返回值，兼容 RED/GREEN 两版实现）
    [manager claimTempDirectoryForJob:job];
    NSString *path = [job.tempRootURL URLByStandardizingPath].path;
    return RDClaims(manager)[path] != nil;
}

static void RDAgeDirectory(NSURL *directory) {
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-600]}
                                     ofItemAtPath:directory.path error:nil];
}

// T47：归属检查与删除必须处于同一跨实例原子协议
//   a) 检查点处另一实例认领成功 ⇒ 清理必须放弃删除（目录保留、他人认领仍持有）
//   b) 认领在检查之前就成立 ⇒ 必须跳过（他人锁仍有效）
//   c) 无人认领的陈旧孤儿 ⇒ 仍要回收（不得因加锁而永不回收）
static void TestOwnershipReclaimIsAtomicWithDelete(void) {
    NSString *rootPath = RDPhase4Root(@"t47");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    // a) 竞态交错：检查后另一实例认领
    DownloadManager *owner = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.p47a");
    DownloadJob *jobA = RDPhase4Job(root);
    [owner claimTempDirectoryForJob:jobA];
    [owner releaseTempDirClaimForPath:jobA.tempRootURL.path];   // 上一实例已退出：无人持锁
    RDAgeDirectory(jobA.tempRootURL);
    Phase4CheckingManager *cleaner = [[Phase4CheckingManager alloc] initWithBackend:[MockDownloadBackend new]
                                                                           tempRoot:root store:MakeOwnershipStore(@"com.sevenzz.tests.p47a")];
    cleaner.rd_enableEndpointResolution = NO;
    __block BOOL injected = NO;
    cleaner.afterOwnershipCheck = ^{ injected = RDClaimHeld(owner, jobA); };
    [cleaner cleanupOrphanTempDirs];
    Check(injected, @"T47a: 前置——归属检查点处另一实例认领成功（竞态条件成立）");
    Check(FileExists(jobA.tempRootURL),
          @"T47a: 检查后认领的目录不得被清理删除（R1：认领/孤儿判定/删除必须同一原子协议）");
    NSString *aPath = [jobA.tempRootURL URLByStandardizingPath].path;
    Check(RDClaims(owner)[aPath] != nil,
          @"T47a: 另一实例的认领仍然持有（清理不得抢走他人锁）");

    // b) 认领在检查之前成立 ⇒ 必须跳过
    DownloadJob *jobB = RDPhase4Job(root);
    Check(RDClaimHeld(owner, jobB), @"T47b: 前置——另一实例已认领目录");
    RDAgeDirectory(jobB.tempRootURL);
    DownloadManager *cleaner2 = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.p47b");
    [cleaner2 cleanupOrphanTempDirs];
    Check(FileExists(jobB.tempRootURL),
          @"T47b: 检查之前已被认领的目录不得删除（他人锁仍有效）");
    int fdB = RDClaims(owner)[[jobB.tempRootURL URLByStandardizingPath].path].intValue;
    Check(RDFdOpen(fdB), @"T47b: 他人认领的文件描述符仍然有效");

    // c) 无人认领的陈旧孤儿 ⇒ 回收（既有行为不得回退）
    DownloadJob *jobC = RDPhase4Job(root);
    [owner claimTempDirectoryForJob:jobC];
    [owner releaseTempDirClaimForPath:jobC.tempRootURL.path];
    RDAgeDirectory(jobC.tempRootURL);
    DownloadManager *cleaner3 = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.p47c");
    [cleaner3 cleanupOrphanTempDirs];
    Check(!FileExists(jobC.tempRootURL),
          @"T47c: 无人认领的陈旧孤儿目录仍要被回收（加锁不得导致永不回收）");

    [fm removeItemAtPath:rootPath error:nil];
}

// T48：认领失败的实例不得恢复/取消/清除他人任务与共享恢复记录
static void TestForeignJobNotOperatedWithoutOwnership(void) {
    NSString *rootPath = RDPhase4Root(@"t48");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    // 第一实例**真实入队**并持有目录（公共路径，不走私有捷径）
    DownloadManager *owner = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.p48a");
    DownloadJob *job = EnqueueVideoFrom(owner, dest, @"/p48.mp4");
    Check(FileExists(job.tempRootURL), @"T48: 前置——第一实例已入队并持有目录");

    Phase4RecordingStore *store = [Phase4RecordingStore new];
    store.records = @{ job.identifier: @{
        @"sourceURL": job.sourceURL.absoluteString ?: @"",
        @"destinationURL": job.destinationURL.absoluteString ?: @"",
        @"tempRootURL": job.tempRootURL.absoluteString } };
    DownloadManager *restored = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                                tempRoot:root store:store];
    restored.rd_enableEndpointResolution = NO;
    NSString *ownedPath = [job.tempRootURL URLByStandardizingPath].path;
    Check(RDClaims(restored)[ownedPath] == nil,
          @"T48: 恢复方未取得所有权（锁被第一实例持有，认领必须显式失败）");
    __block DownloadJob *restoredJob = nil;
    for (DownloadJob *candidate in restored.allJobs)
        if ([candidate.identifier isEqualToString:job.identifier]) restoredJob = candidate;
    Check(restoredJob != nil, @"T48: 冲突任务仍对用户可见（保守展示，不静默丢失）");
    Check(restoredJob.state == DownloadJobStateInterrupted,
          @"T48: 无所有权的冲突任务不得被当作本实例可运行任务（实际 state=%ld）", (long)restoredJob.state);

    // 真实公共恢复路径：无所有权不得启动写入
    [restored resumeJob:job.identifier];
    Check(restoredJob.state == DownloadJobStateInterrupted,
          @"T48: 无所有权实例不得恢复（启动写入）他人任务（实际 state=%ld）", (long)restoredJob.state);
    Check(FileExists(job.tempRootURL), @"T48: 恢复尝试不得删除他人目录");
    int ownerFd = RDClaims(owner)[ownedPath].intValue;
    Check(RDFdOpen(ownerFd), @"T48: 所有者的锁仍有效");

    // 真实公共取消路径：无所有权不得删除他人目录、不得清除/改写共享恢复记录
    [restored cancelJob:job.identifier];
    Check(FileExists(job.tempRootURL),
          @"T48: 无所有权实例的取消不得删除他人目录（R2）");
    Check(RDFdOpen(RDClaims(owner)[ownedPath].intValue),
          @"T48: 取消后所有者的锁与描述符仍有效");
    Check(restoredJob.state == DownloadJobStateInterrupted,
          @"T48: 冲突任务不得被无所有权实例推进到取消终态（实际 state=%ld）", (long)restoredJob.state);
    Check(store.removedInterruptedCount == 0,
          @"T48: 不得清除另一实例的恢复记录（实际删除 %ld 次）", (long)store.removedInterruptedCount);
    Check(store.finishedRecordCount == 0,
          @"T48: 不得为他人任务写入完成历史（实际写入 %ld 次）", (long)store.finishedRecordCount);
    Check(FileExists(job.tempRootURL), @"T48: 目录在全部操作后仍然完好");

    // 对照：所有者自己的取消路径必须照常工作（不得因加锁把正常清理弄坏）
    [owner cancelJob:job.identifier];
    Check(!FileExists(job.tempRootURL),
          @"T48: 所有者自身取消仍会清理自己的目录（既有行为不回退）");

    [fm removeItemAtPath:rootPath error:nil];
}

// T49：manager 析构必须关闭所有权描述符，且后继实例能重新取得锁
static void TestManagerDeallocReleasesOwnershipDescriptors(void) {
    NSString *rootPath = RDPhase4Root(@"t49");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];
    NSString *suite = @"com.sevenzz.tests.p49";
    __weak DownloadManager *weak = nil;
    int descriptor = -1;
    NSString *ownedPath = nil;
    NSString *identifier = nil;
    @autoreleasepool {
        Phase4RecordingStore *store = [Phase4RecordingStore new];
        DownloadManager *temporary = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                                     tempRoot:root store:store];
        temporary.rd_enableEndpointResolution = NO;
        weak = temporary;
        DownloadJob *job = RDPhase4Job(root);
        Check(RDClaimHeld(temporary, job), @"T49: 前置——认领成立");
        identifier = job.identifier;
        ownedPath = [job.tempRootURL URLByStandardizingPath].path;
        descriptor = RDClaims(temporary)[ownedPath].intValue;
        Check(RDFdOpen(descriptor), @"T49: 认领后描述符有效（fd=%d）", descriptor);
        temporary = nil;
    }
    Check(weak == nil, @"T49: manager 已销毁（无外部强引用）");
    Check(!RDFdOpen(descriptor),
          @"T49: 销毁后所有权描述符必须关闭（R3：长期运行进程内反复创建/销毁不得泄漏 fd 与锁）");
    Check(FileExists([NSURL fileURLWithPath:ownedPath]),
          @"T49: 释放锁不得删除待恢复数据（目录仍留在磁盘上）");

    // 后继实例（恢复同一中断任务）必须能重新取得锁
    Phase4RecordingStore *store = [Phase4RecordingStore new];
    store.records = @{ identifier: @{
        @"sourceURL": @"https://example.com/p49.mp4",
        @"destinationURL": [root URLByAppendingPathComponent:@"out.mp4"].absoluteString,
        @"tempRootURL": [NSURL fileURLWithPath:ownedPath].absoluteString } };
    DownloadManager *successor = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                                 tempRoot:root store:store];
    successor.rd_enableEndpointResolution = NO;
    Check(RDClaims(successor)[ownedPath] != nil,
          @"T49: 后继实例能重新取得同一目录的所有权（锁已随析构释放）");
    [fm removeItemAtPath:rootPath error:nil];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
}

// T50：旧尝试的迟到 progress 不得污染新尝试的任何状态
static void TestStaleProgressCannotPolluteNewAttempt(void) {
    HoldableBackend *backend = [HoldableBackend new];
    backend.shouldHold = ^BOOL(NSURLRequest *request) { return YES; };   // 全部在途
    TestContext *ctx = MakeHoldableContext(backend);                     // 专用测试沙盒根/目标
    int64_t total = 25165824;
    DownloadJob *job = EnqueueSegmented(ctx, @"/p4-late-progress.mp4", total);
    Check(job.segmented && job.segmentCount >= 2,
          @"T50: 前置——分段任务在途（%ld 段）", (long)job.segmentCount);
    Check(backend.held.count > 0, @"T50: 前置——传输处于在途挂起状态");
    DownloadManager *manager = ctx.manager;

    HeldTransfer *oldTransfer = backend.held.firstObject;
    int64_t segmentLength = total / job.segmentCount;
    oldTransfer.progress(200000, 200000, segmentLength);
    Check(RDAttemptByteValue(manager, job, @0) == 200000,
          @"T50: 前置——本次尝试字节按旧尝试记录（实际 %lld）",
          RDAttemptByteValue(manager, job, @0));
    NSDate *progressAtBefore = RDProgressAt(manager, job, @0);
    int64_t cumulativeBefore = RDCumulativeBytes(manager, job, @0);
    int64_t transferredBefore = job.transferredBytes;

    // 换连接重发：token 更换、本次尝试字节归零（既有行为）
    [manager reissueSegmentOnFreshConnectionForJob:job index:0 reason:@"p4 replacement"];
    Check(RDAttemptByteValue(manager, job, @0) == 0,
          @"T50: 换连接后本次尝试字节归零（既有行为，实际 %lld）",
          RDAttemptByteValue(manager, job, @0));
    // 新尝试的时间基准在重发时已重建：这里记录的是**新尝试**的基准
    NSDate *progressAtAfterReissue = RDProgressAt(manager, job, @0);
    int64_t transferredAfterReissue = job.transferredBytes;

    // 旧任务的迟到 progress：不得写入 attempt 字节、不得改写累计口径 / last-progress / 用户进度
    oldTransfer.progress(100000, 300000, segmentLength);
    Check(RDAttemptByteValue(manager, job, @0) == 0,
          @"T50/R4: 旧尝试迟到 progress 不得写入新尝试的 attempt 字节（实际 %lld）",
          RDAttemptByteValue(manager, job, @0));
    Check(RDCumulativeBytes(manager, job, @0) == cumulativeBefore,
          @"T50/R4: 旧尝试迟到 progress 不得改写跨尝试累计口径（实际 %lld，期望 %lld）",
          RDCumulativeBytes(manager, job, @0), cumulativeBefore);
    Check([RDProgressAt(manager, job, @0) isEqualToDate:progressAtAfterReissue],
          @"T50/R4: 旧尝试迟到 progress 不得刷新新尝试的 last-progress");
    Check(job.transferredBytes == transferredAfterReissue,
          @"T50/R4: 旧尝试迟到 progress 不得改写用户可见进度（实际 %lld，期望 %lld）",
          job.transferredBytes, transferredAfterReissue);
    Check(job.state == DownloadJobStateRunning, @"T50: 任务仍在正常运行（未因迟到回调进入终态）");
}

// T51：真实跨进程——持锁子进程存活时清理必须跳过；子进程被 SIGKILL 后孤儿必须被回收
static void TestCrossProcessCrashReleasesOwnership(void) {
    NSString *rootPath = RDPhase4Root(@"t51");
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    NSString *dirPath = [rootPath stringByAppendingPathComponent:@"orphan"];
    [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
    [@"partial" writeToFile:[dirPath stringByAppendingPathComponent:@"000.part"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    RDAgeDirectory([NSURL fileURLWithPath:dirPath]);

    RDChildProcess *child = RDSpawnTestChild(@[@"--rd-child-claim", dirPath, @"60"]);
    Check(child != nil, @"T51: 子进程启动");
    NSString *locked = RDWaitForChildLine(child, @"RD-CHILD-LOCKED", 20);
    Check(locked != nil, @"T51: 前置——真实另一进程已用 flock 持有该目录（%@）", dirPath);

    DownloadManager *cleaner = MakeOwnershipManager([NSURL fileURLWithPath:rootPath],
                                                   [NSURL fileURLWithPath:[rootPath stringByAppendingPathComponent:@"dest"]],
                                                   [MockDownloadBackend new], @"com.sevenzz.tests.p51");
    [cleaner cleanupOrphanTempDirs];
    Check(FileExists([NSURL fileURLWithPath:dirPath]),
          @"T51: 真实另一进程持锁时，孤儿清理不得删除该目录（跨进程）");

    kill(child.task.processIdentifier, SIGKILL);
    RDWaitForChildExit(child, 20);
    Check(child.ended, @"T51: 持锁子进程已被杀死（模拟崩溃）");
    [cleaner cleanupOrphanTempDirs];
    Check(!FileExists([NSURL fileURLWithPath:dirPath]),
          @"T51: 持锁进程崩溃后锁由内核释放，孤儿目录被安全回收（真实跨进程）");
    [fm removeItemAtPath:rootPath error:nil];
}

// T52：普通终态清理不得删除并发认领者的数据（P1-A）
//   基线：removeTempRootForJob: 先 releaseTempDirClaimForPath: 再 removeItemAtURL:，
//   中间的释放窗口里另一实例可以合法认领并写入，随后被这一步删除。
//   这里用 release 之后的确定性调度点复现，不靠 sleep / 概率。
@interface Phase5ReleaseSchedulingManager : DownloadManager
@property (nonatomic, copy) void (^afterRelease)(void);
@end
@implementation Phase5ReleaseSchedulingManager
- (void)releaseTempDirClaimForPath:(NSString *)path {
    [super releaseTempDirClaimForPath:path];
    if (self.afterRelease) {
        void (^callback)(void) = self.afterRelease;
        self.afterRelease = nil;
        callback();
    }
}
@end

static void TestTerminalCleanupPreservesConcurrentClaimant(void) {
    NSString *rootPath = RDPhase4Root(@"t52");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];

    NSString *suite = @"com.sevenzz.tests.p52";
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]];
    Phase5ReleaseSchedulingManager *owner = [[Phase5ReleaseSchedulingManager alloc] initWithBackend:[MockDownloadBackend new]
                                                                                         tempRoot:root store:store];
    owner.rd_enableEndpointResolution = NO;
    DownloadJob *job = RDPhase4Job(root);
    Check(RDClaimHeld(owner, job), @"T52: 前置——清理方持有临时目录所有权");
    NSString *sentinelPath = [job.tempRootURL.path stringByAppendingPathComponent:@"sentinel.part"];

    DownloadManager *successor = MakeOwnershipManager(root, [NSURL fileURLWithPath:destPath],
                                                     [MockDownloadBackend new], @"com.sevenzz.tests.p52b");
    __block BOOL successorClaimed = NO;
    owner.afterRelease = ^{
        successorClaimed = RDClaimHeld(successor, job);
        [@"successor data" writeToFile:sentinelPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    };
    [owner removeTempRootForJob:job];

    Check(successorClaimed, @"T52: 调度点处后继实例合法认领成功（竞争条件成立）");
    Check(!successorClaimed || (FileExists(job.tempRootURL) && FileExists([NSURL fileURLWithPath:sentinelPath])),
          @"T52: 后继实例的目录与数据不得被普通终态清理删除（P1-A）");
    Check(RDClaimHeld(successor, job), @"T52: 后继实例的认领仍然有效");
    [fm removeItemAtPath:rootPath error:nil];
}

// T53：陈旧 inode 的锁不得构成对当前路径的所有权（P1-B）
//   基线 ownsTempDirectoryAtPath: 只看描述符表，因此旧锁文件被 unlink、同一路径换上
//   新 inode 之后，旧实例仍自认拥有，随后删掉真正拥有者的数据。
//   这里把该身份不变量固定成回归（真实 flock 时序由验收钩子探针覆盖）。
static void TestStaleInodeDoesNotConferOwnership(void) {
    NSString *rootPath = RDPhase4Root(@"t53");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];

    DownloadManager *stale = MakeOwnershipManager(root, [NSURL fileURLWithPath:destPath],
                                                  [MockDownloadBackend new], @"com.sevenzz.tests.p53");
    DownloadJob *job = RDPhase4Job(root);
    Check(RDClaimHeld(stale, job), @"T53: 前置——陈旧实例已认领目录");
    NSString *path = [job.tempRootURL URLByStandardizingPath].path;
    NSString *sentinelPath = [path stringByAppendingPathComponent:@"successor.part"];

    // 模拟另一实例在旧 inode 被 unlink 之后于同路径重建：整棵删除，再由后继实例重建并写入。
    [fm removeItemAtPath:path error:nil];
    Check(!FileExists(job.tempRootURL), @"T53: 前置——旧目录及其旧锁 inode 已被移除");
    DownloadManager *successor = MakeOwnershipManager(root, [NSURL fileURLWithPath:destPath],
                                                     [MockDownloadBackend new], @"com.sevenzz.tests.p53b");
    DownloadJob *job2 = [DownloadJob new];
    job2.identifier = job.identifier;
    job2.tempRootURL = job.tempRootURL;
    Check(RDClaimHeld(successor, job2), @"T53: 前置——后继实例已在同路径重建并认领（新 inode）");
    [@"successor data" writeToFile:sentinelPath atomically:NO encoding:NSUTF8StringEncoding error:nil];

    Check(![stale ownsTempDirectoryAtPath:path],
          @"T53: 陈旧实例的旧 inode 不得构成所有权（P1-B 根因）");
    [stale removeTempRootForJob:job];
    Check(FileExists([NSURL fileURLWithPath:sentinelPath]),
          @"T53: 陈旧实例的清理不得删除后继实例的数据");
    Check(RDClaimHeld(successor, job2), @"T53: 后继实例的认领仍然有效");
    [fm removeItemAtPath:rootPath error:nil];
}

// T54：退出顺序必须是「先落盘、后放锁」
//   若先释放归属锁再持久化中断记录，窗口内另一实例的启动清理会把「锁文件还在、
//   但无人持锁」的可续传目录当孤儿回收，用户分段数据丢失。
@interface Phase5OrderingStore : DownloadStore
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *records;
@property (nonatomic, weak) DownloadManager *observedManager;
@property (nonatomic, copy) NSString *observedPath;
@property (nonatomic, assign) BOOL ownedDuringPersist;
@property (nonatomic, assign) NSInteger setCount;
@end
@implementation Phase5OrderingStore
- (NSDictionary<NSString *, NSDictionary *> *)interruptedRecords { return self.records; }
- (NSArray<NSDictionary<NSString *, id> *> *)finishedJobRecords { return @[]; }
- (void)recordFinishedJob:(NSDictionary<NSString *, id> *)record {}
- (void)removeInterruptedRecord:(NSString *)identifier {}
- (void)setInterruptedRecords:(NSDictionary<NSString *, NSDictionary *> *)records {
    self.setCount += 1;
    self.ownedDuringPersist = [self.observedManager ownsTempDirectoryAtPath:self.observedPath];
    self.records = records;
}
@end

static void TestInterruptPersistencePrecedesClaimRelease(void) {
    NSString *rootPath = RDPhase4Root(@"t54");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    Phase5OrderingStore *store = [Phase5OrderingStore new];
    DownloadManager *manager = [[DownloadManager alloc] initWithBackend:[MockDownloadBackend new]
                                                               tempRoot:root store:store];
    manager.rd_enableEndpointResolution = NO;
    [manager beginBatchEnqueue];   // 入队不启动，保证任务停在 Queued，判定确定
    DownloadJob *job = EnqueueVideoFrom(manager, dest, @"/interrupt-order.mp4");
    Check(job != nil && RDClaimHeld(manager, job), @"T54: 前置——任务已入队并持有临时目录所有权");

    // 另一实例的中断记录：其目录不归本实例，退出时必须被合并保留而不是被覆盖。
    store.records = @{ @"FOREIGN-JOB": @{ @"sourceURL": @"https://example.com/foreign.mp4",
                                           @"destinationURL": [root URLByAppendingPathComponent:@"foreign.mp4"].absoluteString,
                                           @"tempRootURL": [root URLByAppendingPathComponent:@"FOREIGN-JOB"].absoluteString } };
    store.observedManager = manager;
    store.observedPath = job.tempRootURL.path;

    [manager markInterruptedOnTerminate];
    [manager endBatchEnqueue];

    Check(store.setCount == 1, @"T54: 中断记录写回一次（实际 %ld 次）", (long)store.setCount);
    Check(store.ownedDuringPersist,
          @"T54: 持久化进行中本实例仍持有归属锁（先落盘、后放锁）");
    Check(store.records[job.identifier] != nil, @"T54: 本实例中断记录已持久化");
    Check(store.records[@"FOREIGN-JOB"] != nil, @"T54: 另一实例的中断记录被合并保留");
    Check(![manager ownsTempDirectoryAtPath:job.tempRootURL.path],
          @"T54: 落盘完成后归属锁已释放（下一次启动可接管）");
    Check(FileExists(job.tempRootURL), @"T54: 释放锁不得删除待续传目录");

    // 后继实例必须能真正接管同一目录（锁确已释放而不是仅从字典移除）
    DownloadManager *successor = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.p54b");
    DownloadJob *job2 = [DownloadJob new];
    job2.identifier = job.identifier;
    job2.tempRootURL = job.tempRootURL;
    Check(RDClaimHeld(successor, job2), @"T54: 后继实例能重新取得同一目录（锁已真正释放）");
    [fm removeItemAtPath:rootPath error:nil];
}

// ===================== 第六阶段：本地稳定性补缺口（先测试，后决定是否改生产代码） =====================

// T55：取消路径的异步回调 / 重复取消不得重复清理或损坏状态
@interface Phase6RecordingStore : DownloadStore
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *finishedCounts;
@property (nonatomic, assign) NSInteger removedInterruptedCount;
@end
@implementation Phase6RecordingStore
- (instancetype)init {
    self = [super initWithUserDefaults:[[NSUserDefaults alloc] initWithSuiteName:@"com.sevenzz.tests.phase6.null"]];
    if (self) _finishedCounts = [NSMutableDictionary dictionary];
    return self;
}
- (NSDictionary<NSString *, NSDictionary *> *)interruptedRecords { return @{}; }
- (NSArray<NSDictionary<NSString *, id> *> *)finishedJobRecords { return @[]; }
- (void)recordFinishedJob:(NSDictionary<NSString *, id> *)record {
    NSString *identifier = record[@"identifier"] ?: @"?";
    self.finishedCounts[identifier] = @(self.finishedCounts[identifier].integerValue + 1);
}
- (void)removeInterruptedRecord:(NSString *)identifier { self.removedInterruptedCount += 1; }
- (void)setInterruptedRecords:(NSDictionary<NSString *, NSDictionary *> *)records {}
@end

static void TestCancellationLateCallbacksAndRepeatedCancel(void) {
    HoldableBackend *backend = [HoldableBackend new];
    backend.shouldHold = ^BOOL(NSURLRequest *request) { return YES; };   // 全部在途挂起
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"zz-dl-tests-t55-%ld", (long)(++gContextSeq)]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *dest = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"dest"]];
    NSURL *root = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"tmp"]];
    [fm createDirectoryAtPath:dest.path withIntermediateDirectories:YES attributes:nil error:nil];
    Phase6RecordingStore *store = [Phase6RecordingStore new];
    DownloadManager *manager = [[DownloadManager alloc] initWithBackend:backend tempRoot:root store:store];
    manager.rd_enableEndpointResolution = NO;

    NSURL *url = [NSURL URLWithString:@"https://cdn.example.com/cancel-async.mp4"];
    manager.defaultReferer = @"https://page.example.com/watch";
    DownloadJob *job = [manager enqueueItemWithSourceURL:url folder:dest preferredName:@"cancel-async"
                                                    etag:@"E" lastModified:@"L" acceptRanges:YES
                                            expectedLength:25165824];
    Check(job.segmented && job.segmentCount >= 2, @"T55: 前置——分段任务在途（%ld 段）", (long)job.segmentCount);
    Check(backend.held.count > 0, @"T55: 前置——存在在途挂起的传输");
    NSString *tempPath = [job.tempRootURL URLByStandardizingPath].path;
    Check(FileExists(job.tempRootURL), @"T55: 前置——分段目录已建立");

    [manager cancelJob:job.identifier];
    Check(job.state == DownloadJobStateCancelled, @"T55: 取消后进入 Cancelled（实际 %ld）", (long)job.state);
    NSInteger finishedAfterFirstCancel = store.finishedCounts[job.identifier].integerValue;
    Check(finishedAfterFirstCancel == 1, @"T55: 取消只写一次终态记录（实际 %ld）", (long)finishedAfterFirstCancel);

    // 重复取消：不得改写终态、不得重复写记录
    [manager cancelJob:job.identifier];
    [manager cancelJob:job.identifier];
    Check(job.state == DownloadJobStateCancelled, @"T55: 重复取消不改写终态（实际 %ld）", (long)job.state);
    Check(store.finishedCounts[job.identifier].integerValue == finishedAfterFirstCancel,
          @"T55: 重复取消不重复写终态记录（实际 %ld）",
          (long)store.finishedCounts[job.identifier].integerValue);

    // 迟到的异步完成回调到达：不得复活任务、不得重复清理、不得落盘半成品
    [backend releaseHeld];
    Wait(^BOOL { return NO; }, 1.5);   // 让 dispatch_async 的迟到回调跑完
    Check(job.state == DownloadJobStateCancelled,
          @"T55: 迟到完成回调不得复活已取消任务（实际 %ld）", (long)job.state);
    Check(store.finishedCounts[job.identifier].integerValue == finishedAfterFirstCancel,
          @"T55: 迟到回调不重复写终态记录（实际 %ld）",
          (long)store.finishedCounts[job.identifier].integerValue);
    Check(!FileExists(job.destinationURL), @"T55: 取消后不得落盘目标文件");
    Check(![[NSFileManager defaultManager] fileExistsAtPath:tempPath],
          @"T55: 取消后分段目录已被清理（且未因重复清理出错）");
    Check([manager valueForKey:@"activeTasks"][job.identifier] == nil, @"T55: 取消后活动槽位已释放");
    [fm removeItemAtPath:base error:nil];
}

// T56：rename 后 / 删除前退出 ⇒ 下次启动安全清理隔离区残留（.rd-trash）
static void TestQuarantineResidueCleanupAfterCrash(void) {
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"zz-dl-tests-t56-%ld", (long)(++gContextSeq)]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:base error:nil];
    NSString *destPath = [base stringByAppendingPathComponent:@"dest"];
    NSString *rootPath = [base stringByAppendingPathComponent:@"tmp"];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    // 模拟「rename 成功、删除前进程退出」遗留的隔离区内容
    NSString *trash = [rootPath stringByAppendingPathComponent:@".rd-trash"];
    NSString *residue = [trash stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [fm createDirectoryAtPath:[residue stringByAppendingPathComponent:@"inner"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"half" writeToFile:[residue stringByAppendingPathComponent:@"inner/000.part"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check([fm fileExistsAtPath:[residue stringByAppendingPathComponent:@"inner/000.part"]],
          @"T56: 前置——隔离区里存在残留数据");

    // 同时放一个真正的陈旧孤儿：必须仍按既有规则回收（清理不得因隔离区逻辑而失效）
    NSString *orphan = [rootPath stringByAppendingPathComponent:@"0BADC0DE-1111-4000-8000-0000000000AA"];
    [fm createDirectoryAtPath:orphan withIntermediateDirectories:YES attributes:nil error:nil];
    [fm setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-600]} ofItemAtPath:orphan error:nil];

    DownloadManager *m = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t56");
    Check(m != nil, @"T56: 前置——新实例构造完成（init 已执行清理）");

    NSArray *left = [fm contentsOfDirectoryAtPath:trash error:nil];
    Check(left.count == 0, @"T56: 隔离区残留被安全清理（剩余 %lu 项）", (unsigned long)left.count);
    Check(![fm fileExistsAtPath:residue], @"T56: 残留目录本体已删除");
    Check(![fm fileExistsAtPath:orphan], @"T56: 陈旧孤儿仍按既有规则回收（清理未失效）");
    [fm removeItemAtPath:base error:nil];
}

// T57：隔离改名失败时绝不降级为「先释放锁再就地删除」
@interface DownloadManager (Phase6QuarantineAccess)
- (NSString *)newQuarantinePath;
- (BOOL)quarantineAndRemoveOwnedTempDirectoryAtPath:(NSString *)path;
@end

@interface Phase6BrokenQuarantineManager : DownloadManager
@end
@implementation Phase6BrokenQuarantineManager
- (NSString *)newQuarantinePath {
    // 指向不存在的父目录 ⇒ rename(2) 必然失败（ENOENT）
    return @"/nonexistent-rd-quarantine-dir/UUID";
}
@end

static void TestQuarantineFailureNeverFallsBackToInPlaceDelete(void) {
    NSString *rootPath = RDPhase4Root(@"t57");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    NSString *suite = @"com.sevenzz.tests.t57";
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]];
    Phase6BrokenQuarantineManager *owner = [[Phase6BrokenQuarantineManager alloc] initWithBackend:[MockDownloadBackend new]
                                                                                         tempRoot:root store:store];
    owner.rd_enableEndpointResolution = NO;
    DownloadJob *job = RDPhase4Job(root);
    Check(RDClaimHeld(owner, job), @"T57: 前置——本实例持有临时目录");
    [@"keep me" writeToFile:[job.tempRootURL.path stringByAppendingPathComponent:@"sentinel.part"]
                 atomically:NO encoding:NSUTF8StringEncoding error:nil];
    int fdBefore = RDClaims(owner)[[job.tempRootURL URLByStandardizingPath].path].intValue;

    [owner removeTempRootForJob:job];

    Check(FileExists(job.tempRootURL),
          @"T57: 改名失败时不得退化为就地删除（目录必须保留）");
    Check([[NSFileManager defaultManager] fileExistsAtPath:
           [job.tempRootURL.path stringByAppendingPathComponent:@"sentinel.part"]],
          @"T57: 改名失败时目录内数据必须原样保留");
    Check(![owner ownsTempDirectoryAtPath:job.tempRootURL.path],
          @"T57: 放弃删除后所有权登记已统一释放（不泄漏状态）");
    Check(!RDFdOpen(fdBefore), @"T57: 放弃删除后文件描述符已关闭（不泄漏 fd）");
    [fm removeItemAtPath:rootPath error:nil];
}

// T58：-fb / -rf 变体目录——自己的清理回收，他人持有的绝不误删
static void TestVariantTempDirsNotDeletedWhenForeign(void) {
    NSString *rootPath = RDPhase4Root(@"t58");
    NSString *destPath = [rootPath stringByAppendingPathComponent:@"dest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:rootPath error:nil];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root = [NSURL fileURLWithPath:rootPath];
    NSURL *dest = [NSURL fileURLWithPath:destPath];

    DownloadManager *owner = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t58");
    DownloadManager *other = MakeOwnershipManager(root, dest, [MockDownloadBackend new], @"com.sevenzz.tests.t58b");
    DownloadJob *job = RDPhase4Job(root);
    NSURL *mainURL = job.tempRootURL;
    NSURL *fbURL = [root URLByAppendingPathComponent:[job.identifier stringByAppendingString:@"-fb"]];
    NSURL *rfURL = [root URLByAppendingPathComponent:[job.identifier stringByAppendingString:@"-rf"]];

    Check(RDClaimHeld(owner, job), @"T58: 前置——本实例持有主目录");
    job.tempRootURL = fbURL;   // 本实例通过 -fb 回退目录";
    Check(RDClaimHeld(owner, job), @"T58: 前置——本实例持有 -fb 变体");
    [@"fb data" writeToFile:[fbURL.path stringByAppendingPathComponent:@"sentinel.part"]
                 atomically:NO encoding:NSUTF8StringEncoding error:nil];
    job.tempRootURL = rfURL;   // 另一实例通过 -rf 重启目录
    Check(RDClaimHeld(other, job), @"T58: 前置——另一实例持有 -rf 变体");
    [@"rf data" writeToFile:[rfURL.path stringByAppendingPathComponent:@"sentinel.part"]
                 atomically:NO encoding:NSUTF8StringEncoding error:nil];
    job.tempRootURL = mainURL;

    [owner removeTempRootForJob:job];

    Check(!FileExists(mainURL), @"T58: 本实例主目录被正常回收");
    Check(!FileExists(fbURL), @"T58: 本实例拥有的 -fb 变体被回收（既有清理契约不回退）");
    Check(FileExists(rfURL), @"T58: 另一实例持有的 -rf 变体不得被误删");
    Check([[NSFileManager defaultManager] fileExistsAtPath:
           [rfURL.path stringByAppendingPathComponent:@"sentinel.part"]],
          @"T58: -rf 变体内的他人数据必须保留");
    Check(RDClaimHeld(other, job), @"T58: 另一实例对 -rf 的认领仍然有效");
    [fm removeItemAtPath:rootPath error:nil];
}

// T59：取消一个已失败的任务不得重建已清理的临时目录
//   失败路径（failJob:）已删除临时目录；旧 cancelJob: 在终态判定之前以
//   ensureOwnershipForJob:（createIfMissing:YES）取得所有权，会把目录重新建出来
//   并重新登记所有权 ⇒ 目录 + fd 泄漏。这里把该行为固定成回归。
static void TestCancelFailedJobDoesNotRecreateTempDir(void) {
    TestContext *ctx = MakeContext();
    ctx.backend.script = ^MockScript *(NSURLRequest *request, NSInteger index) {
        return [MockScript response:500 headers:@{} body:[NSData data]];
    };
    DownloadManager *manager = ctx.manager;
    DownloadJob *job = EnqueueVideo(ctx, @"/t59-fail-cancel.mp4", @"https://page.example.com/watch", 4096);
    Check(WaitForState(manager, job, DownloadJobStateFailed, 10),
          @"T59: 前置——任务进入失败终态（实际 %ld）", (long)job.state);
    NSString *tempPath = [job.tempRootURL URLByStandardizingPath].path;
    Check(!FileExists(job.tempRootURL) && ![manager ownsTempDirectoryAtPath:tempPath],
          @"T59: 前置——失败终态已删除临时目录并释放所有权");

    [manager cancelJob:job.identifier];
    Check(job.state == DownloadJobStateCancelled, @"T59: 取消后进入 Cancelled（实际 %ld）", (long)job.state);
    Check(!FileExists(job.tempRootURL),
          @"T59: 取消已失败任务不得重建临时目录（旧实现在此处以 createIfMissing:YES 重建）");
    Check(![manager ownsTempDirectoryAtPath:tempPath],
          @"T59: 取消已失败任务不得重新登记所有权（不得泄漏 fd/锁）");
    // 重复取消仍然是空操作
    [manager cancelJob:job.identifier];
    Check(job.state == DownloadJobStateCancelled && !FileExists(job.tempRootURL),
          @"T59: 重复取消保持空操作（不重建目录、不改写终态）");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [PerformancePolicy setMode:1];   // 标准模式：允许分段，行为确定
        // 仅测试用途：跨实例目录归属用例的独立子进程入口（必须在任何测试之前分流）。
        if (argc >= 2 && strcmp(argv[1], "--rd-child-download") == 0) {
            NSMutableArray<NSString *> *args = [NSMutableArray array];
            for (int i = 0; i < argc; i++) [args addObject:[NSString stringWithUTF8String:argv[i]]];
            return RDRunChildDownload(args);
        }
        if (argc >= 2 && strcmp(argv[1], "--rd-child-cleanup") == 0) {
            NSMutableArray<NSString *> *args = [NSMutableArray array];
            for (int i = 0; i < argc; i++) [args addObject:[NSString stringWithUTF8String:argv[i]]];
            return RDRunChildCleanup(args);
        }
        // 仅测试用途：真实跨进程持锁（模拟另一实例），供 T51 做崩溃/存活两种交错
        if (argc >= 2 && strcmp(argv[1], "--rd-child-claim") == 0) {
            NSString *dirPath = [NSString stringWithUTF8String:argv[2]];
            double seconds = argc > 3 ? atof(argv[3]) : 30.0;
            NSString *lockPath = [dirPath stringByAppendingPathComponent:@".rd-owner.lock"];
            int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
            if (fd < 0) { printf("RD-CHILD-OPEN-FAILED\n"); return 2; }
            if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); printf("RD-CHILD-LOCK-BUSY\n"); return 3; }
            printf("RD-CHILD-LOCKED\n"); fflush(stdout);
            NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
            while (end.timeIntervalSinceNow > 0)
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            close(fd);
            return 0;
        }
        // 性能回归：大文件在单任务内至少允许 8 个并行分段；旧基线固定为 4，
        // 在真实 CDN 上会让最慢的单段连接决定总耗时。
        Check([PerformancePolicy maximumSegmentsPerDownloadJob] >= 8,
              @"性能回归：标准模式分段上限至少为 8（当前 %ld）",
              (long)[PerformancePolicy maximumSegmentsPerDownloadJob]);
        TestLargeVideoPlansEightTransfers();
        NSLog(@"== 下载完整性隔离测试开始 ==");
        TestHTML143ErrorPage();
        TestHTMLWithLyingVideoMIME();
        TestInvalid143ByteMP4();
        TestValidMP4Completes();
        TestForbiddenAndNotFound();
        Test50MBExpected143BytesReceived();
        TestRefererIsolationBetweenJobs();
        TestSegmentedRefererAndMerge();
        TestSegmentWrongContentRangeFallsBack();
        TestShortSegmentFallsBack();
        TestMergedGarbageRejected();
        TestTransientErrorRetryStillWorks();
        TestRedirectKeepsReferer();
        TestProbeDoesNotTrustErrorPages();
        TestRealBackendAgainstLocalServer();
        TestLinkRefreshKeepsReferer();
        TestCompletionPersistsFinalPath();
        TestFailureNotReportedAsSuccess();
        TestRejectedEnqueueStaysInList();
        TestUnknownFreeSpaceDoesNotReject();
        TestTerminatePersistsAndClearsInterrupted();
        TestFileNameSanitizationAndExtension();
        TestDNSFlapRetryBudget();
        TestProgressIgnoresFinishedHistory();
        TestSegmentRetrySurvivesSlotStarvation();
        TestResumeRebuildsProgressWatchdog();
        TestLinkRefreshRestartReprobesCapability();
        TestDNSTimeoutClassification();
        TestEndpointDNSTimeoutDefersThenSucceeds();
        TestEndpointDNSTimeoutExhaustionReportsTimeout();
        TestReservedAddressStillBlockedViaEndpoint();
        TestSegmentProgressNeverRegresses();
        TestStalledSegmentReissued();
        TestWholePoolStallRotatesConnections();
        TestSingleSegmentStallReissuedImmediately();
        TestPoolStallNeverRecoversFailsBounded();
        // 探测瞬时失败（超时）必须有限重试，不得永久降级为单连接。
        TestCapabilityProbeTimeoutRetriesInsteadOfPermanentFallback();
        TestCapabilityProbeTimeoutRetriesAreBounded();
        // 无首字节的段：停滞窗口 8s → 6s（真实站点交替对照显示 6s 明显更稳）。
        TestFirstByteStallWindowIsSixSeconds();
        TestAdaptiveSchedulerShrinksOnSustainedLowThroughput();
        // 分段级自适应：连续低速但仍有数据的段必须被定向换连接重发（有界、顺延、不误伤）。
        TestSustainedSlowSegmentAdaptiveReissue();
        TestSustainedSlowSegmentReissueCapAndNoStorm();
        // 换连接后的新连接必须按「本次尝试零字节」用 6s 首字节窗口（不得沿用旧尝试累计字节）
        TestFreshConnectionGetsFirstByteWindow();
        // 临时目录归属：跨实例清理不得删除另一实例在途的分段目录（受控服务 + 独立子进程）
        TestCrossInstanceCleanupKeepsInFlightTempDir();
        TestTempDirOwnershipRules();
        // 第四阶段：独立验收 R1–R4 的正式行为回归
        TestOwnershipReclaimIsAtomicWithDelete();
        TestForeignJobNotOperatedWithoutOwnership();
        TestManagerDeallocReleasesOwnershipDescriptors();
        TestStaleProgressCannotPolluteNewAttempt();
        TestCrossProcessCrashReleasesOwnership();
        // 第五阶段：统一归属协议的两条调度反例正式化
        TestTerminalCleanupPreservesConcurrentClaimant();
        TestStaleInodeDoesNotConferOwnership();
        // 退出生命周期：先落盘、后放锁
        TestInterruptPersistencePrecedesClaimRelease();
        // 第六阶段：本地稳定性补缺口
        TestCancellationLateCallbacksAndRepeatedCancel();
        TestQuarantineResidueCleanupAfterCrash();
        TestQuarantineFailureNeverFallsBackToInPlaceDelete();
        TestVariantTempDirsNotDeletedWhenForeign();
        TestCancelFailedJobDoesNotRecreateTempDir();
        NSLog(@"== 全部 %d 项检查通过 ==", gChecks);
        NSLog(@"TEST-SUITE-PASSED");
        return 0;
    }
}
