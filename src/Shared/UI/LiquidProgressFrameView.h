//
//  LiquidProgressFrameView.h — 迁移自 App/SevenZZToolbox.m
//
//  液态进度描边框：视觉覆盖层（hitTest→nil），控件保持可交互；
//  active 时边框发光并流动。
//
#import <Cocoa/Cocoa.h>

@interface LiquidProgressFrameView : NSView
@property(nonatomic) double minValue;
@property(nonatomic) double maxValue;
@property(nonatomic) double doubleValue;
@property(nonatomic) BOOL active;
@property(nonatomic) CGFloat phase;
@property(strong) NSTimer *flowTimer;
@end
