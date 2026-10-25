//
//  HTTPPrivacyPolicy.h — 模块 08｜请求隐私头策略（纯逻辑、无网络、无 GUI）
//
//  通用 refererHeaderForRequestURL 规则（媒体传输使用下方专用净化方法）：
//  · 跨域请求默认不发送 Referer（返回 nil，调用方不得设置该头）；
//  · 同域请求默认也只允许发送 origin（https://site.test），不包含
//    path / query / fragment —— 避免泄露 token、用户 ID、签名参数；
//  · 该默认档可通过 refererMode / setRefererModeOverride: 切换到
//    「完整来源页参考」（本文件下方 HTTPRefererMode 说明），用于救回
//    校验完整路径 Referer 的热链保护 CDN；切档后跨域仍旧一律不发。
//
//  本文件不读偏好、不依赖 PreferencesStore：档位由 App 层启动时注入
//  （静态注入 + 测试覆盖，与 URLPolicy 的 setSystemProxyActiveOverride: 同族写法）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Referer 强度档位。
typedef NS_ENUM(NSInteger, HTTPRefererMode) {
    HTTPRefererModeOrigin = 0,      ///< 仅 origin（默认，现状行为）
    HTTPRefererModeFullPath = 1,    ///< 同源时发送完整来源页 URL（含 path/query，去 fragment）
    HTTPRefererModeNone = 2,        ///< 一律不发 Referer
};

@interface HTTPPrivacyPolicy : NSObject

/// 当前档位（默认 Origin）。非法注入值一律按 Origin 处理。
+ (HTTPRefererMode)refererMode;

/// 测试/App 注入：nil 恢复默认 Origin。
+ (void)setRefererModeOverride:(nullable NSNumber *)override;

/// 请求 requestURL、来源页面 pageURL 时允许的 Referer 值；nil 表示不发送。
/// 任一参数为 nil 时返回 nil。
/// · Origin：跨域 nil，同域仅 origin；
/// · FullPath：跨域 nil（绝不跨域泄露来源路径），同域发完整来源页 URL
///   （scheme+host+port+path+query，剥掉 fragment 与 userinfo）；
/// · None：一律 nil。
+ (nullable NSString *)refererHeaderForRequestURL:(nullable NSURL *)requestURL
                                     fromPageURL:(nullable NSURL *)pageURL;

/// Media transports send only the validated origin of an explicit Referer
/// (FullPath mode: the full same-origin page URL; None mode: no Referer at all).
+ (void)sanitizeMediaRequest:(NSMutableURLRequest *)request;

/// Redirect hop policy: same-origin preserves current request headers;
/// cross-origin clears Authorization/Cookie but retains sanitized origin Referer.
/// Never copy secrets
/// from the task's original request after a previous hop stripped them.
+ (void)sanitizeRedirectRequest:(NSMutableURLRequest *)request fromRequest:(nullable NSURLRequest *)previous;

/// 仅 http/https 且含 host 的 origin（含非默认端口）；其余返回 nil。
+ (nullable NSString *)originForURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END
