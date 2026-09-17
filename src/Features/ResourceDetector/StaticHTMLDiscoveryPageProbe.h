#import <Foundation/Foundation.h>
#import "ResourceDiscoveryCoordinator.h"
#import "URLPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// 详情页静态 HTML 探测器。每个调用可并行，适用于列表页批量详情探测。
/// 初始地址与每次重定向都执行 URLPolicy 文本校验和 DNS 后 IP 校验。
@interface StaticHTMLDiscoveryPageProbe : NSObject <ZZDiscoveryPageProbing, ZZDiscoveryHTMLProviding>

@property (nonatomic, assign) NSUInteger maxHTMLBytes;       // 默认 2 MB
@property (nonatomic, assign) NSTimeInterval requestTimeout; // 默认 12 秒

- (instancetype)initWithPolicy:(nullable URLPolicy *)policy;

/// 可注入协议类的测试入口；生产代码使用上面的默认临时会话。
- (instancetype)initWithPolicy:(nullable URLPolicy *)policy
           sessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;

@end

NS_ASSUME_NONNULL_END
