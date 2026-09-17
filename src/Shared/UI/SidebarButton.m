//
//  SidebarButton.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "SidebarButton.h"
#import "UIThemeSupport.h"

@implementation SidebarButton
- (void)resetCursorRects { [super resetCursorRects]; if(self.enabled)[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)highlight:(BOOL)flag {
    // Keep sidebar icon taps steady; selection state handles feedback.
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)mouseDown:(NSEvent *)event {
    // Bypass NSButton's native press tracking entirely. It can briefly draw a
    // focus/pressed frame even when highlight: is overridden.
    if (self.enabled && self.action) [NSApp sendAction:self.action to:self.target from:self];
}

- (instancetype)initWithImage:(NSImage *)image tooltip:(NSString *)tooltip size:(CGFloat)size cornerRadius:(CGFloat)cornerRadius {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    self.title = @"";
    NSImage *paddedImage = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [paddedImage lockFocus];
    // 统一放大功能区图标本体，按钮命中区域、侧栏间距和圆形框架保持不变。
    // 基金素材自带额外留白，因此再略多给一点绘制范围以与其它图标视觉等大。
    CGFloat imageSide = size - ([tooltip hasPrefix:@"基金与存钱"] ? 4 : 6);
    NSRect imageRect = NSMakeRect((size-imageSide)/2.0, (size-imageSide)/2.0, imageSide, imageSide);
    // 这枚素材的黑色圆盘和紫色外环在源图中留白较多；裁去 8% 的静区后再绘制，
    // 才能与其余六枚在视觉直径上对齐，而不是只让按钮的数学尺寸相同。
    NSRect sourceRect = NSZeroRect;
    if ([tooltip hasPrefix:@"基金与存钱"]) {
        CGFloat cropInset = 0.08;
        sourceRect = NSMakeRect(image.size.width * cropInset,
                                image.size.height * cropInset,
                                image.size.width * (1.0 - cropInset * 2.0),
                                image.size.height * (1.0 - cropInset * 2.0));
    }
    [[NSBezierPath bezierPathWithOvalInRect:imageRect] addClip];
    [image drawInRect:imageRect
             fromRect:sourceRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
    if ([tooltip hasPrefix:@"三角洲情报"]) {
        // Keep the icon frame and purple ring fixed; move only the artwork inside it.
        CGFloat cropInset = 0.18;
        NSSize sourceSize = image.size;
        NSRect sourceCrop = NSMakeRect(sourceSize.width * cropInset,
                                       sourceSize.height * cropInset,
                                       sourceSize.width * (1.0 - cropInset * 2.0),
                                       sourceSize.height * (1.0 - cropInset * 2.0));
        NSRect destinationCrop = NSInsetRect(imageRect, imageSide * cropInset, imageSide * cropInset);
        CGFloat artworkNudge = imageSide * 0.022;
        NSRect shiftedDestination = NSOffsetRect(destinationCrop, artworkNudge, artworkNudge);
        [NSColor.blackColor setFill];
        NSRectFill(NSUnionRect(destinationCrop, shiftedDestination));
        [image drawInRect:shiftedDestination
                 fromRect:sourceCrop
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                    hints:nil];
    }
    [paddedImage unlockFocus];
    paddedImage.template = image.isTemplate;
    self.decorativeImage = paddedImage;
    NSString *cleanSymbol = [tooltip hasPrefix:@"媒体转换"] ? @"arrow.triangle.2.circlepath" : ([tooltip hasPrefix:@"随机数"] ? @"die.face.5" : ([tooltip hasPrefix:@"美股行情"] ? @"chart.line.uptrend.xyaxis" : @"gearshape"));
    self.cleanImage = Symbol(cleanSymbol);
    self.image = paddedImage;
    self.imagePosition = NSImageOnly;
    self.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.toolTip = tooltip;
    self.bordered = NO;
    self.focusRingType = NSFocusRingTypeNone;
    self.refusesFirstResponder = YES;
    if ([self.cell respondsToSelector:@selector(setHighlightsBy:)]) [(NSButtonCell *)self.cell setHighlightsBy:0];
    self.contentTintColor = C(0.70, 0.76, 0.84, 1);
    self.wantsLayer = YES;
    self.layer.masksToBounds = NO;
    // The sidebar reads as a set of circular destinations, not as flat utility buttons.
    self.layer.cornerRadius = size / 2.0;
    self.layer.borderWidth = 0;
    self.layer.borderColor = NSColor.clearColor.CGColor;
    self.glowExtent = 10;
    self.glowLayer = [CAGradientLayer layer];
    self.glowLayer.type = kCAGradientLayerRadial;
    self.glowLayer.startPoint = CGPointMake(0.5, 0.5);
    self.glowLayer.endPoint = CGPointMake(0.95, 0.95);
    self.glowLayer.colors = @[
        (__bridge id)C(0.62, 0.34, 1.0, 0.86).CGColor,
        (__bridge id)C(0.52, 0.25, 0.96, 0.38).CGColor,
        (__bridge id)C(0.42, 0.18, 0.86, 0.10).CGColor,
        (__bridge id)NSColor.clearColor.CGColor
    ];
    self.glowLayer.locations = @[@0.0, @0.34, @0.68, @1.0];
    // Start in the true inactive appearance. Otherwise setActive:NO is skipped
    // on first launch because BOOL defaults to NO, leaving the icon too bright.
    self.glowLayer.opacity = 0.08;
    [self.layer insertSublayer:self.glowLayer atIndex:0];
    self.ringLayer = [CAShapeLayer layer];
    self.ringLayer.fillColor = NSColor.clearColor.CGColor;
    self.ringLayer.lineCap = kCALineCapRound;
    self.ringLayer.shadowColor = C(0.55, 0.28, 1.0, 0.90).CGColor;
    self.ringLayer.shadowRadius = 3;
    self.ringLayer.shadowOffset = CGSizeZero;
    // Artwork already carries its own outer rim; a second runtime ring makes
    // the sidebar read as doubled circles.
    self.ringLayer.hidden = YES;
    [self.layer addSublayer:self.ringLayer];
    self.windLayer = [CALayer layer];
    self.windLayer.masksToBounds = NO;
    self.windLayer.opacity = 0;
    [self.layer addSublayer:self.windLayer];
    self.alphaValue = 0.40;
    for (NSInteger i = 0; i < 7; i++) {
        CAShapeLayer *blade = [CAShapeLayer layer];
        blade.fillColor = NSColor.clearColor.CGColor;
        blade.strokeColor = C(0.72, 0.48, 1.0, 0.64 - i * 0.034).CGColor;
        blade.lineWidth = i == 0 ? 1.50 : (i < 3 ? 1.12 : 0.76);
        blade.lineCap = kCALineCapRound;
        blade.lineJoin = kCALineJoinRound;
        blade.shadowColor = C(0.50, 0.20, 0.96, 0.92).CGColor;
        blade.shadowOpacity = 0.44;
        blade.shadowRadius = 4;
        blade.shadowOffset = CGSizeZero;
        [self.windLayer addSublayer:blade];
    }
    [self.widthAnchor constraintEqualToConstant:size].active = YES;
    [self.heightAnchor constraintEqualToConstant:size].active = YES;
    return self;
}

- (void)layout {
    [super layout];
    CGFloat inset = -self.glowExtent;
    self.glowLayer.frame = CGRectInset(self.bounds, inset, inset);
    self.windLayer.frame = self.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat ringInset = self.bounds.size.width <= 40 ? 2.5 : 2.0;
    self.ringLayer.frame = self.bounds;
    CGPathRef ringPath = CGPathCreateWithEllipseInRect(CGRectInset(self.bounds, ringInset, ringInset), NULL);
    self.ringLayer.path = ringPath;
    CGPathRelease(ringPath);
    NSArray<CAShapeLayer *> *streams = (NSArray<CAShapeLayer *> *)self.windLayer.sublayers;
    for (NSInteger i = 0; i < streams.count; i++) {
        CAShapeLayer *blade = streams[i];
        CGMutablePathRef path = CGPathCreateMutable();
        CGFloat phase = (CGFloat)i * (CGFloat)(M_PI * 2.0 / streams.count) - 0.45;
        for (NSInteger step = 0; step <= 12; step++) {
            CGFloat t = step / 12.0;
            CGFloat radius = 24.5 - 5.5 * t;
            CGFloat angle = phase + t * 0.92;
            CGPoint point = CGPointMake(center.x + cos(angle) * radius, center.y + sin(angle) * radius);
            if (step == 0) CGPathMoveToPoint(path, NULL, point.x, point.y);
            else CGPathAddLineToPoint(path, NULL, point.x, point.y);
        }
        blade.bounds = self.bounds;
        blade.position = center;
        blade.anchorPoint = CGPointMake(0.5, 0.5);
        blade.path = path;
        CGPathRelease(path);
    }
}

- (void)setGlowExtent:(CGFloat)glowExtent {
    _glowExtent = glowExtent;
    [self setNeedsLayout:YES];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self refreshAppearance];
    [CATransaction commit];

    [self.windLayer removeAllAnimations];
}

- (void)refreshAppearance {
    self.layer.backgroundColor=NSColor.clearColor.CGColor;
    self.windLayer.opacity=0;
    [self.windLayer removeAllAnimations];
    if (gLavenderTheme) {
        self.image=self.decorativeImage;
        self.glowLayer.opacity=self.active ? .26 : .035;
        self.alphaValue=1;
        self.layer.backgroundColor=(self.active?RC(.855,.805,1,.76):NSColor.clearColor).CGColor;
        self.layer.borderWidth=self.active?.8:0;
        self.layer.borderColor=RC(.650,.540,.94,.58).CGColor;
        self.ringLayer.strokeColor=RC(.57,.43,.90,self.active?.78:.42).CGColor;
        self.ringLayer.lineWidth=self.active?1.35:1.0;
        self.ringLayer.shadowOpacity=self.active?.24:.08;
    } else if (gLightTheme) {
        // White surfaces need crisp, opaque symbols; translucent decorative
        // artwork creates a dirty grey haze even when its brightness is correct.
        self.image=self.decorativeImage;
        self.glowLayer.opacity=0;
        self.alphaValue=1;
        self.layer.backgroundColor=NSColor.clearColor.CGColor;
        self.layer.borderWidth=0;
        self.layer.borderColor=NSColor.clearColor.CGColor;
        self.ringLayer.strokeColor=C(0.43,0.22,0.76,0.88).CGColor;
        self.ringLayer.lineWidth=self.bounds.size.width<=40?1.0:1.35;
        self.ringLayer.shadowOpacity=.18;
    } else {
        self.image=self.decorativeImage;
        self.glowLayer.opacity=self.active ? 0.58 : 0.025;
        self.alphaValue=self.active ? 1.0 : 0.78;
        self.layer.borderWidth=0;
        self.layer.borderColor=NSColor.clearColor.CGColor;
        self.ringLayer.strokeColor=RC(0.60,0.35,1.0,self.active?.92:.54).CGColor;
        self.ringLayer.lineWidth=self.active?1.45:1.0;
        self.ringLayer.shadowOpacity=self.active?.38:.12;
    }
}
@end
