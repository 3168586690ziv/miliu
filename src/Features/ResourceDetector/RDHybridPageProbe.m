#import "RDHybridPageProbe.h"
#import "RDLog.h"
#import "StaticHTMLDiscoveryPageProbe.h"
#import "ProductionDiscoveryHTMLProvider.h"
#import "RDNetworkValidation.h"
#import "RDURLUtilities.h"
@interface RDHybridContext : NSObject
// ctx 强持有发起探测的 probe（第 47 轮修 90s 超时）。
// 背景：动态腿的 completion 里用 `__weak` 取 owner，等它几秒后回来时 owner 已被释放，
// 于是 `if(callbackOwner) [callbackOwner finishIfBothLegsDone:ctx];` **整句被跳过**——
// 两腿其实都成功了（实测 2 秒拿到 133KB 页面、4 条媒体），但永远没人收尾，
// 调用方等满 90s 拿到「超时无结果」。ctx 本来就活到收尾，让它强持有 probe 即可，
// 不引入循环引用（publish final:YES 会把 ctx 从 contexts 移除，随后一起释放）。
@property (nonatomic, strong) id ownerProbe;
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
@property BOOL staticConverged;   // 静态腿丰收提前收敛标志（见 startContext 注释）
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
        ctx.ownerProbe = self;   // 见 RDHybridContext 注释：保证回调期 owner 存活
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
            // ── 静态腿丰收提前收敛（2026-10-06 语料实测驱动）──
            // 图片/素材聚合页的媒体全部在静态 HTML 里（pexels 338 条、stocksnap 51 条
            // 均在 14s 内由静态腿拿满），但动态 WebKit 腿仍会跑满 45s 硬超时，用户
            // 白等半分钟且探针整体被判超时。静态腿已达丰收阈值时不再等动态腿：
            // 立即按最终结果收敛。阈值取 60（远高于常规视频页的 1–10 条，不会
            // 让"静态腿只抓到零星图片、真视频在动态腿"的页面提前收工）。
            if(!ctx.dynamicDone && ctx.staticMedia.count >= 60 && !ctx.staticConverged){
                ctx.staticConverged=YES;
                ctx.dynamicDone=YES;          // 让 finishIfBothLegsDone 直接收敛
                // 已启动的动态腿立即停：cancelAll 明确不触发 completion，槽位必须自己还，
                // 否则全局动态并发（2）会被一条已无意义的 WebKit 腿占满 45s。
                if(ctx.hasDynamicSlot){
                    ctx.hasDynamicSlot=NO;
                    if(self.activeDynamic>0)self.activeDynamic--;
                }
                [ctx.dynamic cancelAll];
                [ctx.dynamic detachWebView];
                [self pump];
                RDLogWrite(@"probe", @"静态腿丰收 media=%lu（≥60），提前收敛不再等动态腿", (unsigned long)ctx.staticMedia.count);
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
                if(ctx.cancelled || ctx.dynamicDone){owner.activeDynamic--;[owner pump];return;}
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
                        RDLogWrite(@"probe", @"动态腿完成 done=%d 结果=%lu 消费端=%d",
                                   (int)ctx.dynamicDone, (unsigned long)(result.media.count),
                                   (int)(ctx.completion != nil));
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
    RDLogWrite(@"probe", @"finishIfBothLegsDone 进入 cancelled=%d hasConsumer=%d",
               (int)ctx.cancelled, (int)[self contextHasConsumer:ctx]);
    if(ctx.cancelled || ![self contextHasConsumer:ctx])return;
    if(!ctx.staticDone || !ctx.dynamicDone){
        RDLogWrite(@"probe", @"收尾等待 staticDone=%d dynamicDone=%d", (int)ctx.staticDone, (int)ctx.dynamicDone);
        return;
    }
    RDLogWrite(@"probe", @"收尾开始：两腿均完成，准备合并");
    NSArray *merged=[self mergedMediaForContext:ctx];
    RDLogWrite(@"probe", @"收尾合并完成 media=%lu", (unsigned long)merged.count);
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
    NSArray *allMedia=[dynamicMedia arrayByAddingObjectsFromArray:ctx.staticMedia];
    // ── HLS/DASH 分片收口（第 47 轮：一个视频被拆成几十个碎片的根因修复）──
    // 播放 HLS 时 hls.js 逐片 fetch（seg-000.ts、seg-001.ts…），动态腿把每个分片
    // 请求都当独立媒体上报 → 列表出现几十上百个「视频」，点任何一个下载到的只是片段。
    // 收口规则：本批若存在清单，则把「与清单同 host 同目录、且文件名呈序号尾缀」的
    // 分片整体剔除；清单本身（m3u8/mpd）保留，用户点它下载的是完整流。
    // 单独的 .ts 直链（无清单在场）**不受影响**，仍是合法媒体。
    NSMutableArray<NSURL *> *manifestURLs=[NSMutableArray array];
    for(DetectedMedia *m in allMedia){
        NSString *ext=[[NSURL URLWithString:m.mediaURL ?: @""].path.pathExtension.lowercaseString copy];
        if(ext.length && RDIsManifestExtension(ext)){
            NSURL *u=[NSURL URLWithString:m.mediaURL];
            if(u) [manifestURLs addObject:u];
        }
    }
    NSUInteger droppedFragments=0;
    for(DetectedMedia *m in allMedia){
        if(manifestURLs.count
           && RDIsHLSPlaylistFragment([NSURL URLWithString:m.mediaURL ?: @""], manifestURLs)){
            droppedFragments++;
            continue;   // 分片：不进入结果列表（清单才是完整视频）
        }
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
    if(droppedFragments>0){
        RDLogWrite(@"probe", @"分片收口 清单=%lu 剔除分片=%lu 保留媒体=%lu",
                   (unsigned long)manifestURLs.count, (unsigned long)droppedFragments,
                   (unsigned long)merged.count);
    }
    return merged;
}
// 发布一次结果。final=NO 时保留消费者（稍后还会发布动态腿合并后的最终结果，
// 调用方必须按「更新」而非「结论」处理）；final=YES 时消费回调并释放上下文。
- (void)publish:(RDHybridContext *)ctx media:(NSArray *)media error:(NSError *)error final:(BOOL)isFinal {
    RDLogWrite(@"probe", @"publish final=%d media=%lu cancelled=%d inc=%d one=%d",
               (int)isFinal, (unsigned long)media.count, (int)ctx.cancelled,
               (int)(ctx.incrementalCompletion != nil), (int)(ctx.completion != nil));
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
