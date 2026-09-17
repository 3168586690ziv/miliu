//
//  InvisibleScroller.m — R49:透明滚动条统一实现(自 R40 起,从 SevenZZToolbox.m 共享化)
//  背景:autohidesScrollers 的 overlay 滚动条只会在「滚动停止后」淡出,滚动中仍可见黑柱。
//  方案:用透明 NSScroller 子类替换,覆盖全部绘制入口 + 强制 alpha 恒为 0,
//  使 AppKit 的 flash/fade-in 动画无法把它恢复成可见状态;滚动本身完全不受影响。
//
#import "InvisibleScroller.h"

@interface ZZInvisibleScroller : NSScroller
@end

@implementation ZZInvisibleScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return YES; }
+ (CGFloat)scrollerWidth { return 0.0; }
+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize scrollerStyle:(NSScrollerStyle)scrollerStyle {
    (void)controlSize; (void)scrollerStyle; return 0.0;
}
- (instancetype)initWithFrame:(NSRect)frameRect {
    if((self=[super initWithFrame:frameRect])){
        self.wantsLayer=YES;
        [super setAlphaValue:0.0];
        if(self.layer){ self.layer.opacity=0.0f; self.layer.contents=nil; self.layer.backgroundColor=NULL; }
    }
    return self;
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { if(self.layer){ self.layer.contents=nil; self.layer.backgroundColor=NULL; self.layer.opacity=0.0f; } }
- (void)drawRect:(NSRect)dirtyRect { (void)dirtyRect; /* 不绘制任何内容 */ }
- (void)drawKnob { /* 不绘制 thumb */ }
- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)flag { (void)slotRect; (void)flag; /* 不绘制槽 */ }
- (void)setAlphaValue:(CGFloat)alphaValue {
    (void)alphaValue; [super setAlphaValue:0.0];
    if(self.layer){ self.layer.opacity=0.0f; }
}
- (void)setKnobProportion:(CGFloat)proportion {
    [super setKnobProportion:proportion]; [super setAlphaValue:0.0];
    if(self.layer){ self.layer.opacity=0.0f; }
}
- (void)setDoubleValue:(double)doubleValue {
    [super setDoubleValue:doubleValue]; [super setAlphaValue:0.0];
    if(self.layer){ self.layer.opacity=0.0f; }
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance]; [super setAlphaValue:0.0];
    if(self.layer){ self.layer.opacity=0.0f; }
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [super setAlphaValue:0.0]; if(self.layer){ self.layer.opacity=0.0f; } }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; } /* 点击穿透到内容,不拦截滚动/拖拽 */
@end

/* 已托管的 scroll view 弱引用登记表:主题切换/窗口尺寸变化后可整体复核 */
static NSHashTable *ZZInvisibleScrollerRegistry(void){
    static NSHashTable *table=nil; static dispatch_once_t once;
    dispatch_once(&once,^{ table=[NSHashTable weakObjectsHashTable]; });
    return table;
}

/* 统一安装入口:保留竖直滚动能力,仅让指示器彻底不可见 */
void ZZInstallInvisibleVerticalScroller(NSScrollView *sv){
    if(![sv isKindOfClass:[NSScrollView class]]) return;
    sv.hasVerticalScroller=YES;          /* 保留竖直滚动(滚轮/触控板/键盘均依赖它) */
    sv.hasHorizontalScroller=NO;
    sv.scrollerStyle=NSScrollerStyleOverlay;
    sv.autohidesScrollers=YES;
    sv.drawsBackground=NO;
    if(sv.contentView){ sv.contentView.drawsBackground=NO; }
    if(![sv.verticalScroller isKindOfClass:[ZZInvisibleScroller class]]){
        ZZInvisibleScroller *scroller=[[ZZInvisibleScroller alloc]initWithFrame:NSMakeRect(0,0,15,100)];
        sv.verticalScroller=scroller;
    }
    [sv.verticalScroller setAlphaValue:0.0];
    if(sv.horizontalScroller){ [sv.horizontalScroller setAlphaValue:0.0]; }
    [ZZInvisibleScrollerRegistry() addObject:sv];
}

/* 复核:任何时机(主题切换、重新布局、滚动结束)都可调用,保证仍为透明 scroller */
void ZZReassertInvisibleScrollers(void){
    NSArray *all=[[ZZInvisibleScrollerRegistry() allObjects] copy];
    for(NSScrollView *sv in all){
        if(![sv isKindOfClass:[NSScrollView class]]) continue;
        if(![sv.verticalScroller isKindOfClass:[ZZInvisibleScroller class]]){ ZZInstallInvisibleVerticalScroller(sv); }
        else { [sv.verticalScroller setAlphaValue:0.0]; }
    }
}

BOOL ZZInvisibleScrollerActive(NSScrollView *sv){
    return [sv isKindOfClass:[NSScrollView class]] &&
           [sv.verticalScroller isKindOfClass:[ZZInvisibleScroller class]] &&
           sv.verticalScroller.alphaValue < 0.01;
}
