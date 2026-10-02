//
//  RDWatchlistPage.m — 追更页实现（App 侧；数据层 RDWatchlistStore 禁改，直接使用）
//
//  结构基准＝已定稿预览稿 ③（1:1）：工具栏（＋添加当前页 / ↻全部重探 / 摘要）+
//  列表头 + 行高 58 的观察列表 + 底部设置卡四行。配色沿用觅流暖纸浅色主题
// （App 在 applicationDidFinishLaunching 固定 Aqua 外观）。
//
//  跨进程交互（契约 WATCH-V1 §3.1/§3.2/§3.5，字面值勿改）：
//  · 助手运行态：NSWorkspace.runningApplications 查 bundle id 含 watchlist
//  · 「全部重探」/ 行内「立即重探」：助手运行中才发分布式通知 com.sevenzz.miliu.watchNow
//  · 开机自启开关：助手运行中发 com.sevenzz.miliu.watchService {enabled:BOOL}；
//    未运行时仅写偏好并提示下次启动生效
//  · com.sevenzz.miliu.openAndScan 的接收端在 ResourceDetectorApp.m（App 最小接线）
//

#import "RDWatchlistPage.h"
#import "RDWatchlistStore.h"
#import "PreferencesStore.h"

// ── 契约常量定义（声明见 RDWatchlistPage.h）──
NSString *const RDWatchNotificationOpenAndScan  = @"com.sevenzz.miliu.openAndScan";
NSString *const RDWatchNotificationWatchNow     = @"com.sevenzz.miliu.watchNow";
NSString *const RDWatchNotificationWatchService = @"com.sevenzz.miliu.watchService";
NSString *const RDWatchAgentBundleIdentifier    = @"com.sevenzz.resource-detector.watchlist";

// 开机自启期望状态的偏好键。契约 §3.3 只登记 NotifyEnabled / QuietHours 两个键，
// 自启状态键名字面未定 —— 暂以 MiliuWatch* 同族命名直接写 standardUserDefaults，
// 助手侧（B）按同名键读取即可。见交回报告「待裁决」。
static NSString *const kRDWatchAutoLaunchDefaultsKey = @"MiliuWatchAutoLaunch";

// 页面控制器的私有接口与动作声明：置于行 cell 之前，
// 使 @selector(...) 在 -Wundeclared-selector 下也能解析（动作由控制器实现）。
@class RDWatchSettingsCardView;

@interface RDWatchlistPageController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) NSView *pageView;
@property (nonatomic, weak) id<RDWatchlistPageDelegate> delegate;
@property (nonatomic, copy) NSArray<RDWatchlistEntry *> *entries;   // 展示快照（来自 store 缓存拷贝）
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSTextField *pageTitle;
@property (nonatomic, strong) NSButton *addButton;
@property (nonatomic, strong) NSButton *reloadAllButton;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSArray<NSTextField *> *headerLabels;
@property (nonatomic, strong) NSBox *headerRule;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) RDWatchSettingsCardView *settingsCard;
@property (nonatomic, strong) NSSwitch *autoLaunchSwitch;
@property (nonatomic, strong) NSSwitch *notifySwitch;
@property (nonatomic, strong) NSSegmentedControl *quietHoursControl;
@property (nonatomic, strong) NSSegmentedControl *scopeControl;
// 动作（行 cell 的控件 target=self，见 RDWatchRowCellView configureWithEntry:）
- (void)backTapped:(id)sender;
- (void)addCurrentPageTapped:(id)sender;
- (void)reloadAllTapped:(id)sender;
- (void)watchIntervalChanged:(NSSegmentedControl *)sender;
- (void)watchSwitchChanged:(NSSwitch *)sender;
- (void)watchDeleteTapped:(NSButton *)sender;
- (void)watchViewTapped:(NSButton *)sender;
- (void)watchReprobeTapped:(NSButton *)sender;
- (void)watchAutoLaunchChanged:(NSSwitch *)sender;
- (void)watchNotifyChanged:(NSSwitch *)sender;
- (void)watchQuietHoursChanged:(NSSegmentedControl *)sender;
@end

#pragma mark - 行内列几何（表头标签与行 cell 共用）

typedef struct {
    CGFloat titleX, titleW;
    CGFloat intervalX, lastX, pillX, viewX, reprobeX, switchX, deleteX;
} RDWatchRowColumns;

// 右起固定列（开关/删除/重探/查看/胶囊/上次探测/间隔），标题块吃剩余宽度。
static RDWatchRowColumns RDWatchRowColumnsForWidth(CGFloat width) {
    RDWatchRowColumns c;
    CGFloat right = width - 14.0;
    c.switchX = right - 40.0;   right = c.switchX - 8.0;
    c.deleteX = right - 42.0;   right = c.deleteX - 10.0;
    c.reprobeX = right - 26.0;  right = c.reprobeX - 8.0;
    c.viewX = right - 42.0;     right = c.viewX - 8.0;
    c.pillX = right - 104.0;    right = c.pillX - 8.0;
    c.lastX = right - 96.0;     right = c.lastX - 8.0;
    c.intervalX = right - 118.0; right = right - 8.0;
    c.titleX = 14.0;
    c.titleW = MAX(80.0, right - c.titleX);
    return c;
}

// 行控件 identifier 形如 RDWatchRowSwitch.<uuid>；UUID 不含「.」，取首个「.」之后即条目 id。
static NSString * _Nullable RDWatchEntryIDInControlIdentifier(NSString * _Nullable controlIdentifier) {
    if (controlIdentifier.length == 0) return nil;
    NSUInteger dot = [controlIdentifier rangeOfString:@"."].location;
    if (dot == NSNotFound || dot + 1 >= controlIdentifier.length) return nil;
    return [controlIdentifier substringFromIndex:dot + 1];
}

#pragma mark - 时间格式化（上次探测：绝对时间 + 相对时间两行）

static NSDateFormatter *RDWatchClockFormatter(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.dateStyle = NSDateFormatterNoStyle;
        f.timeStyle = NSDateFormatterShortStyle;
    });
    return f;
}

static NSRelativeDateTimeFormatter *RDWatchRelativeFormatter(void) {
    static NSRelativeDateTimeFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSRelativeDateTimeFormatter alloc] init];
        f.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    });
    return f;
}

#pragma mark - 行视图（底部细分隔线，照 RDDownloadRowView 模式）

@interface RDWatchRowView : NSTableRowView
@end

@implementation RDWatchRowView
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(14.0, 0.0, MAX(0.0, NSWidth(self.bounds) - 28.0), 1.0));
}
@end

#pragma mark - 行 cell（创建后按 entry + 宽度配置；窗口缩放经 setFrameSize 重排）

@interface RDWatchRowCellView : NSTableCellView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *urlLabel;
@property (nonatomic, strong) NSSegmentedControl *intervalControl;
@property (nonatomic, strong) NSTextField *lastLabel;
@property (nonatomic, strong) NSTextField *statusPill;
@property (nonatomic, strong) NSButton *viewButton;
@property (nonatomic, strong) NSButton *reprobeButton;
@property (nonatomic, strong) NSSwitch *enabledSwitch;
@property (nonatomic, strong) NSButton *deleteButton;
// 窗口缩放重排所需：记住最近一次配置的条目与 target（弱引用，避免延长生命周期）
@property (nonatomic, strong) RDWatchlistEntry *lastEntry;
@property (nonatomic, weak) id lastTarget;
- (void)configureWithEntry:(RDWatchlistEntry *)entry width:(CGFloat)width target:(id)target;
@end

@implementation RDWatchRowCellView

// 视图表格默认把整个 cell 折叠成没有内容的 AXCell（照 RDDownloadRowCellView 处理）。
- (BOOL)isAccessibilityElement { return NO; }

- (NSArray *)accessibilityChildren {
    NSMutableArray *children = [NSMutableArray array];
    for (NSView *v in @[self.titleLabel, self.urlLabel, self.intervalControl,
                        self.lastLabel, self.statusPill, self.viewButton,
                        self.reprobeButton, self.enabledSwitch, self.deleteButton]) {
        if (v) [children addObject:v];
    }
    return children;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.titleLabel.bezeled = NO; self.titleLabel.drawsBackground = NO; self.titleLabel.editable = NO;
        self.titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        self.titleLabel.textColor = [NSColor labelColor];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.titleLabel];

        self.urlLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.urlLabel.bezeled = NO; self.urlLabel.drawsBackground = NO; self.urlLabel.editable = NO;
        self.urlLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        self.urlLabel.textColor = [NSColor tertiaryLabelColor];
        self.urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self addSubview:self.urlLabel];

        self.intervalControl = [NSSegmentedControl
            segmentedControlWithLabels:@[@"15", @"30", @"60", @"120"]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
        self.intervalControl.segmentStyle = NSSegmentStyleRounded;
        self.intervalControl.font = [NSFont systemFontOfSize:10.5];
        [self addSubview:self.intervalControl];

        self.lastLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.lastLabel.bezeled = NO; self.lastLabel.drawsBackground = NO; self.lastLabel.editable = NO;
        self.lastLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.lastLabel];

        self.statusPill = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.statusPill.bezeled = NO; self.statusPill.drawsBackground = NO; self.statusPill.editable = NO;
        self.statusPill.alignment = NSTextAlignmentCenter;
        self.statusPill.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        self.statusPill.lineBreakMode = NSLineBreakByTruncatingTail;
        self.statusPill.usesSingleLineMode = YES;
        self.statusPill.wantsLayer = YES;
        self.statusPill.layer.cornerRadius = 10.0;
        self.statusPill.layer.masksToBounds = YES;
        [self addSubview:self.statusPill];

        self.viewButton = [NSButton buttonWithTitle:@"查看" target:nil action:nil];
        self.viewButton.bordered = NO;
        self.viewButton.font = [NSFont systemFontOfSize:11.5];
        self.viewButton.attributedTitle = [[NSAttributedString alloc]
            initWithString:@"查看" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.5],
                                                NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.04 green:0.52 blue:1.0 alpha:1.0]}];
        [self addSubview:self.viewButton];

        self.reprobeButton = [NSButton buttonWithTitle:@"↻" target:nil action:nil];
        self.reprobeButton.bordered = NO;
        self.reprobeButton.font = [NSFont systemFontOfSize:13];
        self.reprobeButton.toolTip = @"立即重探";
        [self addSubview:self.reprobeButton];

        self.enabledSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
        [self addSubview:self.enabledSwitch];

        self.deleteButton = [NSButton buttonWithTitle:@"删除" target:nil action:nil];
        self.deleteButton.bordered = NO;
        self.deleteButton.font = [NSFont systemFontOfSize:11.5];
        self.deleteButton.attributedTitle = [[NSAttributedString alloc]
            initWithString:@"删除" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.5],
                                                NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}];
        [self addSubview:self.deleteButton];
    }
    return self;
}

- (void)configureWithEntry:(RDWatchlistEntry *)entry width:(CGFloat)width target:(id)target {
    self.lastEntry = entry;
    self.lastTarget = target;
    [self applyLayoutWithWidth:width];

    NSString *host = [NSURL URLWithString:entry.pageURL].host ?: @"";
    self.titleLabel.stringValue = entry.title.length ? entry.title
                                : (host.length ? host : entry.pageURL);
    self.urlLabel.stringValue = entry.pageURL ?: @"";

    NSArray<NSNumber *> *allowed = @[@15, @30, @60, @120];
    NSInteger seg = 1;   // 默认 30
    for (NSUInteger i = 0; i < allowed.count; i++) {
        if (allowed[i].integerValue == entry.intervalMinutes) seg = (NSInteger)i;
    }
    self.intervalControl.selectedSegment = seg;
    self.intervalControl.identifier = [@"RDWatchRowInterval." stringByAppendingString:entry.identifier];
    self.intervalControl.target = target;
    self.intervalControl.action = @selector(watchIntervalChanged:);

    [self applyLastLabelForEntry:entry];
    [self applyStatusPillForEntry:entry];

    self.viewButton.identifier = [@"RDWatchRowViewButton." stringByAppendingString:entry.identifier];
    self.viewButton.target = target;
    self.viewButton.action = @selector(watchViewTapped:);

    self.reprobeButton.identifier = [@"RDWatchRowReprobe." stringByAppendingString:entry.identifier];
    self.reprobeButton.target = target;
    self.reprobeButton.action = @selector(watchReprobeTapped:);

    self.enabledSwitch.identifier = [@"RDWatchRowSwitch." stringByAppendingString:entry.identifier];
    self.enabledSwitch.state = entry.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.enabledSwitch.target = target;
    self.enabledSwitch.action = @selector(watchSwitchChanged:);

    self.deleteButton.identifier = [@"RDWatchRowDelete." stringByAppendingString:entry.identifier];
    self.deleteButton.target = target;
    self.deleteButton.action = @selector(watchDeleteTapped:);
}

- (void)applyLastLabelForEntry:(RDWatchlistEntry *)entry {
    NSDate *probeAt = entry.lastProbeAt;
    if (!probeAt) {
        self.lastLabel.attributedStringValue = [[NSAttributedString alloc]
            initWithString:@"—" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.5],
                                             NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]}];
        return;
    }
    NSString *clock = [RDWatchClockFormatter() stringFromDate:probeAt];
    NSString *rel = [RDWatchRelativeFormatter() localizedStringForDate:probeAt
                                                        relativeToDate:[NSDate date]];
    NSDictionary *mainAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5],
                                NSForegroundColorAttributeName: [NSColor labelColor]};
    NSDictionary *subAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5],
                               NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:clock ?: @"" attributes:mainAttrs]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:subAttrs]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:rel ?: @"" attributes:subAttrs]];
    self.lastLabel.attributedStringValue = as;
}

// 状态胶囊（契约 §3.4 文案定死）：已暂停 ＞ ＋N 新资源 ＞ 失败：… ＞ 无更新
- (void)applyStatusPillForEntry:(RDWatchlistEntry *)entry {
    NSString *text;
    NSColor *fg;
    NSColor *bg;
    if (!entry.enabled) {
        text = @"已暂停";
        fg = [NSColor tertiaryLabelColor];
        bg = [[NSColor labelColor] colorWithAlphaComponent:0.07];
    } else if (entry.pendingNewKeys.count > 0) {
        text = [NSString stringWithFormat:@"＋%lu 新资源", (unsigned long)entry.pendingNewKeys.count];
        fg = [NSColor colorWithSRGBRed:0.94 green:0.30 blue:0.25 alpha:1.0];
        bg = [[NSColor colorWithSRGBRed:1.0 green:0.27 blue:0.23 alpha:1.0] colorWithAlphaComponent:0.14];
    } else if (entry.lastError.length > 0) {
        NSString *summary = entry.lastError.length > 20
            ? [[entry.lastError substringToIndex:20] stringByAppendingString:@"…"]
            : entry.lastError;
        text = [NSString stringWithFormat:@"失败：%@", summary];
        fg = [NSColor systemOrangeColor];
        bg = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.15];
    } else {
        text = @"无更新";
        fg = [NSColor colorWithSRGBRed:0.20 green:0.72 blue:0.36 alpha:1.0];
        bg = [[NSColor colorWithSRGBRed:0.19 green:0.82 blue:0.35 alpha:1.0] colorWithAlphaComponent:0.13];
    }
    self.statusPill.stringValue = text;
    self.statusPill.textColor = fg;
    self.statusPill.layer.backgroundColor = bg.CGColor;
}

- (void)applyLayoutWithWidth:(CGFloat)width {
    CGFloat h = NSHeight(self.bounds);
    if (h <= 0) h = 58.0;
    RDWatchRowColumns c = RDWatchRowColumnsForWidth(width);
    self.titleLabel.frame = NSMakeRect(c.titleX, h - 33.0, c.titleW, 17.0);
    self.urlLabel.frame = NSMakeRect(c.titleX, 11.0, c.titleW, 14.0);
    self.intervalControl.frame = NSMakeRect(c.intervalX, (h - 24.0) / 2.0, 118.0, 24.0);
    self.lastLabel.frame = NSMakeRect(c.lastX, 13.0, 96.0, 32.0);
    self.statusPill.frame = NSMakeRect(c.pillX, (h - 20.0) / 2.0, 104.0, 20.0);
    self.viewButton.frame = NSMakeRect(c.viewX, (h - 24.0) / 2.0, 42.0, 24.0);
    self.reprobeButton.frame = NSMakeRect(c.reprobeX, (h - 26.0) / 2.0, 26.0, 26.0);
    self.enabledSwitch.frame = NSMakeRect(c.switchX, (h - 24.0) / 2.0, 40.0, 24.0);
    self.deleteButton.frame = NSMakeRect(c.deleteX, (h - 24.0) / 2.0, 42.0, 24.0);
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (self.lastEntry && newSize.width > 0) [self applyLayoutWithWidth:newSize.width];
}

@end

#pragma mark - 设置卡容器（内部行随宽度重排）

@interface RDWatchSettingsCardRow : NSObject
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *hintLabel;
@property (nonatomic, strong) NSView *control;
@end
@implementation RDWatchSettingsCardRow
@end

@interface RDWatchSettingsCardView : NSView
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSMutableArray<RDWatchSettingsCardRow *> *rows;
@property (nonatomic, strong) NSMutableArray<NSBox *> *separators;
- (void)addRowWithTitle:(NSString *)title hint:(NSString *)hint control:(NSView *)control;
@end

@implementation RDWatchSettingsCardView

// AX（契约 §3.4）：卡片容器自身以 AXGroup 元素出现并携带 RDWatchSettingsCard 标识，
// 子控件经 accessibilityChildren 继续可达 —— 否则普通 NSView 容器会被 AX 桥裁掉，
// 标识无法被黑盒探针定位。
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSArray<id<NSAccessibilityElement>> *)accessibilityChildren {
    return NSAccessibilityUnignoredChildren(self.subviews);
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.rows = [NSMutableArray array];
        self.separators = [NSMutableArray array];
        self.headerLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.headerLabel.bezeled = NO; self.headerLabel.drawsBackground = NO;
        self.headerLabel.editable = NO; self.headerLabel.selectable = NO;
        self.headerLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.headerLabel.textColor = [[NSColor labelColor] colorWithAlphaComponent:0.58];
        self.headerLabel.stringValue = @"追更设置";
        [self addSubview:self.headerLabel];
    }
    return self;
}

- (void)addRowWithTitle:(NSString *)title hint:(NSString *)hint control:(NSView *)control {
    RDWatchSettingsCardRow *row = [[RDWatchSettingsCardRow alloc] init];
    row.titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    row.titleLabel.bezeled = NO; row.titleLabel.drawsBackground = NO;
    row.titleLabel.editable = NO; row.titleLabel.selectable = NO;
    row.titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    row.titleLabel.textColor = [NSColor labelColor];
    row.titleLabel.stringValue = title;
    [self addSubview:row.titleLabel];

    row.hintLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    row.hintLabel.bezeled = NO; row.hintLabel.drawsBackground = NO;
    row.hintLabel.editable = NO; row.hintLabel.selectable = NO;
    row.hintLabel.font = [NSFont systemFontOfSize:11];
    row.hintLabel.textColor = [[NSColor labelColor] colorWithAlphaComponent:0.60];
    row.hintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    row.hintLabel.stringValue = hint ?: @"";
    [self addSubview:row.hintLabel];

    row.control = control;
    [self addSubview:control];
    [self.rows addObject:row];

    if (self.rows.count > 1) {
        NSBox *sep = [[NSBox alloc] initWithFrame:NSZeroRect];
        sep.boxType = NSBoxSeparator;
        [self addSubview:sep];
        [self.separators addObject:sep];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutRows];
}

- (void)layoutRows {
    CGFloat W = NSWidth(self.bounds);
    CGFloat H = NSHeight(self.bounds);
    if (W <= 0 || H <= 0) return;
    const CGFloat padX = 16.0;
    const CGFloat rowH = 34.0;
    self.headerLabel.frame = NSMakeRect(padX, H - 24.0, 240.0, 15.0);
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        RDWatchSettingsCardRow *row = self.rows[i];
        CGFloat rowY = H - 34.0 - (CGFloat)(i + 1) * rowH;
        CGFloat controlW = NSWidth(row.control.frame);
        CGFloat controlH = NSHeight(row.control.frame);
        row.control.frame = NSMakeRect(W - padX - controlW, rowY + (rowH - controlH) / 2.0, controlW, controlH);
        row.titleLabel.frame = NSMakeRect(padX, rowY + 9.0, 120.0, 16.0);
        CGFloat hintX = padX + 120.0 + 12.0;
        CGFloat hintW = MAX(40.0, (W - padX - controlW - 8.0) - hintX);
        row.hintLabel.frame = NSMakeRect(hintX, rowY + 10.0, hintW, 14.0);
    }
    for (NSUInteger i = 0; i < self.separators.count; i++) {
        NSBox *sep = self.separators[i];
        CGFloat y = H - 34.0 - (CGFloat)(i + 1) * rowH;
        sep.frame = NSMakeRect(padX, y, MAX(0.0, W - 2.0 * padX), 1.0);
    }
}

@end

#pragma mark - 页面控制器

@implementation RDWatchlistPageController

- (instancetype)initWithFrame:(NSRect)frame delegate:(id<RDWatchlistPageDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        _entries = @[];
        [self buildPageWithFrame:frame];
    }
    return self;
}

#pragma mark 构建

- (void)buildPageWithFrame:(NSRect)frame {
    self.pageView = [[NSView alloc] initWithFrame:frame];

    // ── 页头：返回 + 标题（照 buildDownloadsPage 的模式与位置）──
    self.backButton = [NSButton buttonWithTitle:@"← 返回主页" target:self action:@selector(backTapped:)];
    self.backButton.bordered = NO;
    self.backButton.font = [NSFont systemFontOfSize:12];
    self.backButton.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"← 返回主页" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12],
                                                  NSForegroundColorAttributeName: [NSColor systemGrayColor]}];
    self.backButton.frame = NSMakeRect(24, 642, 90, 24);
    self.backButton.autoresizingMask = NSViewMinYMargin;
    self.backButton.identifier = @"RDWatchBackButton";
    [self.pageView addSubview:self.backButton];

    self.pageTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 600, 300, 30)];
    self.pageTitle.bezeled = NO; self.pageTitle.drawsBackground = NO;
    self.pageTitle.editable = NO; self.pageTitle.selectable = NO;
    self.pageTitle.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    self.pageTitle.textColor = [NSColor labelColor];
    self.pageTitle.stringValue = @"追更";
    self.pageTitle.autoresizingMask = NSViewMinYMargin;
    [self.pageView addSubview:self.pageTitle];

    // ── 工具栏 ──
    self.addButton = [NSButton buttonWithTitle:@"" target:self action:@selector(addCurrentPageTapped:)];
    self.addButton.bordered = NO;
    self.addButton.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"＋ 添加当前页" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                                                     NSForegroundColorAttributeName: NSColor.whiteColor}];
    self.addButton.wantsLayer = YES;
    self.addButton.layer.backgroundColor = [NSColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0].CGColor;
    self.addButton.layer.cornerRadius = 6.0;
    [self.addButton sizeToFit];
    NSRect addFrame = self.addButton.frame;
    addFrame.size.width += 28.0;
    addFrame.size.height = 28.0;
    addFrame.origin = NSMakePoint(30, 562);
    self.addButton.frame = addFrame;
    self.addButton.identifier = @"RDWatchAddCurrentPageButton";
    self.addButton.autoresizingMask = NSViewMinYMargin;
    [self.pageView addSubview:self.addButton];

    self.reloadAllButton = [NSButton buttonWithTitle:@"" target:self action:@selector(reloadAllTapped:)];
    self.reloadAllButton.bordered = NO;
    self.reloadAllButton.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"↻ 全部重探" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12],
                                                  NSForegroundColorAttributeName: [NSColor labelColor]}];
    self.reloadAllButton.wantsLayer = YES;
    self.reloadAllButton.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    self.reloadAllButton.layer.borderWidth = 1.0;
    self.reloadAllButton.layer.borderColor = NSColor.separatorColor.CGColor;
    self.reloadAllButton.layer.cornerRadius = 6.0;
    [self.reloadAllButton sizeToFit];
    NSRect reloadFrame = self.reloadAllButton.frame;
    reloadFrame.size.width += 28.0;
    reloadFrame.size.height = 28.0;
    reloadFrame.origin = NSMakePoint(NSMaxX(addFrame) + 12.0, 562);
    self.reloadAllButton.frame = reloadFrame;
    self.reloadAllButton.identifier = @"RDWatchReloadAllButton";
    self.reloadAllButton.autoresizingMask = NSViewMinYMargin;
    [self.pageView addSubview:self.reloadAllButton];

    // 摘要（右对齐）：N 个页面 · M 个未读 · 助手运行中/未运行
    CGFloat pageW = NSWidth(frame);
    self.summaryLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(pageW - 24.0 - 420.0, 568, 420, 16)];
    self.summaryLabel.bezeled = NO; self.summaryLabel.drawsBackground = NO;
    self.summaryLabel.editable = NO; self.summaryLabel.selectable = NO;
    self.summaryLabel.alignment = NSTextAlignmentRight;
    self.summaryLabel.font = [NSFont systemFontOfSize:12];
    self.summaryLabel.textColor = [NSColor secondaryLabelColor];
    self.summaryLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.pageView addSubview:self.summaryLabel];

    // 状态行：默认显示助手运行态；动作反馈就地覆盖
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 534, pageW - 60.0, 18)];
    self.statusLabel.bezeled = NO; self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO; self.statusLabel.selectable = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.pageView addSubview:self.statusLabel];

    // ── 列表头 + 分隔细线 ──
    self.headerRule = [[NSBox alloc] initWithFrame:NSMakeRect(24, 510, pageW - 48.0, 1)];
    self.headerRule.boxType = NSBoxSeparator;
    self.headerRule.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.pageView addSubview:self.headerRule];
    [self buildHeaderLabelsForTableWidth:pageW - 48.0];

    // ── 观察列表 ──
    self.table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, pageW - 48.0, 270)];
    self.table.rowHeight = 58.0;
    self.table.headerView = nil;
    self.table.backgroundColor = [NSColor colorWithSRGBRed:0.980 green:0.973 blue:0.957 alpha:1.0];
    self.table.usesAlternatingRowBackgroundColors = NO;
    self.table.dataSource = (id)self;
    self.table.delegate = (id)self;
    self.table.allowsColumnResizing = NO;
    self.table.allowsColumnReordering = NO;
    self.table.allowsMultipleSelection = NO;
    self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;   // 行点按＝查看
    self.table.identifier = @"RDWatchTableView";
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"watch"];
    col.width = pageW - 48.0;
    col.minWidth = 80;
    col.maxWidth = CGFLOAT_MAX;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:col];
    self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 236, pageW - 48.0, 270)];
    self.scrollView.documentView = self.table;
    self.table.frame = NSMakeRect(0, 0, NSWidth(self.scrollView.contentView.bounds), NSHeight(self.scrollView.contentView.bounds));
    self.table.autoresizingMask = NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.drawsBackground = YES;
    self.scrollView.backgroundColor = [NSColor colorWithSRGBRed:0.980 green:0.973 blue:0.957 alpha:1.0];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.pageView addSubview:self.scrollView];

    self.emptyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 236, pageW - 48.0, 270)];
    self.emptyLabel.bezeled = NO; self.emptyLabel.drawsBackground = NO;
    self.emptyLabel.editable = NO; self.emptyLabel.selectable = NO;
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [NSFont systemFontOfSize:13];
    self.emptyLabel.textColor = [NSColor secondaryLabelColor];
    self.emptyLabel.stringValue = @"还没有追更的页面 — 回到主页粘贴网址，再点「＋ 添加当前页」";
    self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.emptyLabel.identifier = @"RDWatchEmptyLabel";
    [self.pageView addSubview:self.emptyLabel];

    // ── 设置卡（四行）──
    [self buildSettingsCardWithWidth:pageW - 48.0];

    [self refreshData];
}

- (void)buildHeaderLabelsForTableWidth:(CGFloat)tableWidth {
    RDWatchRowColumns c = RDWatchRowColumnsForWidth(tableWidth);
    NSArray<NSString *> *titles = @[@"页面", @"间隔", @"上次探测", @"状态", @"启用"];
    CGFloat xs[5] = {24.0 + c.titleX, 24.0 + c.intervalX, 24.0 + c.lastX, 24.0 + c.pillX, 24.0 + c.switchX};
    CGFloat ws[5] = {c.titleW, 118.0, 96.0, 104.0, 40.0};
    NSMutableArray<NSTextField *> *labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(xs[i], 516, ws[i], 13)];
        l.bezeled = NO; l.drawsBackground = NO; l.editable = NO; l.selectable = NO;
        l.font = [NSFont systemFontOfSize:10.5];
        l.textColor = [NSColor tertiaryLabelColor];
        l.stringValue = titles[i];
        // 页面列锚左；右起各列与行内列一样锚右（右缘固定偏移），窗口缩放时随列走
        l.autoresizingMask = (i == 0) ? NSViewMinYMargin : (NSViewMinXMargin | NSViewMinYMargin);
        [self.pageView addSubview:l];
        [labels addObject:l];
    }
    self.headerLabels = labels;
}

- (void)buildSettingsCardWithWidth:(CGFloat)cardWidth {
    self.settingsCard = [[RDWatchSettingsCardView alloc] initWithFrame:NSMakeRect(24, 44, cardWidth, 186)];
    self.settingsCard.wantsLayer = YES;
    self.settingsCard.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    self.settingsCard.layer.cornerRadius = 8.0;
    self.settingsCard.layer.borderWidth = 1.0;
    self.settingsCard.layer.borderColor = NSColor.separatorColor.CGColor;
    self.settingsCard.identifier = @"RDWatchSettingsCard";
    self.settingsCard.autoresizingMask = NSViewWidthSizable;   // 锚底，不与列表重叠
    [self.pageView addSubview:self.settingsCard];

    self.autoLaunchSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    self.autoLaunchSwitch.identifier = @"RDWatchAutoLaunchSwitch";
    self.autoLaunchSwitch.target = self;
    self.autoLaunchSwitch.action = @selector(watchAutoLaunchChanged:);
    [self.settingsCard addRowWithTitle:@"开机自启助手" hint:@"登录时后台常驻，无需打开觅流" control:self.autoLaunchSwitch];

    self.notifySwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    self.notifySwitch.identifier = @"RDWatchNotifySwitch";
    self.notifySwitch.target = self;
    self.notifySwitch.action = @selector(watchNotifyChanged:);
    [self.settingsCard addRowWithTitle:@"新资源通知" hint:@"系统通知中心，含声音" control:self.notifySwitch];

    self.quietHoursControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"00:00–08:00", @"关闭"]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self action:@selector(watchQuietHoursChanged:)];
    self.quietHoursControl.identifier = @"RDWatchQuietHoursControl";
    self.quietHoursControl.frame = NSMakeRect(0, 0, 170, 26);
    self.quietHoursControl.segmentStyle = NSSegmentStyleRounded;
    self.quietHoursControl.font = [NSFont systemFontOfSize:11];
    [self.settingsCard addRowWithTitle:@"静音时段" hint:@"时段内不弹通知，仅累计角标" control:self.quietHoursControl];

    // 判定范围：v1 固定「仅视频」（条目 videoOnly 恒为 YES），整组置灰注明 v2
    self.scopeControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"仅视频", @"视频＋图片"]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:nil action:nil];
    self.scopeControl.identifier = @"RDWatchScopeControl";
    self.scopeControl.frame = NSMakeRect(0, 0, 190, 26);
    self.scopeControl.segmentStyle = NSSegmentStyleRounded;
    self.scopeControl.font = [NSFont systemFontOfSize:11];
    self.scopeControl.selectedSegment = 0;
    self.scopeControl.enabled = NO;
    [self.settingsCard addRowWithTitle:@"判定范围" hint:@"图片类资源是否也算「新」· 图片判定 v2 开放" control:self.scopeControl];

    [self.settingsCard layoutRows];
}

#pragma mark 显示前刷新

- (void)prepareForShow {
    [self refreshData];
    [self syncSettingsCardControls];
}

- (void)syncSettingsCardControls {
    id storedAutoLaunch = [[NSUserDefaults standardUserDefaults] objectForKey:kRDWatchAutoLaunchDefaultsKey];
    BOOL autoLaunchOn = (storedAutoLaunch == nil) ? YES : [storedAutoLaunch boolValue];
    self.autoLaunchSwitch.state = autoLaunchOn ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL notify = [PreferencesStore.shared boolForKey:SevenZZKeyWatchNotifyEnabled defaultValue:YES];
    self.notifySwitch.state = notify ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *quiet = [PreferencesStore.shared stringForKey:SevenZZKeyWatchQuietHours defaultValue:@"00:00-08:00"];
    self.quietHoursControl.selectedSegment = [quiet isEqualToString:@"off"] ? 1 : 0;
    self.scopeControl.selectedSegment = 0;
}

#pragma mark 数据刷新

- (void)refreshData {
    self.entries = RDWatchlistStore.sharedStore.entries;
    [self.table reloadData];
    BOOL running = [self watchAgentRunning];
    NSInteger pages = (NSInteger)self.entries.count;
    NSInteger unread = [RDWatchlistStore.sharedStore totalPendingNewCount];
    self.summaryLabel.stringValue = [NSString stringWithFormat:@"%ld 个页面 · %ld 个未读 · 助手%@",
                                     (long)pages, (long)unread, running ? @"运行中" : @"未运行"];
    self.emptyLabel.hidden = pages > 0;
    self.statusLabel.stringValue = running ? @"助手运行中 · 到点自动静默重探"
                                           : @"助手未运行 · 助手启动后开始定时重探";
}

- (void)setStatusText:(NSString *)text {
    self.statusLabel.stringValue = text ?: @"";
}

// 契约 §3.5：运行态检测＝NSWorkspace.runningApplications 查 bundle id 含 watchlist
// （即 com.sevenzz.resource-detector.watchlist）
- (BOOL)watchAgentRunning {
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        NSString *bid = app.bundleIdentifier;
        if (bid.length && [bid containsString:@"watchlist"]) return YES;
    }
    return NO;
}

#pragma mark 工具栏动作

- (void)addCurrentPageTapped:(id)sender {
    NSString *raw = [self.delegate watchlistPageCurrentAddressForWatchlist] ?: @"";
    raw = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (raw.length == 0) { [self setStatusText:@"主页地址栏为空，先在主页粘贴网址"]; return; }
    NSURL *url = [NSURL URLWithString:raw];
    NSString *scheme = url.scheme.lowercaseString;
    if (url.host.length == 0 ||
        (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
        [self setStatusText:@"不是有效的网页地址"];
        return;
    }
    BOOL existed = ([RDWatchlistStore.sharedStore entryForURL:raw] != nil);
    [RDWatchlistStore.sharedStore upsertEntryForURL:raw title:nil];
    [self refreshData];
    [self setStatusText:existed ? @"该页面已在追更列表中" : @"已添加当前页到追更"];
}

- (void)reloadAllTapped:(id)sender {
    if (![self watchAgentRunning]) { [self setStatusText:@"助手未运行"]; return; }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:RDWatchNotificationWatchNow object:nil userInfo:nil deliverImmediately:YES];
    [self setStatusText:@"已请求助手立即重探"];
}

- (void)backTapped:(id)sender {
    [self.delegate watchlistPageDidRequestBack];
}

#pragma mark 行动作

- (void)watchIntervalChanged:(NSSegmentedControl *)sender {
    RDWatchlistEntry *entry = [self entryForControlIdentifier:sender.identifier];
    if (!entry) return;
    static const NSInteger kMinutes[4] = {15, 30, 60, 120};
    NSInteger idx = MAX(0, MIN(3, sender.selectedSegment));
    entry.intervalMinutes = kMinutes[idx];   // 条目 setter 另有白名单清洗
    [RDWatchlistStore.sharedStore updateEntry:entry];   // 改动即持久化（契约 §3.4）
    [self refreshData];
}

- (void)watchSwitchChanged:(NSSwitch *)sender {
    RDWatchlistEntry *entry = [self entryForControlIdentifier:sender.identifier];
    if (!entry) return;
    entry.enabled = (sender.state == NSControlStateValueOn);
    [RDWatchlistStore.sharedStore updateEntry:entry];
    [self refreshData];
}

- (void)watchDeleteTapped:(NSButton *)sender {
    RDWatchlistEntry *entry = [self entryForControlIdentifier:sender.identifier];
    if (!entry) return;
    [RDWatchlistStore.sharedStore removeEntryWithIdentifier:entry.identifier];
    [self refreshData];
    [self setStatusText:@"已从追更列表移除"];
}

- (void)watchViewTapped:(NSButton *)sender {
    RDWatchlistEntry *entry = [self entryForControlIdentifier:sender.identifier];
    if (!entry) return;
    [self openEntry:entry];
}

// 行内「立即重探」：与工具栏「全部重探」同发 com.sevenzz.miliu.watchNow
//（契约 §3.5 只定义了这一条 App→助手重探通知，未提供按条目定向的通知）
- (void)watchReprobeTapped:(NSButton *)sender {
    if (![self watchAgentRunning]) { [self setStatusText:@"助手未运行"]; return; }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:RDWatchNotificationWatchNow object:nil userInfo:nil deliverImmediately:YES];
    [self setStatusText:@"已请求助手立即重探"];
}

- (nullable RDWatchlistEntry *)entryForControlIdentifier:(NSString *)controlIdentifier {
    NSString *entryID = RDWatchEntryIDInControlIdentifier(controlIdentifier);
    if (entryID.length == 0) return nil;
    // 动作时刻直接取 store 当前缓存（任何一次 store 变更都会先从磁盘重读），
    // 不用展示快照：缩小 updateEntry 整行写回覆盖并发更新的窗口。
    for (RDWatchlistEntry *e in RDWatchlistStore.sharedStore.entries) {
        if ([e.identifier isEqualToString:entryID]) return e;
    }
    return nil;
}

// 「查看」/ 行点按：标已读 + 回主页 + 填址 scan:（切页与探测经 delegate 由 App 执行）
- (void)openEntry:(RDWatchlistEntry *)entry {
    [RDWatchlistStore.sharedStore markPendingRead:entry.identifier];
    [self refreshData];
    [self.delegate watchlistPageDidRequestOpenPageURL:entry.pageURL];
}

#pragma mark 设置卡动作

// 开机自启（契约 §3.5）：助手运行中 → 发 com.sevenzz.miliu.watchService {enabled:BOOL}
// 让助手注册/注销 LaunchAgent；未运行且打开 → 直接拉起助手（其启动时按偏好自注册，
// 2026-10-03 集成补全：否则用户装完无入口首次启用常驻）
- (void)watchAutoLaunchChanged:(NSSwitch *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kRDWatchAutoLaunchDefaultsKey];
    if ([self watchAgentRunning]) {
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:RDWatchNotificationWatchService object:nil
            userInfo:@{@"enabled": @(on)} deliverImmediately:YES];
        [self setStatusText:on ? @"已请求助手注册开机自启" : @"已请求助手注销开机自启"];
    } else if (on) {
        [self launchWatchAgent];
        [self setStatusText:@"助手已拉起 · 正在注册开机自启"];
    } else {
        [self setStatusText:@"助手未运行 · 设置已保存"];
    }
}

// 拉起内嵌助手（同 bundle 内相对定位；失败时按 bundle id 兜底）
- (void)launchWatchAgent {
    NSURL *helperURL = [[[NSBundle mainBundle] bundleURL]
        URLByAppendingPathComponent:@"Contents/Helpers/觅流追更助手.app"];
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:helperURL.path isDirectory:&dir] || !dir) {
        helperURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:RDWatchAgentBundleIdentifier];
    }
    if (!helperURL) { [self setStatusText:@"未找到追更助手（安装可能不完整）"]; return; }
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:helperURL
                                             configuration:[NSWorkspaceOpenConfiguration configuration]
                                       completionHandler:nil];
}

- (void)watchNotifyChanged:(NSSwitch *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [PreferencesStore.shared setBool:on forKey:SevenZZKeyWatchNotifyEnabled];
}

// 静音时段：契约 §3.2 存储 "HH:mm-HH:mm"，字面 off=关闭；展示用 en dash
- (void)watchQuietHoursChanged:(NSSegmentedControl *)sender {
    NSString *value = (sender.selectedSegment == 1) ? @"off" : @"00:00-08:00";
    [PreferencesStore.shared setString:value forKey:SevenZZKeyWatchQuietHours];
}

#pragma mark 表格数据源与委托

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.entries.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[RDWatchRowView alloc] initWithFrame:NSMakeRect(0.0, 0.0, NSWidth(tableView.bounds), tableView.rowHeight)];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.entries.count) return nil;
    RDWatchlistEntry *entry = self.entries[(NSUInteger)row];
    RDWatchRowCellView *cell = [[RDWatchRowCellView alloc]
        initWithFrame:NSMakeRect(0, 0, NSWidth(tableView.bounds), tableView.rowHeight)];
    [cell configureWithEntry:entry width:NSWidth(tableView.bounds) target:self];
    return cell;
}

// 行点按＝查看（查看按钮同一入口）
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != self.table) return;
    NSInteger row = self.table.selectedRow;
    [self.table deselectAll:nil];
    if (row < 0 || row >= (NSInteger)self.entries.count) return;
    [self openEntry:self.entries[(NSUInteger)row]];
}

@end
