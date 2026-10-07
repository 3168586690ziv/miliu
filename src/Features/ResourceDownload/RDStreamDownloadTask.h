#import "DownloadManager.h"
NS_ASSUME_NONNULL_BEGIN
@interface RDStreamDownloadTask : NSObject<RDDownloadTask>
- (instancetype)initWithBackend:(id<RDDownloadBackend>)backend request:(NSURLRequest *)request output:(NSURL *)output muxer:(NSURL *)muxer progress:(void (^)(int64_t,int64_t,int64_t))progress completion:(void (^)(NSURL *,NSHTTPURLResponse *,NSError *))completion;
// 合流开始通知（2026-10-07 审计修复）：合流阶段不产生下载进度回调，
// manager 据此把看门狗预算从 45s 放宽到 300s（慢磁盘大文件合流可能超 45s）。
@property (nonatomic, copy, nullable) void (^willBeginMuxing)(void);
- (void)start;
/// 清单解析入口 URL。界面选中具体 HLS 档位时是来源主清单（分离音轨只能
/// 从 master 解析）；为空时使用 request.URL。
@property (nonatomic, strong, nullable) NSURL *startURL;
/// 界面选中的具体档位子清单 URL：主清单内命中时固定选择该变体，
/// 未命中时回退到带宽择优（确定性规则）。
@property (nonatomic, copy, nullable) NSURL *pinnedVariantURL;
@end
NS_ASSUME_NONNULL_END
