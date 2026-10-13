//
//  RDMetadataRecoveryCoordinator.h — 元数据恢复编排（2026-10-12 第 38 轮接线）
//
//  背景：三个生产组件（RDCoverRecoveryEngine / RDDisplayMetadataRecoveryStore /
//  ResourceTitleTranslator）此前**代码完整但零引用**——它们承诺的能力
//  （封面自动恢复、标题与封面防退化、非中文标题翻译）在 App 里从不执行，
//  却已被编进主 App 二进制、并计入版本号第一段。
//  本类把它们接到真实调用链上，逐条对应：
//    · RDDisplayMetadataRecoveryStore —— 探测结果落地时按来源页记录标题/封面，
//      持久化到用户偏好；标题/封面退化（token 刷新、重启）时按来源页回补；
//    · ResourceTitleTranslator        —— 卡片标题为非中文时翻译为简体中文并回填；
//    · RDCoverRecoveryEngine          —— 封面加载失败后按固定顺序有限次恢复
//      （内存缓存 → 磁盘缓存 → 原 URL 重试 → 来源页重探测 → 本地首帧）。
//
//  线程：所有对外 completion 固定在主线程回调（与 App 层其余异步接口一致）。
//  边界：本类不写任何磁盘缓存（恢复引擎本身也无写缓存能力）；
//        持久化只走 PreferencesStore 的一个键；不绕过 URLPolicy。
//

#import <Cocoa/Cocoa.h>
#import "DetectedMedia.h"
#import "RDResourceDisplayMetadata.h"

@class URLPolicy;
@class PreferencesStore;

NS_ASSUME_NONNULL_BEGIN

/// 重新访问来源页并取回该页的媒体（生产传 App 层的单页重探测；测试可传 nil）。
typedef void (^RDMetadataReprobeHandler)(NSURL *sourcePageURL,
                                         void (^completion)(NSArray<DetectedMedia *> * _Nullable media));

@interface RDMetadataRecoveryCoordinator : NSObject

/// policy 用于封面 URL 的安全校验；reprobeHandler 提供「重新访问来源页」能力。
- (instancetype)initWithPolicy:(nullable URLPolicy *)policy
                reprobeHandler:(nullable RDMetadataReprobeHandler)reprobeHandler;

/// 测试注入：使用独立偏好 suite，不触碰真实用户偏好。
- (instancetype)initWithPolicy:(nullable URLPolicy *)policy
                reprobeHandler:(nullable RDMetadataReprobeHandler)reprobeHandler
                   preferences:(nullable PreferencesStore *)preferences;

/// 探测结果落地时调用：按规范化 sourcePage 记录标题与封面。
- (void)recordDetectedMedia:(NSArray<DetectedMedia *> *)media;

/// 列表页解析出的封面（键 = 详情页 URL，值 = 该视频在列表中的封面 URL）。
/// 对应 DiscoverySessionController.listingPagePreviewHandler。
- (void)recordListingPosters:(NSDictionary<NSString *, NSString *> *)posterByPageURL;

/// 显示时查询：来源页 → 已记录的展示元数据（nil = 无记录）。用于标题/封面回补。
- (nullable RDResourceDisplayMetadata *)metadataForSourcePageURL:(nullable NSString *)sourcePageURL;

/// 标题解析：需要翻译时给出简体中文译文，否则原样返回。主线程回调、恰好一次。
- (void)resolvedTitleFor:(NSString *)title completion:(void (^)(NSString *title))completion;

/// 封面恢复：仅在封面加载确实失败后调用。主线程回调、恰好一次；失败回 nil。
/// media 为 nil 时直接回 nil（调用方可能在资源换代后迟到触发）。
- (void)recoverCoverForMedia:(nullable DetectedMedia *)media
                  completion:(void (^)(NSImage * _Nullable image))completion;

/// 记住一张已成功解码的封面（供恢复链第 1 步的内存缓存命中）。
- (void)rememberCover:(NSImage *)image forReuseKey:(NSString *)reuseKey;

/// 持久化 / 载入（偏好键固定，见实现）。启动时载入，结果变化后持久化。
- (void)persist;
- (void)loadPersistedState;

/// 取消在途翻译与恢复（任务换代/离开页面）。
- (void)cancelAll;

/// 可观测计数（供套件断言接线真的发生过）。
@property (nonatomic, readonly) NSUInteger recordedMediaCount;
@property (nonatomic, readonly) NSUInteger translatedTitleCount;
@property (nonatomic, readonly) NSUInteger coverRecoveryAttemptCount;

@end

NS_ASSUME_NONNULL_END
