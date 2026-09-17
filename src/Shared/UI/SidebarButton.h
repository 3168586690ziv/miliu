//
//  SidebarButton.h — 迁移自 App/SevenZZToolbox.m
//
//  侧栏圆形导航按钮：自带径向辉光、风旋与圆环图层；
//  主题切换通过 refreshAppearance 重绘。
//
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/QuartzCore.h>

@interface SidebarButton : NSButton
@property (nonatomic) BOOL active;
@property (nonatomic) CGFloat glowExtent;
@property (strong) CAGradientLayer *glowLayer;
@property (strong) CALayer *windLayer;
@property (strong) CAShapeLayer *ringLayer;
@property (strong) NSImage *decorativeImage;
@property (strong) NSImage *cleanImage;
- (instancetype)initWithImage:(NSImage *)image tooltip:(NSString *)tooltip size:(CGFloat)size cornerRadius:(CGFloat)cornerRadius;
- (void)refreshAppearance;
@end
