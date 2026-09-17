//
//  DownloadLinkRefresher.h
//  7zz
//
//  下载链接自动刷新（单资源级）。
//
//  职责：
//   · 只对“链接失效类”失败触发（HTTP 401/403/404/410、签名/token 过期
//     表现出的 403/410、伪媒体 HTML 响应、服务器明确表示链接失效）；
//     本地磁盘不足、权限错误、用户取消等绝不触发；
//   · 根据任务保留的来源页 URL 重新探测该单页，只匹配当前资源
//     （稳定资源身份 + 标题确认），不重新创建整个批次；
//   · 匹配成功后原地重启原 DownloadJob（保留 identifier/标题/画质/用户
//     选择/目标文件名），绝不产生第二个任务或重复文件；
//   · 优先匹配原画质；原画质不可用时选择最低可用画质；
//   · 每个任务自动刷新最多一次；手动“重新获取”每 tap 恰好一次；
//   · 刷新回调返回时若任务已不再是 Failed（如用户已取消），一律放弃，
//     任务状态不得复活、不得重建、不得写入新文件。
//
//  线程模型：公开方法任意线程可调（内部统一转发主线程）；
//  reprobeHandler/statusHandler 固定在主线程回调。
//

#import <Foundation/Foundation.h>
#import "DownloadManager.h"
#import "DetectedMedia.h"

NS_ASSUME_NONNULL_BEGIN

/// 重新探测来源页的回调：返回该页当前可用的媒体候选（含画质）。
typedef void (^DownloadLinkReprobeCompletion)(NSArray<DetectedMedia *> * _Nullable media,
                                              NSError * _Nullable error);
/// App 层提供的单页重探测能力（生产用 StaticHTMLDiscoveryPageProbe）。
typedef void (^DownloadLinkReprobeHandler)(NSURL *sourcePageURL,
                                           DownloadLinkReprobeCompletion completion);

@interface DownloadLinkRefresher : NSObject

- (instancetype)initWithManager:(DownloadManager *)manager
                 reprobeHandler:(DownloadLinkReprobeHandler)handler;

/// 恢复过程中的状态文本回调（主线程；如“链接已失效，正在重新获取…”）。
@property (nonatomic, copy, nullable) void (^statusHandler)(DownloadJob *job, NSString *statusText);

/// DownloadManager 链接失效失败的转发入口（manager.linkRefreshHandler 应指向这里）。
/// linkExpired=NO 的失败一律忽略（本地错误不触发链接刷新）。
- (void)handleJobDidFail:(DownloadJob *)job reason:(nullable NSString *)reason linkExpired:(BOOL)linkExpired;

/// 用户手动“重新获取”：每次调用恰好触发一次重探测 + 至多一次原地重启。
- (void)refreshJobManually:(NSString *)identifier;

- (BOOL)isRefreshingJob:(NSString *)identifier;

/// 从重探测候选中选择应重启的媒体：优先稳定资源身份匹配；身份不再匹配时
/// 用标题确认同一资源；然后优先原画质（qualityHint），不可用时选最低
/// 可用画质。无法确认同一资源时返回 nil（保持失败状态，绝不猜）。
- (nullable DetectedMedia *)bestMediaForJob:(DownloadJob *)job
                            fromCandidates:(NSArray<DetectedMedia *> *)candidates;

/// 画质排序值：解析“720p/1080p”等前导数字；无法解析返回 NSIntegerMax
/// （不会被“最低画质”规则选中，除非没有其它候选）。
+ (NSInteger)qualityRank:(nullable NSString *)quality;

@end

NS_ASSUME_NONNULL_END
