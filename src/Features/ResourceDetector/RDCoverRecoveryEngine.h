//
//  RDCoverRecoveryEngine.h
//  7zz
//
//  资源级封面自动恢复引擎（纯逻辑、无 UI、可 headless 测试）。
//
//  恢复顺序固定（与验收标准一致）：
//    1) 当前有效内存缓存；
//    2) 最近一次成功的磁盘缓存（本引擎只读，绝不写入/覆盖任何缓存）；
//    3) 原封面 URL 有限次数重试（Cookie/Referer/UA 由注入的 fetch provider
//       负责；可恢复错误最多重试 2 次，短退避）；
//    4) 重新访问资源来源页面，提取新的封面 URL 后再取一次；
//    5) 本地安全首帧（仅媒体可本地安全读取时，由 provider 决定）；
//    6) 全部失败 → Failed（调用方展示统一占位图）。
//
//  硬约束：
//   · 同一资源同一时间最多一条恢复链路；在途期间的重复请求共享同一条
//     链路的最终结果，绝不并发发起重复请求；
//   · 每个资源在一个引擎生命周期内只完整尝试一次，之后直接返回上次
//     终态结果，翻页/重绑定不会形成请求风暴；
//   · 每步都有超时（provider 请求自身带超时），整体有看门狗，任何一步
//     都不会无限等待；
//   · 失败结果绝不落盘、绝不覆盖成功缓存（引擎没有写缓存的能力）；
//   · cancelAllRecovery 后，所有未决回调以 Superseded 收尾，迟到结果丢弃。
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "RDResourceDisplayMetadata.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RDCoverRecoveryOutcome) {
    RDCoverRecoveryOutcomeFailed = 0,   // 全链路失败 → 调用方展示统一占位图
    RDCoverRecoveryOutcomeSucceeded,    // 恢复成功，image 为已验证的真实封面
    RDCoverRecoveryOutcomeSuperseded,   // 已被取消/换代，结果必须丢弃
};

typedef void (^RDCoverRecoveryCompletion)(NSImage * _Nullable image,
                                          RDCoverRecoveryOutcome outcome,
                                          RDResourceDisplayMetadata * _Nullable recoveredMetadata);

@interface RDCoverRecoveryEngine : NSObject

// —— 注入的恢复原语（生产由 App 层提供；测试用 mock）——

/// 1) 当前有效内存缓存（同步、廉价）。
@property (nonatomic, copy, nullable) NSImage *(^memoryCacheProvider)(NSString *reuseKey);

/// 2) 最近一次成功的磁盘缓存（只读；completion 恰好一次，可为任意线程）。
@property (nonatomic, copy, nullable) void (^diskCacheProvider)(NSString *reuseKey,
    void(^completion)(NSImage * _Nullable image));

/// 3) 单次“已验证”的封面请求：provider 必须校验 HTTP 状态、MIME 与图片
///    解码，只有完全合法才回调 image != nil。httpStatus/error 供引擎分类
///    是否值得重试（网络层错误或 403/429/5xx 可重试；401/404/410 与
///    “200 但内容不是图片”不重试，直接进入下一恢复步骤）。
@property (nonatomic, copy, nullable) void (^posterFetchProvider)(NSURL *posterURL,
    NSURL * _Nullable sourcePageURL,
    void(^completion)(NSImage * _Nullable image, NSInteger httpStatus, NSError * _Nullable error));

/// 4a) 重新访问来源页面并提取结构化展示元数据（标题 + 预览图 + 可信级别）。
@property (nonatomic, copy, nullable) void (^sourcePageMetadataProvider)(NSURL *sourcePageURL,
    void(^completion)(RDResourceDisplayMetadata * _Nullable metadata));

/// 4b) 兼容旧接口：仅返回封面 URL。若 sourcePageMetadataProvider 已注入则优先使用它。
@property (nonatomic, copy, nullable) void (^sourcePagePosterProvider)(NSURL *sourcePageURL,
    void(^completion)(NSURL * _Nullable posterURL));

/// 5) 本地安全首帧兜底（仅媒体可本地安全读取时返回非 nil；可为 nil）。
@property (nonatomic, copy, nullable) void (^localFrameProvider)(NSString *reuseKey,
    void(^completion)(NSImage * _Nullable image));

/// 6) URL 文本校验（安全策略；未注入时视为放行）。
@property (nonatomic, copy, nullable) BOOL (^urlAllowedProvider)(NSURL *url);

// —— 策略（可注入测试值）——

/// 原封面 URL 最多尝试次数：1 + 最多 2 次重试（默认 3，硬上限 3）。
@property (nonatomic, assign) NSUInteger maxFetchAttempts;
/// 重试退避基数（默认 0.4s；第 n 次重试等待 base*n）。
@property (nonatomic, assign) NSTimeInterval retryBackoffSeconds;
/// 单资源整体看门狗超时（默认 15s；保证任何一步都不会无限等待）。
@property (nonatomic, assign) NSTimeInterval watchdogTimeout;

/// 对单个资源启动封面自动恢复。completion 固定在主线程回调。
/// 在途期间对同一 key 的重复调用共享同一条链路结果（不并发、不重复请求）。
- (void)recoverCoverForReuseKey:(NSString *)reuseKey
                      posterURL:(nullable NSURL *)posterURL
                  sourcePageURL:(nullable NSURL *)sourcePageURL
                     completion:(RDCoverRecoveryCompletion)completion;

/// 取消全部在途恢复（页面换代/离开）。未决 completion 以 Superseded 收尾，
/// 之后所有迟到的 provider 回调全部作废。
- (void)cancelAllRecovery;

- (BOOL)isRecoveringKey:(NSString *)reuseKey;
- (BOOL)hasAttemptedKey:(NSString *)reuseKey;
- (NSUInteger)recoveringKeyCount;

/// 封面响应 MIME 是否可接受：image/*、空（服务器未声明，交给解码兜底）
/// 与 application/octet-stream（同样交给解码验证）。
+ (BOOL)isAcceptablePosterMIME:(nullable NSString *)mime;

/// 是否值得对同一 URL 重试：403（防盗链，Cookie 重试可能有效）、
/// 429 与 5xx。401/404/410 及其它状态视为不可恢复。
+ (BOOL)isRecoverablePosterStatus:(NSInteger)httpStatus;

@end

NS_ASSUME_NONNULL_END
