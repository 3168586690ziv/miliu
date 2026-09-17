//
//  GlassSurfaceView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "GlassSurfaceView.h"
#import "UIThemeSupport.h"

@implementation GlassSurfaceView
- (instancetype)initWithFrame:(NSRect)frame { if((self=[super initWithFrame:frame])){self.wantsLayer=YES;NSView *effect=nil;if(@available(macOS 26.0,*)){effect=[NSGlassEffectView new];effect.translatesAutoresizingMaskIntoConstraints=NO;[super addSubview:effect];self.effectView=effect;}NSView *content=[NSView new];content.translatesAutoresizingMaskIntoConstraints=NO;[super addSubview:content];self.surfaceContentView=content;NSMutableArray *constraints=[NSMutableArray arrayWithArray:@[[content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[content.topAnchor constraintEqualToAnchor:self.topAnchor],[content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];if(effect)[constraints addObjectsFromArray:@[[effect.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[effect.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[effect.topAnchor constraintEqualToAnchor:self.topAnchor],[effect.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];[NSLayoutConstraint activateConstraints:constraints];self.routesContent=YES;}return self; }
- (void)addSubview:(NSView *)view { if(self.routesContent&&view!=self.surfaceContentView&&view!=self.effectView)[self.surfaceContentView addSubview:view];else[super addSubview:view]; }
- (void)configureForLightTheme:(BOOL)light radius:(CGFloat)radius {self.layer.cornerRadius=radius;self.layer.masksToBounds=NO;self.layer.backgroundColor=(gLavenderTheme?RC(.985,.970,1,.82):(light?NSColor.clearColor:RC(.009,.011,.016,1))).CGColor;if(@available(macOS 26.0,*)){if([self.effectView isKindOfClass:NSGlassEffectView.class]){NSGlassEffectView *glass=(NSGlassEffectView *)self.effectView;glass.hidden=!light;glass.style=NSGlassEffectViewStyleRegular;glass.cornerRadius=radius;glass.tintColor=gLavenderTheme?RC(.82,.75,1,.34):RC(.96,.98,1,.16);}}}
@end
