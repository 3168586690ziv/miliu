//
//  ProductionDiscoveryPageProbe.m — 第 5 阶段｜生产单页面探测器适配器实现
//

#import "ProductionDiscoveryPageProbe.h"

NSString *const ZZProductionPageProbeErrorDomain = @"ZZProductionPageProbeErrorDomain";

@implementation ProductionDiscoveryPageProbe

- (instancetype)initWithPolicy:(URLPolicy *)policy {
    self = [super init];
    if (self) {
        _webProbe = [[WebProbe alloc] initWithPolicy:policy ?: [URLPolicy new]];
    }
    return self;
}

- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(void (^)(NSArray<DetectedMedia *> * _Nullable media,
                                      NSError * _Nullable error))completion {
    if (!completion) return nil;
    if (pageURL == nil || pageURL.absoluteString.length == 0) {
        completion(@[], [NSError errorWithDomain:ZZProductionPageProbeErrorDomain
                                            code:ZZResourceDiscoveryErrorInvalidURL
                                        userInfo:@{NSLocalizedDescriptionKey : @"页面地址无效"}]);
        return nil;
    }
    __weak typeof(self) w = self;
    NSUInteger generation = [self.webProbe probeURL:pageURL.absoluteString
                                         completion:^(RDProbeResult *result, AppError *error, NSUInteger gen) {
        __strong typeof(w) s = w;
        if (!s) return;
        // WebProbe 的 completion 线程取决于 loader；统一转主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                NSError *e = [NSError errorWithDomain:ZZProductionPageProbeErrorDomain
                                                  code:error.type
                                              userInfo:@{NSLocalizedDescriptionKey : (error.message ?: @"页面探测失败")}];
                completion(@[], e);
            } else {
                completion(result.media ?: @[], nil);
            }
        });
    }];
    (void)generation;
    return @(generation);  // 凭据：WebProbe 内部 generation（cancelAll 使其作废）
}

- (void)cancelProbe:(nullable id)probeToken {
    // 串行多页探测中同一时刻仅一个在途任务；cancelAll 即取消当前页，
    // 且使该页迟到的 completion 不再回调（WebProbe generation 机制）。
    [self.webProbe cancelAll];
}

@end
