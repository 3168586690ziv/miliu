//
//  HTTPClient.m — 模块 08
//
#import "HTTPClient.h"
#import "AppError.h"
#import "RDLog.h"

// 流式接收（security-hardening）：自建 NSURLSession 走 delegate 回调，
// 收到响应/数据块时累计字节数，超过 maxBodyBytes 立即取消，绝不把超大
// 响应完整载入内存后才检查。expectedContentLength 仅作提示性提前取消。
@interface HTTPTask ()
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL delivered;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong) HTTPRequest *request;
@property (nonatomic, copy) void (^completion)(HTTPResult *result);
@property (nonatomic, weak) HTTPClient *client;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, assign) BOOL limitExceeded;      // 因超过 maxBodyBytes 被取消
@property (nonatomic, strong) NSHTTPURLResponse *httpResponse;
@property (nonatomic, assign) NSInteger attempt;        // 当前尝试次数（流式路径重试用）
- (void)markCancelled;
@end

@implementation HTTPTask
- (void)cancel {
    [self markCancelled];
    [self.dataTask cancel];
}
- (void)markCancelled {
    _cancelled = YES;
}
- (BOOL)isCancelled { return _cancelled; }
@end

@interface HTTPClient () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableSet<HTTPTask *> *activeTasks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, HTTPTask *> *taskMap; // taskIdentifier -> task
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) dispatch_queue_t mockQueue;
@property (nonatomic, assign) BOOL streamingEnabled;  // 自建 session 才启用 delegate 流式
@end

@implementation HTTPClient

- (instancetype)initWithSession:(nullable NSURLSession *)session {
    self = [super init];
    if (self) {
        _activeTasks = [NSMutableSet set];
        _taskMap = [NSMutableDictionary dictionary];
        _workQueue = dispatch_queue_create("com.sevenzz.httpclient", DISPATCH_QUEUE_SERIAL);
        _mockQueue = dispatch_queue_create("com.sevenzz.httpclient.mock", DISPATCH_QUEUE_SERIAL);
        if (session) {
            // 注入的 session 无法挂接本类 delegate：沿用 completionHandler 路径（兼容注入场景）
            _session = session;
            _streamingEnabled = NO;
        } else {
            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            cfg.timeoutIntervalForRequest = 30.0;
            cfg.timeoutIntervalForResource = 30.0;
            if (_protocolClasses.count) cfg.protocolClasses = _protocolClasses;
            _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
            _streamingEnabled = YES;
        }
    }
    return self;
}

// 设置自定义协议类时重建流式会话（仅自建 session 生效；测试用于注入受控数据流）
- (void)setProtocolClasses:(NSArray<Class> *)protocolClasses {
    _protocolClasses = [protocolClasses copy];
    if (self.streamingEnabled && self.session) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30.0;
        cfg.timeoutIntervalForResource = 30.0;
        if (_protocolClasses.count) cfg.protocolClasses = _protocolClasses;
        self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
}

- (HTTPTask *)performRequest:(HTTPRequest *)request
                   completion:(void (^)(HTTPResult *result))completion {
    HTTPTask *task = [[HTTPTask alloc] init];
    task.client = self;
    task.request = request;
    task.completion = completion;
    @synchronized(self.activeTasks) { [self.activeTasks addObject:task]; }

    // mock 模式超时强制（真实网络由 session 自身超时控制）
    if (self.mockHandler && request.timeout > 0) {
        __weak HTTPTask *weakTask = task;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(request.timeout * NSEC_PER_SEC)),
                       self.workQueue, ^{
            HTTPTask *t = weakTask;
            if (!t || t.isCancelled) return;
            HTTPResult *r = [[HTTPResult alloc] init];
            r.error = [AppError errorWithType:AppErrorTimeout message:@"request timeout"];
            r.statusCode = 0;
            [self finishTask:t withResult:r];
        });
    }

    [self runAttempt:0 forTask:task];
    return task;
}

// 单一投递保证：只回调一次，回主线程，取消后不回调
- (void)finishTask:(HTTPTask *)task withResult:(HTTPResult *)result {
    if (task.isCancelled) return;
    BOOL should;
    @synchronized(task) {
        should = !task.delivered;
        task.delivered = YES;
    }
    if (!should) return;
    // 统一失败出口：此前本文件 0 条日志，请求为什么失败完全不可追溯。
    // 只在真正失败时记一条（取消不算），host 交给 RDLog 脱敏保留。
    if (result.error && result.error.type != AppErrorCancelled) {
        RDLogWriteLevel(RDLogLevelWarn, @"probe",
                        @"HTTP 请求失败 type=%ld 错误码=%ld 状态=%ld host=%@ 文案=%@",
                        (long)result.error.type, (long)result.error.httpStatusCode,
                        (long)result.statusCode, task.request.url.host ?: @"(无host)",
                        result.error.message ?: @"(无文案)");
    }
    @synchronized(self.activeTasks) { [self.activeTasks removeObject:task]; }
    @synchronized(self.taskMap) {
        if (task.dataTask) [self.taskMap removeObjectForKey:@(task.dataTask.taskIdentifier)];
    }
    void (^completion)(HTTPResult *) = task.completion;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (task.isCancelled) return;
        if (completion) completion(result);
    });
}

- (BOOL)isTransientError:(AppError *)error statusCode:(NSInteger)statusCode {
    if (!error) return NO;
    return (error.type == AppErrorTimeout ||
            error.type == AppErrorOffline ||
            (error.type == AppErrorHTTP && statusCode >= 500));
}

// 客户端级响应体上限保护：对任何来源（含 mock）成功响应统一施加，超限转 file 错误并丢弃数据。
- (HTTPResult *)applyBodyLimit:(HTTPResult *)r request:(HTTPRequest *)request {
    if (r.error) return r;
    if (r.statusCode >= 200 && r.statusCode < 300 && r.data.length > request.maxBodyBytes) {
        r.error = [AppError errorWithType:AppErrorFile
                                  message:[NSString stringWithFormat:@"response body %lu exceeds max %ld",
                                           (unsigned long)r.data.length, (long)request.maxBodyBytes]];
        r.data = nil;
    }
    return r;
}

- (void)scheduleRetry:(NSInteger)nextAttempt forTask:(HTTPTask *)task {
    // 上一轮尝试的 dataTask 映射在此处已终结（超时/错误已触发重试）：
    // 立即移除，否则旧 taskIdentifier 会一直强持 HTTPTask 及其响应缓冲，
    // 每次重试泄漏一条映射并在长会话批量探测下缓慢累积。
    @synchronized(self.taskMap) {
        if (task.dataTask) [self.taskMap removeObjectForKey:@(task.dataTask.taskIdentifier)];
    }
    // 退避随重试次数递增但设 3s 上限；采用亚秒基数以保证受限重试及时收敛。
    NSTimeInterval backoff = MIN(nextAttempt * 0.2, 3.0);
    __weak HTTPTask *weakTask = task;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                   self.workQueue, ^{
        HTTPTask *t = weakTask;
        if (!t || t.isCancelled) return;
        [self runAttempt:nextAttempt forTask:t];
    });
}

- (void)runAttempt:(NSInteger)attempt forTask:(HTTPTask *)task {
    if (task.isCancelled) return;
    HTTPRequest *request = task.request;
    task.attempt = attempt;

    // mock 注入（独立队列，避免阻塞超时计时器）
    if (self.mockHandler) {
        __weak HTTPTask *weakTask = task;
        dispatch_async(self.mockQueue, ^{
            HTTPTask *t = weakTask;
            if (!t || t.isCancelled) return;
            HTTPResult *r = [self applyBodyLimit:self.mockHandler(request) request:request];
            BOOL retryable = [self isTransientError:r.error statusCode:r.statusCode] &&
                             request.idempotent && attempt < request.retryLimit;
            if (retryable) {
                [self scheduleRetry:attempt + 1 forTask:t];
            } else {
                [self finishTask:t withResult:r];
            }
        });
        return;
    }

    if (request.url == nil) {
        HTTPResult *r = [[HTTPResult alloc] init];
        r.error = [AppError errorWithType:AppErrorFile message:@"nil URL"];
        r.statusCode = 0;
        [self finishTask:task withResult:r];
        return;
    }

    NSMutableURLRequest *urlReq = [NSMutableURLRequest requestWithURL:request.url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:request.timeout];
    urlReq.HTTPMethod = request.method ?: @"GET";

    __weak HTTPTask *weakTask = task;
    if (self.streamingEnabled) {
        // 流式路径：delegate 回调逐步接收，didReceiveData 超限立即取消
        task.responseData = [NSMutableData data];
        task.limitExceeded = NO;
        task.httpResponse = nil;
        NSURLSessionDataTask *dataTask = [self.session dataTaskWithRequest:urlReq];
        task.dataTask = dataTask;
        @synchronized(self.taskMap) { self.taskMap[@(dataTask.taskIdentifier)] = task; }
        [dataTask resume];
        (void)weakTask;
    } else {
        // 注入 session（无本类 delegate）：completionHandler 路径 + 完成后 applyBodyLimit
        NSURLSessionDataTask *dataTask = [self.session dataTaskWithRequest:urlReq
                                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            HTTPTask *t = weakTask;
            if (!t || t.isCancelled) return;
            HTTPResult *r = [[HTTPResult alloc] init];
            r.fetchedAt = [NSDate date];
            if (error) {
                if (error.code == NSURLErrorTimedOut) {
                    r.error = [AppError errorWithType:AppErrorTimeout message:error.localizedDescription];
                } else if (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost) {
                    r.error = [AppError errorWithType:AppErrorOffline message:error.localizedDescription];
                } else if (error.code == NSURLErrorCancelled) {
                    r.error = [AppError errorWithType:AppErrorCancelled message:@"cancelled"];
                } else {
                    r.error = [AppError errorWithType:AppErrorHTTP message:error.localizedDescription];
                }
                r.statusCode = 0;
            } else {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                r.statusCode = (NSInteger)http.statusCode;
                r.contentType = http.allHeaderFields[@"Content-Type"];
                if (http.statusCode >= 200 && http.statusCode < 300) {
                    if (data.length > request.maxBodyBytes) {
                        r.error = [AppError errorWithType:AppErrorFile
                                                  message:[NSString stringWithFormat:@"response body %lu exceeds max %ld",
                                                           (unsigned long)data.length, (long)request.maxBodyBytes]];
                        r.data = nil;
                    } else {
                        r.data = data;
                        r.source = @"live";
                    }
                } else {
                    r.error = [AppError errorWithType:AppErrorHTTP httpStatusCode:http.statusCode
                                              message:[NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]];
                }
            }
            BOOL retryable = [self isTransientError:r.error statusCode:r.statusCode] &&
                             request.idempotent && attempt < request.retryLimit;
            if (retryable) {
                [self scheduleRetry:attempt + 1 forTask:t];
                return;
            }
            [self finishTask:t withResult:r];
        }];
        task.dataTask = dataTask;
        [dataTask resume];
    }
}

#pragma mark - NSURLSessionDataDelegate（流式限流）

- (HTTPTask *)taskForDataTask:(NSURLSessionTask *)dataTask {
    @synchronized(self.taskMap) {
        return self.taskMap[@(dataTask.taskIdentifier)];
    }
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    HTTPTask *t = [self taskForDataTask:dataTask];
    if (!t) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    t.httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    // expectedContentLength 仅作提示：已知超限可提前取消，但真实防护以实际接收字节为准
    if ([response isKindOfClass:NSHTTPURLResponse.class] &&
        response.expectedContentLength > 0 &&
        response.expectedContentLength > t.request.maxBodyBytes) {
        t.limitExceeded = YES;
        [dataTask cancel];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    HTTPTask *t = [self taskForDataTask:dataTask];
    if (!t) return;
    [t.responseData appendData:data];
    if (t.responseData.length > (NSUInteger)t.request.maxBodyBytes) {
        // 流式限流：超过上限立即取消，不再接收剩余内容
        t.limitExceeded = YES;
        [dataTask cancel];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    HTTPTask *t = [self taskForDataTask:task];
    if (!t || t.isCancelled) return;

    HTTPResult *r = [[HTTPResult alloc] init];
    r.fetchedAt = [NSDate date];
    if (error) {
        if (t.limitExceeded) {
            r.error = [AppError errorWithType:AppErrorFile
                                      message:[NSString stringWithFormat:@"response body exceeds max %ld",
                                               (long)t.request.maxBodyBytes]];
        } else if (error.code == NSURLErrorTimedOut) {
            r.error = [AppError errorWithType:AppErrorTimeout message:error.localizedDescription];
        } else if (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost) {
            r.error = [AppError errorWithType:AppErrorOffline message:error.localizedDescription];
        } else if (error.code == NSURLErrorCancelled) {
            r.error = [AppError errorWithType:AppErrorCancelled message:@"cancelled"];
        } else {
            r.error = [AppError errorWithType:AppErrorHTTP message:error.localizedDescription];
        }
        r.statusCode = 0;
    } else {
        NSHTTPURLResponse *http = t.httpResponse;
        if (http) {
            r.statusCode = (NSInteger)http.statusCode;
            r.contentType = http.allHeaderFields[@"Content-Type"];
        }
        if (r.statusCode >= 200 && r.statusCode < 300) {
            if (t.limitExceeded || t.responseData.length > (NSUInteger)t.request.maxBodyBytes) {
                r.error = [AppError errorWithType:AppErrorFile
                                          message:[NSString stringWithFormat:@"response body %lu exceeds max %ld",
                                                   (unsigned long)t.responseData.length, (long)t.request.maxBodyBytes]];
                r.data = nil;
            } else {
                r.data = [t.responseData copy];
                r.source = @"live";
            }
        } else {
            r.error = [AppError errorWithType:AppErrorHTTP httpStatusCode:r.statusCode
                                      message:[NSString stringWithFormat:@"HTTP %ld", (long)r.statusCode]];
        }
    }
    BOOL retryable = [self isTransientError:r.error statusCode:r.statusCode] &&
                     t.request.idempotent && t.attempt < t.request.retryLimit;
    if (retryable) {
        [self scheduleRetry:t.attempt + 1 forTask:t];
        return;
    }
    [self finishTask:t withResult:r];
}

- (void)cancelAll {
    NSSet *tasks;
    @synchronized(self.activeTasks) { tasks = [self.activeTasks copy]; }
    for (HTTPTask *t in tasks) [t cancel];
}

@end
