//
//  HTTPPrivacyPolicy.h — 模块 08｜请求隐私头策略（纯逻辑、无网络、无 GUI）
//
//  通用 refererHeaderForRequestURL 规则（媒体传输使用下方专用净化方法）：
//  · 跨域请求默认不发送 Referer（返回 nil，调用方不得设置该头）；
//  · 同域请求也只允许发送 origin（https://site.test），绝不包含
//    path / query / fragment —— 避免泄露 token、用户 ID、签名参数。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HTTPPrivacyPolicy : NSObject

/// 请求 requestURL、来源页面 pageURL 时允许的 Referer 值；nil 表示不发送。
/// 任一参数为 nil 时返回 nil。
+ (nullable NSString *)refererHeaderForRequestURL:(nullable NSURL *)requestURL
                                     fromPageURL:(nullable NSURL *)pageURL;

/// Media transports send only the validated origin of an explicit Referer.
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
