//
//  GlassSurfaceView.h — 迁移自 App/SevenZZToolbox.m
//
//  玻璃质感内容承载面：addSubview 路由到内部 content 视图；
//  macOS 26 可用时叠加 NSGlassEffectView 玻璃材质。
//
#import <Cocoa/Cocoa.h>

@interface GlassSurfaceView : NSView
@property BOOL routesContent;
@property (strong) NSView *surfaceContentView;
@property (strong) NSView *effectView;
- (void)configureForLightTheme:(BOOL)light radius:(CGFloat)radius;
@end
