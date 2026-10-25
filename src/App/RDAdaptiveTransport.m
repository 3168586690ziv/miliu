//
//  RDAdaptiveTransport.m — 元数据复合传输实现
//
//  回退触发条件（「栈指纹拦截签名」，实测 www.hanime2.org → vcsocdp.net 系列）：
//    · 原生拿到 RDMetadataHTTPFailure（站点返回 403 拦截页 / 4xx / 5xx）；
//    · 原生 RDMetadataTimedOut 且完全没有响应头（连接被晾，CF 拦截的另一形态）。
//  绝不回退：RDMetadataBlocked（本地策略拦截，借 curl 绕过 = 打穿 SSRF 防线）、
//  RDMetadataBudgetExceeded（预算内不该再花钱）、以及原生成功/取消路径。
//  curl 跳也没能完成有效交换（Unresolved）时保留原生结果，绝不覆盖错误语义。
//

#import "RDAdaptiveTransport.h"
#import "HTTPPrivacyPolicy.h"
#import "RDLog.h"
#import "RDCurlHopper.h"

@implementation RDAdaptiveTransport {
    id<RDMetadataTransporting> _native;
    // hopper 归属是**每请求**的：元数据服务允许多 work 并发，全部挤进单个
    // "_activeHopper" 槽会让请求 A 的取消终止请求 B 正在跑的 curl（取消串号，
    // 2026-10-24 审计）。现在每个请求自带 cancelled 标志与 hopper 引用，锁只
    // 保护「后台注册 × 主线程取消」这两个不同线程的读写对。
    NSLock *_hopperLock;
}

- (instancetype)initWithNativeTransport:(id<RDMetadataTransporting>)nativeTransport {
    if ((self = [super init])) {
        _native = nativeTransport;
        _curlPath = @"/usr/bin/curl";
        _hopperLock = [NSLock new];
    }
    return self;
}

+ (instancetype)adaptiveWithNativeTransport:(id<RDMetadataTransporting>)nativeTransport {
    return [[self alloc] initWithNativeTransport:nativeTransport];
}

#pragma mark - RDMetadataTransporting

- (RDMetadataToken *)request:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout completion:(void (^)(RDMetadataResponse *))completion {
    NSAssert(NSThread.isMainThread, @"main queue");
    if (!request || !completion) return [RDMetadataToken new];
    RDMetadataToken *composite = [RDMetadataToken new];
    __weak typeof(self) weak = self;
    // 本请求的取消状态与在途 hopper（_hopperLock 保护；注册发生在后台队列）。
    __block BOOL requestCancelled = NO;
    __block RDCurlHopper *requestHopper = nil;
    RDMetadataToken *nativeToken = [_native request:request budget:budget timeout:timeout completion:^(RDMetadataResponse *r) {
        if (composite.cancelled) return;
        if (r && ![self shouldFallbackForResponse:r]) { completion(r); return; }
        __strong typeof(weak) s = weak;
        if (!s) { completion(r); return; }
        RDLogWrite(@"meta", @"原生传输命中指纹拦截签名（%@/%ld），尝试 curl 回退",
                   r.error.domain ?: @"(无)", r.error ? (long)r.error.code : 0);
        // curl 回退是同步等待子进程（RDCurlHopper 内 waitUntilExit）。这里原本直接
        // 在主线程调用，站点 403/挂起时会把 UI 冻结到 curl 的 connect-timeout。
        // 回退整体挪到后台队列；delivered 内部已经回主线程，取消检查不变。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (composite.cancelled) return;   // 回退启动前已被取消：不再发起 curl 子进程
            [s runCurlFallbackForRequest:request budget:budget timeout:timeout
                              registered:^(RDCurlHopper *hopper) {
                // 注册点：与取消点互斥。取消先到则当场终止新 hopper，无竞态窗口。
                [_hopperLock lock];
                if (requestCancelled) { [_hopperLock unlock]; [hopper cancel]; return; }
                requestHopper = hopper;
                [_hopperLock unlock];
            } delivered:^(RDMetadataResponse *result) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!composite.cancelled) completion(result ?: r);   // curl 没能改善时保留原生结果
                });
            }];
        });
    }];
    [composite addCancellation:^{
        [nativeToken cancel];
        [_hopperLock lock];
        requestCancelled = YES;
        RDCurlHopper *hopper = requestHopper;
        [_hopperLock unlock];
        [hopper cancel];   // 尚未注册（nil）时为空操作；注册块稍后见 cancelled 标志自会终止
    }];
    return composite;
}

// 原生结果是否值得换栈重试。r.error 必然存在（原生无错误不回退）。
- (BOOL)shouldFallbackForResponse:(RDMetadataResponse *)r {
    if (!r || !r.error) return NO;
    if (![r.error.domain isEqual:RDMetadataErrorDomain]) return NO;
    if (r.error.code == RDMetadataHTTPFailure) return YES;              // 含 403 拦截页
    if (r.error.code == RDMetadataTimedOut && !r.response) return YES;  // 连接被晾（无响应头）
    return NO;                                                          // Blocked / Budget / 其他一律不借道
}

- (void)runCurlFallbackForRequest:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout
                       registered:(void (^)(RDCurlHopper *hopper))registered
                        delivered:(void (^)(RDMetadataResponse *))delivered {
    // 与原生传输同一份头语义：Referer 归一在进入回退前完成，两条栈各带同一套头。
    NSMutableURLRequest *sanitized = [request mutableCopy];
    [HTTPPrivacyPolicy sanitizeMediaRequest:sanitized];
    RDCurlHopper *hopper = [RDCurlHopper new];
    hopper.curlPath = self.curlPath;
    hopper.runner = self.curlRunner;
    hopper.logComponent = @"meta";
    hopper.resolver = self.resolver;
    if (registered) registered(hopper);   // 注册后调用方才能按请求取消（composite token 语义）
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + MAX(0.1, timeout);
    [hopper walkURL:sanitized.URL
             method:sanitized.HTTPMethod ?: @"GET"
            headers:sanitized.allHTTPHeaderFields ?: @{}
             budget:budget
           deadline:deadline
         bodyToFile:NO
         completion:^(RDCurlHopResult *result) {
        if (!result || result.error.code == RDCurlHopUnresolved) { delivered(nil); return; }
        RDMetadataResponse *r = [RDMetadataResponse new];
        r.response = result.response;
        if (result.error) {
            r.error = [NSError errorWithDomain:RDMetadataErrorDomain
                                          code:[self metadataCodeForHopError:result.error.code]
                                      userInfo:nil];
            delivered(r);
            return;
        }
        r.data = result.body;
        delivered(r);
    }];
}

- (RDMetadataError)metadataCodeForHopError:(RDCurlHopError)code {
    switch (code) {
        case RDCurlHopBlocked: return RDMetadataBlocked;
        case RDCurlHopTimedOut: return RDMetadataTimedOut;
        case RDCurlHopBudgetExceeded: return RDMetadataBudgetExceeded;
        case RDCurlHopHTTPFailure: return RDMetadataHTTPFailure;
        case RDCurlHopUnresolved: return RDMetadataHTTPFailure;
    }
    return RDMetadataHTTPFailure;
}

@end
