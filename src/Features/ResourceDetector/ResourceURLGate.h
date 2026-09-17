//
//  ResourceURLGate.h — 模块 17｜资源 URL 统一安全校验入口
//
//  全部资源 URL（用户输入 / 导航重定向 / 页面发现的视频 / poster / HEAD /
//  缩略图 / AVURLAsset / 下载）统一经过同一 URLPolicy：
//   1) 文本阶段（scheme、localhost、IP 字面量分类）——同步、无网络；
//   2) DNS 解析后逐 IP 校验——异步、解析失败视为拒绝。
//      预解析不是 peer-IP 绑定，不提供严格 DNS rebinding 防护。
//  取代 App 内旧 isSafeResourceURL: 的仅 scheme 检查。
//

#import <Foundation/Foundation.h>
#import "URLPolicy.h"

NS_ASSUME_NONNULL_BEGIN

@interface ResourceURLGate : NSObject
@property (nonatomic, strong) URLPolicy *policy;

/// 校验总开关（默认 YES）。测试模式（EnvCore.isTestMode）下关闭以允许本地
/// server / 假域名跑功能测试；生产模式必须保持 YES（文本 + DNS 全链路）。
@property (nonatomic, assign) BOOL rd_checksEnabled;

/// 文本阶段决策（同步、无网络）。nil URL 视为拒绝。
- (URLPolicyDecision *)textDecisionForURL:(nullable NSURL *)url;

/// 便捷布尔：文本阶段是否放行。
- (BOOL)isTextAllowed:(nullable NSURL *)url;

/// 完整校验：文本放行后异步解析主机全部 IP 并逐 IP 校验，
/// 在主线程回调最终决策；解析失败（空数组）视为拒绝。
- (void)verifyURLAsync:(NSURL *)url
            completion:(void (^)(URLPolicyDecision * _Nullable decision))completion;

@end

NS_ASSUME_NONNULL_END
