//
//  ZZTopNavigationView.m — 主页 UI 重构 01：自包含原生顶部导航壳
//
//  视觉基准：outputs/sevenzz-sunset-background-preview-v3.html 的
//  .titlebar/.nav/.brand/.nav-item（透明背景、底对齐、柔和文字阴影、
//  hover/active 只变文字颜色）。组件不引用 AppDelegate/EnvCore，
//  不读取主题全局或 UserDefaults；颜色与字体全部由 App 注入。
//  所有尺寸由明确约束控制；hover/active 只换颜色，不产生布局跳动。
//
#import "ZZTopNavigationView.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSString * const ZZTopNavIdentifierBrand    = @"brand";
NSString * const ZZTopNavIdentifierHome     = @"home";
NSString * const ZZTopNavIdentifierDelta    = @"delta";
NSString * const ZZTopNavIdentifierFund     = @"fund";
NSString * const ZZTopNavIdentifierCleanup  = @"cleanup";
NSString * const ZZTopNavIdentifierLibrary  = @"library";
NSString * const ZZTopNavIdentifierSettings = @"settings";

// The HTTP benchmark keeps an 840pt minimum canvas and lets a narrower
// browser viewport crop it; it does not collapse navigation items.  Keep the
// legacy compact mode below the supported 720pt acceptance width only, so a
// 720pt native window follows the same cropped-full-row semantics.
const CGFloat ZZTopNavFullModeMinimumWidth = 700.0;
const CGFloat ZZTopNavigationViewHeight    = 62.0;

// 版式常量（只在本文件使用）。
static const CGFloat kZZNavLeadingInset     = 20.0;
static const CGFloat kZZNavTrailingInset    = 20.0;
static const CGFloat kZZNavBottomInset      = 14.0;
static const CGFloat kZZNavItemGap          = 2.0;
static const CGFloat kZZNavBrandGap         = 24.0;
static const CGFloat kZZNavMediumBrandGap   = 12.0;
static const CGFloat kZZNavCompactBrandGap  = 10.0;
// CSS reference: nav items are 9px vertical padding around a normal line;
// the resulting line box is 38px high at both 14px (<=1040px) and 16px
// (wide) body text. The brand has 5px/9px vertical padding around 38px.
static const CGFloat kZZNavItemHeight       = 38.0;
static const CGFloat kZZNavBrandHeight      = 52.0;
static const CGFloat kZZNavWideItemPaddingH = 12.0;
static const CGFloat kZZNavMediumItemPaddingH = 9.0;
static const CGFloat kZZNavBrandPaddingH    = 4.0;

#pragma mark 导航项模型

@implementation ZZTopNavItemModel

- (instancetype)initWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                           handler:(nullable void (^)(void))handler {
    if(!(self=[super init])) return nil;
    if(identifier.length==0 || title.length==0) return nil;
    _identifier=[identifier copy];
    _title=[title copy];
    _handler=[handler copy];
    return self;
}

@end

#pragma mark 已解析外观

@implementation ZZTopNavAppearance

- (instancetype)initWithTextColor:(NSColor *)textColor
                      activeColor:(NSColor *)activeColor
                       hoverColor:(NSColor *)hoverColor
                      shadowColor:(NSColor *)shadowColor
                         itemFont:(NSFont *)itemFont
                        brandFont:(NSFont *)brandFont {
    if(!(self=[super init])) return nil;
    if(!textColor||!activeColor||!hoverColor||!shadowColor||!itemFont||!brandFont) return nil;
    _textColor=textColor;
    _activeColor=activeColor;
    _hoverColor=hoverColor;
    _shadowColor=shadowColor;
    _itemFont=itemFont;
    _brandFont=brandFont;
    return self;
}

@end

#pragma mark 私有：block 动作桥（菜单项回调）

@interface ZZTopNavActionBridge : NSObject
@property (nonatomic, copy) void (^handler)(void);
- (void)invoke:(id)sender;
@end
@implementation ZZTopNavActionBridge
- (void)invoke:(__unused id)sender {
    void (^h)(void)=self.handler;
    if(h) h();
}
@end

static void *ZZTopNavBridgesKey=&ZZTopNavBridgesKey;

#pragma mark 私有：文字导航按钮

@class ZZTopNavigationView;

@interface ZZTopNavTextButton : NSButton
@property (nonatomic, copy) NSString *navIdentifier;
@property (nonatomic, assign, getter=isNavActive) BOOL navActive;
@property (nonatomic, assign, getter=isNavHovered) BOOL navHovered;
@property (nonatomic, weak) ZZTopNavAppearance *navAppearance;
/// 固定渲染行高：保证各入口字形基线一致，不随字体度量抖动。
@property (nonatomic, assign) CGFloat textLineHeight;
@property (nonatomic, assign) CGFloat textPaddingH;
- (void)zz_refreshAttributedTitle;
@end

// NSStackView's vertical edgeInsets are interpreted against the stack's
// own (non-flipped) coordinate system.  With bottom alignment AppKit keeps
// arranged controls at y=0 and effectively ignores the requested bottom
// inset, which puts this row 14 px below the HTML reference.  Keep the
// normal stack sizing/spacing algorithm for horizontal geometry, then apply
// the measured visual offset after each layout pass.  This is deliberately
// local to the navigation row and does not alter accessibility frames or
// route behavior.
@interface ZZTopNavRow : NSStackView
@end

@implementation ZZTopNavRow
- (void)layout {
    [super layout];
    for (NSView *view in self.arrangedSubviews) {
        if (view.hidden || NSHeight(view.frame) <= 0.0) continue;
        NSRect frame = view.frame;
        frame.origin.y = kZZNavBottomInset;
        view.frame = frame;
    }
}
@end

@implementation ZZTopNavTextButton

- (instancetype)initWithFrame:(NSRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    self.bordered=NO;
    self.wantsLayer=YES;
    self.layer.backgroundColor=NSColor.clearColor.CGColor;
    _textPaddingH=kZZNavWideItemPaddingH;
    return self;
}

- (NSAttributedString *)zz_currentAttributedTitle {
    ZZTopNavAppearance *ap=self.navAppearance;
    if(!ap) return [[NSAttributedString alloc] initWithString:self.title?:@""];
    // The reference keeps the Seven brand in the bright paper tier even when
    // the Home destination is the active item; only the destination label
    // changes state color.
    BOOL isBrand=[self.navIdentifier isEqualToString:ZZTopNavIdentifierBrand];
    NSColor *color=isBrand?ap.activeColor:(self.navActive?ap.activeColor:(self.navHovered?ap.hoverColor:ap.textColor));
    NSShadow *sh=[[NSShadow alloc] init];
    sh.shadowColor=ap.shadowColor;
    sh.shadowBlurRadius=2.2;
    sh.shadowOffset=NSMakeSize(0,-1);
    NSDictionary *attrs=@{
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: self.font ?: ap.itemFont,
        NSShadowAttributeName: sh,
    };
    return [[NSAttributedString alloc] initWithString:self.title attributes:attrs];
}

- (void)zz_refreshAttributedTitle {
    NSAttributedString *attr=[self zz_currentAttributedTitle];
    self.attributedTitle=attr;
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}

- (NSSize)intrinsicContentSize {
    NSSize ts=[[self zz_currentAttributedTitle] size];
    CGFloat pad=self.textPaddingH>0?self.textPaddingH:kZZNavWideItemPaddingH;
    return NSMakeSize(ceil(ts.width)+pad*2,
                      self.textLineHeight>0?self.textLineHeight:ceil(ts.height));
}

- (void)setNavActive:(BOOL)navActive {
    _navActive=navActive;
    [self zz_refreshAttributedTitle];
}

- (void)setNavHovered:(BOOL)navHovered {
    _navHovered=navHovered;
    [self zz_refreshAttributedTitle];
}

- (void)drawRect:(__unused NSRect)dirtyRect {
    NSAttributedString *attr=self.attributedTitle;
    NSSize ts=[attr size];
    NSSize bs=self.bounds.size;
    NSRect r=NSMakeRect(floor((bs.width-ts.width)/2),
                        floor((bs.height-ts.height)/2)+1,
                        ceil(ts.width), ceil(ts.height));
    [attr drawInRect:r];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for(NSTrackingArea *ta in self.trackingAreas) [self removeTrackingArea:ta];
    NSTrackingArea *area=[[NSTrackingArea alloc] initWithRect:self.bounds
                                                      options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect
                                                        owner:self
                                                     userInfo:nil];
    [self addTrackingArea:area];
}

- (void)mouseEntered:(__unused NSEvent *)event { self.navHovered=YES; }
- (void)mouseExited:(__unused NSEvent *)event { self.navHovered=NO; }

@end

#pragma mark 私有：功能库菜单按钮（鼠标 / Space-Enter 等价 / 辅助功能 全部汇入宿主统一入口）

@interface ZZTopNavMenuButton : ZZTopNavTextButton
@property (nonatomic, weak) ZZTopNavigationView *ownerView;
@end

@implementation ZZTopNavMenuButton
- (instancetype)initWithFrame:(NSRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    self.accessibilityRole=NSAccessibilityPopUpButtonRole;
    return self;
}
// 交互修补 01（P1 根因修复）：键盘等价激活 performClick: 原先走普通 button
// action 分发到无 handler 的 library 模型，导致 Space/Enter 打不开菜单。
// 现与 mouseDown:、accessibilityPerformPress 一样进入宿主唯一打开入口，
// 不再依赖鼠标坐标，也不改变 accessibility role/label/identifier。
- (void)performClick:(__unused id)sender {
    [self.ownerView openLibraryMenuFromEvent:nil];
}
- (void)mouseDown:(NSEvent *)event {
    [self.ownerView openLibraryMenuFromEvent:event];
}
- (BOOL)accessibilityPerformPress {
    return [self.ownerView openLibraryMenuFromEvent:nil];
}
@end

#pragma mark 主视图

@interface ZZTopNavigationView ()
@property (nonatomic, strong) NSStackView *row;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZZTopNavTextButton *> *buttonsByIdentifier;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZZTopNavItemModel *> *modelsByIdentifier;
@property (nonatomic, copy) NSArray<NSString *> *itemOrder;
@property (nonatomic, copy) NSArray<NSString *> *secondaryIdentifiers;
@property (nonatomic, copy) NSArray<ZZTopNavItemModel *> *(^libraryMenuProvider)(void);
@property (nonatomic, assign, getter=isCompact) BOOL compact;
@property (nonatomic, assign, getter=isMedium) BOOL medium;
@end

@implementation ZZTopNavigationView

- (instancetype)initWithBrandTitle:(NSString *)__unused brandTitle
                             items:(NSArray<ZZTopNavItemModel *> *)items
          secondaryIdentifiers:(NSArray<NSString *> *)secondaryIdentifiers
          libraryMenuProvider:(NSArray<ZZTopNavItemModel *> *(^)(void))libraryMenuProvider
                    appearance:(ZZTopNavAppearance *)appearance {
    if(!(self=[super initWithFrame:NSZeroRect])) return nil;
    // secondaryIdentifiers 只是"窄屏折叠进功能库"的集合，空数组是合法状态
    // （例如用户把所有可折叠工具开关全关）。此前把空当非法入参，会让这类
    // 配置直接建不出整个导航壳。2026-09-03 修复：仅拒绝真正非法的入参。
    if(items.count==0 || !libraryMenuProvider || !appearance) return nil;

    _compact=NO;
    _medium=NO;
    _secondaryIdentifiers=[secondaryIdentifiers copy] ?: @[];
    _libraryMenuProvider=[libraryMenuProvider copy];
    _modelsByIdentifier=[NSMutableDictionary dictionary];
    NSMutableArray *order=[NSMutableArray array];
    for(ZZTopNavItemModel *m in items){
        if(!m || _modelsByIdentifier[m.identifier]) return nil;
        _modelsByIdentifier[m.identifier]=m;
        [order addObject:m.identifier];
    }
    if(!_modelsByIdentifier[ZZTopNavIdentifierBrand]) return nil;
    _itemOrder=[order copy];
    _buttonsByIdentifier=[NSMutableDictionary dictionary];

    self.wantsLayer=YES;
    self.layer.backgroundColor=NSColor.clearColor.CGColor;
    self.translatesAutoresizingMaskIntoConstraints=NO;
    self.accessibilityIdentifier=@"ZZTopNav";
    self.accessibilityLabel=@"顶部导航";
    [self.heightAnchor constraintEqualToConstant:ZZTopNavigationViewHeight].active=YES;

    NSStackView *row=[[ZZTopNavRow alloc] initWithFrame:NSZeroRect];
    _row=row;
    row.orientation=NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment=NSLayoutAttributeBottom;   // 对齐基准 .nav { align-items:flex-end }
    row.spacing=kZZNavItemGap;
    row.edgeInsets=NSEdgeInsetsMake(0,kZZNavLeadingInset,kZZNavBottomInset,kZZNavTrailingInset);
    row.translatesAutoresizingMaskIntoConstraints=NO;
    [self addSubview:row];
    NSLayoutConstraint *trailing=[row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor];
    // At 720pt the reference still lays out an 840pt app and crops its right
    // edge.  A required trailing equality would compress that row back into
    // the native viewport (and incorrectly reveal Settings), so permit the
    // row to extend beyond the clipped navigation host at that one tier.
    trailing.priority=NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        trailing,
        [row.widthAnchor constraintGreaterThanOrEqualToConstant:840.0],
        [row.topAnchor constraintEqualToAnchor:self.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    for(NSString *ident in _itemOrder){
        BOOL isMenu=[ident isEqualToString:ZZTopNavIdentifierLibrary];
        BOOL isSettings=[ident isEqualToString:ZZTopNavIdentifierSettings];
        if(isSettings){
            // 设置前放弹性 spacer，等价 .nav-item.settings { margin-left:auto }。
            NSView *spacer=[NSView new];
            [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            [spacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            [spacer.widthAnchor constraintGreaterThanOrEqualToConstant:8].active=YES;
            [_row addArrangedSubview:spacer];
        }
        ZZTopNavTextButton *button=isMenu ? [[ZZTopNavMenuButton alloc] initWithFrame:NSZeroRect]
                                          : [[ZZTopNavTextButton alloc] initWithFrame:NSZeroRect];
        if(isMenu)((ZZTopNavMenuButton *)button).ownerView=self;
        button.navIdentifier=ident;
        button.title=_modelsByIdentifier[ident].title;
        button.font=[ident isEqualToString:ZZTopNavIdentifierBrand]?appearance.brandFont:appearance.itemFont;
        button.textLineHeight=[ident isEqualToString:ZZTopNavIdentifierBrand] ? kZZNavBrandHeight : kZZNavItemHeight;
        button.textPaddingH=[ident isEqualToString:ZZTopNavIdentifierBrand] ? kZZNavBrandPaddingH : kZZNavWideItemPaddingH;
        button.navAppearance=appearance;
        button.target=self;
        button.action=@selector(zz_navButtonClicked:);
        button.accessibilityLabel=_modelsByIdentifier[ident].title;
        button.accessibilityIdentifier=[NSString stringWithFormat:@"ZZTopNav.item.%@", ident];
        button.focusRingType=NSFocusRingTypeDefault;
        [button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        CGFloat h=[ident isEqualToString:ZZTopNavIdentifierBrand] ? kZZNavBrandHeight : kZZNavItemHeight;
        [button.heightAnchor constraintEqualToConstant:h].active=YES;
        [_buttonsByIdentifier setObject:button forKey:ident];
        [_row addArrangedSubview:button];
        if([ident isEqualToString:ZZTopNavIdentifierBrand]){
            [_row setCustomSpacing:kZZNavBrandGap afterView:button];
        }
    }
    [self applyAppearance:appearance];
    return self;
}

- (IBAction)zz_navButtonClicked:(NSButton *)sender {
    if([sender isKindOfClass:[ZZTopNavTextButton class]]){
        NSString *ident=((ZZTopNavTextButton *)sender).navIdentifier;
        if(ident.length) [self sendActionForItemWithIdentifier:ident];
    }
}

#pragma mark 状态更新

- (void)setActiveItemIdentifier:(NSString *)activeItemIdentifier {
    _activeItemIdentifier=[activeItemIdentifier copy];
    for(NSString *ident in _itemOrder){
        ZZTopNavTextButton *b=_buttonsByIdentifier[ident];
        b.navActive=(_activeItemIdentifier && [ident isEqualToString:_activeItemIdentifier]);
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    BOOL shouldCompact=(newSize.width>0 && newSize.width<ZZTopNavFullModeMinimumWidth);
    BOOL shouldMedium=(newSize.width>0 && newSize.width<1040.0);
    if(shouldCompact!=_compact || shouldMedium!=_medium){
        _compact=shouldCompact;
        _medium=shouldMedium;
        [self zzApplyResponsiveLayout];
    }
}

- (BOOL)isCompact { return _compact; }

- (NSArray<NSString *> *)visibleItemIdentifiers {
    NSMutableArray *out=[NSMutableArray array];
    for(NSString *ident in _itemOrder){
        NSView *v=_buttonsByIdentifier[ident];
        if(v && !v.hidden) [out addObject:ident];
    }
    return out;
}

+ (NSArray<NSString *> *)menuIdentifiersForWidth:(CGFloat)width
                                  toolIdentifiers:(NSArray<NSString *> *)toolIdentifiers
                              overflowIdentifiers:(NSArray<NSString *> *)overflowIdentifiers {
    NSMutableArray *ids=[NSMutableArray arrayWithArray:toolIdentifiers ?: @[]];
    if(width>0 && width<ZZTopNavFullModeMinimumWidth){
        for(NSString *ov in overflowIdentifiers ?: @[]){
            if(![ids containsObject:ov]) [ids addObject:ov];
        }
    }
    return ids;
}

- (NSArray<NSString *> *)currentMenuItemIdentifiers {
    NSArray *tools=_libraryMenuProvider ? _libraryMenuProvider() : @[];
    NSMutableArray *toolIds=[NSMutableArray array];
    for(ZZTopNavItemModel *m in tools){ if(m) [toolIds addObject:m.identifier]; }
    CGFloat width=self.frame.size.width>0?self.frame.size.width:self.bounds.size.width;
    NSMutableArray *overflow=[NSMutableArray array];
    for(NSString *sid in _secondaryIdentifiers){
        if(_modelsByIdentifier[sid]) [overflow addObject:sid];
    }
    return [[self class] menuIdentifiersForWidth:width toolIdentifiers:toolIds overflowIdentifiers:overflow];
}

#pragma mark 回调统一入口

- (BOOL)sendActionForItemWithIdentifier:(NSString *)identifier {
    ZZTopNavItemModel *m=_modelsByIdentifier[identifier];
    if(!m || !m.handler) return NO;
    m.handler();
    return YES;
}

- (BOOL)isItemActiveWithIdentifier:(NSString *)identifier {
    if(!identifier) return NO;
    return [_activeItemIdentifier isEqualToString:identifier];
}

#pragma mark 功能库菜单构建

- (NSMenu *)zz_menuForLibraryButton {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"功能库"];
    menu.autoenablesItems=NO;
    [self zz_appendModels:_libraryMenuProvider() toMenu:menu];
    if(_compact){
        [menu addItem:[NSMenuItem separatorItem]];
        NSMutableArray *overflow=[NSMutableArray array];
        for(NSString *sid in _secondaryIdentifiers){
            ZZTopNavItemModel *m=_modelsByIdentifier[sid];
            if(m) [overflow addObject:m];
        }
        [self zz_appendModels:overflow toMenu:menu];
    }
    return menu;
}

// 鼠标 / performClick:（Space-Enter 等价）/ accessibilityPerformPress 的唯一打开入口。
- (BOOL)openLibraryMenuFromEvent:(NSEvent *)event {
    NSView *btn=_buttonsByIdentifier[ZZTopNavIdentifierLibrary];
    if(!btn || btn.hidden) return NO;
    NSMenu *menu=[self zz_menuForLibraryButton];
    if(!menu || menu.numberOfItems==0) return NO;   // 全部工具被隐藏且无溢出项时不弹出
    [self refreshButtonTitles];
    if(_onPresentLibraryMenu){
        // 注入的呈现器（测试替身/宿主扩展）：只回传真实菜单，不阻塞。
        _onPresentLibraryMenu(menu, btn);
        return YES;
    }
    NSPoint atLocation=(event && event.window && event.window==self.window)
        ? [btn convertPoint:event.locationInWindow fromView:nil]
        : NSMakePoint(btn.bounds.size.width/2, -4);
    [menu popUpMenuPositioningItem:nil atLocation:atLocation inView:btn];
    // 菜单随弹层关闭释放；桥由菜单条目持有、随之销毁，无跨次累积状态。
    objc_setAssociatedObject(menu, ZZTopNavBridgesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

- (void)zz_appendModels:(NSArray<ZZTopNavItemModel *> *)models toMenu:(NSMenu *)menu {
    if(!models) return;
    NSMutableArray *bridges=objc_getAssociatedObject(menu, ZZTopNavBridgesKey) ?: [NSMutableArray array];
    for(ZZTopNavItemModel *m in models){
        if(!m) continue;
        ZZTopNavActionBridge *bridge=[ZZTopNavActionBridge new];
        // 交互修补 01（P0 根因修复）：bridge 直接捕获构建该菜单项时的 handler
        // （显式 copy），不再经 sendActionForItemWithIdentifier: 回查只含顶部七项的
        // _modelsByIdentifier —— tool-* 等动态 provider 模型因此可恰好执行一次。
        void (^handler)(void)=m.handler;
        bridge.handler=handler?[handler copy]:nil;
        [bridges addObject:bridge];
        NSMenuItem *it=[[NSMenuItem alloc] initWithTitle:m.title action:@selector(invoke:) keyEquivalent:@""];
        it.target=bridge;
        it.representedObject=m.identifier;
        it.enabled=(bridge.handler!=nil);
        [menu addItem:it];
    }
    objc_setAssociatedObject(menu, ZZTopNavBridgesKey, bridges, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark 外观与紧凑降级

- (void)applyAppearance:(ZZTopNavAppearance *)appearance {
    _navAppearance=appearance;
    for(NSString *ident in _itemOrder){
        ZZTopNavTextButton *b=_buttonsByIdentifier[ident];
        b.navAppearance=appearance;
        b.font=[ident isEqualToString:ZZTopNavIdentifierBrand]?appearance.brandFont:appearance.itemFont;
        b.textLineHeight=[ident isEqualToString:ZZTopNavIdentifierBrand]?kZZNavBrandHeight:kZZNavItemHeight;
        b.textPaddingH=[ident isEqualToString:ZZTopNavIdentifierBrand] ? kZZNavBrandPaddingH : (_medium ? kZZNavMediumItemPaddingH : kZZNavWideItemPaddingH);
        [b zz_refreshAttributedTitle];
    }
    [self zzApplyResponsiveLayout];
    [self refreshButtonTitles];
}

- (void)zzApplyResponsiveLayout {
    for(NSString *sid in _secondaryIdentifiers){
        NSView *v=_buttonsByIdentifier[sid];
        v.hidden=_compact;
    }
    for(NSString *ident in _itemOrder){
        ZZTopNavTextButton *button=_buttonsByIdentifier[ident];
        if(!button) continue;
        BOOL brand=[ident isEqualToString:ZZTopNavIdentifierBrand];
        button.textPaddingH=brand ? kZZNavBrandPaddingH : (_medium ? kZZNavMediumItemPaddingH : kZZNavWideItemPaddingH);
        if(!brand && _medium && button.navAppearance.itemFont){
            button.font=[button.navAppearance.itemFont fontWithSize:14.0];
        }else if(!brand && button.navAppearance.itemFont){
            button.font=button.navAppearance.itemFont;
        }
        button.textLineHeight=brand?kZZNavBrandHeight:kZZNavItemHeight;
    }
    NSView *brandBtn=_buttonsByIdentifier[ZZTopNavIdentifierBrand];
    if(brandBtn){
        [_row setCustomSpacing:_compact?kZZNavCompactBrandGap:(_medium?kZZNavMediumBrandGap:kZZNavBrandGap) afterView:brandBtn];
        // The CSS transform is visual-only; keep the layout box stable for
        // overflow/accessibility checks and move the painted brand 10px right
        // and 3.2px down (AppKit's layer Y axis is bottom-origin).
        brandBtn.layer.affineTransform=CGAffineTransformMakeTranslation(10.0,-3.2);
    }
    [_row setNeedsLayout:YES];
}

- (void)refreshButtonTitles {
    for(NSString *ident in _itemOrder){
        [_buttonsByIdentifier[ident] zz_refreshAttributedTitle];
    }
}

@end
