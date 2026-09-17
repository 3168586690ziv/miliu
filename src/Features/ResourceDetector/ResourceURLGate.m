//
//  ResourceURLGate.m — 模块 17｜资源 URL 统一安全校验入口实现
//
#import "ResourceURLGate.h"
#import "DNSResolver.h"

// 同主机「在途」校验合并：
// 一个页面里几十~上百个候选 URL（真实现场 106 个）通常只落在少数几个主机上，
// 逐个发起 getaddrinfo 会在 GCD 工具队列上互相挤占线程——实测同一批候选
// 逐个并发解析要 4.2s，而顺序解析 106 次只要 0.11s。这里把「同时在途」的
// 同主机校验合并为一次解析，拿到的 IP 结论分别对每个候选 URL 做逐 IP 策略判定，
// 使静态取页腿的固定开销回到解析本身（毫秒级）。
//
// 本层只合并在途请求；DNSResolver 另有 0.5 秒有界缓存。
// NSURLSession/WebKit 会独立解析并连接，预检查不绑定 peer IP；
// 因此不能声称完全阻止 DNS rebinding，HTTPS 证书校验仍交给系统。
@interface ResourceURLGate ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *rd_inFlightByHost;
@end

@implementation ResourceURLGate

- (instancetype)init {
    self = [super init];
    if (self) {
        _policy = [URLPolicy new];
        _rd_checksEnabled = YES;
        _rd_inFlightByHost = [NSMutableDictionary dictionary];
    }
    return self;
}

- (URLPolicyDecision *)textDecisionForURL:(NSURL *)url {
    if (!self.rd_checksEnabled) {
        // 测试模式：关闭校验（功能测试使用本地 server / 假域名）
        return [URLPolicyDecision allow];
    }
    if (url == nil || url.absoluteString.length == 0) {
        return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:@"地址无效"];
    }
    return [self.policy evaluateTextURL:url.absoluteString];
}

- (BOOL)isTextAllowed:(NSURL *)url {
    return [self textDecisionForURL:url].allowed;
}

- (void)verifyURLAsync:(NSURL *)url
            completion:(void (^)(URLPolicyDecision * _Nullable decision))completion {
    if (!self.rd_checksEnabled) {
        if (completion) completion([URLPolicyDecision allow]);
        return;
    }
    URLPolicyDecision *text = [self textDecisionForURL:url];
    if (!text.allowed) {
        if (completion) completion(text);
        return;
    }
    if (url.host.length == 0) {
        if (completion) completion([URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:@"地址缺少主机名"]);
        return;
    }
    NSURL *copy = [url copy];
    NSString *host = copy.host.lowercaseString ?: @"";
    // 每个等待者保留“自己的 URL + 自己的回调”：解析结果共享，逐 IP 策略判定仍按 URL 独立执行
    // （例如同一主机下不同路径可以有不同的业务策略结论）。
    void (^finishCallback)(URLPolicyDecision *) = completion ?: ^(URLPolicyDecision *decision){};
    NSArray *waiter = @[copy, [finishCallback copy]];

    BOOL startsLookup = NO;
    @synchronized (self) {
        if (!self.rd_inFlightByHost) self.rd_inFlightByHost = [NSMutableDictionary dictionary];
        NSMutableArray<NSArray *> *waiters = self.rd_inFlightByHost[host];
        if (waiters) {
            [waiters addObject:waiter];
        } else {
            self.rd_inFlightByHost[host] = [NSMutableArray arrayWithObject:waiter];
            startsLookup = YES;
        }
    }
    if (!startsLookup) return;   // 同主机已有解析在途：合并，等待共享结论

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        DNSResolutionStatus status;
        NSArray<NSString *> *ips = [DNSResolver resolveIPsForHost:copy.host ?: @"" status:&status];
        NSArray<NSArray *> *waiters = nil;
        @synchronized (self) {
            waiters = [self.rd_inFlightByHost[host] copy];
            // 完成即失效：绝不让“已完成”的解析结论被后续请求复用
            [self.rd_inFlightByHost removeObjectForKey:host];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSArray *w in waiters) {
                NSURL *candidate = w[0];
                void (^finish)(URLPolicyDecision *) = w[1];
                finish([self.policy evaluateResolvedURL:candidate resolvedIPs:ips resolutionStatus:status]);
            }
        });
    });
}

@end
