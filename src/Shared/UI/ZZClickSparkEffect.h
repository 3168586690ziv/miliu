//
//  ZZClickSparkEffect.h — 全局点击火花特效（1:1 移植自用户确认的 React ClickSpark canvas 组件）
//
//  确认参数：sparkColor #ae7ddc / sparkSize 7 / sparkRadius 20 / sparkCount 7 /
//  duration 500ms / easing ease-out（t*(2-t)）/ extraScale 1.0 / lineWidth 2。
//  几何与网页版逐项一致：第 i 条火花角度 = 2π·i/count；距离 d = ease(p)·radius·extraScale；
//  线长 len = size·(1-ease(p))；线段从 (d) 画到 (d+len)。
//
//  实现：CALayer + CAKeyframeAnimation(path) 交给 Core Animation 合成器，
//  无常驻 rAF/定时器；点击瞬间创建 7 条线层，500ms 后自动移除。
//  特效层 hitTest 返回 nil，不拦截任何点击；系统 Reduce Motion 时不生成特效。
//
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// 确认稿常量（测试与实现共用，避免复制数值）。
FOUNDATION_EXPORT double const ZZClickSparkSize;        // 7
FOUNDATION_EXPORT double const ZZClickSparkRadius;      // 20
FOUNDATION_EXPORT NSInteger const ZZClickSparkCount;    // 7
FOUNDATION_EXPORT double const ZZClickSparkDuration;    // 0.5 秒
FOUNDATION_EXPORT double const ZZClickSparkLineWidth;   // 2

/// 确认稿 ease-out：t*(2-t)（网页组件 default 分支）。
extern double ZZClickSparkEaseOut(double t);

/// 单条火花的线段端点（沿 +X 局部坐标；角度由调用方旋转）。
/// d = ease(p)·radius·extraScale；len = size·(1-ease(p))；线段 [d, d+len]。
extern void ZZClickSparkLineEndpoints(double progress, double radius, double size, double extraScale,
                                      double *outX1, double *outX2);

/// 全局点击火花控制器：监听本 App 的左键点击，在对应窗口叠加特效层。
/// 生命周期：App 启动时 install 一次；无需手动停止（无定时器/常驻回调）。
@interface ZZClickSparkController : NSObject

/// 安装全局点击监听（幂等；多次调用只装一次）。
+ (instancetype)sharedController;

/// 安装本 App 的点击监听（幂等）；App 启动时调用一次。
- (void)installIfNeeded;

/// 当前生效图层总数（测试观察；= 每次未完成点击 × sparkCount）。
@property (nonatomic, readonly) NSUInteger activeSparkLayerCount;

/// 测试接缝：注入 false 强制生成特效（默认读系统 Reduce Motion）。
@property (nonatomic, assign) BOOL ignoresReduceMotionForTesting;

/// 直接在指定坐标生成一次点击火花（窗口坐标；生产由事件监听调用，测试直接驱动）。
- (void)spawnSparksAtPoint:(NSPoint)point inWindow:(NSWindow *)window;

/// 清除当前所有火花层（测试隔离用）。
- (void)removeAllSparkLayers;

@end

NS_ASSUME_NONNULL_END
