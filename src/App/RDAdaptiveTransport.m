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
    NSLock *_hopperLock;
    RDCurlHopper *_activeHopper;   // 复合 token 取消时终止在途 curl 跳
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
    RDMetadataToken *nativeToken = [_native request:request budget:budget timeout:timeout completion:^(RDMetadataResponse *r) {
        if (composite.cancelled) return;
        if (r && ![self shouldFallbackForResponse:r]) { completion(r); return; }
        __strong typeof(weak) s = weak;
        if (!s) { completion(r); return; }
        RDLogWrite(@"meta", @"原生传输命中指纹拦截签名（%@/%ld），尝试 curl 回退",
                   r.error.domain ?: @"(无)", r.error ? (long)r.error.code : 0);
        [s runCurlFallbackForRequest:request budget:budget timeout:timeout delivered:^(RDMetadataResponse *result) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!composite.cancelled) completion(result ?: r);   // curl 没能改善时保留原生结果
            });
        }];
    }];
    [composite addCancellation:^{
        [nativeToken cancel];
        __strong typeof(weak) s = weak;
        [s cancelActiveHopper];
    }];
    return composite;
}

- (void)cancelActiveHopper {
    [_hopperLock lock];
    RDCurlHopper *hopper = _activeHopper;
    [_hopperLock unlock];
    [hopper cancel];
}

// 原生结果是否值得换栈重试。r.error 必然存在（原生无错误不回退）。
- (BOOL)shouldFallbackForResponse:(RDMetadataResponse *)r {
    if (!r || !r.error) return NO;
    if (![r.error.domain isEqual:RDMetadataErrorDomain]) return NO;
    if (r.error.code == RDMetadataHTTPFailure) return YES;              // 含 403 拦截页
    if (r.error.code == RDMetadataTimedOut && !r.response) return YES;  // 连接被晾（无响应头）
    return NO;                                                          // Blocked / Budget / 其他一律不借道
}

- (void)runCurlFallbackForRequest:(NSURLRequest *)request budget:(NSUInteger)budget timeout:(NSTimeInterval)timeout delivered:(void (^)(RDMetadataResponse *))delivered {
    // 与原生传输同一份头语义：Referer 归一在进入回退前完成，两条栈各带同一套头。
    NSMutableURLRequest *sanitized = [request mutableCopy];
    [HTTPPrivacyPolicy sanitizeMediaRequest:sanitized];
    RDCurlHopper *hopper = [RDCurlHopper new];
    hopper.curlPath = self.curlPath;
    hopper.runner = self.curlRunner;
    hopper.logComponent = @"meta";
    hopper.resolver = self.resolver;
    [_hopperLock lock];
    _activeHopper = hopper;
    [_hopperLock unlock];
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
