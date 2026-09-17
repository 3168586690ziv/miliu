//
//  SubpageLinkExtractor.h — 第 2 阶段｜总站探测·子页面链接提取器
//
//  纯逻辑（仅 Foundation）：HTML + baseURL → 候选子页面 URL 列表。
//
//  处理流程：
//  · 仅提取 <a href="..."> / <a href='...'>（大小写不敏感，支持属性间空格）；
//  · 相对链接按 baseURL 解析为绝对 URL（复用 NSURL 系统解析，与 WebProbe 同源）；
//  · 仅接受 http/https 且必须存在 host；
//  · 去除 fragment；scheme/host 比较不区分大小写；
//    不修改路径、查询参数与尾部斜杠（服务器可能有语义）；
//  · 默认仅保留与 baseURL 同源的链接（scheme + host + 有效端口；
//    显式默认端口 443/80 视同缺省，页面 https 时不放行 http）；
//  · 排除带用户名/密码的 URL 与 javascript:/data:/blob:/file:/ftp:/mailto: 等协议；
//  · 排除静态资源与媒体清单扩展名（css/js/png/…/mp4/m3u8/mpd/…）；
//  · 排除登录/注册/搜索等操作页路径段（login/register/…，页面扩展名剥离后比较）；
//  · 排除与 baseURL 规范化后相同的链接（种子页自身不是候选子页面）；
//  · 按首次出现顺序去重返回（fragment 与 scheme/host 大小写不参与去重）；
//  · 最多返回 maxCount 条；maxCount == 0 返回空数组；
//    重复链接与被过滤链接不消耗返回数量；
//  · html/baseURL 为 nil、baseURL 非 http(s) 或无 host 时返回空数组（宁严勿宽）。
//
//  约束：无 UI、无 WebKit、无网络请求、无下载逻辑、无全局可变状态；
//  相同输入输出稳定。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SubpageLinkExtractor : NSObject

/// 从 HTML 提取候选子页面链接（纯函数，不触网）。
/// @param html 页面 HTML；nil 或空串返回空数组
/// @param baseURL 种子页面 URL，用于相对解析与同源过滤；
///        nil、非 http(s) 或无 host 时返回空数组
/// @param maxCount 最大返回数量；0 返回空数组；
///        重复链接与被过滤链接不消耗数量
/// @return 规范化去重后的候选子页面 URL，按首次出现顺序排列（可能为空，不为 nil）
+ (NSArray<NSURL *> *)extractSubpageLinksFromHTML:(nullable NSString *)html
                                         baseURL:(nullable NSURL *)baseURL
                                         maxCount:(NSUInteger)maxCount;

/// 返回候选子页面 URL 对应的列表页可见标题。键为规范化后的绝对 URL 字符串，
/// 值来自同一 <a> 元素的可见文字（已去标签、解码 HTML 实体并压缩空白）。
/// 只返回通过 extractSubpageLinksFromHTML:baseURL:maxCount: 过滤的候选。
+ (NSDictionary<NSString *, NSString *> *)extractSubpageTitlesFromHTML:(nullable NSString *)html
                                                               baseURL:(nullable NSURL *)baseURL
                                                               maxCount:(NSUInteger)maxCount;

/// 返回候选子页面 URL 对应的列表卡片封面。优先取同一个 <a> 元素内的图片；
/// 对使用 image/cover/<video-id> 的列表，也可按 watch?v=<video-id> 稳定匹配。
/// 属性按 src、data-src、data-original 的顺序选择，仅接受无凭据的 http/https URL。
/// 图片可以来自跨域 CDN；子页面本身仍必须通过现有同源与安全过滤。
+ (NSDictionary<NSString *, NSString *> *)extractSubpagePreviewImagesFromHTML:(nullable NSString *)html
                                                                      baseURL:(nullable NSURL *)baseURL
                                                                     maxCount:(NSUInteger)maxCount;

@end

NS_ASSUME_NONNULL_END
