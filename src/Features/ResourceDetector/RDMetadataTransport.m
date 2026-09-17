#import "RDMetadataTransport.h"
#import "URLPolicy.h"
#import "HTTPPrivacyPolicy.h"
#import "DNSResolver.h"
#import "RDLog.h"
NSString * const RDMetadataErrorDomain = @"RDMetadata";
@interface RDMetadataToken ()
@property BOOL cancelled;
@property NSMutableArray *cancellations;
@end
@implementation RDMetadataToken
- (instancetype)init { if ((self = [super init])) _cancellations = [NSMutableArray array]; return self; }
- (void)addCancellation:(dispatch_block_t)b {
    NSAssert(NSThread.isMainThread, @"main queue");
    if (!b) return;
    if (_cancelled) b(); else [_cancellations addObject:[b copy]];
}
- (void)cancel { NSAssert(NSThread.isMainThread, @"main queue"); if (_cancelled) return; _cancelled = YES; NSArray *blocks = [_cancellations copy]; [_cancellations removeAllObjects]; for (dispatch_block_t b in blocks) b(); }
@end
@implementation RDMetadataResponse
@end
// 元数据传输专用串行队列：响应拼装与委托回调都在这里，主线程只接收结论。
// NSURLSession 的 delegateQueue 只接受 NSOperationQueue。
static NSOperationQueue *RDTransferQueue(void) {
    static NSOperationQueue *queue; static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new];
        queue.name = @"rd.metadata.transfer";
        queue.maxConcurrentOperationCount = 1;
        queue.suspended = NO;
    });
    return queue;
}

// 连接阶段看门狗：服务器 TCP/TLS 握手偶发卡住（真实网址实测 7–9.5s 甚至更久），
// 但同一次请求只要连上，传输本身常常只要 0.1–0.5s。等到整个预算（10s 起）用完
// 才重试等于白等。这里在“连上之前”用更短的预算主动失败，交给服务层立即重试，
// 重试通常几毫秒就建连成功。
static const NSTimeInterval kRDConnectPhaseBudget = 5.0;
// 对冲请求（hedged request）：站点偶发把某个请求晾在服务器侧 5–40s 才回；
// 同一个 Range GET 是幂等的，因此只要第一条请求在 1.2s 内还没拿到响应头，
// 就并行发一条同样的请求（HTTP/2 同一连接多路复用），谁先回用谁。
// 正常请求（0.1–0.5s）永远不会触发，只有真正卡住的请求才会多花一次带宽。
static const NSTimeInterval kRDHedgeDelay = 0.8;
NSTimeInterval RDMetadataHedgeDelay(void) { return kRDHedgeDelay; }

@class RDMetadataSessionHub;
@interface RDMetadataTransfer : NSObject <NSURLSessionDataDelegate>
@property RDMetadataResolver resolver;
@property NSArray *classes;
@property RDMetadataToken *token;
@property (weak) RDMetadataSessionHub *hub;
@property NSURLSessionDataTask *task;
@property NSURLSessionDataTask *hedgeTask;
@property NSURLRequest *request;
@property NSURLSessionDataTask *winnerTask;
@property (nonatomic, assign) BOOL primaryDone;
@property (nonatomic, assign) BOOL hedgeDone;
@property (nonatomic, assign) NSUInteger variant;
@property NSMutableData *body;
@property RDMetadataResponse *result;
@property NSUInteger budget;
@property NSUInteger redirects;
@property BOOL finished;
@property BOOL head;
@property BOOL gotResponse;
@property (copy) void (^completion)(RDMetadataResponse *);
@end

// 进程级共享会话：所有元数据请求复用同一个 NSURLSession，从而复用同一条
// TCP/TLS 连接。旧实现每个请求新建并销毁一个会话，每个请求都要重新建连
// （真实网址实测：冷连接 0.13s / 7.03s / 9.5s，同一连接内的第二个请求
// 0.13–0.29s）。会话按 protocolClasses 分组，测试注入的协议类互不干扰。
@interface RDMetadataSessionHub : NSObject <NSURLSessionDataDelegate>
// 多个会话 = 多条独立连接池。实测该站点的卡顿是"连接级"的：同一条连接被
// 服务器晾住时，同连接上的第二个请求（HTTP/2 多路复用）也会一起被晾住；
// 而换一条新连接几乎总是 0.1–0.5s 返回。因此维护最多 3 条连接池，
// 把"卡住"的那条标记为生病并短期绕开。
@property (nonatomic, strong) NSMutableArray<NSURLSession *> *sessions;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDate *> *sickUntil;
@property (nonatomic, assign) NSUInteger nextVariant;
@property (nonatomic, strong) NSArray<Class> *protocolClasses;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, RDMetadataTransfer *> *transfers;
- (NSURLSession *)sessionForVariant:(NSUInteger)variant;
- (NSUInteger)healthyVariantExcluding:(NSInteger)excluded;
- (void)markVariantSick:(NSUInteger)variant;
@end
@implementation RDMetadataSessionHub
+ (instancetype)hubForProtocolClasses:(NSArray<Class> *)classes {
    static NSMutableDictionary<NSString *, RDMetadataSessionHub *> *hubs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hubs = [NSMutableDictionary dictionary]; });
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class cls in classes) [names addObject:NSStringFromClass(cls)];
    NSString *key = names.count ? [names componentsJoinedByString:@","] : @"default";
    RDMetadataSessionHub *hub = hubs[key];
    if (hub) return hub;
    hub = [RDMetadataSessionHub new];
    hub.transfers = [NSMutableDictionary dictionary];
    hub.sessions = [NSMutableArray array];
    hub.sickUntil = [NSMutableDictionary dictionary];
    hub.protocolClasses = classes;
    hubs[key] = hub;
    return hub;
}
- (NSURLSession *)sessionForVariant:(NSUInteger)variant {
    while (self.sessions.count <= variant) {
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.URLCache = nil; cfg.HTTPCookieStorage = nil; cfg.URLCredentialStorage = nil; cfg.HTTPShouldSetCookies = NO;
        cfg.protocolClasses = self.protocolClasses.count ? self.protocolClasses : cfg.protocolClasses;
        // 单请求预算由每个 transfer 自己的定时器执行（10–30s），这里只做兜底：
        // 连接空闲/总时长上限与全局看门狗一致。
        cfg.timeoutIntervalForRequest = 30.0;
        cfg.timeoutIntervalForResource = 30.0;
        cfg.HTTPMaximumConnectionsPerHost = 8;
        [self.sessions addObject:[NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:RDTransferQueue()]];
    }
    return self.sessions[variant];
}
- (NSUInteger)healthyVariantExcluding:(NSInteger)excluded {
    static const NSUInteger kMaxVariants = 3;
    NSDate *now = [NSDate date];
    for (NSUInteger step = 0; step < kMaxVariants; step++) {
        NSUInteger variant = (self.nextVariant + step) % kMaxVariants;
        if ((NSInteger)variant == excluded) continue;
        NSDate *until = self.sickUntil[@(variant)];
        if (until && [until timeIntervalSinceDate:now] > 0) continue;
        self.nextVariant = (variant + 1) % kMaxVariants;
        return variant;
    }
    NSUInteger fallback = (excluded == 0) ? 1 : 0;
    return MIN(fallback, kMaxVariants - 1);
}
- (void)markVariantSick:(NSUInteger)variant {
    // 连接级卡顿：10 秒内不再优先使用这条连接池。
    self.sickUntil[@(variant)] = [NSDate dateWithTimeIntervalSinceNow:10.0];
}
- (void)registerTransfer:(RDMetadataTransfer *)transfer forTask:(NSURLSessionDataTask *)task {
    if (!task) return;
    // 键必须是任务对象本身：taskIdentifier 只在单个会话内唯一，而这里最多有
    // 3 条连接池（3 个会话），不同会话的第一条任务都会拿到 identifier=1。
    @synchronized (self.transfers) { self.transfers[(NSURLSessionTask *)task] = transfer; }
}
- (void)unregisterTask:(NSURLSessionDataTask *)task {
    if (!task) return;
    @synchronized (self.transfers) { [self.transfers removeObjectForKey:(NSURLSessionTask *)task]; }
}
- (RDMetadataTransfer *)transferForTask:(NSURLSessionTask *)task {
    @synchronized (self.transfers) { return task ? self.transfers[task] : nil; }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    [[self transferForTask:task] URLSession:session task:task willPerformHTTPRedirection:response newRequest:request completionHandler:handler];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    RDMetadataTransfer *transfer = [self transferForTask:task];
    if (!transfer) { handler(NSURLSessionResponseCancel); return; }
    [transfer URLSession:session dataTask:task didReceiveResponse:response completionHandler:handler];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [[self transferForTask:task] URLSession:session dataTask:task didReceiveData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [[self transferForTask:task] URLSession:session task:task didCompleteWithError:error];
}
@end

@implementation RDMetadataTransfer
- (void)finish:(NSInteger)code {
    // 委托回调在后台队列、取消/超时在主队列：_finished 检查必须互斥。
    RDMetadataResponse *delivered = nil;
    @synchronized (self) {
        if (_finished) return;
        _finished = YES;
        if (code) _result.error = [NSError errorWithDomain:RDMetadataErrorDomain code:code userInfo:nil];
        _result.data = _result.error ? nil : [_body copy];
        delivered = _result;
    }
    if (delivered.error) {
        // 元数据失败此前只有服务层 1 条订阅日志，失败原因不可追溯。
        NSError *failure = delivered.error;
        RDLogWriteLevel(RDLogLevelWarn, @"meta",
                        @"元数据请求失败 domain=%@ code=%ld http=%ld host=%@ 已收=%lu 字节 文案=%@",
                        failure.domain ?: @"(无domain)", (long)failure.code,
                        (long)delivered.response.statusCode,
                        self.request.URL.host ?: @"(无host)", (unsigned long)_body.length,
                        failure.localizedDescription ?: @"(无文案)");
    }
    [_task cancel];
    [_hedgeTask cancel];
    [_hub unregisterTask:_task];
    [_hub unregisterTask:_hedgeTask];
    void (^done)(RDMetadataResponse *) = _completion; _completion = nil;
    if (!_token.cancelled && done) {
        // 服务层契约：完成回调始终在主队列，快照状态只在主线程变更。
        dispatch_async(dispatch_get_main_queue(), ^{ done(delivered); });
    }
}
// 第一条请求还没拿到响应头时，补发一条同样的请求；先回的那条获胜。
- (void)startHedgeIfStillWaiting {
    @synchronized (self) {
        if (_finished || _gotResponse || _hedgeTask || !_request) return;
    }
    RDMetadataSessionHub *hub = self.hub;
    if (!hub) return;
    // 对冲必须走另一条连接池：同一条被晾住的连接上再发一次没有意义。
    NSUInteger hedgeVariant = [hub healthyVariantExcluding:(NSInteger)self.variant];
    NSURLSessionDataTask *hedge = [[hub sessionForVariant:hedgeVariant] dataTaskWithRequest:self.request];
    @synchronized (self) {
        if (_finished || _gotResponse) { [hedge cancel]; return; }
        _hedgeTask = hedge;
    }
    [hub registerTransfer:self forTask:hedge];
    [hedge resume];
}

// 连接阶段看门狗：还没收到响应头就超预算 → 主动失败（服务层会立即重试）。
- (void)failIfNoResponseYet {
    @synchronized (self) {
        if (_finished || _gotResponse) return;
    }
    // 还没拿到响应头 → 这条连接池很可能被服务器晾住了：标记生病，让重试/后续
    // 请求换一条新连接（实测新连接 0.1–0.5s 就能返回）。
    [self.hub markVariantSick:self.variant];
    [self finish:RDMetadataTimedOut];
}
- (void)validate:(NSURL *)url completion:(void (^)(BOOL))done {
    if (!done) return;
    URLPolicy *policy = [URLPolicy new];
    if (![policy evaluateTextURL:url.absoluteString].allowed || !url.host.length || url.user.length || url.password.length) { done(NO); return; }
    RDMetadataResolver resolver = _resolver;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        DNSResolutionStatus status=DNSResolutionSucceeded;
        NSArray *ips = resolver ? resolver(url.host) : [DNSResolver resolveIPsForHost:url.host status:&status];
        URLPolicyDecision *decision = [policy evaluateResolvedURL:url resolvedIPs:ips resolutionStatus:status];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(decision.verdict==URLPolicyBlockedDNSBusy||decision.verdict==URLPolicyBlockedDNSTimeout)[self finish:RDMetadataTimedOut];
            done(decision.allowed && !self.finished && !self.token.cancelled);
        });
    });
}
- (void)start:(NSURLRequest *)request timeout:(NSTimeInterval)timeout {
    NSMutableURLRequest *sanitized = [request mutableCopy];
    [HTTPPrivacyPolicy sanitizeMediaRequest:sanitized];
    request = sanitized;
    _body = [NSMutableData data]; _result = [RDMetadataResponse new]; _head = [request.HTTPMethod isEqual:@"HEAD"];
    __weak typeof(self) weak = self;
    [_token addCancellation:^{ [weak finish:0]; }];
    // 总预算定时器（服务层分阶段预算：10–30s）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weak finish:RDMetadataTimedOut]; });
    // 连接阶段看门狗（更短）：卡在建连时不白等到总预算。
    NSTimeInterval connectBudget = MIN(kRDConnectPhaseBudget, MAX(1.5, timeout * 0.5));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(connectBudget*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weak failIfNoResponseYet]; });
    [self validate:request.URL completion:^(BOOL allowed) {
        if (self.finished) return;
        if (!allowed) { [self finish:RDMetadataBlocked]; return; }
        RDMetadataSessionHub *hub = [RDMetadataSessionHub hubForProtocolClasses:self.classes];
        self.hub = hub;
        self.request = request;
        self.variant = [hub healthyVariantExcluding:-1];
        self.task = [[hub sessionForVariant:self.variant] dataTaskWithRequest:request];
        [hub registerTransfer:self forTask:self.task];
        [self.task resume];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRDHedgeDelay*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf startHedgeIfStillWaiting];
        });
    }];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    if (++_redirects > 5 || ![[URLPolicy new] evaluateRedirect:request.URL fromURL:response.URL].allowed) { handler(nil); [self finish:RDMetadataBlocked]; return; }
    [self validate:request.URL completion:^(BOOL allowed) {
        NSMutableURLRequest *next = [request mutableCopy];
        NSMutableURLRequest *previous = [task.currentRequest mutableCopy];
        previous.URL = response.URL;
        [HTTPPrivacyPolicy sanitizeRedirectRequest:next fromRequest:previous];
        [RDTransferQueue() addOperation:[NSBlockOperation blockOperationWithBlock:^{ handler(allowed ? next : nil); }]];
        if (!allowed) [self finish:RDMetadataBlocked];
    }];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    @synchronized (self) {
        if (_finished) { handler(NSURLSessionResponseCancel); return; }
        if (!_winnerTask) _winnerTask = task;          // 先拿到响应头的那条获胜
        if (_winnerTask != task) { handler(NSURLSessionResponseCancel); return; }   // 对冲败者：取消
        _gotResponse = YES;
        _result.response = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    }
    if (!_result.response || _result.response.statusCode < 200 || _result.response.statusCode >= 300) { handler(NSURLSessionResponseCancel); [self finish:RDMetadataHTTPFailure]; return; }
    if (!_head && response.expectedContentLength > 0 && (unsigned long long)response.expectedContentLength > _budget) { handler(NSURLSessionResponseCancel); [self finish:RDMetadataBudgetExceeded]; return; }
    handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    @synchronized (self) {
        if (_finished || (_winnerTask && _winnerTask != task)) return;
        if (data.length > _budget - _body.length) { [self finish:RDMetadataBudgetExceeded]; return; }
        [_body appendData:data];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized (self) {
        if (_finished) return;
        if (task == _hedgeTask) _hedgeDone = YES; else _primaryDone = YES;
        if (_winnerTask) {
            // 已有胜者：败者的完成/取消一律忽略，否则会用半截数据结束 transfer
            //（真实回归：对冲败者被取消后立刻 finish，moov 解析成“不支持”）。
            if (_winnerTask != task) return;
        } else {
            // 还没有任何响应头：只要另一条还在飞就继续等它。
            BOOL otherPending = (task == _hedgeTask) ? !_primaryDone : (_hedgeTask != nil && !_hedgeDone);
            if (otherPending) return;
        }
        _result.error = error;
    }
    [self finish:error.code == NSURLErrorTimedOut ? RDMetadataTimedOut : 0];
}
@end
@interface RDMetadataTransport ()
@property RDMetadataResolver resolver;
@property NSArray *classes;
@end
@implementation RDMetadataTransport
- (instancetype)init { return [self initWithResolver:nil protocolClasses:nil]; }
- (instancetype)initWithResolver:(RDMetadataResolver)resolver protocolClasses:(NSArray<Class> *)classes {
    if ((self = [super init])) { _resolver = resolver; _classes = [classes copy]; } return self;
}
- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion {
    NSAssert(NSThread.isMainThread, @"main queue");
    if (!request || !completion) return [RDMetadataToken new];
    RDMetadataTransfer *transfer = [RDMetadataTransfer new]; transfer.resolver = _resolver; transfer.classes = _classes;
    transfer.token = [RDMetadataToken new]; transfer.budget = budget; transfer.completion = completion;
    [transfer start:request timeout:MAX(0.01, timeout)]; return transfer.token;
}
@end
