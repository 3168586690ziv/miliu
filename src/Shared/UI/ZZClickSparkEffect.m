//
//  ZZClickSparkEffect.m — 全局点击火花特效（1:1 移植自用户确认的 React ClickSpark canvas 组件）
//
//  该字段效果与用户提供的 React canvas 组件逐参数一致（见 .h 注释）。
//  每次点击：按确认角度 2π·i/7 生成 7 条 CALayer 线，path 用 9 个关键帧
//  采样确认 ease-out 曲线，Core Animation 合成器插值渲染；500ms 后自动移除。
//  无常驻回调（对比网页版 requestAnimationFrame：网页版空闲时也逐帧清屏，
//  本实现空闲时零开销）。
//
#import "ZZClickSparkEffect.h"

double const ZZClickSparkSize = 7.0;
double const ZZClickSparkRadius = 20.0;
NSInteger const ZZClickSparkCount = 7;
double const ZZClickSparkDuration = 0.5;
double const ZZClickSparkLineWidth = 2.0;

double ZZClickSparkEaseOut(double t) {
    if(!(t>=0.0)) return 0.0;
    if(t>1.0) return 1.0;
    return t*(2.0-t);
}

void ZZClickSparkLineEndpoints(double progress, double radius, double size, double extraScale,
                               double *outX1, double *outX2) {
    double e=ZZClickSparkEaseOut(progress);
    double d=e*radius*extraScale;
    double len=size*(1.0-e);
    *outX1=d;
    *outX2=d+len;
}

// 确认色 #ae7ddc（sRGB 0..1 分量）。
static inline CGFloat ZZSparkR(void) { return 0xae/255.0; }
static inline CGFloat ZZSparkG(void) { return 0x7d/255.0; }
static inline CGFloat ZZSparkB(void) { return 0xdc/255.0; }

@interface ZZClickSparkController ()
@property (nonatomic, strong, nullable) id localMonitor;
@property (nonatomic, strong, nullable) NSColor *sparkColor;
@end

// 特效容器：永不拦截命中测试（点击穿透到下层真实控件）。
@interface ZZSparkOverlayView : NSView
@end
@implementation ZZSparkOverlayView
- (nullable NSView *)hitTest:(NSPoint)point { return nil; }
@end

@implementation ZZClickSparkController {
    // 火花层挂在各自窗口的特效视图上；计数遍历该表。
    NSMapTable<NSWindow *, NSView *> *_overlayViews;
}

+ (instancetype)sharedController {
    static ZZClickSparkController *g=nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g=[[ZZClickSparkController alloc] init]; });
    return g;
}

- (instancetype)init {
    if(!(self=[super init])) return nil;
    _overlayViews=[NSMapTable weakToStrongObjectsMapTable];
    _sparkColor=[NSColor colorWithSRGBRed:ZZSparkR() green:ZZSparkG() blue:ZZSparkB() alpha:1.0];
    return self;
}

- (void)installIfNeeded {
    if(_localMonitor) return;
    __weak typeof(self) weakSelf=self;
    _localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent * _Nullable(NSEvent *event){
        __strong typeof(weakSelf) self=weakSelf;
        if(self && event.type==NSEventTypeLeftMouseDown && event.clickCount>=1){
            NSWindow *w=event.window;
            if(w) [self spawnSparksAtPoint:event.locationInWindow inWindow:w];
        }
        return event;   // 永不吞事件：特效只旁观
    }];
}

- (NSUInteger)activeSparkLayerCount {
    NSUInteger n=0;
    for(NSView *v in [_overlayViews objectEnumerator]){
        if(!v) continue;
        n+=(NSUInteger)v.layer.sublayers.count;
    }
    return n;
}

- (void)removeAllSparkLayers {
    for(NSView *v in [_overlayViews objectEnumerator]){
        if(!v) continue;
        for(CALayer *l in [NSArray arrayWithArray:v.layer.sublayers]) [l removeFromSuperlayer];
    }
}

- (void)spawnSparksAtPoint:(NSPoint)point inWindow:(NSWindow *)window {
    if(!window || window.contentView.bounds.size.width<=0) return;
    // Reduce Motion 降级（确认稿外的项目惯例；测试可注入关闭）。
    if(!self.ignoresReduceMotionForTesting &&
       NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;

    NSView *content=window.contentView;
    NSView *overlay=[_overlayViews objectForKey:window];
    if(!overlay || overlay.window!=window){
        overlay=[[ZZSparkOverlayView alloc] initWithFrame:content.bounds];
        overlay.wantsLayer=YES;
        overlay.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        overlay.layer.zPosition=CGFLOAT_MAX;      // 永远在最上层
        [content addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [_overlayViews setObject:overlay forKey:window];
    }
    CGPoint center=[content convertPoint:point fromView:nil];

    for(NSInteger i=0;i<ZZClickSparkCount;i++){
        double angle=(2.0*M_PI*(double)i)/(double)ZZClickSparkCount;
        CAShapeLayer *line=[CAShapeLayer layer];
        // path 沿 +X，[x1,x2]；角度用 transform 旋转（同网页版 cos/sin 语义）。
        double x1,x2;

        // 9 关键帧采样确认 ease-out；CA 对同构 path 线性插值（帧间差异亚像素）。
        CAKeyframeAnimation *anim=[CAKeyframeAnimation animationWithKeyPath:@"path"];
        NSMutableArray *frames=[NSMutableArray arrayWithCapacity:9];
        for(int k=0;k<9;k++){
            double pr=(double)k/8.0;
            CGMutablePathRef pk=CGPathCreateMutable();
            ZZClickSparkLineEndpoints(pr, ZZClickSparkRadius, ZZClickSparkSize, 1.0, &x1, &x2);
            CGPathMoveToPoint(pk,NULL,x1,0); CGPathAddLineToPoint(pk,NULL,x2,0);
            [frames addObject:(__bridge id)pk];   // 数组持有（CFRetain）；所有权仍在此处释放
            CGPathRelease(pk);
        }
        anim.values=frames;
        anim.duration=ZZClickSparkDuration;
        anim.fillMode=kCAFillModeForwards;
        anim.removedOnCompletion=NO;

        line.anchorPoint=CGPointZero;
        line.position=center;
        line.transform=CATransform3DMakeRotation(angle, 0, 0, 1);
        line.strokeColor=_sparkColor.CGColor;
        line.lineWidth=ZZClickSparkLineWidth;
        line.lineCap=kCALineCapButt;
        line.zPosition=CGFLOAT_MAX;
        line.path=(__bridge CGPathRef)frames.firstObject;
        [overlay.layer addSublayer:line];
        [line addAnimation:anim forKey:@"zz-spark-line"];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(ZZClickSparkDuration*NSEC_PER_SEC)+NSEC_PER_MSEC*20),
                       dispatch_get_main_queue(), ^{ [line removeFromSuperlayer]; });
    }
}

@end
