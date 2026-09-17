//
//  ProductionDiscoveryPageProbe.h — 第 5 阶段｜生产单页面探测器适配器
//
//  把现有生产类 WebProbe（模块 17，含 generation/取消/硬超时/纯函数分析，
//  已有 97 项测试覆盖）适配为协调器的 ZZDiscoveryPageProbing 协议：
//  · probePageURL → WebProbe probeURL:completion:（RDProbeResult → DetectedMedia 列表）；
//  · 回调固定主线程；
//  · 取消凭据为 @(generation)；cancelProbe: 统一走 WebProbe cancelAll
//    （多页面串行场景同一时刻至多一个在途探测，cancelAll 即取消当前页；
//    WebProbe 自身 generation 机制保证取消后迟到回调不会调用 completion）。
//
//  不复制 WebProbe 逻辑；不绕过 URLPolicy（WebProbe 内部仍做文本校验）。
//

#import <Foundation/Foundation.h>
#import "ResourceDiscoveryCoordinator.h"
#import "WebProbe.h"

NS_ASSUME_NONNULL_BEGIN

@interface ProductionDiscoveryPageProbe : NSObject <ZZDiscoveryPageProbing>

@property (nonatomic, strong, readonly) WebProbe *webProbe;

- (instancetype)initWithPolicy:(URLPolicy *)policy;

@end

NS_ASSUME_NONNULL_END
