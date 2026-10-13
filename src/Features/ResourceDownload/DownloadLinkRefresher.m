//
//  DownloadLinkRefresher.m
//  7zz
//
//  链接刷新编排实现：状态收集在主线程；重探测由注入的 handler 异步执行，
//  迟到回调以“任务仍处于 Failed”为唯一放行条件。
//

#import "DownloadLinkRefresher.h"
#import "RDURLUtilities.h"

static NSString * const kLinkRefreshStatusFetching = @"链接已失效，正在重新获取…";
static NSString * const kLinkRefreshStatusFailed = @"链接已失效，可点击“重新获取”重试";
static NSString * const kLinkRefreshStatusNoSource = @"链接已失效且来源页不可用，可点击“重新获取”重试";

@interface DownloadLinkRefresher ()
@property (nonatomic, strong) DownloadManager *manager;
@property (nonatomic, copy) DownloadLinkReprobeHandler reprobeHandler;
@property (nonatomic, strong) NSMutableSet<NSString *> *refreshingIdentifiers;
@end

@implementation DownloadLinkRefresher

- (instancetype)initWithManager:(DownloadManager *)manager
                 reprobeHandler:(DownloadLinkReprobeHandler)handler {
    self = [super init];
    if (self) {
        _manager = manager;
        _reprobeHandler = [handler copy];
        _refreshingIdentifiers = [NSMutableSet set];
    }
    return self;
}

#pragma mark - 入口

- (void)handleJobDidFail:(DownloadJob *)job reason:(NSString *)reason linkExpired:(BOOL)linkExpired {
    if (!linkExpired) return; // 本地错误/取消/普通失败绝不触发链接刷新
    dispatch_async(dispatch_get_main_queue(), ^{
        [self beginRefreshForJob:job manual:NO];
    });
}

- (void)refreshJobManually:(NSString *)identifier {
    dispatch_async(dispatch_get_main_queue(), ^{
        DownloadJob *job = nil;
        for (DownloadJob *candidate in [self.manager allJobs]) {
            if ([candidate.identifier isEqualToString:identifier]) { job = candidate; break; }
        }
        if (!job) return;
        [self beginRefreshForJob:job manual:YES];
    });
}

- (BOOL)isRefreshingJob:(NSString *)identifier {
    if (!identifier.length) return NO;
    // 只在主线程读取（与写入同线程）。
    if (![NSThread isMainThread]) {
        __block BOOL refreshing = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            refreshing = [self.refreshingIdentifiers containsObject:identifier];
        });
        return refreshing;
    }
    return [self.refreshingIdentifiers containsObject:identifier];
}

#pragma mark - 刷新流程（主线程）

- (void)beginRefreshForJob:(DownloadJob *)job manual:(BOOL)manual {
    if (!job || job.state != DownloadJobStateFailed) return;
    if ([self.refreshingIdentifiers containsObject:job.identifier]) return; // 不并发重复刷新
    if (!manual && job.linkRefreshAttempted) return; // 自动刷新每任务最多一次
    if (!self.reprobeHandler) return;

    NSURL *sourcePageURL = nil;
    if (job.sourcePageURL.length) sourcePageURL = [NSURL URLWithString:job.sourcePageURL];
    if (!sourcePageURL && job.referer.length) sourcePageURL = [NSURL URLWithString:job.referer];

    job.linkRefreshAttempted = YES; // 先占位：刷新期间任何失败/取消都不得再次自动触发
    [self.refreshingIdentifiers addObject:job.identifier];
    [self reportStatus:job status:kLinkRefreshStatusFetching];

    if (!sourcePageURL || ![sourcePageURL.scheme.lowercaseString hasPrefix:@"http"]) {
        [self.refreshingIdentifiers removeObject:job.identifier];
        [self reportStatus:job status:kLinkRefreshStatusNoSource];
        return;
    }

    DownloadJob *target = job;
    DownloadLinkReprobeHandler handler = self.reprobeHandler;
    handler(sourcePageURL, ^(NSArray<DetectedMedia *> *media, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshingIdentifiers removeObject:target.identifier];
            // 唯一放行条件：任务仍是 Failed。用户已取消（Cancelled）或
            // 状态被其它路径改变时，一律放弃——不得复活、不得重建任务。
            if (target.state != DownloadJobStateFailed) {
                [self reportStatus:target status:@""];
                return;
            }
            if (!media.count) {
                [self reportStatus:target status:kLinkRefreshStatusFailed];
                return;
            }
            DetectedMedia *best = [self bestMediaForJob:target fromCandidates:media];
            if (!best || !best.mediaURL.length) {
                [self reportStatus:target status:kLinkRefreshStatusFailed];
                return;
            }
            NSURL *newURL = [NSURL URLWithString:best.mediaURL];
            BOOL accepted = [self.manager restartFailedJobWithIdentifier:target.identifier
                                                               sourceURL:newURL
                                                           expectedLength:best.sizeBytes
                                                                     etag:nil
                                                             lastModified:nil
                                                            acceptRanges:NO];
            if (!accepted) {
                // 重启被拒（如新地址被安全策略阻止）：保持单项失败状态。
                [self reportStatus:target status:kLinkRefreshStatusFailed];
            }
        });
    });
}

- (void)reportStatus:(DownloadJob *)job status:(NSString *)status {
    if (self.statusHandler) self.statusHandler(job, status ?: @"");
}

#pragma mark - 候选匹配

- (DetectedMedia *)bestMediaForJob:(DownloadJob *)job
                    fromCandidates:(NSArray<DetectedMedia *> *)candidates {
    if (!job || !candidates.count) return nil;
    // 稳定资源身份必须**忽略 CDN 签名/过期参数**（RDResourceGroupingIdentity）。
    // 2026-10-13 真实现场：重探测候选里同一影片的旧/新签名是两条不同的
    // dedupKey；此前这里用保留全部参数的 RDCanonicalResourceURL，于是只有旧
    // 签名那条能进池——新签名被当成「别的资源」踢出，过期让位根本没机会跑，
    // 410 后自动刷新拿回同一个死链接。方法头注释里的「忽略签名」说的就是这个
    // 语义，实现此前与注释不符。
    NSString *jobIdentity = [DownloadManager sourceIdentityForURL:job.sourceURL];
    NSString *jobGroupIdentity = RDResourceGroupingIdentity(job.sourceURL);

    // 1) 稳定资源身份匹配（忽略 CDN 签名/过期参数）。
    NSMutableArray<DetectedMedia *> *pool = [NSMutableArray array];
    if (jobGroupIdentity.length) {
        for (DetectedMedia *media in candidates) {
            NSURL *url = [NSURL URLWithString:media.mediaURL];
            if (!url) continue;
            NSString *identity = RDResourceGroupingIdentity(url);
            if (identity.length && [identity isEqualToString:jobGroupIdentity]) [pool addObject:media];
        }
    }
    // 分组身份异常为空时才退回下载身份，绝不因实现改动把原有匹配面收窄。
    if (!pool.count && jobIdentity.length) {
        for (DetectedMedia *media in candidates) {
            NSURL *url = [NSURL URLWithString:media.mediaURL];
            if (!url) continue;
            NSString *identity = [DownloadManager sourceIdentityForURL:url];
            if (identity.length && [identity isEqualToString:jobIdentity]) [pool addObject:media];
        }
    }

    // 2) 身份不再匹配时（站点换了文件命名）：仅当标题能确认同一资源才继续，
    //    多个不同资源且标题对不上时宁可不刷新，也绝不猜错资源。
    if (!pool.count) {
        NSString *title = [job.resourceTitle stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (title.length) {
            for (DetectedMedia *media in candidates) {
                NSString *mediaTitle = [media.title stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (mediaTitle.length && [mediaTitle isEqualToString:title]) [pool addObject:media];
            }
        } else if (candidates.count == 1) {
            [pool addObject:candidates.firstObject];
        }
    }
    if (!pool.count) return nil;

    // 3) 过期签名让位（2026-10-13 真实现场驱动）。hanime2.org 每次取页给全部媒体
    //    换一套签名（约 24–32h 有效）；重探测候选里「动态腿（共享 WebKit 会话的
    //    缓存页）的旧签名」与「静态腿的新签名」并存，而动态结果在合并列表里排前
    //    —— 此前取同画质第一条恰好总选旧签名，410 后自动刷新等于白刷一次。
    //    判据是 URL **自己声明**的过期时刻（RDLinkTokenStateForURL）：
    //    · 只让「确凿已过期」的让位，且仅当同池里还有别家可换时才让；
    //    · 判定不出来的候选（Unknown）绝不剔除 —— 保证刷新只会变强，
    //      不会因判定失败变弱。
    if (pool.count > 1) {
        NSMutableArray<DetectedMedia *> *live = [NSMutableArray array];
        NSUInteger expiredCount = 0;
        for (DetectedMedia *media in pool) {
            NSURL *u = [NSURL URLWithString:media.mediaURL ?: @""];
            if (u && RDLinkTokenStateForURL(u) == RDLinkTokenExpired) expiredCount++;
            else [live addObject:media];
        }
        if (expiredCount > 0 && live.count > 0) pool = live;
    }

    // 4) 优先原画质。
    if (job.qualityHint.length) {
        for (DetectedMedia *media in pool) {
            if ([media.quality isEqualToString:job.qualityHint]) return media;
        }
    }
    // 5) 原画质不可用 → 最低可用画质。
    DetectedMedia *lowest = nil;
    NSInteger lowestRank = NSIntegerMax;
    for (DetectedMedia *media in pool) {
        NSInteger rank = [DownloadLinkRefresher qualityRank:media.quality];
        if (rank < lowestRank || (rank == lowestRank && !lowest)) {
            lowestRank = rank;
            lowest = media;
        }
    }
    return lowest ?: pool.firstObject;
}

+ (NSInteger)qualityRank:(NSString *)quality {
    if (!quality.length) return NSIntegerMax;
    NSScanner *scanner = [NSScanner scannerWithString:quality];
    NSInteger value = 0;
    if ([scanner scanInteger:&value] && value > 0) return value;
    return NSIntegerMax;
}

@end
