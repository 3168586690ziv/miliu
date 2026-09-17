#import "RDHybridPageProbe.h"
#import "RDLog.h"
#import "StaticHTMLDiscoveryPageProbe.h"
#import "ProductionDiscoveryHTMLProvider.h"
#import "RDNetworkValidation.h"
@interface RDHybridContext : NSObject
@property BOOL cancelled;
@property BOOL hasDynamicSlot;
@property WebProbe *dynamic;
@property ProductionDiscoveryHTMLProvider *htmlProvider;
@property id staticToken;
@property id htmlToken;
@property (copy) void (^completion)(NSArray *,NSError *);
// 增量发布消费者（可选）：每次发布都带终态标志，临时结果（final=NO）只为让
// 调用方先把列表显示出来，最终结果（final=YES）才代表这次探测的结论。
@property (copy) void (^incrementalCompletion)(NSArray *,NSError *,BOOL);
@property NSArray *staticMedia;
// 两条腿各自的完成状态：静态取页与动态 WebKit 取页互不依赖，并行执行、
// 都到齐后再合并（旧实现串行等待，白等一整条腿的时间）。
@property BOOL staticDone;
@property BOOL dynamicDone;
// 静态腿结果是否已经先发布过一次（避免重复提前发布）。
@property BOOL publishedStatic;
@property (strong) RDProbeResult *dynamicResult;
@property (strong) AppError *dynamicError;
@property (strong) NSError *staticError;
@end
@implementation RDHybridContext
@end
@interface RDHybridPageProbe ()
@property URLPolicy *policy;
@property StaticHTMLDiscoveryPageProbe *statik;
@property NSMutableSet *contexts;
@property NSMutableArray<dispatch_block_t> *dynamicQueue;
@property NSUInteger activeDynamic;
@end
@implementation RDHybridPageProbe
- (instancetype)initWithPolicy:(URLPolicy *)policy {
    if((self=[super init])){_policy=policy ?: [URLPolicy new];_statik=[[StaticHTMLDiscoveryPageProbe alloc]initWithPolicy:_policy];_contexts=[NSMutableSet set];_dynamicQueue=[NSMutableArray array];}
    return self;
}
- (void)pump {
    while(self.activeDynamic<2 && self.dynamicQueue.count){dispatch_block_t next=self.dynamicQueue.firstObject;[self.dynamicQueue removeObjectAtIndex:0];self.activeDynamic++;next();}
}
- (id)probePageURL:(NSURL *)url completion:(void (^)(NSArray<DetectedMedia *> *,NSError *))completion {
    RDHybridContext *ctx=[RDHybridContext new];ctx.completion=completion;
    [self startContext:ctx forURL:url];
    return ctx;
}
// 增量发布（实现 ZZDiscoveryPageProbing / ZZSinglePageProbing 的可选能力）：
// 静态腿先回来时发布一次 final=NO 的临时结果，两腿都完成后发布 final=YES 的最终
// 合并结果。调用方必须只在 final=YES 时把结果当作结论——否则动态腿独有的资源
// 会被丢掉（2026-09-10 现场：资源数 104 vs 改前 105–107）。
- (id)probePageURL:(NSURL *)url incrementalCompletion:(void (^)(NSArray<DetectedMedia *> *,NSError *,BOOL))completion {
    RDHybridContext *ctx=[RDHybridContext new];ctx.incrementalCompletion=completion;
    [self startContext:ctx forURL:url];
    return ctx;
}
// 该上下文是否仍有消费者：一次性回调与增量回调共用同一套发布/结束逻辑。
- (BOOL)contextHasConsumer:(RDHybridContext *)ctx {
    return ctx.completion != nil || ctx.incrementalCompletion != nil;
}
- (void)startContext:(RDHybridContext *)ctx forURL:(NSURL *)url {
    dispatch_async(dispatch_get_main_queue(),^{
        if(ctx.cancelled)return;
        [self.contexts addObject:ctx];
        // ── 腿 1：静态 HTML 取页（纯 HTTP）──
        ctx.staticToken=[self.statik probePageURL:url completion:^(NSArray *media,NSError *error){
            if(ctx.cancelled)return;
            ctx.staticMedia=media ?: @[];
            ctx.staticError=error;
            ctx.staticDone=YES;
            // 静态腿先出列表：本站视频直链就在静态 HTML 里，静态腿 1.7–3.6s 已能
            // 填充左侧列表，而动态 WebKit 腿要 6.7–9.3s。此前必须等两腿都完成才
            // 发布一次，用户白等 4–6 秒。这里先发布静态结果，动态腿回来后由
            // finishIfBothLegsDone 再发布一次合并结果（调用方按“更新”处理多次回调）。
            if(!ctx.dynamicDone && ctx.staticMedia.count > 0 && !ctx.publishedStatic){
                ctx.publishedStatic=YES;
                RDLogWrite(@"probe", @"静态腿先出结果 media=%lu（动态腿未回，先上临时结果）", (unsigned long)ctx.staticMedia.count);
                [self publish:ctx media:[self mergedMediaForContext:ctx] error:nil final:NO];
            }
            [self finishIfBothLegsDone:ctx];
        }];
        // ── 腿 2：动态 WebKit 取页（并行启动，不再等静态腿）──
        RDValidateNetworkURL(url,self.policy,nil,^(URLPolicyDecision *decision){
            if(ctx.cancelled)return;
            if(!decision.allowed){
                ctx.dynamicDone=YES;
                ctx.dynamicError=[AppError errorWithType:AppErrorPermission message:decision.userMessage];
                [self finishIfBothLegsDone:ctx];
                return;
            }
            __weak RDHybridPageProbe *weakSelf = self;
            [self.dynamicQueue addObject:^{
                RDHybridPageProbe *owner = weakSelf;
                if(!owner){ return; }
                if(ctx.cancelled){owner.activeDynamic--;[owner pump];return;}
                ctx.hasDynamicSlot=YES;
                // 动态腿硬超时 20s → 45s（2026-09-18）：20s 对「首屏只是 JS 壳、内容全靠
                // 脚本渲染」的站点不够用。实测 www.360kan.com 的 HTML 仅 1749 字节、
                // 媒体全由外部脚本加载：20s 时 0 资源并报「探测超时」，45s 时抓到 46 个
                // 资源（列表 33.1s 出现）。失败页面的等待上限因此由 20s 变为 45s，
                // 与项目其它路径（WebProbe 默认 30s、单页预算 15s/硬上限 20s 只针对静态
                // 列表页）相比仍属同一量级。
                ctx.dynamic=[[WebProbe alloc]initWithPolicy:owner.policy];ctx.dynamic.hardTimeout=45;
                if(owner.loaderFactory)ctx.dynamic.loader=owner.loaderFactory();
                [ctx.dynamic probeURL:url.absoluteString completion:^(RDProbeResult *result,AppError *dynamicError,NSUInteger generation){
                    dispatch_async(dispatch_get_main_queue(),^{
                        RDHybridPageProbe *callbackOwner = weakSelf;
                        if(ctx.hasDynamicSlot){
                            ctx.hasDynamicSlot=NO;
                            if(callbackOwner) callbackOwner.activeDynamic--;
                        }
                        [ctx.dynamic detachWebView];
                        if(callbackOwner) [callbackOwner pump];
                        if(ctx.cancelled)return;
                        ctx.dynamicResult=result;ctx.dynamicError=dynamicError;ctx.dynamicDone=YES;
                        if(callbackOwner) [callbackOwner finishIfBothLegsDone:ctx];
                    });
                }];
            }];[self pump];
        });
    });
}

// 两条腿都结束（或已被取消）后合并一次。动态结果在前、静态结果在后：同一地址
// 两条记录必须合并成一条更完整的记录（身份/画质声明/poster 等字段补齐），
// 绝不能让先到的“信息更少”的条目顶掉静态侧的 family 与画质声明——否则同一
// 影片会以两行出现，且选中那行没有 poster，详情只能走视频抽帧而变慢。
- (void)finishIfBothLegsDone:(RDHybridContext *)ctx {
    if(ctx.cancelled || ![self contextHasConsumer:ctx])return;
    if(!ctx.staticDone || !ctx.dynamicDone)return;
    NSArray *merged=[self mergedMediaForContext:ctx];
    AppError *dynamicError=ctx.dynamicError;
    BOOL staticBad = [ctx.staticError.domain isEqual:ZZResourceDiscoveryErrorDomain] && ctx.staticError.code == ZZResourceDiscoveryErrorUnrecognizedPage;
    BOOL dynamicBad = ctx.dynamicResult.isBadPage;
    // A complete recognizable DOM can recover an empty raw-HTML response.
    // But a static empty result must not conceal a failed dynamic leg.
    // Login forms alone are not classified as bad pages.
    BOOL recoveredStaticBad = staticBad && ctx.dynamicResult && !dynamicError && !dynamicBad;
    NSError *failure = nil;
    if (!merged.count) {
        if (dynamicBad || (staticBad && !recoveredStaticBad)) failure = [NSError errorWithDomain:ZZResourceDiscoveryErrorDomain
            code:ZZResourceDiscoveryErrorUnrecognizedPage userInfo:@{NSLocalizedDescriptionKey:@"页面无法识别，请检查页面内容或稍后重试"}];
        else failure = (recoveredStaticBad ? nil : ctx.staticError) ?: (dynamicError ? [NSError errorWithDomain:@"RDHybrid" code:dynamicError.type
            userInfo:@{NSLocalizedDescriptionKey:dynamicError.message ?: @"页面读取失败"}] : nil);
    }
    [self finish:ctx media:merged error:failure];
}
// 合并“目前已经回来的腿”。动态结果在前、静态结果在后：同一地址两条记录必须
// 合并成一条更完整的记录（身份/画质声明/poster 等字段补齐），绝不能让先到的
// “信息更少”的条目顶掉静态侧的 family 与画质声明——否则同一影片会以两行出现，
// 且选中那行没有 poster，详情只能走视频抽帧而变慢。只有静态腿时同样走这里，
// 保证提前发布的那一份与最终结果用的是同一套合并规则、不会出现两份不同口径。
- (NSArray *)mergedMediaForContext:(RDHybridContext *)ctx {
    NSMutableArray *merged=[NSMutableArray array];
    NSMutableDictionary<NSString *,NSNumber *> *indexByKey=[NSMutableDictionary dictionary];
    NSArray *dynamicMedia=ctx.dynamicResult.media ?: @[];
    for(DetectedMedia *m in [dynamicMedia arrayByAddingObjectsFromArray:ctx.staticMedia]){
        // 用"同一资源"身份（忽略 CDN 签名参数）合并：两次取页的签名不同，
        // 但资源是同一个。
        NSString *key=[DetectedMedia groupingKeyForURL:m.mediaURL];
        if(!key.length)continue;
        NSNumber *existing=indexByKey[key];
        if(existing){
            NSUInteger idx=existing.unsignedIntegerValue;
            merged[idx]=[DetectedMedia mediaByEnriching:merged[idx] with:m];
            continue;
        }
        indexByKey[key]=@(merged.count);
        [merged addObject:m];
    }
    return merged;
}
// 发布一次结果。final=NO 时保留消费者（稍后还会发布动态腿合并后的最终结果，
// 调用方必须按「更新」而非「结论」处理）；final=YES 时消费回调并释放上下文。
- (void)publish:(RDHybridContext *)ctx media:(NSArray *)media error:(NSError *)error final:(BOOL)isFinal {
    if(ctx.cancelled)return;
    void (^incremental)(NSArray *,NSError *,BOOL)=ctx.incrementalCompletion;
    void (^oneShot)(NSArray *,NSError *)=ctx.completion;
    if(!incremental && !oneShot)return;
    if(isFinal){ctx.completion=nil;ctx.incrementalCompletion=nil;[self.contexts removeObject:ctx];}
    // One-shot callers must never mistake a static interim publish for final.
    // Incremental consumers retain both interim and complete dynamic results.
    if(incremental)incremental(media,error,isFinal);
    else if(isFinal)oneShot(media,error);
}
- (void)finish:(RDHybridContext *)ctx media:(NSArray *)media error:(NSError *)error {
    [self publish:ctx media:media error:error final:YES];
}
- (void)cancelProbe:(id)token {
    RDHybridContext *ctx=token;
    dispatch_async(dispatch_get_main_queue(),^{
        if(ctx.cancelled)return;ctx.cancelled=YES;ctx.completion=nil;ctx.incrementalCompletion=nil;
        [self.statik cancelProbe:ctx.staticToken];
        // WebProbe cancellation suppresses its completion, so release its slot here.
        if(ctx.dynamic){[ctx.dynamic cancelAll];[ctx.dynamic detachWebView];ctx.dynamic=nil;if(ctx.hasDynamicSlot){ctx.hasDynamicSlot=NO;self.activeDynamic--;}[self pump];}
        [ctx.htmlProvider cancelHTMLRequest:ctx.htmlToken];[self.contexts removeObject:ctx];
    });
}
- (id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    RDHybridContext *ctx=[RDHybridContext new];
    dispatch_async(dispatch_get_main_queue(),^{
        if(ctx.cancelled)return;[self.contexts addObject:ctx];ctx.htmlProvider=[ProductionDiscoveryHTMLProvider new];
        ctx.htmlToken=[ctx.htmlProvider loadHTMLForURL:url completion:^(NSString *html,NSURL *finalURL,NSError *error){
            [self.contexts removeObject:ctx];if(!ctx.cancelled)completion(html,finalURL,error);ctx.htmlProvider=nil;
        }];
    });return ctx;
}
- (void)cancelHTMLRequest:(id)token { [self cancelProbe:token]; }
@end
