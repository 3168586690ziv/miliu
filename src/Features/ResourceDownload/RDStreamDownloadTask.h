#import "DownloadManager.h"
NS_ASSUME_NONNULL_BEGIN
@interface RDStreamDownloadTask : NSObject<RDDownloadTask>
- (instancetype)initWithBackend:(id<RDDownloadBackend>)backend request:(NSURLRequest *)request output:(NSURL *)output muxer:(NSURL *)muxer progress:(void (^)(int64_t,int64_t,int64_t))progress completion:(void (^)(NSURL *,NSHTTPURLResponse *,NSError *))completion;
- (void)start;
/// 清单解析入口 URL。界面选中具体 HLS 档位时是来源主清单（分离音轨只能
/// 从 master 解析）；为空时使用 request.URL。
@property (nonatomic, strong, nullable) NSURL *startURL;
/// 界面选中的具体档位子清单 URL：主清单内命中时固定选择该变体，
/// 未命中时回退到带宽择优（确定性规则）。
@property (nonatomic, copy, nullable) NSURL *pinnedVariantURL;
@end
NS_ASSUME_NONNULL_END
