#import <Cocoa/Cocoa.h>
#import "RDMetadataTransport.h"
#import "DetectedMedia.h"

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, RDMetadataState) { RDMetadataKnown, RDMetadataUnknown, RDMetadataUnsupported, RDMetadataTimeout, RDMetadataFailed, RDMetadataLoading };
@interface RDMetadataField : NSObject
@property RDMetadataState state;
@property id _Nullable value;
@property NSString * _Nullable source;
- (NSString *)statusText;
@end
@interface RDMetadataSnapshot : NSObject
@property NSArray<NSDictionary *> *variants;
@property RDMetadataField *duration; // NSNumber seconds; images: unsupported / not-applicable
@property RDMetadataField *dimensions; // NSValue size, display orientation
@property RDMetadataField *size; // NSNumber bytes; manifests always unknown
@property RDMetadataField *preview; // NSImage, at most 1024 px per side
@end

// Main queue API. One token per subscriber. Last cancellation cancels all underlying work.
// 缓存按规范化媒体身份（URL/poster/sourcePage/resourceKind/isManifest）分字段保存：
// 已成功字段（含缩略图）与结构性未知复用 5 分钟，普通未知 30 秒，失败/超时不缓存
// （下次订阅重试）。容量 64 个媒体身份、缩略图单独上限 16。reload 显式清除成功缓存；
// 同一请求合并为同一 inflight work；排队中的 work/缩略图可取消，已完成字段保留。
@interface RDMetadataService : NSObject
- (instancetype)initWithTransport:(id<RDMetadataTransporting>)transport;
- (RDMetadataToken *)subscribeMedia:(DetectedMedia *)media reload:(BOOL)reload update:(void (^)(RDMetadataSnapshot *))update;
// 列表首屏预热：只启动缩略图（海报）通道，绝不启动时长/大小/分辨率等
// 需要真实媒体读取的 leg——那些只在用户真正选中该资源时读取。
// 同一个媒体随后被 subscribeMedia:reload:update: 订阅时，会在已有 work 上
// 继续补齐媒体 leg，不会重复下载海报。
- (RDMetadataToken *)subscribePreviewOnlyForMedia:(DetectedMedia *)media
                                           update:(void (^)(RDMetadataSnapshot *))update;
// 同步取回已缓存的字段/缩略图（无缓存返回 nil）：切换回同一媒体时立即恢复显示，
// 再只请求缺失/过期字段。
- (RDMetadataSnapshot *)cachedSnapshotForMedia:(DetectedMedia *)media;
// 用户点击当前项时调用：把该媒体在排队中的 work 与缩略图请求提到队列最前
// （下一个释放的并发槽位先执行它）。不取消、不抢占在途 work，也不突破并发上限。
- (void)prioritizeMedia:(DetectedMedia *)media;
// 分阶段超时预算：HEAD 3s；小请求（探测/清单/海报/图像）10s；
// 大块传输按 256KB/s 保守吞吐外推，30s 全局看门狗封顶。测试锁定。
+ (NSTimeInterval)requestTimeoutForMethod:(NSString *)method budget:(NSUInteger)budget;
@end
NS_ASSUME_NONNULL_END
