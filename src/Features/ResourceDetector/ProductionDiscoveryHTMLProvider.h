//
//  ProductionDiscoveryHTMLProvider.h — 第 5 阶段｜生产页面 HTML 来源
//
//  用专用 WKWebView（App 容器内的**持久化**会话存储，与手动验证窗口共用
//  同一实例：第 13 轮起由会话隔离改为会话延续，见 .m 中的说明）加载页面并
//  取回渲染后的 outerHTML：
//  · 导航的每一跳（含重定向）经 URLPolicy（evaluateRedirect 文本校验 +
//    ResourceURLGate verifyURLAsync DNS 后全 IP 校验）——与生产资源探测
//    WebView 的 decidePolicyForNavigationAction 同一安全边界，不绕过任何
//    现有安全限制；
//  · about:blank（WebKit 内部空文档，navigationType==Other）放行（对齐生产实现）；
//  · HTML 超过 8MB 截断（资源耗尽防护，对齐 WebProbe.maxHTMLBytes）；
//  · 20s 硬超时定时器 → 超时错误；
//  · 取消凭据 = @(generation)；cancelHTMLRequest: stopLoading 并使迟到
//    回调作废（generation 递增）；
//  · 回调固定主线程（finalURL 为重定向后的最终页面 URL，供链接提取作 base）；
//  · WebKit 线程要求：WKWebView / WKWebViewConfiguration 创建、loadRequest、
//    stopLoading、evaluateJavaScript 只在主线程发生（本类可能被
//    zz.resourcediscovery.state 等后台串行队列调用，WebKit 部分统一异步
//    跳主线程；webView 属性只在主线程读写）。
//
//  只负责 HTML 获取，不做媒体分析（分析由 WebProbe/协调器层负责）。
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "ResourceDiscoveryCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

/// WebView 工厂：必须且只会在主线程被调用（与 RDProbeWebViewFactory 同款
/// 注入模式）。生产默认工厂创建真实 WKWebView；测试注入线程记录工厂
/// 验证创建/加载/拆除的线程归属。
@protocol ZZDiscoveryWebViewFactory <NSObject>
- (WKWebView *)makeWebViewWithConfiguration:(WKWebViewConfiguration *)configuration;
@end

@interface ProductionDiscoveryHTMLProvider : NSObject <ZZDiscoveryHTMLProviding, WKNavigationDelegate>

- (instancetype)init;
/// 注入 WebView 工厂（测试用）；nil 走默认真实 WKWebView 工厂。
- (instancetype)initWithWebViewFactory:(nullable id<ZZDiscoveryWebViewFactory>)factory;

@end

NS_ASSUME_NONNULL_END
