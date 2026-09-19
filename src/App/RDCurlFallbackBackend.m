//
//  RDCurlFallbackBackend.m — 下载传输后端 curl 回退实现
//

#import "RDCurlFallbackBackend.h"
#import "HTTPPrivacyPolicy.h"
#import "RDLog.h"
#import "RDCurlHopper.h"

static void deliveredOnMain(NSURL *url, NSHTTPURLResponse *response, NSError *error,
                            void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *));

// 分段 curl 回退的单跳总预算：正常分段 20-60s 完成；预算只防极端挂起，
// 真正的"无进展"由 DownloadManager 的停滞看门狗经 progress 回调感知。
static const NSTimeInterval kRDCurlFallbackSegmentDeadline = 3600.0;

@interface RDCurlFallbackTask : NSObject <RDDownloadTask>
@property (nonatomic, copy) void (^onCancel)(void);
@end
@implementation RDCurlFallbackTask
- (void)rd_cancel { if (self.onCancel) self.onCancel(); }
@end

@implementation RDCurlFallbackBackend {
    id<RDDownloadBackend> _native;
}

- (instancetype)initWithNativeBackend:(id<RDDownloadBackend>)nativeBackend {
    if ((self = [super init])) {
        _native = nativeBackend;
        _curlPath = @"/usr/bin/curl";
    }
    return self;
}

+ (instancetype)backendWithNativeBackend:(id<RDDownloadBackend>)nativeBackend {
    return [[self alloc] initWithNativeBackend:nativeBackend];
}

#pragma mark - RDDownloadBackend

- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                            completion:(void (^)(NSURL * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable))completion {
    return [self rd_startRequest:request writeToURL:writeToURL progress:nil completion:completion];
}

- (id<RDDownloadTask>)rd_startRequest:(NSURLRequest *)request
                            writeToURL:(NSURL *)writeToURL
                             progress:(nullable void (^)(int64_t, int64_t, int64_t))progress
                           completion:(void (^)(NSURL * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable))completion {
    return [self forwardRequest:request writeToURL:writeToURL progress:progress completion:completion reissue:NO];
}

- (id<RDDownloadTask>)rd_reissueRequest:(NSURLRequest *)request
                             writeToURL:(NSURL *)writeToURL
                               progress:(nullable void (^)(int64_t, int64_t, int64_t))progress
                             completion:(void (^)(NSURL * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable))completion {
    // curl 回退本身每跳都是全新进程/连接，重发语义天然满足；原生腿仍走 reissue。
    return [self forwardRequest:request writeToURL:writeToURL progress:progress completion:completion reissue:YES];
}

#pragma mark - 转发与回退

- (id<RDDownloadTask>)forwardRequest:(NSURLRequest *)request
                          writeToURL:(NSURL *)writeToURL
                            progress:(nullable void (^)(int64_t, int64_t, int64_t))progress
                          completion:(void (^)(NSURL * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable))completion
                            reissue:(BOOL)reissue {
    RDCurlFallbackTask *task = [RDCurlFallbackTask new];
    __block RDCurlHopper *hopper = nil;
    __block NSTimer *poller = nil;
    void (^stopPoller)(void) = ^{ [poller invalidate]; poller = nil; };
    task.onCancel = ^{
        [hopper cancel];
        stopPoller();
    };

    void (^nativeBlock)(NSURL *, NSHTTPURLResponse *, NSError *) = ^(NSURL *written, NSHTTPURLResponse *resp, NSError *err) {
        if (![self shouldFallbackForNativeResult:written response:resp error:err]) {
            completion(written, resp, err);
            return;
        }
        RDLogWrite(@"dl", @"原生下载命中指纹拦截签名（status=%ld err=%ld），尝试 curl 回退",
                   resp ? (long)resp.statusCode : 0, err ? (long)err.code : 0);
        hopper = [RDCurlHopper new];
        hopper.curlPath = self.curlPath;
        hopper.runner = self.curlRunner;
        hopper.logComponent = @"dl";
        hopper.resolver = self.resolver;
        // curl 也没能改善时保留的原生结果：与原生完成语义同队列（主队列）投递。
        void (^nativeResult)(void) = ^{ dispatch_async(dispatch_get_main_queue(), ^{ completion(written, resp, err); }); };

        // 响应体落到分段目录旁边（同卷改名），传输中逐秒轮询大小喂进度看门狗。
        NSString *bodyName = [NSString stringWithFormat:@"%@.curl-%@.tmp",
                              writeToURL.lastPathComponent.stringByDeletingPathExtension ?: @"part",
                              NSUUID.UUID.UUIDString];
        NSString *bodyPath = [writeToURL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:bodyName];
        hopper.bodyFilePath = bodyPath;

        NSMutableURLRequest *sanitized = [request mutableCopy];
        [HTTPPrivacyPolicy sanitizeMediaRequest:sanitized];

        if (progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __block unsigned long long last = 0;
                NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                    unsigned long long size = [[NSFileManager defaultManager] attributesOfItemAtPath:bodyPath error:nil].fileSize;
                    if (size > last) {
                        progress((int64_t)(size - last), (int64_t)size, 0);
                        last = size;
                    }
                }];
                [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
                poller = timer;
            });
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [hopper walkURL:sanitized.URL
                     method:sanitized.HTTPMethod ?: @"GET"
                    headers:sanitized.allHTTPHeaderFields ?: @{}
                     budget:0   // 分段下载不限字节预算（段大小由 Range 头决定）
                   deadline:CFAbsoluteTimeGetCurrent() + kRDCurlFallbackSegmentDeadline
                 bodyToFile:YES
                 completion:^(RDCurlHopResult *result) {
                dispatch_async(dispatch_get_main_queue(), ^{ stopPoller(); });
                if (!result || result.error.code == RDCurlHopUnresolved) {
                    nativeResult();   // curl 没能改善：原样保留原生结果（含原生已写盘文件）
                    return;
                }
                if (result.error) {
                    RDLogWriteLevel(RDLogLevelWarn, @"dl", @"curl 下载回退失败 code=%ld", (long)result.error.code);
                    deliveredOnMain(nil, result.response, result.error, completion);
                    return;
                }
                // 终跳 2xx：把 curl 写的响应体挪到 manager 指定的分段文件。
                NSError *moveError = nil;
                NSURL *dest = writeToURL;
                if ([[NSFileManager defaultManager] fileExistsAtPath:writeToURL.path]) {
                    NSString *alt = [NSString stringWithFormat:@"%@-%@.tmp",
                                     writeToURL.lastPathComponent.stringByDeletingPathExtension ?: @"part",
                                     NSUUID.UUID.UUIDString];
                    dest = [writeToURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:alt];
                }
                BOOL ok = result.bodyFile && [[NSFileManager defaultManager] moveItemAtPath:result.bodyFile toPath:dest.path error:&moveError];
                if (!ok) {
                    RDLogWriteLevel(RDLogLevelWarn, @"dl", @"curl 下载回退落盘失败：%@", moveError.localizedDescription ?: @"未知");
                    deliveredOnMain(nil, result.response, moveError, completion);
                    return;
                }
                RDLogWrite(@"dl", @"curl 下载回退完成 段文件=%@ 字节=%llu", dest.lastPathComponent,
                           (unsigned long long)[[NSFileManager defaultManager] attributesOfItemAtPath:dest.path error:nil].fileSize);
                deliveredOnMain(dest, result.response, nil, completion);
            }];
        });
    };

    id<RDDownloadTask> nativeTask = reissue
        ? [(id)_native rd_reissueRequest:request writeToURL:writeToURL progress:progress completion:nativeBlock]
        : [(id)_native rd_startRequest:request writeToURL:writeToURL progress:progress completion:nativeBlock];
    void (^previousCancel)(void) = task.onCancel;
    task.onCancel = ^{
        [nativeTask rd_cancel];
        previousCancel();
    };
    return task;
}

static void deliveredOnMain(NSURL *url, NSHTTPURLResponse *response, NSError *error,
                            void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *)) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(url, response, error); });
}

// 原生结果是否值得换栈重试（见头文件契约）。
- (BOOL)shouldFallbackForNativeResult:(NSURL * _Nullable)written response:(NSHTTPURLResponse * _Nullable)resp error:(NSError * _Nullable)err {
    if (resp && resp.statusCode == 403) return YES;                          // CF 拦截页（可能已作为响应体写盘）
    if (err && !resp && [err.domain isEqual:NSURLErrorDomain]) return YES;   // 连接层失败/被晾
    return NO;
}

@end
