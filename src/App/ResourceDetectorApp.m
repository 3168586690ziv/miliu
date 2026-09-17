#import <Cocoa/Cocoa.h>
#import "RDLog.h"
#import <limits.h>
#import <math.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import "DiscoverySessionController.h"
#import "DetectedMedia.h"
#import "DownloadManager.h"
#import "ResourceDownloadSettings.h"
#import "PreferencesStore.h"
#import "ResourceResultRowView.h"
#import "../Shared/UI/RDByteCountFormatting.h"
#import "RDMetadataService.h"
#import "RDQualityTier.h"
#import "DownloadLinkRefresher.h"
#import "RDHybridPageProbe.h"
#import "RDGeneratedVersion.h"  // 构建期生成（scripts/generate-version.sh → build/generated/）

// AppKit 的 NSProgressIndicator 即使把 frame 压到 1px，仍可能按控件尺寸
// 强制绘制成约 2px。这个轻量视图直接绘制 1px 的轨道与填充，保证视觉粗细
// 由 frame 决定，同时允许进度展示层以定时器平滑追赶真实目标值。
@class RDDownloadRowCellView;
@interface RDThinProgressView : NSView
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) BOOL indeterminate;
@end

// 选中指示属于行，而不是 cell。NSTableView 会复用/重挂载 cell，
// 因此从 cell 的 superview 链查找表格会在点击、刷新和滚动时得到过期状态。
@interface RDDownloadRowView : NSTableRowView
@end

@implementation RDDownloadRowView
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSColor colorWithWhite:0.72 alpha:0.55] setFill];
    NSRect separator = NSMakeRect(16.0, 0.0, MAX(0.0, NSWidth(self.bounds) - 32.0), 1.0);
    NSRectFill(separator);
    if (self.selected) {
        [[NSColor colorWithRed:0.31 green:0.56 blue:1.0 alpha:0.9] setFill];
        NSRectFill(NSMakeRect(0.0, 0.0, 3.0, NSHeight(self.bounds)));
    }
}
@end

@implementation RDThinProgressView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.accessibilityRole = NSAccessibilityProgressIndicatorRole;
        self.accessibilityValue = @0.0;
    }
    return self;
}
- (void)setProgress:(double)progress {
    _progress = isfinite(progress) ? MAX(0.0, MIN(1.0, progress)) : 0.0;
    self.accessibilityValue = _indeterminate ? nil : @(_progress);
    [self setNeedsDisplay:YES];
}
- (void)setIndeterminate:(BOOL)indeterminate {
    _indeterminate = indeterminate;
    self.accessibilityValue = indeterminate ? nil : @(_progress);
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = self.bounds;
    [[NSColor colorWithWhite:0.0 alpha:0.10] setFill];
    NSRectFill(bounds);
    NSColor *fillColor = [NSColor colorWithRed:0.31 green:0.56 blue:1.0 alpha:1.0];
    if (self.indeterminate) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        CGFloat stripe = 6.0;
        CGFloat h = NSHeight(bounds);
        for (CGFloat x = -h; x < NSWidth(bounds) + h; x += stripe * 2.0) {
            [path moveToPoint:NSMakePoint(x, 0)];
            [path lineToPoint:NSMakePoint(x + h, h)];
            [path lineToPoint:NSMakePoint(x + h + stripe, h)];
            [path lineToPoint:NSMakePoint(x + stripe, 0)];
            [path closePath];
        }
        [[fillColor colorWithAlphaComponent:0.35] setFill];
        [path fill];
        return;
    }
    if (self.progress <= 0) return;
    NSRect fill = bounds;
    fill.size.width = floor(NSWidth(bounds) * self.progress);
    [fillColor setFill];
    NSRectFill(fill);
}
@end

#pragma mark - 下载列表行视图

@interface RDDownloadRowCellView : NSTableCellView
@property (nonatomic, strong) NSTextField *fileNameLabel;
@property (nonatomic, strong) NSTextField *metricsLabel;
@property (nonatomic, strong) NSTextField *stateLabel;
@property (nonatomic, strong) NSTextField *errorLabel;
@property (nonatomic, strong) RDThinProgressView *progressView;
@property (nonatomic, strong) NSButton *pauseButton;
@property (nonatomic, strong) NSButton *resumeButton;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *revealButton;
@property (nonatomic, copy) NSString *jobIdentifier;
// 窗口缩放时重排所需：记住最近一次配置的任务与宿主（弱引用，避免延长生命周期）
@property (nonatomic, strong) DownloadJob *lastJob;
@property (nonatomic, weak) id lastApp;
- (void)configureWithJob:(DownloadJob *)job width:(CGFloat)width app:(id)app;
@end


#pragma mark - 应用委托

// ── 统一呈现预算 ──
// 页面探测回调完成 ≠ 可以呈现：列表缩略图与当前详情可能仍在读取。这两个量
// 都到达终态（已读取 / 明确失败 / 超时 / 不支持）之前，进度不得到 100%，也
// 不得显示“探测完成”；全部就绪后在同一轮主线程更新中一次性呈现。
static const NSUInteger kRDPresentationPreviewBudget = 12;   // 首屏缩略图行数上限
static const NSTimeInterval kRDPresentationSafetyDeadline = 60.0;

@class RDSlashWindow;

typedef NS_ENUM(NSInteger, RDDownloadFilter) {
    RDDownloadFilterAll = 0,
    RDDownloadFilterActive,
    RDDownloadFilterSucceeded,
    RDDownloadFilterFailed,
};

@interface ResourceDetectorAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, DownloadManagerDelegate>
@property (nonatomic, assign) RDDownloadFilter downloadFilter;
@property RDSlashWindow *window;
@property NSView *homePage;
@property NSView *settingsPage;
@property NSView *downloadsPage;
@property NSButton *downloadsBackButton;
@property NSTextField *downloadsTitleLabel;
@property NSView *downloadsFilterBar;
@property NSArray<NSButton *> *downloadsFilterButtons;
@property NSTextField *downloadsStatusLabel;
@property NSTableView *downloadsTable;
@property NSScrollView *downloadsScrollView;
@property (nonatomic, strong) NSTimer *downloadsRefreshTimer;              // 合并高频进度回调（≈5Hz）
@property (nonatomic, copy) NSArray<NSString *> *downloadsRenderedIdentifiers; // 行顺序快照
@property (nonatomic, assign) BOOL downloadsListDirtyWhileHidden;         // 页面隐藏期间的变动
@property NSTextField *downloadsEmptyLabel;
@property DownloadLinkRefresher *linkRefresher;
@property RDHybridPageProbe *refreshProbe;
@property NSTextField *slashLabel;
@property NSTextField *urlField;
@property NSButton *modeButton;
@property NSButton *settingsButton;
@property NSTextField *pagesField;
@property NSButton *pagesUnitButton;
@property BOOL filterVideoOnly;
@property BOOL filterImagesOnly;
@property NSSwitch *settingsVideoSwitch;
@property NSSwitch *settingsImagesSwitch;
@property NSSegmentedControl *settingsPaneRatioControl;
@property NSButton *clearDownloadRecordsButton;
@property NSTextField *settingsVersionLabel;  // 设置页右下角版本号（构建期生成，运行期固定）
@property NSTextField *checkLabel;
@property NSTextField *statusNote;
@property NSTableView *table;
@property NSMutableArray<DetectedMedia *> *results;
// 分栏布局：左列表 / 右详情（手动布局，3:7 恒定）
@property NSView *leftPane;
@property NSView *detailPane;
@property NSView *vDivider;
@property NSView *topDivider;
@property NSArray<NSView *> *detailContent;
// 设置页「分组卡片」布局状态（第 12 轮改版）。
// 重要：行标题 / 说明 / 控件仍然全部是 settingsPage 的**直接子视图** ——
// 黑盒测试（UIExperienceTests 的 RatioLabelIn）和 AX 遍历都依赖扁平结构；
// 卡片与分隔线只是「背景装饰视图」，先加入、让它们留在 z 序下层。
@property (nonatomic, strong) NSArray<NSView *> *settingsGroupLabels;
@property (nonatomic, strong) NSArray<NSView *> *settingsCards;
@property (nonatomic, strong) NSArray<NSTextField *> *settingsRowTitles;
@property (nonatomic, strong) NSArray *settingsRowHints;                      // NSTextField 或 NSNull（该行无说明）
@property (nonatomic, strong) NSArray<NSArray<NSView *> *> *settingsRowControls;  // 每行右侧 1..n 个控件
@property (nonatomic, strong) NSArray<NSNumber *> *settingsRowCard;               // 每行归属的卡片下标
@property (nonatomic, strong) NSArray<NSView *> *settingsSeparators;
@property (nonatomic, strong) NSArray<NSNumber *> *settingsSeparatorRow;          // 分隔线画在第几行之后
@property (nonatomic, weak) NSTextField *settingsTitleLabel;
@property (nonatomic, weak) NSButton *settingsBackButton;
@property NSTextField *emptyHint;
@property NSImageView *thumbView;
@property NSTextField *thumbStatusLabel;
@property NSTextField *detailTitle;
@property NSTextField *durationTitle;
@property NSTextField *durationValue;
@property NSTextField *formatTitle;
@property NSTextField *formatValue;
@property NSTextField *sizeTitle;
@property NSTextField *sizeValue;
@property NSTextField *dimensionTitle;
@property NSTextField *dimensionValue;
@property NSPopUpButton *variantPicker;
@property DetectedMedia *selectedVariantMedia;
@property NSString *previewPosterURL;
@property NSTextField *sourceTitle;
@property NSTextField *sourceValue;
@property NSTextField *linkTitleLabel;
@property NSTextField *linkField;
@property NSButton *linkCopyButton;
@property NSButton *detailDownloadButton;
@property RDMetadataService *metadataService;
@property RDMetadataToken *metadataToken;
@property RDMetadataSnapshot *metadataSnapshot;
@property NSMutableDictionary<NSString *, NSString *> *durationCache;
// 用户为“当前选中行”选定的画质档位摘要（时长/大小文本），键 = 该行的资源身份。
// 详情显示的是行内某个档位时，列表行摘要必须与详情、与 ⌘D 实际下载的对象一致；
// 否则会出现「列表说 30.4 MB、实际下 100.6 MB」的观感不一致（2026-09-13 真实验收发现）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *selectedTierRowDisplay;
@property (nonatomic, weak) DetectedMedia *detailMedia;  // 详情面板当前展示的资源（异步回填用）
@property (nonatomic, strong) DetectedMedia *currentDownloadMedia; // 详情中明确选中的实际下载对象
@property (nonatomic, assign) BOOL restoringSelectionAfterReload; // reload 期间抑制选择回调
// 当前缩略图是否就是 posterURL 那张海报解码出来的图（用于判断能否跨画质沿用，
// 避免把上一档位的视频首帧当成新档位的缩略图）。
@property (nonatomic, assign) BOOL thumbShowsPosterImage;
@property NSInteger detailGeneration;
// ── 统一呈现 ──（详见 finishScanWithResult: / beginUnifiedPresentationForResult:）
@property (nonatomic, assign) BOOL presentationPreparing;
@property (nonatomic, assign) NSInteger presentationGeneration;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *presentationTokens; // @{{token, legs}}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *presentationRequirements;
@property (nonatomic, strong) NSMutableSet<NSString *> *presentationSettled;
@property (nonatomic, assign) NSUInteger presentationOutstanding;
@property (nonatomic, assign) NSUInteger presentationRequirementTotal; // 必需项总数（含每个画质档位）
@property (nonatomic, assign) BOOL explorationResultsSuppressed;      // 探索未完成前列表不呈现任何行
@property (nonatomic, copy) NSString *pendingCompletionStatus;
@property (nonatomic, assign) BOOL pendingCompletionShowsCheck;
@property DiscoverySessionController *session;
@property DownloadManager *downloadManager;
@property (nonatomic, copy) NSString *latestDownloadJobIdentifier;
@property (nonatomic, strong) NSTimer *downloadRecencyTimer;
@property ResourceDownloadSettings *downloadSettings;
@property NSButton *rescanFooter;
@property NSButton *downloadFooter;
@property NSButton *downloadsFooter;
@property (nullable) NSButton *downloadPauseFooter;
@property BOOL scanning;
@property (nonatomic, assign) NSInteger scanGeneration;   // 探测代次：新探测/取消都会作废旧回调
// 已用「临时结果」先把列表显示出来（探测仍在进行，动态 WebKit 腿还没回来）。
// 此时列表可点、可选中，但不代表探测结束。
@property (nonatomic, assign) BOOL previewShown;
@property (nonatomic, assign) ZZResourceDiscoveryMode mode;
@property (nonatomic, assign) NSUInteger sitePages;
// 供快捷键窗口调用的动作（需要在接口中声明）
- (void)scan:(id)sender;
- (void)cancelScan:(id)sender;
- (void)showDownloads:(id)sender;
#pragma mark - 统一呈现（私有）
- (void)beginUnifiedPresentationForResult:(ZZResourceDiscoveryResult *)result;
- (void)presentationSnapshotArrived:(RDMetadataSnapshot *)snapshot
                           forMedia:(DetectedMedia *)media
                         generation:(NSInteger)generation;
- (void)commitUnifiedPresentationForGeneration:(NSInteger)generation;
- (void)cancelPresentationPreparation;
- (void)registerPresentationMedia:(DetectedMedia *)media
                 includeMediaLegs:(BOOL)includeMediaLegs
                           entries:(NSMutableArray<NSMutableDictionary *> *)entries
                      requirements:(NSMutableDictionary<NSString *, NSNumber *> *)requirements;
- (void)requirePresentationForMediaWhilePreparing:(DetectedMedia *)media;
- (void)refreshDetailPresentation;
- (void)downloadSelected:(id)sender;
// ⌘空格：暂停/继续当前下载（CGEventTap 前台接管，见实现）
- (void)toggleDownloadPauseResume:(id)sender;
- (void)installSpaceHotkeyTap;

@property (nonatomic, assign) CFMachPortRef spaceTap;        // ⌘空格 事件口
@property (nonatomic, assign) CFRunLoopSourceRef spaceTapSource;
@end

// 快捷键窗口：⌘D 下载选中、⌘L 下载列表、⌘P 暂停/继续（零权限）
@interface RDSlashWindow : NSWindow
@end

@implementation RDSlashWindow
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags == NSEventModifierFlagCommand) {
        NSString *ch = [event.charactersIgnoringModifiers lowercaseString];
        ResourceDetectorAppDelegate *delegate = (ResourceDetectorAppDelegate *)self.delegate;
        if ([ch isEqualToString:@"d"] && [delegate respondsToSelector:@selector(downloadSelected:)]) {
            [delegate downloadSelected:nil];
            return YES;
        }
        if ([ch isEqualToString:@"l"] && [delegate respondsToSelector:@selector(showDownloads:)]) {
            [delegate showDownloads:nil];
            return YES;
        }
        // ⌘P：暂停/继续下载。APP 内普通快捷键，无需任何系统权限；
        // 与 ⌘空格（需辅助功能授权的全局截获）等效。
        if ([ch isEqualToString:@"p"] && [delegate respondsToSelector:@selector(toggleDownloadPauseResume:)]) {
            [delegate toggleDownloadPauseResume:nil];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}
@end

@implementation ResourceDetectorAppDelegate

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_spaceTapSource) {
        CFRunLoopSourceInvalidate(_spaceTapSource);
        CFRelease(_spaceTapSource);
        _spaceTapSource = NULL;
    }
    if (_spaceTap) {
        CFMachPortInvalidate(_spaceTap);
        CFRelease(_spaceTap);
        _spaceTap = NULL;
    }
}

#pragma mark - ⌘空格 暂停/继续

// ⌘空格 是系统 Spotlight 快捷键，在窗口服务层就被消费，NSWindow 级别的
// performKeyEquivalent 永远收不到——必须用 CGEventTap 在会话层截获。
// 策略：仅当本 APP 是前台应用时接管（吞掉事件并切换暂停），否则原样放行，
// Spotlight 不受影响。事件口需要“辅助功能”权限：未授权时创建返回 NULL，
// 只引导一次，绝不反复弹窗打断使用。
static CGEventRef RDSpaceTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    ResourceDetectorAppDelegate *delegate = (__bridge ResourceDetectorAppDelegate *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(delegate.spaceTap, YES); // 系统超时禁用后自动恢复
        NSLog(@"[hotkey] 事件口被系统禁用，已重新启用");
        return event;
    }
    if (type != kCGEventKeyDown) return event;
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return event; // 长按空格不连发
    CGEventFlags flags = CGEventGetFlags(event);
    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    BOOL cmd = (flags & kCGEventFlagMaskCommand) != 0;
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (cmd && keycode == 49 /* Space */) {
        if (!front || front.processIdentifier != [[NSProcessInfo processInfo] processIdentifier]) {
            NSLog(@"[hotkey] 非前台，放行给系统");
            return event;
        }
        NSLog(@"[hotkey] 前台接管，切换暂停/继续");
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate toggleDownloadPauseResume:nil]; });
        return NULL; // 已消费
    }
    return event;
}

- (void)installSpaceHotkeyTap {
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault,
                                         CGEventMaskBit(kCGEventKeyDown),
                                         RDSpaceTapCallback, (__bridge void *)self);
    if (!tap) {
        NSLog(@"[hotkey] ⌘空格 事件口创建失败：需要在 系统设置→隐私与安全性→辅助功能 中允许「资源探测」");
        // 只在用户明确想要 ⌘空格 时才引导（应用内 ⌘P 无需任何权限）。
        // 弹过一次或用户点过“以后再说”就永久记住，绝不在每次启动时打扰。
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (![defaults boolForKey:@"ZZHotkeyGuideAnswered"]) {
            [defaults setBool:YES forKey:@"ZZHotkeyGuideAnswered"];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"⌘空格 暂停下载需要一次系统授权";
            alert.informativeText = @"APP 内直接按 ⌘P 即可暂停/继续下载，无需任何权限。"
                                     "若你更想用 ⌘空格（系统级），请在「系统设置 → 隐私与安全性 → 辅助功能」"
                                     "中打开「资源探测」并重启 APP；不想授权就忽略本提示，下次不再出现。";
            [alert addButtonWithTitle:@"打开设置"];
            [alert addButtonWithTitle:@"用 ⌘P 就好"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
            }
        }
        return;
    }
    _spaceTap = tap;
    _spaceTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (self.spaceTapSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), self.spaceTapSource, kCFRunLoopCommonModes);
    }
    CGEventTapEnable(tap, YES);
}

// ⌘空格：有运行中的任务则全部暂停，否则继续暂停或中断的任务。
// 列表与进度条保持展示暂停进度（“加载中”挂起状态），再按一次即恢复。
- (void)toggleDownloadPauseResume:(id)sender {
    NSArray<DownloadJob *> *active = self.downloadManager.allJobs ?: @[];
    BOOL anyPaused = NO;
    BOOL anyRunning = NO;
    for (DownloadJob *job in active) {
        if (job.state == DownloadJobStatePaused || job.state == DownloadJobStateInterrupted) anyPaused = YES;
        if (job.state == DownloadJobStateRunning) anyRunning = YES;
    }
    BOOL shouldResume = anyPaused && !anyRunning;
    NSInteger changed = 0;
    for (DownloadJob *job in active) {
        if (shouldResume && (job.state == DownloadJobStatePaused || job.state == DownloadJobStateInterrupted)) {
            DownloadJobState before = job.state;
            [self.downloadManager resumeJob:job.identifier];
            if (job.state != before) changed++;
        } else if (!shouldResume && job.state == DownloadJobStateRunning) {
            [self.downloadManager pauseJob:job.identifier];
            changed++;
        }
    }
    if (changed == 0 && shouldResume) {
        // resumeJob 在无空闲连接槽位时会保持 Paused（绝不突破并发上限）：
        // 此时列表里明明有暂停任务，旧文案“没有可暂停/继续的下载”与事实矛盾。
        self.statusNote.stringValue = @"连接数已满，稍后再次按 ⌘P 继续下载";
    } else if (changed == 0) {
        self.statusNote.stringValue = @"当前没有可暂停/继续的下载";
    } else if (shouldResume) {
        self.statusNote.stringValue = [NSString stringWithFormat:@"已继续 %ld 个下载（⌘P 或 ⌘空格 暂停）", (long)changed];
    } else {
        self.statusNote.stringValue = [NSString stringWithFormat:@"已暂停 %ld 个下载（⌘P 或 ⌘空格 继续）", (long)changed];
    }
    [self updateDownloadPauseButton];
}

#pragma mark - 启动与布局

// 标准主菜单：App 菜单 + 编辑菜单。没有编辑菜单时，文本框的 ⌘C/⌘V/⌘X 没有执行者而失效
- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 资源探测" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"隐藏 资源探测" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 资源探测" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    NSApp.mainMenu = mainMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {

    RDLogWrite(@"app", @"applicationDidFinishLaunching");
    // BUG-010 option A: this UI is a deliberate warm-paper light design. Pin it
    // before windows are built so dynamic label colors stay dark in Dark Mode.
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [self buildMainMenu];  // 关键：提供 ⌘C/⌘V/⌘X/⌘Z/⌘A 的执行者（AppKit 中这些快捷键由菜单项分发）
    self.results = [NSMutableArray array];
    self.mode = ZZResourceDiscoveryModeCurrentPage;
    self.sitePages = 3;
    // 内容过滤开关（可叠加，持久化在独立 App 自己的 defaults 中）
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    self.filterVideoOnly = [def boolForKey:@"ZZFilterVideoOnly"];
    self.filterImagesOnly = [def boolForKey:@"ZZFilterImagesOnly"];
    NSInteger ratioIndex = [PreferencesStore.shared integerForKey:SevenZZKeyMainPaneRatio defaultValue:0];
    if (ratioIndex < 0 || ratioIndex > 2) ratioIndex = 0;
    [def setInteger:ratioIndex forKey:SevenZZKeyMainPaneRatio];
    self.session = [[DiscoverySessionController alloc] initWithDefaultDependencies];
    self.downloadManager = [DownloadManager sharedManager];
    self.downloadManager.delegate = self;
    self.refreshProbe = [[RDHybridPageProbe alloc] initWithPolicy:[URLPolicy new]];
    __weak typeof(self) refreshOwner = self;
    self.linkRefresher = [[DownloadLinkRefresher alloc] initWithManager:self.downloadManager reprobeHandler:^(NSURL *url, DownloadLinkReprobeCompletion completion) {
        [refreshOwner.refreshProbe probePageURL:url completion:completion];
    }];
    self.downloadManager.linkRefreshHandler = ^(DownloadJob *job, NSString *reason) { [refreshOwner.linkRefresher handleJobDidFail:job reason:reason linkExpired:YES]; };
    self.linkRefresher.statusHandler = ^(DownloadJob *job, NSString *status) { if (status.length) refreshOwner.statusNote.stringValue = status; [refreshOwner refreshDownloadsList]; };
    self.downloadSettings = [[ResourceDownloadSettings alloc]
        initWithPreferencesStore:[PreferencesStore shared]
        downloadsURL:[NSURL fileURLWithPath:NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject]
        desktopURL:[NSURL fileURLWithPath:NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES).firstObject]];

    NSRect frame = NSMakeRect(0, 0, 980, 700);
    self.window = [[RDSlashWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"资源探测";
    // 暖纸背景 #FAF8F4：纸感浅色，眩光低于纯白，纯黑斜杠如墨水落于纸上
    NSColor *paperColor = [NSColor colorWithSRGBRed:0.980 green:0.973 blue:0.957 alpha:1.0];
    self.window.backgroundColor = paperColor;
    self.window.titlebarAppearsTransparent = YES;
    self.window.minSize = NSMakeSize(760, 460);
    self.window.delegate = self;
    NSView *root = [[NSView alloc] initWithFrame:frame];
    self.window.contentView = root;

    // 同一窗口内的三个页面容器：探测页(默认) + 设置页 + 下载列表页
    self.homePage = [[NSView alloc] initWithFrame:frame];
    self.homePage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:self.homePage];
    self.settingsPage = [[NSView alloc] initWithFrame:frame];
    self.settingsPage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.settingsPage.hidden = YES;
    [root addSubview:self.settingsPage];
    self.downloadsPage = [[NSView alloc] initWithFrame:frame];
    self.downloadsPage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.downloadsPage.hidden = YES;
    [root addSubview:self.downloadsPage];
    self.downloadFilter = RDDownloadFilterAll;
    [self buildDownloadsPage];

    // ── 斜杠行（顶部固定） ──
    self.slashLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 637, 16, 30)];
    self.slashLabel.bezeled = NO; self.slashLabel.drawsBackground = NO; self.slashLabel.editable = NO;
    self.slashLabel.font = [NSFont monospacedSystemFontOfSize:20.5 weight:NSFontWeightLight];
    self.slashLabel.textColor = [NSColor blackColor];
    self.slashLabel.stringValue = @"/";
    self.slashLabel.wantsLayer = YES;
    // 固定向左轻转：更斜向竖直但远不到「|」，底部左移 2px 补偿绕中心的偏移
    self.slashLabel.frameCenterRotation = 10.0;
    self.slashLabel.autoresizingMask = NSViewMinYMargin;
    [self.homePage addSubview:self.slashLabel];

    // 字号 11；框高按基线公式算出 22.82，保证底-基线=7.25px 与 20.5 号斜杠对齐
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(44, 637, 658, 22.82)];
    self.urlField.bezeled = NO; self.urlField.drawsBackground = NO;
    self.urlField.focusRingType = NSFocusRingTypeNone;
    self.urlField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.urlField.textColor = [NSColor labelColor];
    self.urlField.placeholderString = @"粘贴视频网页链接，回车开始";
    self.urlField.delegate = self;
    self.urlField.target = self;
    self.urlField.action = @selector(scan:);
    self.urlField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.homePage addSubview:self.urlField];

    // 模式切换「总/单」：当前模式的字更亮，点击切换
    self.modeButton = [self tinyButtonWithTitle:@"总/单" fontSize:12 color:[NSColor systemGrayColor] action:@selector(toggleMode:)];
    self.modeButton.frame = NSMakeRect(918, 642, 42, 24);
    self.modeButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.homePage addSubview:self.modeButton];
    [self updateModeButtonTitle];

    // 「设置」入口（在总/单上方）：点击在同窗口内切换到设置页
    self.settingsButton = [self tinyButtonWithTitle:@"设置" fontSize:11.5 color:[NSColor systemGrayColor] action:@selector(showSettingsPage:)];
    self.settingsButton.frame = NSMakeRect(928, 674, 32, 24);
    self.settingsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.homePage addSubview:self.settingsButton];

    // 总站页数（仅总站模式显示，自行填写）
    // y=637：离屏实测可编辑框字形比同框按钮高 5px，按钮在 642，框差 5px 正好抵消
    self.pagesField = [[NSTextField alloc] initWithFrame:NSMakeRect(856, 637, 40, 24)];
    self.pagesField.bezeled = NO; self.pagesField.drawsBackground = NO;
    self.pagesField.focusRingType = NSFocusRingTypeNone;
    self.pagesField.font = [NSFont systemFontOfSize:12];
    self.pagesField.textColor = [NSColor systemGrayColor];
    self.pagesField.alignment = NSTextAlignmentRight;
    self.pagesField.placeholderString = @"页数";
    self.pagesField.delegate = self;
    self.pagesField.target = self;
    self.pagesField.action = @selector(commitPages:);
    self.pagesField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.pagesField.hidden = YES;
    self.pagesField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)self.sitePages];
    [self.homePage addSubview:self.pagesField];

    // 「页」单位：与「总/单」同为 NSButton，保证两条文字绘制路径一致、高度天然对齐
    self.pagesUnitButton = [NSButton buttonWithTitle:@"页" target:nil action:nil];
    self.pagesUnitButton.bordered = NO;
    self.pagesUnitButton.font = [NSFont systemFontOfSize:12];
    self.pagesUnitButton.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"页" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12],
                                          NSForegroundColorAttributeName: [NSColor systemGrayColor]}];
    self.pagesUnitButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.pagesUnitButton.hidden = YES;
    [self.pagesUnitButton sizeToFit];
    NSRect unitFrame = self.pagesUnitButton.frame;
    unitFrame.origin.x = 898;
    unitFrame.origin.y = 642;
    unitFrame.size.height = 24;
    self.pagesUnitButton.frame = unitFrame;
    [self.homePage addSubview:self.pagesUnitButton];

    // 探测进度：使用独立的细横向条和百分比文字。进度条只表达探测阶段，
    // 不再显示圆环控件。
    // 探测阶段只显示 statusNote 文字，不创建百分比进度控件。

    // 完成 ✓（短暂显示）
    self.checkLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(926, 636, 32, 26)];
    self.checkLabel.bezeled = NO; self.checkLabel.drawsBackground = NO; self.checkLabel.editable = NO;
    self.checkLabel.alignment = NSTextAlignmentCenter;
    self.checkLabel.font = [NSFont systemFontOfSize:15];
    self.checkLabel.textColor = [NSColor colorWithRed:0.42 green:0.78 blue:0.55 alpha:1.0];
    self.checkLabel.stringValue = @"✓";
    self.checkLabel.hidden = YES;
    self.checkLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.homePage addSubview:self.checkLabel];

    // 状态小字（斜杠行下方）
    self.statusNote = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 606, 700, 18)];
    self.statusNote.bezeled = NO; self.statusNote.drawsBackground = NO; self.statusNote.editable = NO;
    self.statusNote.font = [NSFont systemFontOfSize:12];
    self.statusNote.textColor = [NSColor secondaryLabelColor];
    self.statusNote.stringValue = @"";
    self.statusNote.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.homePage addSubview:self.statusNote];

    // ── 分栏布局：左结果列表 / 右详情面板（Finder 式） ──
    self.durationCache = [NSMutableDictionary dictionary];
    self.selectedTierRowDisplay = [NSMutableDictionary dictionary];
    self.metadataService = [RDMetadataService new];
    self.detailGeneration = 0;

    // ── 分栏：左列表 / 右详情，手动布局保证 3:7 恒定 ──
    self.leftPane = [[NSView alloc] initWithFrame:NSMakeRect(24, 44, 280, 548)];
    [self.homePage addSubview:self.leftPane];

    // 竖直分割线（在横线之下，顶端与横线相交）
    self.vDivider = [[NSView alloc] initWithFrame:NSMakeRect(304, 44, 1, 548)];
    self.vDivider.wantsLayer = YES;
    self.vDivider.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.10].CGColor;
    [self.homePage addSubview:self.vDivider];

    // 分栏顶部的贯穿横线：从左到右贴住窗口两侧边缘
    self.topDivider = [[NSView alloc] initWithFrame:NSMakeRect(0, 592, 980, 1)];
    self.topDivider.wantsLayer = YES;
    self.topDivider.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.10].CGColor;
    [self.homePage addSubview:self.topDivider];

    self.table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 280, 548)];
    self.table.rowHeight = 46;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"resource"];
    col.width = 260;
    col.minWidth = 60;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:col];
    self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.table.headerView = nil;
    self.table.backgroundColor = paperColor;  // 表格区与暖纸背景融合，不留白块
    self.table.dataSource = (id)self;
    self.table.delegate = (id)self;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 280, 548)];
    scroll.documentView = self.table;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;  // 左侧是固定列表：禁水平滚动
    scroll.drawsBackground = YES;
    scroll.backgroundColor = paperColor;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.leftPane addSubview:scroll];

    self.detailPane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 651, 548)];
    self.detailPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.homePage addSubview:self.detailPane];
    [self buildDetailPane];
    [self buildSettingsPage];  // 设置页（同窗口切换）
    [self layoutWorkspace];  // 按 3:7 精确排布左/竖线/右面板
    [self showDetailEmpty];

    // ── 右下角快捷方式小字 ──
    [self buildFooterButtons];

    // ── 探测会话回调 ──（含“新探测作废旧回调”的代次保护，见 installSessionHandlersForGeneration:）
    [self installSessionHandlersForGeneration:self.scanGeneration];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.urlField];

    [self installSpaceHotkeyTap]; // ⌘空格 暂停/继续（前台接管，需辅助功能授权）
}

#pragma mark - 右侧详情面板

- (NSTextField *)detailStaticLabelAtY:(CGFloat)y text:(NSString *)t {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(16, y, 66, 16)];
    l.bezeled = NO; l.drawsBackground = NO; l.editable = NO;
    l.font = [NSFont systemFontOfSize:11.5];
    l.textColor = [NSColor systemGrayColor];
    l.stringValue = t;
    l.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.detailPane addSubview:l];
    return l;
}

- (NSTextField *)detailValueLabelAtY:(CGFloat)y {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(90, y, 545, 16)];
    l.bezeled = NO; l.drawsBackground = NO; l.editable = NO;
    l.font = [NSFont systemFontOfSize:11.5];
    l.textColor = [NSColor labelColor];
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.maximumNumberOfLines = 1;
    l.usesSingleLineMode = YES;
    l.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.detailPane addSubview:l];
    return l;
}

- (NSString *)displayStatusForDiscoveryStatus:(NSString *)status {
    NSString *s = status.lowercaseString ?: @"";
    if ([s containsString:@"探测"] || [s containsString:@"页面"] || [s containsString:@"site"] || [s containsString:@"page"]) return @"正在探测网址…";
    if ([s containsString:@"读取"] || [s containsString:@"load"] || [s containsString:@"request"]) return @"正在读取网址…";
    return @"正在探测…";
}

// 单缩略图框：16:9、水平居中（两翼 flex margin）
- (NSImageView *)detailImageViewAtX:(CGFloat)x y:(CGFloat)y width:(CGFloat)w height:(CGFloat)h {
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    iv.wantsLayer = YES;
    iv.layer.cornerRadius = 8;
    iv.layer.masksToBounds = YES;
    iv.layer.backgroundColor = [[NSColor colorWithSRGBRed:0.912 green:0.900 blue:0.870 alpha:1.0] CGColor];  // 占位底 #E9E5DE
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    iv.imageAlignment = NSImageAlignCenter;
    iv.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;  // 水平居中、贴顶
    [self.detailPane addSubview:iv];
    return iv;
}

// 详情面板宽度（初始 651；未布局时用默认值）
- (CGFloat)detailPaneWidth {
    CGFloat w = NSWidth(self.detailPane.bounds);
    return w > 0 ? w : 651;
}

- (void)buildDetailPane {
    // 空状态提示：位置动态化，始终以右面板实际边界为基准居中
    self.emptyHint = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 264, NSWidth(self.detailPane.bounds), 20)];
    self.emptyHint.bezeled = NO; self.emptyHint.drawsBackground = NO; self.emptyHint.editable = NO;
    self.emptyHint.alignment = NSTextAlignmentCenter;
    self.emptyHint.font = [NSFont systemFontOfSize:12];
    self.emptyHint.textColor = [NSColor systemGrayColor];
    self.emptyHint.stringValue = @"点击左侧资源查看详情";
    self.emptyHint.autoresizingMask = NSViewWidthSizable;
    [self.detailPane addSubview:self.emptyHint];

    // 单缩略图：16:9、水平居中（图片不拉伸，按真实比例填充），尺寸适中
    CGFloat paneW = [self detailPaneWidth];
    CGFloat thumbW = 340, thumbH = thumbW * 9.0 / 16.0;   // 340×191 ≈ 16:9
    CGFloat thumbX = (paneW - thumbW) / 2.0;
    self.thumbView = [self detailImageViewAtX:thumbX y:326 width:thumbW height:thumbH];

    // 缩略图状态字（覆盖在缩略图框内）：加载中/读取超时/读取失败都必须肉眼可辨，
    // 不能留下无法区分“加载中”与“已失败”的纯空白框。
    self.thumbStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 8, thumbW - 16, thumbH - 16)];
    self.thumbStatusLabel.bezeled = NO; self.thumbStatusLabel.drawsBackground = NO;
    self.thumbStatusLabel.editable = NO; self.thumbStatusLabel.selectable = NO;
    self.thumbStatusLabel.alignment = NSTextAlignmentCenter;
    self.thumbStatusLabel.font = [NSFont systemFontOfSize:11.5];
    self.thumbStatusLabel.textColor = [NSColor systemGrayColor];
    self.thumbStatusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.thumbStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.thumbStatusLabel.hidden = YES;
    [self.thumbView addSubview:self.thumbStatusLabel];

    // 标题：允许多行自然换行，绝不省略；实际高度由 layoutDetailContent 计算
    self.detailTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 276, 619, 36)];
    self.detailTitle.bezeled = NO; self.detailTitle.drawsBackground = NO; self.detailTitle.editable = NO;
    self.detailTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.detailTitle.textColor = [NSColor labelColor];
    self.detailTitle.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailTitle.maximumNumberOfLines = 3;
    self.detailTitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.detailPane addSubview:self.detailTitle];

    // 时长、格式、大小与来源等键值行（分辨率行保留给画质档位下拉）
    self.durationTitle = [self detailStaticLabelAtY:230 text:@"时长"]; self.durationValue = [self detailValueLabelAtY:230];
    self.formatTitle   = [self detailStaticLabelAtY:208 text:@"格式"]; self.formatValue   = [self detailValueLabelAtY:208];
    self.sizeTitle     = [self detailStaticLabelAtY:186 text:@"大小"]; self.sizeValue     = [self detailValueLabelAtY:186];
    self.dimensionTitle = [self detailStaticLabelAtY:164 text:@"分辨率"];
    self.dimensionValue = [self detailValueLabelAtY:164];
    self.dimensionTitle.hidden = YES;
    self.dimensionValue.hidden = YES;
    self.sourceTitle   = [self detailStaticLabelAtY:142 text:@"来源"]; self.sourceValue   = [self detailValueLabelAtY:142];

    self.variantPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(90,164,90,20) pullsDown:NO];
    self.variantPicker.bordered = NO;
    self.variantPicker.font = [NSFont systemFontOfSize:11];
    self.variantPicker.target = self; self.variantPicker.action = @selector(selectDeclaredVariant:);
    self.variantPicker.toolTip = @"源站声明的版本";
    self.variantPicker.autoresizingMask = NSViewMinYMargin;
    [self.detailPane addSubview:self.variantPicker];

    // (e) 下载直链（置于「来源」之后）
    NSTextField *linkTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 118, 619, 14)];
    linkTitle.bezeled = NO; linkTitle.drawsBackground = NO; linkTitle.editable = NO;
    linkTitle.font = [NSFont systemFontOfSize:11.5];
    linkTitle.textColor = [NSColor systemGrayColor];
    linkTitle.stringValue = @"下载直链";
    linkTitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.detailPane addSubview:linkTitle];
    self.linkTitleLabel = linkTitle;

    // 直链仍按 URL 专用规则显示：允许中间省略，不换行堆高布局
    self.linkField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 76, 538, 24)];
    self.linkField.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.linkField.textColor = [NSColor labelColor];
    self.linkField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.linkField.maximumNumberOfLines = 1;
    self.linkField.usesSingleLineMode = YES;
    self.linkField.editable = NO;
    self.linkField.selectable = YES;
    self.linkField.bezeled = NO;
    self.linkField.drawsBackground = NO;  // 与米白背景融为一体的纯文字
    self.linkField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.detailPane addSubview:self.linkField];

    // 直链后面的小复制按钮（图标）
    self.linkCopyButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:@"复制直链"] target:self action:@selector(copyLink:)];
    self.linkCopyButton.bordered = NO;
    self.linkCopyButton.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10.5 weight:NSFontWeightRegular];
    self.linkCopyButton.frame = NSMakeRect(566, 86, 18, 18);
    self.linkCopyButton.toolTip = @"复制直链";
    self.linkCopyButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.detailPane addSubview:self.linkCopyButton];

    self.detailDownloadButton = [NSButton buttonWithTitle:@"下载" target:self action:@selector(downloadSelected:)];
    self.detailDownloadButton.controlSize = NSControlSizeSmall;
    self.detailDownloadButton.font = [NSFont systemFontOfSize:11];
    self.detailDownloadButton.frame = NSMakeRect(0, 36, 76, 24);
    self.detailDownloadButton.autoresizingMask = NSViewMinYMargin;  // x 由 layoutWorkspace 统一居中
    [self.detailPane addSubview:self.detailDownloadButton];

    self.detailContent = @[self.thumbView, self.detailTitle, self.durationTitle, self.durationValue,
                           self.formatTitle, self.formatValue, self.sizeTitle,
                           self.sizeValue, self.dimensionTitle, self.dimensionValue, self.sourceTitle, self.sourceValue,
                           self.variantPicker, self.linkTitleLabel, self.linkField, self.linkCopyButton,
                           self.detailDownloadButton];
    // 其余 caption 也要收进 detailContent —— 补齐
    for (NSView *sub in self.detailPane.subviews) {
        if (sub.tag == 0 && sub != self.emptyHint && ![self.detailContent containsObject:sub]) {
            self.detailContent = [self.detailContent arrayByAddingObject:sub];
        }
    }
}

- (void)showDetailEmpty {
    for (NSView *v in self.detailContent) v.hidden = YES;
    self.emptyHint.hidden = NO;
    self.variantPicker.hidden = YES;
    self.detailMedia = nil;
    self.currentDownloadMedia = nil;
    [self layoutDetailCenteredHint];
    self.detailGeneration++;
    [self.metadataToken cancel];
    self.metadataSnapshot = nil;
}

static NSString *RDFormatDurationSeconds(double seconds) {
    if (!isfinite(seconds) || seconds < 0 || seconds > INT_MAX - 0.5) return @"—";
    int total = (int)round(seconds);

    int h = total / 3600, m = (total % 3600) / 60, s = total % 60;
    return h > 0 ? [NSString stringWithFormat:@"%d:%02d:%02d", h, m, s]
                 : [NSString stringWithFormat:@"%02d:%02d", m, s];
}

// 画质下拉项标题。生产链路的档位字典由 RDQualityTier 生成、必带 label；这里再
// 兜一层：缺 label 时按 level / 像素高度推导，绝不把 nil 交给 NSMenuItem
//（`initWithTitle:nil` 会抛 NSInvalidArgumentException 直接崩溃），也绝不因为
// 缺标题就把这个档位从下拉里丢掉（那会让用户白白少一个可下载的档位）。
static NSString *RDVariantPickerLabel(NSDictionary *v) {
    if (![v isKindOfClass:NSDictionary.class]) return @"未知档位";
    NSString *label = [v[@"label"] isKindOfClass:NSString.class] ? v[@"label"] : nil;
    if (label.length) return label;
    NSNumber *level = [v[@"level"] isKindOfClass:NSNumber.class] ? v[@"level"] : nil;
    if (level.integerValue > 0) return [NSString stringWithFormat:@"%ldp", (long)level.integerValue];
    NSNumber *height = [v[@"pixelHeight"] isKindOfClass:NSNumber.class] ? v[@"pixelHeight"] : nil;
    if (height.integerValue > 0) return [NSString stringWithFormat:@"%ldp", (long)height.integerValue];
    NSString *url = [v[@"url"] isKindOfClass:NSString.class] ? v[@"url"] : nil;
    NSString *last = [NSURL URLWithString:url ?: @""].lastPathComponent;
    return last.length ? last : @"未知档位";
}

- (void)configureDetailForMedia:(DetectedMedia *)m {
    for (NSView *v in self.detailContent) v.hidden = NO;
    self.emptyHint.hidden = YES;
    self.detailMedia = m;
    self.currentDownloadMedia = m;
    self.detailGeneration++;

    self.detailTitle.stringValue = m.title.length ? m.title : (m.mediaURL ?: @"未命名资源");
    [self layoutDetailContent];   // 标题长度变化后立即重排，避免与下方字段重叠
    NSString *dur = self.durationCache[m.mediaURL];
    self.durationValue.stringValue = (dur.length == 0 && dur != nil) ? @"获取中…" : (dur ?: @"获取中…");
    self.formatValue.stringValue = m.format.length ? m.format.uppercaseString : @"—";
    self.sizeValue.stringValue = !m.isManifest && m.resourceKind != RDResourceKindManifest && m.sizeBytes > 0
        ? RDFormatByteCount(m.sizeBytes)
        : @"—";
    self.dimensionValue.stringValue = (m.pixelWidth > 0 && m.pixelHeight > 0)
        ? [NSString stringWithFormat:@"%ld × %ld", (long)m.pixelWidth, (long)m.pixelHeight] : @"—";
    NSURL *src = [NSURL URLWithString:(m.sourcePageURL.length ? m.sourcePageURL : m.mediaURL)];
    self.sourceValue.stringValue = src.host.length ? src.host : @"—";

    [self.variantPicker removeAllItems];
    // NSPopUpButton 添加条目后会隐式选中第一项，selectedItem 永远非 nil；
    // “是否选中了当前媒体自己的档位”必须用规范化 URL 显式记录。
    BOOL matchedCurrent = NO;
    for (NSDictionary *v in m.declaredVariants) {
        [self.variantPicker addItemWithTitle:RDVariantPickerLabel(v)];
        self.variantPicker.lastItem.representedObject = v;
        if ([[DetectedMedia dedupKeyForURL:v[@"url"]] isEqual:[DetectedMedia dedupKeyForURL:m.mediaURL]]) {
            [self.variantPicker selectItem:self.variantPicker.lastItem];
            matchedCurrent = YES;
        }
    }
    if (m.declaredVariants.count && !matchedCurrent) {
        // 当前详情对象不属于任何具体档位（典型：HLS master）。界面此时显示
        // 的是第一项档位，必须通过真实选择逻辑把详情、链接与下载对象同步到
        // 该档位；不允许“显示 480p、入队 master”。
        [self.variantPicker selectItemAtIndex:0];
        if (self.variantPicker.selectedItem) {
            [self selectDeclaredVariant:nil];
            return;
        }
    }
    self.variantPicker.hidden = m.declaredVariants.count < 2;
    // 画质下拉的显隐直接决定它是否占用「来源」下方那一行，必须立刻重排，
    // 否则它会停在上一份媒体算出来的坐标上（下拉会压住「来源」行的值）。
    [self layoutDetailContent];
    // 画质区只显示源站声明的 480p/720p 等档位。实际像素尺寸继续写入
    // DetectedMedia 和元数据快照供内部逻辑使用，但不在界面呈现。
    self.dimensionTitle.hidden = YES;
    self.dimensionValue.hidden = YES;
    self.linkField.stringValue = m.mediaURL ?: @"";

    [self subscribeMetadataForMedia:m reload:NO];
    // 列表行摘要必须与详情显示的对象一致（档位切换后行摘要跟随新档位）。
    [self syncSelectedRowTierDisplay];
}

// 与 WebProbe formatFromURL 同一套扩展名约定；返回 nil 表示无法从 URL 判断。
static NSString *RDFormatForMediaURL(NSString *urlString) {
    NSString *ext = [NSURL URLWithString:urlString ?: @""].pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4v"]) return @"mp4";
    if ([ext isEqualToString:@"webm"]) return @"webm";
    if ([ext isEqualToString:@"m3u8"]) return @"hls";
    if ([ext isEqualToString:@"mpd"]) return @"dash";
    return nil;
}

- (void)selectDeclaredVariant:(id)sender {
    NSDictionary *v = self.variantPicker.selectedItem.representedObject;
    DetectedMedia *current = self.detailMedia;
    if (!current || !v || [[DetectedMedia dedupKeyForURL:v[@"url"]] isEqual:[DetectedMedia dedupKeyForURL:current.mediaURL]]) return;
    // 画质切换后的缩略图策略：只有“同一个海报 URL、且当前图就是从该海报来的”
    // 才允许保留旧图（同一张图，保留避免闪烁）。海报失败后回退的视频首帧
    // 随资源 URL 变化，属于依赖画质的信息，绝不能带到新档位继续显示。
    RDMetadataSnapshot *snapshotBeforeSwitch = self.metadataSnapshot;
    BOOL previewComesFromPoster = snapshotBeforeSwitch != nil
        && [snapshotBeforeSwitch.preview.source containsString:@"poster"];
    NSImage *cover = (current.poster.length && previewComesFromPoster) ? self.thumbView.image : nil;
    NSString *targetKey = [DetectedMedia dedupKeyForURL:v[@"url"]];
    DetectedMedia *next = nil;
    for (DetectedMedia *candidate in self.results)
        if ([[DetectedMedia dedupKeyForURL:candidate.mediaURL] isEqual:targetKey]) { next = candidate; break; }
    if (!next) {
        next=[DetectedMedia new]; next.mediaURL=v[@"url"]; next.sourcePageURL=current.sourcePageURL;
        next.title=current.title; next.poster=current.poster;
        // 合成候选保留真实资源类型：MP4 直链仍是视频文件、DASH Representation
        // 仍是 DASH，只有 HLS 变体才是清单。扩展名无法判断时继承来源媒体的
        // 类型（签名 URL、无扩展名子清单）。一律伪装成 hls manifest 会让
        // 普通文件走错误的流媒体分片路径。
        NSString *format = RDFormatForMediaURL(v[@"url"]);
        if (format) {
            next.format = format;
            BOOL manifest = [format isEqualToString:@"hls"] || [format isEqualToString:@"dash"];
            next.resourceKind = manifest ? RDResourceKindManifest : RDResourceKindVideo;
            next.isManifest = manifest;
        } else {
            next.resourceKind = current.resourceKind;
            next.isManifest = current.isManifest;
            next.format = current.format;
        }
        // 保留播放/下载所需上下文：来源主清单关联（HLS 分离音轨依赖它）、
        // 同一视频分组身份，避免下载与分组状态因候选切换而丢失。
        next.parentMediaURL = (current.isManifest && !current.parentMediaURL.length) ? current.mediaURL : current.parentMediaURL;
        next.videoFamilyID = current.videoFamilyID;
        next.declaredVariants=current.declaredVariants;
        self.selectedVariantMedia=next;
    }
    [self configureDetailForMedia:next];
    if (cover && [current.poster isEqual:next.poster]) self.thumbView.image = cover;
}

- (void)copyLink:(id)sender {
    if (!self.linkField.stringValue.length) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:self.linkField.stringValue forType:NSPasteboardTypeString];
    self.statusNote.stringValue = @"直链已复制到剪贴板";
}

// Automatic service retry policy handles transient failures; the App has no manual metadata reload.
- (void)subscribeMetadataForMedia:(DetectedMedia *)m reload:(BOOL)reload {
    [self.metadataToken cancel];
    self.metadataSnapshot = nil;
    if (!self.metadataService) self.metadataService = [RDMetadataService new];
    // 准备阶段中用户又选了别的行：把该行也纳入必需项，完成时机跟随当前选择。
    [self requirePresentationForMediaWhilePreparing:m];
    // 先同步恢复缓存：缩略图与已成功字段立即显示，再只请求缺失/过期字段。
    // 绝不能先清空已显示图像再等网络（切换离开再切回时不得闪空）。
    RDMetadataSnapshot *cached = [self.metadataService cachedSnapshotForMedia:m];
    BOOL restoredPreview = NO;
    if (cached) {
        [self applySnapshotForDisplay:cached media:m];
        restoredPreview = cached.preview.state == RDMetadataKnown && cached.preview.value != nil;
    }
    if (!restoredPreview) {
        // 同海报且当前图确实来自该海报：保留（同一张图，不闪烁）。
        // 海报失败后回退的视频首帧随资源 URL 变化，必须清空。
        BOOL samePosterImage = self.thumbShowsPosterImage && m.poster.length
            && [self.previewPosterURL isEqual:m.poster];
        if (!samePosterImage) {
            self.thumbView.image = nil;
            self.thumbShowsPosterImage = NO;
        }
    }
    self.previewPosterURL = m.poster;
    if (self.thumbView.image == nil) {
        self.thumbStatusLabel.stringValue = @"读取中…";
        self.thumbStatusLabel.hidden = NO;
    }
    NSInteger generation = self.detailGeneration;
    __weak typeof(self) weakSelf = self;
    self.metadataToken = [self.metadataService subscribeMedia:m reload:reload update:^(RDMetadataSnapshot *snapshot) {
        typeof(self) self = weakSelf;
        if (!self || self.detailGeneration != generation || self.detailMedia != m) return;
        self.metadataSnapshot = snapshot;
        if (snapshot.variants.count) {
            // 记住重建前的用户选择档位标签：同档 URL 被择优替换时优先保持同档。
            NSString *previousVariantLabel = self.variantPicker.selectedItem.title;
            // 行集合快照：合并前后可见行集合不变时只刷新行视图，变化时才整体 reload。
            NSArray<DetectedMedia *> *rowsBeforeMerge = [self.visibleMedia copy];
            // 静态声明与清单 Representation 真正合并：清单到达时若媒体已带静态
            // 档位（如 <source size>），两路候选过同一套归一化/去重后合成一份；
            // 不再以“静态为空”为前提跳过清单档位。
            // 直接传 snapshot.variants 原始字典，由 RDQualityTier 统一转换——
            // 调用方与被调用方类型一致（NSArray<NSDictionary*>），不做二次转换。
            NSArray *merged=[RDQualityTier normalizedVariantsByMergingDeclared:m.declaredVariants manifest:snapshot.variants];
            if (merged.count>=1 && ![merged isEqualToArray:m.declaredVariants]) {
                m.declaredVariants=merged;
                if (m.videoFamilyID.length) {
                    for (DetectedMedia *member in self.results) {
                        if ([member.videoFamilyID isEqualToString:m.videoFamilyID]) member.declaredVariants = merged;
                    }
                }
                [self.variantPicker removeAllItems];
                BOOL matchedCurrent = NO;
                for (NSDictionary *v in merged) {
                    [self.variantPicker addItemWithTitle:RDVariantPickerLabel(v)];
                    self.variantPicker.lastItem.representedObject=v;
                    if ([[DetectedMedia dedupKeyForURL:v[@"url"]] isEqual:[DetectedMedia dedupKeyForURL:m.mediaURL]]) {
                        [self.variantPicker selectItem:self.variantPicker.lastItem];
                        matchedCurrent = YES;
                    }
                }
                self.variantPicker.hidden = merged.count < 2;
                self.dimensionTitle.hidden = YES;
                self.dimensionValue.hidden = YES;
                NSArray<DetectedMedia *> *rowsAfterMerge = self.visibleMedia;
                BOOL rowSetUnchanged = rowsAfterMerge.count == rowsBeforeMerge.count;
                if (rowSetUnchanged) for (NSUInteger i = 0; i < rowsBeforeMerge.count; i++)
                    if (rowsBeforeMerge[i] != rowsAfterMerge[i]) { rowSetUnchanged = NO; break; }
                if (rowSetUnchanged) [self refreshVisibleRowForMedia:m];
                else [self reloadTablePreservingSelection];
                if (!matchedCurrent && merged.count) {
                    // 当前详情对象（master 或已被替换的旧档位 URL）不在合并结果
                    // 里：优先回退到同档新 URL（同档择优替换），否则确定性回退
                    // 到第一项；并通过真实选择逻辑同步详情与下载对象。绝不允许
                    // “标签还是旧档位、下载对象已经变了”。
                    NSInteger preferred = -1;
                    if (previousVariantLabel.length)
                        for (NSInteger i = 0; i < (NSInteger)self.variantPicker.numberOfItems; i++)
                            if ([[self.variantPicker itemAtIndex:i].title isEqual:previousVariantLabel]) { preferred = i; break; }
                    [self.variantPicker selectItemAtIndex:preferred >= 0 ? preferred : 0];
                    if (self.variantPicker.selectedItem) {
                        [self selectDeclaredVariant:nil];
                        return;
                    }
                }
                NSRect f=self.dimensionValue.frame; f.origin.x=merged.count>1?190:90; f.size.width=MAX(40,NSWidth(self.detailPane.bounds)-(merged.count>1?206:116)); self.dimensionValue.frame=f;
            }
        }
        NSString *duration = snapshot.duration.state == RDMetadataKnown ? RDFormatDurationSeconds([snapshot.duration.value doubleValue])
            : ([snapshot.duration.source isEqual:@"not-applicable"] ? @"不适用" : snapshot.duration.statusText);
        // Presentation hints only; no request suppression or permanent failure cache in App.
        // 只缓存真实结论（已读取 / 不适用）：列表行用这份缓存显示时长，若把
        // "读取中…" 这类过程状态写进去，未读取过的行会一直显示"读取中…"，
        // 看上去像卡住（首屏现在只预热缩略图，不再预读时长）。
        if ((snapshot.duration.state == RDMetadataKnown || [snapshot.duration.source isEqual:@"not-applicable"])) {
            if (self.durationCache.count >= 200) [self.durationCache removeAllObjects];
            self.durationCache[m.mediaURL] = duration;
        }
        if (snapshot.dimensions.state == RDMetadataKnown) {
            NSSize size = [(NSValue *)snapshot.dimensions.value sizeValue]; m.pixelWidth = lround(size.width); m.pixelHeight = lround(size.height);
        }
        m.sizeBytes = snapshot.size.state == RDMetadataKnown ? [snapshot.size.value longLongValue] : 0;
        if (snapshot.preview.state == RDMetadataKnown) {
            self.thumbView.image = snapshot.preview.value;
            self.thumbShowsPosterImage = [snapshot.preview.source containsString:@"poster"];
            self.thumbStatusLabel.hidden = YES;
        } else {
            if (snapshot.preview.state != RDMetadataLoading) {
                self.thumbView.image = nil;
                self.thumbShowsPosterImage = NO;
            }
            self.thumbStatusLabel.stringValue = snapshot.preview.statusText;
            self.thumbStatusLabel.hidden = NO;
        }
        self.thumbView.toolTip = [NSString stringWithFormat:@"%@ · %@",snapshot.preview.statusText,snapshot.preview.source];
        [self refreshVisibleRowForMedia:m];
        [self refreshDetailMetaLabels];
    }];
    // 当前选中项插队：后台预取不挤占用户正在查看的资源（不取消、不抢占
    // 在途 work，只把排队中的该 work 提到队列最前，并发上限保持不变）。
    [self.metadataService prioritizeMedia:m];
}

// 仅用于同步恢复缓存显示：更新缩略图与已知字段/行提示，不触发档位合并与
// 详情对象切换（那两条仍走订阅回调，避免在 configureDetail 内部重入）。
- (void)applySnapshotForDisplay:(RDMetadataSnapshot *)snapshot media:(DetectedMedia *)m {
    if (!snapshot || !m) return;
    self.metadataSnapshot = snapshot;
    if (snapshot.preview.state == RDMetadataKnown && snapshot.preview.value) {
        self.thumbView.image = snapshot.preview.value;
        self.thumbShowsPosterImage = [snapshot.preview.source containsString:@"poster"];
        self.thumbStatusLabel.hidden = YES;
    }
    if (snapshot.duration.state == RDMetadataKnown)
        self.durationCache[m.mediaURL] = RDFormatDurationSeconds([snapshot.duration.value doubleValue]);
    if (snapshot.dimensions.state == RDMetadataKnown) {
        NSSize size = [(NSValue *)snapshot.dimensions.value sizeValue];
        m.pixelWidth = lround(size.width); m.pixelHeight = lround(size.height);
    }
    if (snapshot.size.state == RDMetadataKnown) m.sizeBytes = [snapshot.size.value longLongValue];
    [self refreshVisibleRowForMedia:m];
    [self refreshDetailMetaLabels];
}

- (void)refreshDetailMetaLabels {
    DetectedMedia *m = self.detailMedia;
    RDMetadataSnapshot *s = self.metadataSnapshot;
    if (!m || !s) return;
    self.durationValue.stringValue = self.durationCache[m.mediaURL] ?: s.duration.statusText;
    self.sizeValue.stringValue = s.size.state == RDMetadataKnown
        ? RDFormatByteCount([s.size.value longLongValue]) : ([s.size.source containsString:@"manifest"] ? @"分片视频，未提供总大小" : s.size.statusText);
    self.dimensionValue.stringValue = s.dimensions.state == RDMetadataKnown && m.pixelWidth > 0 && m.pixelHeight > 0
        ? [NSString stringWithFormat:@"%ld × %ld",(long)m.pixelWidth,(long)m.pixelHeight] : (s.dimensions.state == RDMetadataLoading ? @"像素尺寸读取中…" : @"暂未取得像素尺寸");
    self.durationValue.toolTip = s.duration.source;
    self.sizeValue.toolTip = s.size.source;
    self.dimensionValue.toolTip = s.dimensions.source;
    // 档位元数据到达后，把该档位的大小/时长同步到对应的列表行。
    [self syncSelectedRowTierDisplay];
}

// 懒初始化：该字典在多处被读写，不能依赖 applicationDidFinishLaunching 的
// 初始化顺序（无 UI 的托管路径下也必须可用，否则赋值会静默丢弃）。
- (NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)selectedTierRowDisplay {
    if (!_selectedTierRowDisplay) _selectedTierRowDisplay = [NSMutableDictionary dictionary];
    return _selectedTierRowDisplay;
}

// 列表行摘要的时长提示：用户已为该行选定档位时跟随该档位，否则用发现时的时长。
- (NSString *)rowDurationHintForMedia:(DetectedMedia *)media {
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL ?: @""];
    NSString *hint = key.length ? self.selectedTierRowDisplay[key][@"duration"] : nil;
    return hint.length ? hint : self.durationCache[media.mediaURL];
}

// 列表行摘要的大小提示：只在用户为该行选定过档位时返回（否则由行视图按
// DetectedMedia.sizeBytes 自行展示发现时的大小）。
- (NSString *)rowSizeHintForMedia:(DetectedMedia *)media {
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL ?: @""];
    NSString *hint = key.length ? self.selectedTierRowDisplay[key][@"size"] : nil;
    return hint.length ? hint : nil;
}

// 详情当前展示的媒体属于哪一个可见行（档位切换后详情展示的是行内的某个档位，
// 身份与行本身不同，必须按“行声明的档位集合”归属）。
- (DetectedMedia *)visibleRowOwningMedia:(DetectedMedia *)media {
    if (!media.mediaURL.length) return nil;
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL];
    if (!key.length) return nil;
    for (DetectedMedia *row in self.visibleMedia) {
        if (!row.mediaURL.length) continue;
        if ([[DetectedMedia dedupKeyForURL:row.mediaURL] isEqualToString:key]) return row;
        for (NSDictionary *v in row.declaredVariants) {
            NSString *u = v[@"url"];
            if ([u isKindOfClass:NSString.class] && [[DetectedMedia dedupKeyForURL:u] isEqualToString:key]) return row;
        }
    }
    return nil;
}

// 列表行摘要与详情保持一致：详情显示某行的档位时，把该档位的大小/时长同步到那一行；
// 详情回到行本身（未切档位）时撤销覆盖。只有“当前选中行”允许持有覆盖项，
// 因此每次同步先清空，再按当前状态重建，不会留下旧行的过期摘要。
- (void)syncSelectedRowTierDisplay {
    NSArray<DetectedMedia *> *visible = self.visibleMedia;
    NSInteger row = self.table.selectedRow;
    DetectedMedia *rowMedia = (row >= 0 && row < (NSInteger)visible.count) ? visible[(NSUInteger)row] : nil;
    DetectedMedia *shown = self.detailMedia;
    [self.selectedTierRowDisplay removeAllObjects];
    if (rowMedia.mediaURL.length) {
        NSString *rowKey = [DetectedMedia dedupKeyForURL:rowMedia.mediaURL];
        NSString *shownKey = shown.mediaURL.length ? [DetectedMedia dedupKeyForURL:shown.mediaURL] : nil;
        BOOL detailIsTheRowItself = !shownKey.length || [shownKey isEqualToString:rowKey];
        if (!detailIsTheRowItself)
            self.selectedTierRowDisplay[rowKey] = @{ @"duration": self.durationValue.stringValue ?: @"",
                                                     @"size": self.sizeValue.stringValue ?: @"" };
    }
    for (DetectedMedia *m in visible) [self refreshVisibleRowForMedia:m];
}

// 仅配置已有行视图；不 reload/select，避免选择通知重入详情请求。
- (void)refreshVisibleRowForMedia:(DetectedMedia *)media {
    NSArray<DetectedMedia *> *visible = self.visibleMedia;
    for (NSUInteger row = 0; row < visible.count; row++) {
        if (visible[row] != media) continue;
        NSView *view = [self.table viewAtColumn:0 row:(NSInteger)row makeIfNecessary:NO];
        if ([view isKindOfClass:ResourceResultRowView.class])
            [(ResourceResultRowView *)view configureWithMedia:media
                                                 durationHint:[self rowDurationHintForMedia:media]
                                                     sizeHint:[self rowSizeHintForMedia:media]];
    }
}

// 家族候选集合变化可能改变可见行集合。整体 reload 时把选择恢复到同一
// 视频，并在 reload 期间抑制选择回调，避免 reloadData → selectionDidChange
// → configureDetail 的重入循环。
- (void)reloadTablePreservingSelection {
    NSArray<DetectedMedia *> *before = self.visibleMedia;
    NSInteger selectedRow = self.table.selectedRow;
    DetectedMedia *selected = (selectedRow >= 0 && selectedRow < (NSInteger)before.count) ? before[(NSUInteger)selectedRow] : nil;
    self.restoringSelectionAfterReload = YES;
    [self.table reloadData];
    if (selected) {
        NSArray<DetectedMedia *> *after = self.visibleMedia;
        NSUInteger newRow = [after indexOfObjectIdenticalTo:selected];
        if (newRow != NSNotFound && (NSInteger)newRow != selectedRow)
            [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
    }
    self.restoringSelectionAfterReload = NO;
}

// 在可见行里按「资源身份」找同一资源（合并/更新会生成新的 DetectedMedia 实例，
// 对象指针不可靠）；找不到返回 NSNotFound。
// 先按下载身份（保留全部参数）精确匹配，再退回分组身份（忽略 CDN 签名/过期参数）：
// 真实网址上静态取页腿与动态取页腿各拿到一份签名不同的同一地址
//（…secure=A 与 …secure=B），只按完整 URL 匹配会让用户在临时列表里选中的资源在
// 最终列表里“消失”（选中被清空、详情被关掉）。分组身份保留路径，所以不会把
// 480p/720p 这类不同档位误判成同一行。
- (NSUInteger)visibleRowMatchingMedia:(DetectedMedia *)media {
    if (!media) return NSNotFound;
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL];
    NSString *groupKey = [DetectedMedia groupingKeyForURL:media.mediaURL];
    NSArray<DetectedMedia *> *rows = self.visibleMedia;
    NSUInteger groupMatch = NSNotFound;
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (key.length && [[DetectedMedia dedupKeyForURL:rows[i].mediaURL] isEqualToString:key]) return i;
        if (groupMatch == NSNotFound && groupKey.length &&
            [[DetectedMedia groupingKeyForURL:rows[i].mediaURL] isEqualToString:groupKey]) groupMatch = i;
    }
    return groupMatch;
}

// 探测结果整体重建（临时结果与最终结果共用）。关键点：选中项必须按「资源身份」
// 恢复而不是按下标——探测期间列表会先出现临时结果、随后被最终结果替换，两者顺序
// 可能不同（动态腿的成员在合并结果里靠前），按下标保留会让 ⌘D 下载到“错行”
// 资源；详情面板显示同一资源时继续保留，不重复订阅。
- (void)applyDiscoveryResult:(ZZResourceDiscoveryResult *)result final:(BOOL)isFinal {
    NSArray<DetectedMedia *> *before = self.visibleMedia;
    NSInteger selectedRow = self.table.selectedRow;
    DetectedMedia *selected = (selectedRow >= 0 && selectedRow < (NSInteger)before.count)
        ? before[(NSUInteger)selectedRow] : nil;

    [self.results removeAllObjects];
    [self.results addObjectsFromArray:result.allMedia ?: @[]];
    // Probe response lengths are unverified; metadata service validates file totals.
    for (DetectedMedia *media in self.results) media.sizeBytes = 0;
    if (isFinal) { self.scanning = NO; self.previewShown = NO; }

    self.restoringSelectionAfterReload = YES;
    [self.table reloadData];
    [self layoutWorkspace];  // 内容重建后重排（3:7 恒定）
    NSUInteger restoredRow = [self visibleRowMatchingMedia:selected];
    if (restoredRow != NSNotFound) {
        DetectedMedia *restored = self.visibleMedia[restoredRow];
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:restoredRow] byExtendingSelection:NO];
        [self restoreDetailForRestoredRow:restored];
    } else {
        // 找不到原选中项（或本轮没有选中）：清空选中并回到空详情，避免 ⌘D 错行
        [self.table deselectAll:nil];
        [self showDetailEmpty];
    }
    self.restoringSelectionAfterReload = NO;
}

// 结果列表重建后把详情面板接到重建后的行对象上：
// 详情当前展示的才是“用户选中的东西”。结果列表重建时，结果里可能只有该影片的
// **行对象**（declaredVariants 首项，典型是 480p），而用户选中的是同一行的 1080p
// 档位对象——它不在结果列表里。若按行对象比较，条件恒真，就会把 currentDownloadMedia
// 静静换成 480p 却不重配详情，造成“界面仍显示 1080p（选择器/链接/274MB）、⌘D 却
// 下载 480p（854x480 / 72.9MB）、且入队 expectedLength 变成 0”的现场故障。
// 因此这里以详情当前档位为准，并在重建后恢复同一档位，保证
// 选择器 / 链接 / 详情对象 / 入队对象四者同步。
- (void)restoreDetailForRestoredRow:(DetectedMedia *)restored {
    DetectedMedia *shown = self.detailMedia;
    NSString *shownKey = shown ? [DetectedMedia dedupKeyForURL:shown.mediaURL] : @"";
    NSString *restoredKey = [DetectedMedia dedupKeyForURL:restored.mediaURL];
    NSString *selectedTierKey = self.currentDownloadMedia
        ? [DetectedMedia dedupKeyForURL:self.currentDownloadMedia.mediaURL] : shownKey;
    if (self.detailMedia && shownKey.length && [shownKey isEqualToString:restoredKey]) {
        // 详情面板已经显示同一资源：只把对象换成新实例，不重新订阅
        self.detailMedia = restored;
        self.currentDownloadMedia = restored;
        return;
    }
    [self configureDetailForMedia:restored];
    // 用户原本选中的档位若仍由该行提供，用真实选择逻辑恢复到同一档位；
    // 档位已消失时保持在该行本身（界面与下载对象仍然一致）。
    if (!selectedTierKey.length) return;
    for (NSInteger i = 0; i < (NSInteger)self.variantPicker.numberOfItems; i++) {
        NSDictionary *v = [self.variantPicker itemAtIndex:i].representedObject;
        if ([v isKindOfClass:NSDictionary.class] &&
            [[DetectedMedia dedupKeyForURL:v[@"url"]] isEqualToString:selectedTierKey]) {
            [self.variantPicker selectItemAtIndex:i];
            [self selectDeclaredVariant:nil];
            return;
        }
    }
}

#pragma mark - 统一呈现（页面探测完成 → 列表/缩略图/详情都就绪 → 一次性呈现）

// 快照是否已到终态：任一字段仍为 Loading 都算“还没就绪”。
static BOOL RDPresentationFieldSettled(RDMetadataField *field) {
    return field != nil && field.state != RDMetadataLoading;
}
// 必需项取决于订阅通道（2026-09-13 真实网址 60s 空耗事故）：
//  · 完整详情通道（includeMediaLegs=YES）：时长/大小/分辨率/预览四项都必须有结论；
//  · 首屏缩略图预热通道（includeMediaLegs=NO）：按产品约定只承诺缩略图——生产
//    RDMetadataService 对 previewOnly 订阅**故意不出队媒体腿**，时长/大小/分辨率
//    会长期停在 Loading，留到用户真正选中该资源时再读。若这里仍要求四项全终态，
//    这类行永远“不就绪”，统一呈现只能干等 kRDPresentationSafetyDeadline（60s）
//    才兜底提交（实测 hanime1.life 单资源页 67–74s，其中 60s 是纯空等）。
// 只等缩略图落地：给定了必需项，就不把“等不到”当成“没就绪”。
static BOOL RDPresentationSnapshotSettled(RDMetadataSnapshot *snapshot, BOOL includeMediaLegs) {
    if (!snapshot) return NO;
    if (!RDPresentationFieldSettled(snapshot.preview)) return NO;
    if (!includeMediaLegs) return YES;
    return RDPresentationFieldSettled(snapshot.duration)
        && RDPresentationFieldSettled(snapshot.size)
        && RDPresentationFieldSettled(snapshot.dimensions);
}

// 作废当前准备（取消探测、重新探测、开始新一轮都要调用）。
- (void)cancelPresentationPreparation {
    self.presentationPreparing = NO;
    self.presentationGeneration += 1;   // 旧一轮的迟到回调全部作废
    for (NSDictionary *entry in self.presentationTokens) [(RDMetadataToken *)entry[@"token"] cancel];
    [self.presentationTokens removeAllObjects];
    [self.presentationRequirements removeAllObjects];
    [self.presentationSettled removeAllObjects];
    self.presentationOutstanding = 0;
}

// 探测结果到达后进入准备阶段。必需项只有两类，都是有界的：
//  1) 当前正在展示的详情：完整元数据（时长/大小/分辨率/预览）；
//  2) 首屏前 N 行的缩略图（列表里用户第一眼看到的那几行）。
// 行内的时长/大小仍只在用户真正选中该资源时读取（产品既有约定），因此不会
// 在“探测完成”之后逐项跳出：没有人订阅的行根本不会后到。
- (void)beginUnifiedPresentationForResult:(ZZResourceDiscoveryResult *)result {
    [self cancelPresentationPreparation];
    NSInteger generation = self.presentationGeneration;
    self.presentationPreparing = YES;
    self.statusNote.stringValue = @"正在读取详细信息…";
    NSMutableDictionary<NSString *, NSNumber *> *requirements = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray array];
    NSArray<DetectedMedia *> *visible = self.visibleMedia;
    // 1) 当前详情（用户已经选中并正在看的那一项）
    if (self.detailMedia && self.detailMedia.mediaURL.length)
        [self registerPresentationMedia:self.detailMedia includeMediaLegs:YES entries:entries requirements:requirements];
    // 2) 首屏各行：**有画质档位声明的视频行，把每一档都要求到完整元数据**
    //（时长/大小/分辨率）。产品要求“3 档画质之间的数据全部探索清楚，探索
    // 进度条才能完成”；这也让用户切档位时不再“读取中…”。
    // 其余行（图片 / 未声明档位的视频行）仍走轻量的仅预览通道。
    NSUInteger budget = MIN(kRDPresentationPreviewBudget, visible.count);
    for (NSUInteger i = 0; i < budget; i++) {
        DetectedMedia *row = visible[i];
        BOOL hasTiers = row.resourceKind != RDResourceKindImage && row.declaredVariants.count >= 1;
        // 无海报可预热的行（典型：图片行）走完整通道——仅预览通道对它拿不到
        // 任何终态，会让统一呈现空等安全兜底。
        BOOL noPosterToPreload = row.poster.length == 0;
        if (hasTiers) {
            for (NSDictionary *v in row.declaredVariants) {
                DetectedMedia *tier = [self mediaForVariant:v ofRow:row];
                if (tier) [self registerPresentationMedia:tier includeMediaLegs:YES entries:entries requirements:requirements];
            }
        } else if (noPosterToPreload) {
            [self registerPresentationMedia:row includeMediaLegs:YES entries:entries requirements:requirements];
        } else {
            [self registerPresentationMedia:row includeMediaLegs:NO entries:entries requirements:requirements];
        }
    }
    self.presentationRequirements = requirements;
    self.presentationTokens = [NSMutableArray array];
    self.presentationSettled = [NSMutableSet set];
    self.presentationOutstanding = 0;
    __weak typeof(self) weakSelf = self;
    for (NSMutableDictionary *entry in entries) {
        DetectedMedia *media = entry[@"media"];
        NSString *key = entry[@"key"];
        BOOL legs = [entry[@"legs"] boolValue];
        void (^update)(RDMetadataSnapshot *) = ^(RDMetadataSnapshot *snapshot) {
            [weakSelf presentationSnapshotArrived:snapshot forMedia:media generation:generation];
        };
        RDMetadataToken *token = legs
            ? [self.metadataService subscribeMedia:media reload:NO update:update]
            : [self.metadataService subscribePreviewOnlyForMedia:media update:update];
        // 订阅期间同步到达的快照已在 presentationSettled 里：不要重复计数。
        if (token && ![self.presentationSettled containsObject:key]) {
            [self.presentationTokens addObject:@{ @"token": token, @"legs": @(legs) }];
            self.presentationOutstanding += 1;
        }
    }
    self.presentationRequirementTotal = requirements.count;
    [self refreshPreparationProgress];
    if (self.presentationOutstanding == 0) {
        [self commitUnifiedPresentationForGeneration:generation];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRDPresentationSafetyDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || generation != s.presentationGeneration || !s.presentationPreparing) return;
        [s commitUnifiedPresentationForGeneration:generation];
    });
}

- (void)registerPresentationMedia:(DetectedMedia *)media
                 includeMediaLegs:(BOOL)includeMediaLegs
                           entries:(NSMutableArray<NSMutableDictionary *> *)entries
                      requirements:(NSMutableDictionary<NSString *, NSNumber *> *)requirements {
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL];
    if (!key.length) return;
    NSNumber *existing = requirements[key];
    if (existing) {
        if (!includeMediaLegs || existing.boolValue) return;   // 已有相同/更强要求
        requirements[key] = @YES;
        for (NSMutableDictionary *entry in entries)
            if ([entry[@"key"] isEqualToString:key]) { entry[@"legs"] = @YES; entry[@"media"] = media; }
        return;
    }
    requirements[key] = @(includeMediaLegs);
    [entries addObject:[@{ @"key": key, @"media": media, @"legs": @(includeMediaLegs) } mutableCopy]];
}

// 订阅回调：只有终态快照才算就绪；取消/换轮后的一切回调直接丢弃。
- (void)presentationSnapshotArrived:(RDMetadataSnapshot *)snapshot
                           forMedia:(DetectedMedia *)media
                         generation:(NSInteger)generation {
    if (generation != self.presentationGeneration || !self.presentationPreparing) return;
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL];
    if (!key.length || [self.presentationSettled containsObject:key]) return;
    // 该行当初是按哪条通道登记的，就按哪条通道的要求判“就绪”（见 settle 谓词注释）。
    NSNumber *requirement = self.presentationRequirements[key];
    BOOL includeMediaLegs = requirement ? requirement.boolValue : YES;
    if (!RDPresentationSnapshotSettled(snapshot, includeMediaLegs)) return;
    [self.presentationSettled addObject:key];
    if (self.presentationOutstanding > 0) self.presentationOutstanding -= 1;
    if (self.presentationOutstanding == 0) [self commitUnifiedPresentationForGeneration:generation];
    else [self refreshPreparationProgress];
}

// 统一呈现：列表、缩略图、详情、状态文案、进度在同一轮主线程更新中写完。
// 准备阶段状态文字：就绪计数仍由元数据/缩略图事件驱动，但当前界面只显示
// 固定的“正在整理下载选项…”文字；这里不再计算或绘制百分比进度。
- (void)refreshPreparationProgress {
    NSUInteger total = self.presentationRequirementTotal;
    if (!total) return;
    self.statusNote.stringValue = @"正在整理下载选项…";
}

// 行的某个画质档位对应的媒体对象：优先取结果里已有的实例，否则按
// selectDeclaredVariant: 的同一套规则合成，保证元数据服务用同一身份键命中
// 同一个 work（否则会出现两份重复请求/两份互相打架的详情）。
- (DetectedMedia *)mediaForVariant:(NSDictionary *)v ofRow:(DetectedMedia *)row {
    NSString *url = [v[@"url"] isKindOfClass:NSString.class] ? v[@"url"] : nil;
    if (!url.length) return nil;
    NSString *targetKey = [DetectedMedia dedupKeyForURL:url];
    if (!targetKey.length) return nil;
    for (DetectedMedia *candidate in self.results)
        if ([[DetectedMedia dedupKeyForURL:candidate.mediaURL] isEqual:targetKey]) return candidate;
    DetectedMedia *next = [DetectedMedia new];
    next.mediaURL = url;
    next.sourcePageURL = row.sourcePageURL;
    next.poster = row.poster;
    next.title = row.title;
    NSString *format = RDFormatForMediaURL(url);
    if (format) {
        next.format = format;
        BOOL manifest = [format isEqualToString:@"hls"] || [format isEqualToString:@"dash"];
        next.resourceKind = manifest ? RDResourceKindManifest : RDResourceKindVideo;
        next.isManifest = manifest;
    } else {
        next.resourceKind = row.resourceKind;
        next.isManifest = row.isManifest;
        next.format = row.format;
    }
    next.parentMediaURL = (row.isManifest && !row.parentMediaURL.length) ? row.mediaURL : row.parentMediaURL;
    next.videoFamilyID = row.videoFamilyID;
    next.declaredVariants = row.declaredVariants;
    return next;
}

- (void)commitUnifiedPresentationForGeneration:(NSInteger)generation {
    if (generation != self.presentationGeneration || !self.presentationPreparing) return;
    self.presentationPreparing = NO;
    self.explorationResultsSuppressed = NO;
    // 只取消“仅预览”预热任务；画质档位探索任务必须继续跑完——它们的时长/
    // 大小/分辨率要写入元数据缓存，用户之后切档位才不用重新“读取中…”。
    // （迟到快照不会改写界面：presentationSnapshotArrived 在非准备阶段直接丢弃。）
    for (NSDictionary *entry in self.presentationTokens)
        if (![entry[@"legs"] boolValue]) [(RDMetadataToken *)entry[@"token"] cancel];
    [self.presentationTokens removeAllObjects];
    [self.presentationRequirements removeAllObjects];
    [self.presentationSettled removeAllObjects];
    self.presentationOutstanding = 0;

    [self.table reloadData];              // 列表：行内时长/大小提示一次性生效
    [self refreshDetailPresentation];     // 详情：缩略图与字段一次性生效
    self.modeButton.hidden = NO;
    if (self.pendingCompletionShowsCheck) {
        self.checkLabel.hidden = NO;
        NSInteger checkGeneration = self.detailGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) s = self;
            if (!s || s.scanning || s.presentationPreparing || checkGeneration != s.detailGeneration) return;
            s.checkLabel.hidden = YES;
        });
    } else {
        self.checkLabel.hidden = YES;
    }
    self.statusNote.stringValue = self.pendingCompletionStatus ?: @"";
    self.pendingCompletionStatus = nil;
}

// 详情一次性刷新：缩略图要么是图像，要么是明确终态占位（绝不无限“读取中…”）。
- (void)refreshDetailPresentation {
    if (!self.detailMedia) return;
    [self refreshDetailMetaLabels];
    RDMetadataSnapshot *snapshot = self.metadataSnapshot;
    if (snapshot && snapshot.preview.state == RDMetadataKnown && snapshot.preview.value) {
        self.thumbView.image = snapshot.preview.value;
        self.thumbShowsPosterImage = [snapshot.preview.source containsString:@"poster"];
        self.thumbStatusLabel.hidden = YES;
    } else if (snapshot) {
        self.thumbView.image = nil;
        self.thumbShowsPosterImage = NO;
        self.thumbStatusLabel.stringValue = snapshot.preview.statusText;
        self.thumbStatusLabel.hidden = NO;
    }
    [self refreshVisibleRowForMedia:self.detailMedia];
}

// 准备阶段中用户又选了别的行：把该行也纳入必需项，完成时机跟随用户当前选择。
- (void)requirePresentationForMediaWhilePreparing:(DetectedMedia *)media {
    NSString *key = [DetectedMedia dedupKeyForURL:media.mediaURL];
    if (!key.length || !self.presentationPreparing || self.presentationRequirements[key]) return;
    self.presentationRequirements[key] = @YES;
    NSInteger generation = self.presentationGeneration;
    __weak typeof(self) weakSelf = self;
    RDMetadataToken *token = [self.metadataService subscribeMedia:media reload:NO
                                                          update:^(RDMetadataSnapshot *snapshot) {
        [weakSelf presentationSnapshotArrived:snapshot forMedia:media generation:generation];
    }];
    if (token && ![self.presentationSettled containsObject:key]) {
        [self.presentationTokens addObject:@{ @"token": token, @"legs": @YES }];
        self.presentationOutstanding += 1;
        self.presentationRequirementTotal += 1;
        [self refreshPreparationProgress];
    }
}

#pragma mark - 分栏手动布局（按设置项选择比例）

- (CGFloat)leftPaneRatio {
    NSInteger index = [PreferencesStore.shared integerForKey:SevenZZKeyMainPaneRatio defaultValue:0];
    switch (index) {
        case 1: return 0.20; // 左 2 : 右 8
        case 2: return 0.25; // 左 2.5 : 右 7.5
        default: return 0.30; // 左 3 : 右 7
    }
}

// 拖动 / 缩放 / 内容重建都不改动用户选择的比例：布局由本方法统一计算
- (void)layoutWorkspace {
    NSView *content = self.window.contentView;
    if (!content || !self.leftPane) return;
    CGFloat W = NSWidth(content.bounds);
    CGFloat H = NSHeight(content.bounds);
    CGFloat side = 24;           // 左右边距
    CGFloat bottomY = 44;        // 分栏底
    CGFloat topY = H - 108;      // 分栏顶（横线位置）
    CGFloat innerW = W - 2 * side;
    CGFloat leftW = floor([self leftPaneRatio] * innerW);
    CGFloat rightX = side + leftW + 1;    // 竖线宽 1
    self.leftPane.frame = NSMakeRect(side, bottomY, leftW, topY - bottomY);
    self.vDivider.frame = NSMakeRect(side + leftW, bottomY, 1, topY - 1 - bottomY);  // 顶端止于横线下沿，竖线不穿出
    self.detailPane.frame = NSMakeRect(rightX, bottomY, W - side - rightX, topY - bottomY);
    self.topDivider.frame = NSMakeRect(0, topY - 1, W, 1);
    [self layoutDetailCenteredHint];
    [self layoutDetailContent];   // 标题/字段/缩略图/按钮均按面板实际尺寸流式排布

    // 主页不承载下载进度；下载列表由 DownloadManager 的任务通知驱动。
}

- (void)windowDidResize:(NSNotification *)notification {
    [self layoutWorkspace];
    [self layoutSettingsControls];
    [self layoutDownloadsTable];
    [self layoutDownloadsEmptyLabel];
}

// 设置页自身的尺寸变化也触发重排：窗口代理的 windowDidResize 只覆盖「窗口被拖拽」这一条路径，
// 而设置页需要在任何尺寸下一次就位（构建期由测试直接改 frame、将来换容器承载都算）。
// NSViewFrameDidChangeNotification 在子视图按 autoresizingMask 调整之后发出，
// 因此这里重排可以覆盖掉靠锚定无法表达的整体压缩。
- (void)settingsPageFrameDidChange:(NSNotification *)notification {
    [self layoutSettingsControls];
}

// 空状态提示：按右面板实际边界中心排布（x 居中 + 垂直居中）
- (void)layoutDetailCenteredHint {
    if (self.emptyHint && self.detailPane) {
        CGFloat w = NSWidth(self.detailPane.bounds);
        if (w <= 0) w = 651;
        CGFloat h = NSHeight(self.detailPane.bounds);
        if (h <= 0) h = 548;
        self.emptyHint.frame = NSMakeRect(0, floor((h - 20) / 2.0), w, 20);
    }
}

// 详情面板自上而下流式布局：所有元素的 frame 都由面板实际宽度/高度推导，
// 不依赖 548pt 设计稿的固定坐标。标题按真实文字高度多行展开，缩略图按剩余
// 空间收缩，因此最小窗口下也不会出现文字/图片互相覆盖或越界。
- (void)layoutDetailContent {
    if (!self.detailPane) return;
    CGFloat paneW = NSWidth(self.detailPane.bounds);
    CGFloat paneH = NSHeight(self.detailPane.bounds);
    if (paneW <= 0 || paneH <= 0) return;

    CGFloat marginX = 16;
    CGFloat contentW = MAX(120, paneW - marginX * 2);
    CGFloat valueX = marginX + 74;
    CGFloat valueW = MAX(80, contentW - 74);
    CGFloat captionH = 16;

    // 底部固定：下载按钮贴底，直链区在按钮之上。
    // 「下载直链」小标题必须完整落在直链字段上方：字段高 24pt，标题与它再留 4pt 间距；
    // 旧实现写 linkY+20，比字段上沿还低 4pt，标题会压住字段/复制按钮。
    CGFloat buttonH = 24;
    CGFloat buttonY = 12;
    if (self.detailDownloadButton) {
        self.detailDownloadButton.frame = NSMakeRect(floor((paneW - 76) / 2.0), buttonY, 76, buttonH);
    }
    CGFloat linkY = buttonY + buttonH + 22;             // 直链文字区
    CGFloat linkFieldH = 24;
    CGFloat linkTitleY = linkY + linkFieldH + 4;        // “下载直链”小标题
    CGFloat rowsBottomLimit = linkTitleY + 18;          // 键值行不得越过直链标题上沿

    // 标题：文字高度只取决于面板宽度，先算出来，缩略图才知道自己能占多少高度
    CGFloat titleW = contentW;
    self.detailTitle.preferredMaxLayoutWidth = titleW;
    CGFloat titleH = captionH * 2;
    if (self.detailTitle.stringValue.length) {
        NSRect box = [self.detailTitle.stringValue boundingRectWithSize:NSMakeSize(titleW, CGFLOAT_MAX)
                                                               options:NSStringDrawingUsesLineFragmentOrigin
                                                            attributes:@{NSFontAttributeName: self.detailTitle.font ?: [NSFont systemFontOfSize:13]}];
        titleH = MIN(3, MAX(1, ceil(box.size.height / 16.0))) * 18;
    }
    titleH = MAX(18, titleH);

    BOOL showPicker = self.variantPicker && !self.variantPicker.hidden;
    NSUInteger slotCount = 4 + (showPicker ? 1 : 0);    // 4 行键值 + 可选画质档位行
    CGFloat slotPitch = 22;                             // 设计行距
    // 行块真正需要的纵向空间：首行占 captionH，往下每个槽位跨 slotPitch。
    // 画质下拉占用紧随 4 行之后它的独立槽位（20pt 高，向上占位），因此是 (slotCount-1) 段。
    CGFloat rowsNeed = captionH + (CGFloat)(slotCount - 1) * slotPitch;

    // 顶部固定：缩略图贴顶（16:9，宽度不超过内容宽），但必须先给「标题 + 行块」留足高度；
    // 留不下就按既有规则整块隐藏（<40pt 不显示），绝不让缩略图把键值行挤到相互重叠。
    CGFloat thumbW = MIN(contentW, 340);
    CGFloat thumbH = thumbW * 9.0 / 16.0;
    CGFloat maxThumbH = MAX(0, paneH - 12 - 10 - titleH - 8 - rowsBottomLimit - rowsNeed);
    if (thumbH > maxThumbH) {
        thumbH = maxThumbH;
        thumbW = MIN(thumbW, thumbH * 16.0 / 9.0);
    }
    BOOL showThumb = thumbH >= 40;
    CGFloat thumbY = paneH - 12 - (showThumb ? thumbH : 0);   // 贴顶（y 上沿）
    // 空状态（未选中任何资源）下不碰缩略图可见性，避免 resize 时把隐藏的图重新显示
    BOOL detailVisible = self.emptyHint.hidden;
    if (self.thumbView && detailVisible) {
        self.thumbView.hidden = !showThumb;
        // 缩略图被隐藏时不保留那个放不下的高度：退化成 1pt 的占位帧，
        // 保证面板内任何视图（含隐藏视图）都不会伸到 bounds 之外。
        CGFloat frameH = showThumb ? MAX(1, thumbH) : 1;
        CGFloat frameY = showThumb ? thumbY : MAX(0, paneH - 12 - frameH);
        self.thumbView.frame = NSMakeRect(floor((paneW - thumbW) / 2.0), frameY, MAX(1, thumbW), frameH);
    }

    // 标题紧贴缩略图下方（缩略图隐藏时贴顶），按真实文字高度展开（不限行数，绝不省略）
    CGFloat titleTop = showThumb ? thumbY - 10 : paneH - 12;
    CGFloat titleY = titleTop - titleH;
    self.detailTitle.frame = NSMakeRect(marginX, titleY, titleW, titleH);

    // 键值行从标题下方依次排布；画质档位下拉占用「来源」下方紧跟的独立槽位。
    NSArray<NSArray *> *rows = @[@[self.durationTitle, self.durationValue],
                                 @[self.formatTitle, self.formatValue],
                                 @[self.sizeTitle, self.sizeValue],
                                 @[self.sourceTitle, self.sourceValue]];
    CGFloat rowsTop = titleY - 8;
    CGFloat rowGap = slotPitch;
    CGFloat available = rowsTop - rowsBottomLimit;
    if (rowsNeed > available && slotCount > 0) {
        // 极窄高度兜底压缩行距；下限取 captionH+2，画质下拉行还要保证 ≥ 自身高度 20
        //（低于它下拉的上沿就会压住「来源」行的下沿）。
        CGFloat minGap = showPicker ? 20 : (captionH + 2);
        rowGap = MAX(minGap, (available - captionH) / (CGFloat)(slotCount - 1));
    }
    CGFloat y = rowsTop - captionH;
    for (NSArray *pair in rows) {
        NSTextField *cap = pair[0], *val = pair[1];
        if (cap) cap.frame = NSMakeRect(marginX, y, 66, captionH);
        if (val) val.frame = NSMakeRect(valueX, y, valueW, captionH);
        y -= rowGap;
    }
    if (showPicker) {
        // 下拉排在第 5 个槽位（y 已被 4 行键值各减一次 rowGap），与「来源」整整隔一行
        self.variantPicker.frame = NSMakeRect(valueX, MAX(rowsBottomLimit, y), MIN(120, valueW), 20);
    }

    // 直链区（URL 专用规则：单行中间省略）
    if (self.linkTitleLabel) self.linkTitleLabel.frame = NSMakeRect(marginX, linkTitleY, contentW, 14);
    CGFloat copyW = 18;
    CGFloat linkW = MAX(80, contentW - copyW - 6);
    if (self.linkField) self.linkField.frame = NSMakeRect(marginX, linkY, linkW, linkFieldH);
    if (self.linkCopyButton) self.linkCopyButton.frame = NSMakeRect(marginX + linkW + 6, linkY + 3, copyW, copyW);

    // 隐藏的分辨率行不参与布局
    if (self.dimensionTitle) self.dimensionTitle.hidden = YES;
    if (self.dimensionValue) self.dimensionValue.hidden = YES;
}

// 设置页布局：按 700pt 设计稿等比例缩放纵向位置，并把每个控件夹回页面边界内。
// 防重叠只处理“真正水平相交”的控件对，绝不把并排的标题/开关纵向堆叠
//（旧实现按 maxY 全局级联，会把并排控件一路压到负 y，导致文字越界）。
// 设置页统一布局：自上而下的流式排布，行高按可用高度自适应。
// 高度预算（最小内容区 438pt）：页头 94 + 4 组(标签 13 + 间距 4) 68 + 组间距 18
//   + 卡片内上下留白 32 + 6 行行高 = 438 → 行高 ≈ 37pt，实测 0 越界 0 重叠。
// 关键不变量：所有卡片、行标题、说明、控件、分隔线、版本号都是 settingsPage 的直接子视图，
// 且全部落在页面 bounds 内（RD-11 / UIX-4 会逐个断言）。
- (void)layoutSettingsControls {
    NSView *page = self.settingsPage;
    if (!page || self.settingsCards.count == 0 || self.settingsRowTitles.count == 0) return;
    CGFloat W = NSWidth(page.bounds), H = NSHeight(page.bounds);
    if (W <= 0 || H <= 0) return;

    const CGFloat marginX = 30.0;
    const CGFloat cardPadX = 16.0;
    const CGFloat topMargin = 10.0, bottomMargin = 8.0;
    const CGFloat titleH = 22.0, titleGap = 6.0, backH = 24.0, backGap = 10.0;
    const CGFloat groupLabelH = 13.0, groupLabelGap = 4.0, groupGap = 6.0;
    const CGFloat versionH = 14.0, versionW = 130.0;
    const CGFloat cardPadY = 4.0;
    const CGFloat rowTitleH = 16.0, rowHintH = 13.0, rowHintGap = 3.0;
    const CGFloat minRowH = 34.0, maxRowH = 58.0;

    NSUInteger cardCount = self.settingsCards.count;
    NSUInteger rowCount = self.settingsRowTitles.count;

    // 每个卡片的行数
    NSUInteger rowsInCard[16] = {0};
    for (NSNumber *idx in self.settingsRowCard) {
        NSUInteger c = idx.unsignedIntegerValue;
        if (c < 16) rowsInCard[c]++;
    }

    // 固定开销
    CGFloat overhead = topMargin + titleH + titleGap + backH + backGap + versionH + bottomMargin
                     + cardCount * (groupLabelH + groupLabelGap)
                     + (cardCount > 1 ? (cardCount - 1) * groupGap : 0.0)
                     + cardCount * 2.0 * cardPadY;
    CGFloat avail = H - overhead;
    CGFloat rowH = MIN(maxRowH, MAX(minRowH, floor(avail / (CGFloat)rowCount)));
    // 极端小窗口下若最小行高仍装不下，继续压缩：宁可行内挤一点，也绝不越界（RD-11 是硬断言）
    if (rowH * (CGFloat)rowCount > avail) rowH = MAX(24.0, floor(avail / (CGFloat)rowCount));

    CGFloat extra = MAX(0.0, H - (overhead + rowH * (CGFloat)rowCount));
    CGFloat extraGap = cardCount ? extra / (cardCount * 2.0) : 0.0;

    CGFloat cardX = marginX, cardW = MAX(80.0, W - 2.0 * marginX);
    CGFloat titleW = MAX(60.0, MIN(420.0, cardW));
    CGFloat labelW = MAX(60.0, cardW - 2.0 * cardPadX - 200.0);   // 给右侧控件留位
    NSMutableArray<NSNumber *> *slotTop = [NSMutableArray arrayWithCapacity:rowCount];

    // ── 页头 ──
    CGFloat y = H - topMargin;
    NSTextField *title = self.settingsTitleLabel;
    title.frame = NSMakeRect(marginX, y - titleH, titleW, titleH);
    y -= titleH + titleGap;
    NSButton *back = self.settingsBackButton;
    back.frame = NSMakeRect(marginX, y - backH, 96.0, backH);
    y -= backH + backGap;

    // ── 逐卡片排布 ──
    NSUInteger rowCursor = 0;
    for (NSUInteger c = 0; c < cardCount; c++) {
        y -= extraGap;
        NSView *groupLabel = self.settingsGroupLabels[c];
        groupLabel.frame = NSMakeRect(marginX, y - groupLabelH, MIN(240.0, cardW), groupLabelH);
        y -= groupLabelH + groupLabelGap;

        CGFloat cardH = rowsInCard[c] * rowH + 2.0 * cardPadY;
        self.settingsCards[c].frame = NSMakeRect(cardX, y - cardH, cardW, cardH);

        CGFloat slot = y - cardPadY;
        for (NSUInteger r = 0; r < rowsInCard[c] && rowCursor < rowCount; r++, rowCursor++) {
            [slotTop addObject:@(slot)];
            BOOL hasHint = (self.settingsRowHints[rowCursor] != [NSNull null]);
            CGFloat contentH = rowTitleH + (hasHint ? (rowHintGap + rowHintH) : 0.0);
            CGFloat contentTop = slot - (rowH - contentH) / 2.0;

            NSTextField *rowTitle = self.settingsRowTitles[rowCursor];
            rowTitle.frame = NSMakeRect(cardX + cardPadX, contentTop - rowTitleH, labelW, rowTitleH);
            if (hasHint) {
                NSTextField *hint = (NSTextField *)self.settingsRowHints[rowCursor];
                hint.frame = NSMakeRect(cardX + cardPadX, contentTop - rowTitleH - rowHintGap - rowHintH,
                                        labelW, rowHintH);
            }

            // 右侧控件：从最右往左依次排，垂直居中对齐该行槽位
            CGFloat rightEdge = cardX + cardW - cardPadX;
            NSArray<NSView *> *controls = self.settingsRowControls[rowCursor];
            for (NSView *control in controls.reverseObjectEnumerator) {
                CGFloat cw = MAX(1.0, NSWidth(control.frame));
                CGFloat ch = MAX(1.0, NSHeight(control.frame));
                control.frame = NSMakeRect(rightEdge - cw, slot - (rowH + ch) / 2.0, cw, ch);
                rightEdge -= cw + 8.0;
            }
            slot -= rowH;
        }
        y -= cardH + extraGap;
    }

    // ── 卡片内分隔线（画在指定行槽位的底部）──
    for (NSUInteger s = 0; s < self.settingsSeparators.count; s++) {
        NSUInteger afterRow = self.settingsSeparatorRow[s].unsignedIntegerValue;
        if (afterRow >= slotTop.count) continue;
        CGFloat slot = slotTop[afterRow].doubleValue;
        self.settingsSeparators[s].frame = NSMakeRect(cardX + cardPadX, slot - rowH, cardW - 2.0 * cardPadX, 1.0);
    }

    // ── 右下角版本号（固定在底部，不随内容流动）──
    self.settingsVersionLabel.frame = NSMakeRect(W - marginX - versionW, bottomMargin, versionW, versionH);
}

- (NSButton *)tinyButtonWithTitle:(NSString *)title fontSize:(CGFloat)fontSize color:(NSColor *)color action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.bordered = NO;
    b.font = [NSFont systemFontOfSize:fontSize];
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:fontSize],
                            NSForegroundColorAttributeName: color};
    b.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
    [b sizeToFit];
    return b;
}

- (void)buildFooterButtons {
    self.rescanFooter = [self tinyButtonWithTitle:@"⏎ 重新探测" fontSize:11 color:[NSColor colorWithWhite:0.6 alpha:0.5] action:@selector(scan:)];
    self.downloadFooter = [self tinyButtonWithTitle:@"⌘D 下载选中" fontSize:11 color:[NSColor colorWithWhite:0.6 alpha:0.5] action:@selector(downloadSelected:)];
    self.downloadsFooter = [self tinyButtonWithTitle:@"⌘L 下载列表" fontSize:11 color:[NSColor colorWithWhite:0.6 alpha:0.5] action:@selector(showDownloads:)];
    self.downloadPauseFooter = [self tinyButtonWithTitle:@"暂停下载" fontSize:11 color:NSColor.secondaryLabelColor action:@selector(toggleDownloadPauseResume:)];
    for (NSButton *button in @[self.rescanFooter, self.downloadPauseFooter, self.downloadFooter, self.downloadsFooter]) {
        button.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
        [self.homePage addSubview:button];
    }
    [self updateDownloadPauseButton];
}

- (void)updateDownloadPauseButton {
    if (!self.downloadPauseFooter) return;
    BOOL anyRunning = NO;
    BOOL anyPaused = NO;
    for (DownloadJob *job in self.downloadManager.allJobs) {
        if (job.state == DownloadJobStateRunning) anyRunning = YES;
        if (job.state == DownloadJobStatePaused || job.state == DownloadJobStateInterrupted) anyPaused = YES;
    }
    BOOL shouldResume = !anyRunning && anyPaused;
    NSString *title = shouldResume ? @"继续下载" : @"暂停下载";
    self.downloadPauseFooter.enabled = anyRunning || anyPaused;
    self.downloadPauseFooter.title = title;
    self.downloadPauseFooter.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName:self.downloadPauseFooter.font,
        NSForegroundColorAttributeName:self.downloadPauseFooter.enabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor
    }];
    self.downloadPauseFooter.toolTip = shouldResume ? @"继续所有已暂停或中断的下载（⌘P）" : @"暂停所有正在运行的下载（⌘P）";
    [self.downloadPauseFooter sizeToFit];
    [self layoutFooterButtons];
}

- (void)layoutFooterButtons {
    CGFloat right = NSWidth(self.window.contentView.bounds) - 24;
    for (NSButton *b in @[self.rescanFooter, self.downloadPauseFooter, self.downloadFooter, self.downloadsFooter].reverseObjectEnumerator) {
        NSRect f = b.frame;
        f.origin.x = right - NSWidth(f);
        f.origin.y = 18;
        b.frame = f;
        right = f.origin.x - 14;
    }
}

#pragma mark - 模式切换「总/单」与总站页数

- (void)updateModeButtonTitle {
    BOOL site = (self.mode == ZZResourceDiscoveryModeSite);
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc]
        initWithString:@"总/单"
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12],
                         NSForegroundColorAttributeName: [NSColor systemGrayColor]}];
    NSRange active = site ? NSMakeRange(0, 1) : NSMakeRange(2, 1);
    [title addAttribute:NSForegroundColorAttributeName value:[NSColor labelColor] range:active];
    [title addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] range:active];
    self.modeButton.attributedTitle = title;
    self.pagesField.hidden = !site;
    self.pagesUnitButton.hidden = !site;
}

- (void)toggleMode:(id)sender {
    self.mode = (self.mode == ZZResourceDiscoveryModeSite) ? ZZResourceDiscoveryModeCurrentPage : ZZResourceDiscoveryModeSite;
    [self updateModeButtonTitle];
}

- (void)commitPages:(id)sender {
    NSInteger v = MAX((NSInteger)1, MIN(DiscoverySessionController.siteMaxPages, self.pagesField.integerValue));
    self.sitePages = (NSUInteger)v;
    self.pagesField.stringValue = [NSString stringWithFormat:@"%ld", (long)v];
    [self.window makeFirstResponder:self.urlField];
}

#pragma mark - 设置页（同一窗口内切换，不新开窗口）

// 点击「设置」：隐藏探测页，显示设置页（同一窗口）
- (void)showSettingsPage:(id)sender {
    self.homePage.hidden = YES;
    self.settingsPage.hidden = NO;
    [self.window makeFirstResponder:nil];
}

- (void)switchBackToHome:(id)sender {
    self.settingsPage.hidden = YES;
    self.homePage.hidden = NO;
    [self.window makeFirstResponder:self.urlField];
}

// 过滤设置变更：持久化 + 清空选择 + 刷新列表与详情（叠加过滤，允许同开）
- (void)applyFilterChange {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setBool:self.filterVideoOnly forKey:@"ZZFilterVideoOnly"];
    [def setBool:self.filterImagesOnly forKey:@"ZZFilterImagesOnly"];
    if (self.settingsVideoSwitch.state != (self.filterVideoOnly ? NSControlStateValueOn : NSControlStateValueOff)) {
        self.settingsVideoSwitch.state = self.filterVideoOnly ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.settingsImagesSwitch.state != (self.filterImagesOnly ? NSControlStateValueOn : NSControlStateValueOff)) {
        self.settingsImagesSwitch.state = self.filterImagesOnly ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self.table deselectAll:nil];
    [self.table reloadData];
    [self showDetailEmpty];
    if (!self.scanning) {
        NSUInteger n = self.visibleMedia.count;
        self.statusNote.stringValue = n ? [NSString stringWithFormat:@"过滤后显示 %lu 个资源", (unsigned long)n]
                                        : @"过滤后没有符合条件的资源";
    }
}

- (void)toggleFilterVideoOnly:(NSSwitch *)sender {
    self.filterVideoOnly = sender.state == NSControlStateValueOn;
    [self applyFilterChange];
}

- (void)toggleFilterImagesOnly:(NSSwitch *)sender {
    self.filterImagesOnly = sender.state == NSControlStateValueOn;
    [self applyFilterChange];
}

- (void)changePaneRatio:(NSSegmentedControl *)sender {
    NSInteger index = MAX(0, MIN(2, sender.selectedSegment));
    [PreferencesStore.shared setInteger:index forKey:SevenZZKeyMainPaneRatio];
    [self layoutWorkspace];
}

// 设置页布局：标题 + 返回 + 内容过滤与布局选项
// 设置页布局（第 12 轮改版）：标题 + 返回 + 四组「分组卡片」。
// 高度预算是硬约束：最小内容区 760×438 必须装下全部控件（tests/Tests/RepairTests.m 的
// RD-11 断言会遍历 settingsPage 的每个直接子视图做 NSContainsRect）。实测第 5 个分组放不下
// （会超出约 21pt），因此「日志」作为「数据管理」卡片的第二行，而不是独立成组。
- (void)buildSettingsPage {
    NSView *page = self.settingsPage;

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 0, 420, 22)];
    title.bezeled = NO; title.drawsBackground = NO; title.editable = NO; title.selectable = NO;
    title.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    title.textColor = [NSColor labelColor];
    title.stringValue = @"设置";
    [page addSubview:title];
    self.settingsTitleLabel = title;

    NSButton *back = [NSButton buttonWithTitle:@"← 返回探测" target:self action:@selector(switchBackToHome:)];
    back.controlSize = NSControlSizeSmall;
    back.font = [NSFont systemFontOfSize:12];
    back.frame = NSMakeRect(30, 0, 96, 24);
    [page addSubview:back];
    self.settingsBackButton = back;

    // ── 卡片背景 + 分组标签：先加入，保证留在 z 序下层 ──
    NSArray<NSString *> *groupTitles = @[@"显示选项", @"布局", @"下载", @"数据管理"];
    NSMutableArray<NSView *> *cards = [NSMutableArray arrayWithCapacity:groupTitles.count];
    NSMutableArray<NSView *> *groupLabels = [NSMutableArray arrayWithCapacity:groupTitles.count];
    for (NSString *groupTitle in groupTitles) {
        NSBox *card = [[NSBox alloc] initWithFrame:NSZeroRect];
        card.boxType = NSBoxCustom;
        card.titlePosition = NSNoTitle;
        card.borderWidth = 1.0;
        card.cornerRadius = 8.0;
        card.borderColor = [NSColor separatorColor];
        card.fillColor = [NSColor controlBackgroundColor];
        // 标识为「容器背景」：几何探针据此把「背景 × 其内容」的包含关系排除在重叠统计之外，
        // 但越界检查、以及「内容彼此之间」的重叠检查照旧执行（不放宽真实约束）。
        card.identifier = @"RDSettingsCardBackground";
        [page addSubview:card];
        [cards addObject:card];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 0, 240, 13)];
        label.bezeled = NO; label.drawsBackground = NO; label.editable = NO; label.selectable = NO;
        label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        label.textColor = [NSColor secondaryLabelColor];
        label.stringValue = groupTitle;
        [page addSubview:label];
        [groupLabels addObject:label];
    }
    self.settingsCards = cards;
    self.settingsGroupLabels = groupLabels;

    // ── 行：标题 + 可选说明 + 右侧控件，全部是 settingsPage 的直接子视图 ──
    NSMutableArray<NSTextField *> *rowTitles = [NSMutableArray array];
    NSMutableArray *rowHints = [NSMutableArray array];      // NSTextField 或 NSNull（无说明）
    NSMutableArray<NSArray<NSView *> *> *rowControls = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rowCard = [NSMutableArray array];
    NSMutableArray<NSView *> *separators = [NSMutableArray array];
    NSMutableArray<NSNumber *> *separatorRow = [NSMutableArray array];

    __block NSUInteger currentCard = 0;
    void (^addRow)(NSString *, NSString *, NSArray<NSView *> *) =
        ^(NSString *rowTitle, NSString *rowHint, NSArray<NSView *> *controls) {
        NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(46, 0, 320, 16)];
        l.bezeled = NO; l.drawsBackground = NO; l.editable = NO; l.selectable = NO;
        l.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        l.textColor = [NSColor labelColor];
        l.stringValue = rowTitle;
        [page addSubview:l];
        [rowTitles addObject:l];

        if (rowHint.length) {
            NSTextField *h = [[NSTextField alloc] initWithFrame:NSMakeRect(46, 0, 460, 13)];
            h.bezeled = NO; h.drawsBackground = NO; h.editable = NO; h.selectable = NO;
            h.font = [NSFont systemFontOfSize:11];
            h.textColor = [NSColor secondaryLabelColor];
            h.stringValue = rowHint;
            [page addSubview:h];
            [rowHints addObject:h];
        } else {
            [rowHints addObject:[NSNull null]];
        }

        for (NSView *c in controls) [page addSubview:c];
        [rowControls addObject:controls];
        [rowCard addObject:@(currentCard)];
    };
    void (^addSeparator)(void) = ^{
        NSBox *sep = [[NSBox alloc] initWithFrame:NSZeroRect];
        sep.boxType = NSBoxSeparator;
        sep.identifier = @"RDSettingsRowSeparator";
        [page addSubview:sep];
        [separators addObject:sep];
        [separatorRow addObject:@(rowTitles.count - 1)];
    };

    // 卡片 0：显示选项
    currentCard = 0;
    self.settingsVideoSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    self.settingsVideoSwitch.state = self.filterVideoOnly ? NSControlStateValueOn : NSControlStateValueOff;
    self.settingsVideoSwitch.target = self;
    self.settingsVideoSwitch.action = @selector(toggleFilterVideoOnly:);
    addRow(@"只显示视频", @"开启后，列表里只保留视频/清单，隐藏图片", @[self.settingsVideoSwitch]);
    addSeparator();
    self.settingsImagesSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    self.settingsImagesSwitch.state = self.filterImagesOnly ? NSControlStateValueOn : NSControlStateValueOff;
    self.settingsImagesSwitch.target = self;
    self.settingsImagesSwitch.action = @selector(toggleFilterImagesOnly:);
    addRow(@"只显示图片", @"开启后，列表里只保留图片", @[self.settingsImagesSwitch]);

    // 卡片 1：布局 —— 左右栏比例三档平铺（点哪档切哪档）。
    // identifier 故意沿用 "RDPaneRatioPopup"：它是 build/ui-probe/accept2.sh 的黑盒定位锚点，
    // 换控件类型不改这个 id，既有验收脚本继续可用。
    currentCard = 1;
    NSSegmentedControl *ratioControl =
        [NSSegmentedControl segmentedControlWithLabels:@[@"3 : 7", @"2 : 8", @"2.5 : 7.5"]
                                          trackingMode:NSSegmentSwitchTrackingSelectOne
                                                target:self
                                                action:@selector(changePaneRatio:)];
    ratioControl.identifier = @"RDPaneRatioPopup";
    ratioControl.frame = NSMakeRect(0, 0, 186, 26);
    ratioControl.segmentStyle = NSSegmentStyleRounded;
    ratioControl.font = [NSFont systemFontOfSize:11.5];
    NSInteger ratioIndex = [PreferencesStore.shared integerForKey:SevenZZKeyMainPaneRatio defaultValue:0];
    if (ratioIndex < 0 || ratioIndex > 2) ratioIndex = 0;
    ratioControl.selectedSegment = ratioIndex;
    self.settingsPaneRatioControl = ratioControl;
    addRow(@"左右栏比例", @"调整资源列表与详情区域的宽度比例", @[ratioControl]);

    // 卡片 2：下载
    currentCard = 2;
    NSButton *choose = [NSButton buttonWithTitle:@"选择" target:self action:@selector(chooseDownloadLocation:)];
    choose.controlSize = NSControlSizeSmall;
    choose.font = [NSFont systemFontOfSize:11.5];
    [choose sizeToFit];
    addRow(@"下载位置", @"选择资源下载后保存的文件夹", @[choose]);

    // 卡片 3：数据管理 —— 一键清除下载记录 + 日志（第 12 轮把原来飘在顶部中间的
    // 「打开日志 / 导出诊断」收进本卡片，成为与其它行同构的一行）
    currentCard = 3;
    self.clearDownloadRecordsButton = [NSButton buttonWithTitle:@"清除" target:self action:@selector(clearDownloadRecords:)];
    self.clearDownloadRecordsButton.bordered = NO;
    self.clearDownloadRecordsButton.font = [NSFont systemFontOfSize:12];
    self.clearDownloadRecordsButton.identifier = @"RDClearDownloadRecordsButton";
    self.clearDownloadRecordsButton.attributedTitle =
        [[NSAttributedString alloc] initWithString:@"清除"
                                        attributes:@{NSFontAttributeName: self.clearDownloadRecordsButton.font,
                                                     NSForegroundColorAttributeName: [NSColor systemRedColor]}];
    [self.clearDownloadRecordsButton sizeToFit];
    addRow(@"一键清除下载记录", nil, @[self.clearDownloadRecordsButton]);
    addSeparator();

    NSButton *openLogsButton = [NSButton buttonWithTitle:@"打开日志" target:self action:@selector(openLogsFolder:)];
    openLogsButton.controlSize = NSControlSizeSmall;
    openLogsButton.font = [NSFont systemFontOfSize:11.5];
    [openLogsButton sizeToFit];
    NSButton *exportDiagButton = [NSButton buttonWithTitle:@"导出诊断" target:self action:@selector(exportDiagnostics:)];
    exportDiagButton.controlSize = NSControlSizeSmall;
    exportDiagButton.font = [NSFont systemFontOfSize:11.5];
    [exportDiagButton sizeToFit];
    addRow(@"日志", nil, @[openLogsButton, exportDiagButton]);

    self.settingsRowTitles = rowTitles;
    self.settingsRowHints = rowHints;
    self.settingsRowControls = rowControls;
    self.settingsRowCard = rowCard;
    self.settingsSeparators = separators;
    self.settingsSeparatorRow = separatorRow;

    // 右下角版本号（构建期生成，运行期固定；位置由 layoutSettingsControls 统一给）
    NSTextField *version = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 130, 14)];
    version.bezeled = NO; version.drawsBackground = NO; version.editable = NO; version.selectable = NO;
    version.alignment = NSTextAlignmentRight;
    version.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    version.textColor = [NSColor tertiaryLabelColor];
    version.stringValue = RD_GENERATED_VERSION_STRING;
    version.identifier = @"RDVersionLabel";
    version.toolTip = [NSString stringWithFormat:@"构建版本：%d 行代码 / 第 %d 轮修复",
                       RD_GENERATED_CODE_LINES, RD_GENERATED_FIX_ROUND];
    [page addSubview:version];
    self.settingsVersionLabel = version;

    [self layoutSettingsControls];

    // 设置页在任何尺寸下都要「一笔到位」：由页面自身上报尺寸变化并立即重排。
    // NSViewFrameDidChangeNotification 在子视图被 autoresizingMask 调整之后发出，
    // 所以这里的重排能覆盖掉锚定造成的错位；不再依赖窗口代理是否收到 windowDidResize。
    // 第 12 轮起不再给任何子视图设 autoresizingMask —— 全部位置由本方法一次算清，
    // 避免「锚定先动一次、重排再动一次」带来的中间态。
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewFrameDidChangeNotification object:nil];
    self.settingsPage.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsPageFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:self.settingsPage];
}

- (void)openLogsFolder:(id)sender {
    RDLogRevealInFinder();
}

- (void)exportDiagnostics:(id)sender {
    NSError *err = nil;
    NSString *dir = RDLogExportDiagnostics(RD_GENERATED_VERSION_STRING, &err);
    if (dir) {
        self.statusNote.stringValue = @"诊断包已导出到桌面";
        RDLogWrite(@"app", @"导出诊断包 → %@", dir);
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
    } else {
        self.statusNote.stringValue = @"诊断包导出失败（桌面不可写？）";
        RDLogWrite(@"app", @"导出诊断包失败：%@", err.localizedDescription ?: @"未知错误");
    }
}

- (void)clearDownloadRecords:(id)sender {
    [self.downloadManager clearAllDownloadRecords];
    [self refreshDownloadsList];
    self.statusNote.stringValue = @"下载记录已清除（磁盘文件未删除）";
}

- (void)chooseDownloadLocation:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO; panel.canChooseDirectories = YES; panel.allowsMultipleSelection = NO; panel.canCreateDirectories = YES;
    panel.prompt = @"选择"; panel.message = @"选择下载文件夹";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        [self.downloadSettings setCustomDirectoryURL:panel.URL];
        self.downloadSettings.downloadDestination = ResourceDownloadDestinationCustom;
    }];
}

#pragma mark - 内容过滤视图

// 两个开关为叠加关系：只显示视频=排除图片；只显示图片=只保留图片；同开=空
- (NSArray<DetectedMedia *> *)visibleMedia {
    NSMutableArray *rows=[NSMutableArray array];
    // 分组 key → rows 中的行位置。同一明确 video 元素内的全部成员
    // （video.src + 全部 source.src，有或无 size/label/width/height）共享稳定
    // family ID，因此无论是否声明标准画质都只占一行：未知/非标准画质不伪造
    // 档位，但也绝不以第二行重复出现。没有 family ID 时才退回“候选集合完全
    // 一致”的旧折叠键。每组先到者占位，择优者（declaredVariants 首项 URL）
    // 到达时原位替换；择优项不在结果里时，首个占位行作为确定性回退。
    NSMutableDictionary<NSString *, NSNumber *> *rowByGroup=[NSMutableDictionary dictionary];
    for (DetectedMedia *m in self.results) {
        if (self.filterVideoOnly && m.resourceKind == RDResourceKindImage) continue;
        if (self.filterImagesOnly && m.resourceKind != RDResourceKindImage) continue;
        NSString *key=nil;
        if (m.videoFamilyID.length && m.resourceKind != RDResourceKindImage) {
            key=[@"family:" stringByAppendingString:m.videoFamilyID];
        } else if (m.declaredVariants.count >= 1 && m.resourceKind != RDResourceKindImage) {
            NSArray *urls=[[m.declaredVariants valueForKey:@"url"] sortedArrayUsingSelector:@selector(compare:)];
            key=[urls componentsJoinedByString:@"\n"];
        }
        if (key) {
            NSNumber *existing=rowByGroup[key];
            if (existing) {
                DetectedMedia *current=rows[existing.unsignedIntegerValue];
                NSString *preferred=m.declaredVariants.firstObject[@"url"];
                // 择优代表替换：归一化保留的候选到达时原位替换；占位行尚无档位
                // 而新成员有时也替换为信息更全者。都不满足则保持先到者。
                BOOL preferredArrived = preferred.length && [preferred isEqual:m.mediaURL];
                BOOL richer = current.declaredVariants.count == 0 && m.declaredVariants.count > 0;
                if (preferredArrived || richer) rows[existing.unsignedIntegerValue]=m;
                continue;
            }
            rowByGroup[key]=@(rows.count);
            [rows addObject:m];
            continue;
        }
        [rows addObject:m];
    }
    return rows;
}

#pragma mark - 探测

// 探测会话回调安装：每个探次捕获自己的 generation，旧探次的迟到回调会被丢弃，
// 不会覆盖新一轮的状态文字（包括取消后迟到的结果）。
- (void)installSessionHandlersForGeneration:(NSInteger)generation {
    __weak typeof(self) weakSelf = self;
    self.session.statusHandler = ^(NSString *s){
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) sself = weakSelf; if (!sself || sself.scanGeneration != generation) return;
            if (!sself.scanning) return;
            sself.statusNote.stringValue = [sself displayStatusForDiscoveryStatus:s];
        });
    };
    self.session.progressHandler = ^(double p){
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) sself = weakSelf;
            if (!sself || sself.scanGeneration != generation || !sself.scanning) return;
            sself.statusNote.stringValue = @"正在分析页面内容…";
        });
    };
    self.session.resultHandler = ^(ZZResourceDiscoveryResult *r){
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) sself = weakSelf; if (!sself || sself.scanGeneration != generation) return;
            [sself applyDiscoveryResult:r final:YES];
            [sself finishScanWithResult:r];
        });
    };
    // 临时结果（静态取页腿先回来）：先把列表显示出来，用户不必等动态 WebKit 腿
    // 的 4–6 秒。探测还没结束，所以不动“探测完成”文案。
    self.session.interimResultHandler = ^(ZZResourceDiscoveryResult *r){
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) sself = weakSelf;
            if (!sself || sself.scanGeneration != generation || !sself.scanning) return;
            [sself applyDiscoveryResult:r final:NO];
            NSUInteger count = sself.visibleMedia.count;
            if (count > 0) {
                sself.previewShown = YES;
                sself.statusNote.stringValue = @"正在寻找媒体资源…";
            }
        });
    };
}

- (void)scan:(id)sender {
    if (self.scanning) { self.statusNote.stringValue = @"正在探测中，按 Esc 取消后再试"; return; }
    NSString *s = [self.urlField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *u = [NSURL URLWithString:s];
    if (!u || !u.host.length) { self.statusNote.stringValue = @"请输入有效的网页地址"; return; }
    // 新扫描开始即作废旧预取与旧详情订阅：上一轮的在途请求不允许继续消耗
    // 连接，更不允许迟到的快照写进这一轮的结果。统一呈现状态一并重置，
    // 新探测绝不继承上一轮的加载状态。
    [self cancelPresentationPreparation];
    self.pendingCompletionStatus = nil;
    // 严格统一呈现：新探索开始就抑制列表呈现，探索完成才一次性出现。
    self.explorationResultsSuppressed = YES;
    self.scanGeneration += 1;   // 作废上一轮探次的全部在途回调
    [self installSessionHandlersForGeneration:self.scanGeneration];
    self.statusNote.stringValue = @"准备读取网址…";
    [self.metadataToken cancel];
    [self.durationCache removeAllObjects]; // 旧 URL 的“获取中…”残留不得带入新结果
    [self.selectedTierRowDisplay removeAllObjects]; // 旧 URL 的档位摘要同理
    [self.results removeAllObjects];
    [self.table reloadData];
    [self layoutWorkspace];
    [self showDetailEmpty];
    self.previewShown = NO;
    self.scanning = YES;
    self.modeButton.hidden = YES;
    self.checkLabel.hidden = YES;
    self.statusNote.stringValue = @"正在读取网址…";
    if (self.mode == ZZResourceDiscoveryModeSite) {
        [self.session startSiteBatchWithURL:u listingPageCount:self.sitePages];
    } else {
        [self.session startWithURL:u mode:self.mode];
    }
}

- (void)cancelScan:(id)sender {
    // 准备呈现阶段（页面探测已回调完成、列表缩略图/详情仍在读取）也必须可取消。
    if (!self.scanning && !self.presentationPreparing) return;
    [self cancelPresentationPreparation];
    self.pendingCompletionStatus = nil;
    self.explorationResultsSuppressed = NO;   // 取消后立即按既有行为显示已应用的结果
    if (self.scanning) [self.session cancel];
    // 取消后旧详情订阅必须立即失效：迟到的缩略图/详情不得再写回界面。
    [self.metadataToken cancel];
    self.metadataToken = nil;
    self.metadataSnapshot = nil;
    self.scanning = NO;
    self.scanGeneration += 1;   // 作废本次探次的迟到回调，避免覆盖“已取消探测”
    self.modeButton.hidden = NO;
    self.statusNote.stringValue = @"已取消探测";
}

- (void)finishScanWithResult:(ZZResourceDiscoveryResult *)result {
    // 取消结果可能在 cancelScan 已经收尾后迟到；不能把已取消的探测
    // 重新显示成 100%，也不能重新启动进度动画。取消时同步丢弃准备阶段。
    if (result.cancelled) {
        [self cancelPresentationPreparation];
        self.pendingCompletionStatus = nil;
        self.explorationResultsSuppressed = NO;
        self.modeButton.hidden = NO;
            self.statusNote.stringValue = @"已取消探测";
        return;
    }
    // 统一呈现：先把完成文案挂起，等列表缩略图与当前详情到达终态，
    // 再由 commitUnifiedPresentationForGeneration: 一次性写入。这样进度
    // 100% / “探测完成”与列表、缩略图、详情始终互相一致。
    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    if (result.error) [errors addObject:result.error];
    for (MultiPageProbePageResult *page in result.pageResults) if (page.status == MultiPageProbePageStatusFailed && page.error) [errors addObject:page.error];
    for (ZZResourceDiscoveryResult *listing in result.listingPageResults) if (listing.error) [errors addObject:listing.error];
    NSUInteger count = self.visibleMedia.count;
    if (errors.count) {
        self.pendingCompletionStatus = count
            ? [NSString stringWithFormat:@"发现 %lu 个资源 · 部分页面失败：%@",(unsigned long)count,errors.firstObject.localizedDescription]
            : [NSString stringWithFormat:@"探测失败：%@",errors.firstObject.localizedDescription];
        self.pendingCompletionShowsCheck = NO;
    } else {
        self.pendingCompletionStatus = count
            ? [NSString stringWithFormat:@"探测完成 · 发现 %lu 个资源",(unsigned long)count]
            : @"页面加载成功 · 未发现可下载资源";
        self.pendingCompletionShowsCheck = YES;
    }
    self.statusNote.stringValue = @"正在准备呈现…";
    [self beginUnifiedPresentationForResult:result];
    // 严格统一呈现：探索未完成前列表不出现任何行（“内容先冒出来、数据后补”
    // 正是 2026-09-13 验收发现的加载逻辑错误）；探索完成后由
    // commitUnifiedPresentationForGeneration: 一次性 reloadData 呈现。
    if (self.presentationPreparing) [self.table reloadData];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

// 关窗即退出（见上）。退出前必须把在途任务记为中断并持久化，否则下一次
// 启动下载列表为空、未完成任务无处可寻（2026-09-08 任务丢失事故）。
- (void)applicationWillTerminate:(NSNotification *)notification {
    RDLogWrite(@"app", @"applicationWillTerminate");
    RDLogFlush();   // 常规日志走异步队列，退出前排空，最后一刻的诊断行才不会丢
    [self.downloadManager markInterruptedOnTerminate];
}

#pragma mark - Esc / 回车

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBy:(SEL)commandSelector {
    if (control == self.urlField && commandSelector == @selector(cancelOperation:)) {
        if (self.scanning || self.presentationPreparing) [self cancelScan:nil];
        else self.urlField.stringValue = @"";
        return YES;
    }
    return NO;
}

// 输入框内容一旦改变，当前列表就不再对应用户正在编辑的地址。
// 立即清空旧结果并作废在途回调，避免删除链接或输入半截链接后仍显示上一轮内容。
- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.urlField) return;

    if (self.scanning || self.presentationPreparing) {
        [self cancelScan:nil];
    } else {
        [self cancelPresentationPreparation];
    }
    self.pendingCompletionStatus = nil;
    self.explorationResultsSuppressed = NO;
    [self.metadataToken cancel];
    self.metadataToken = nil;
    self.metadataSnapshot = nil;
    [self.durationCache removeAllObjects];
    [self.selectedTierRowDisplay removeAllObjects];
    [self.results removeAllObjects];
    [self.table deselectAll:nil];
    [self.table reloadData];
    [self showDetailEmpty];
    self.previewShown = NO;
    self.statusNote.stringValue = @"";
}

// 页数输入框失焦时同步（回车由 action 处理）
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.pagesField) {
        NSInteger v = MAX((NSInteger)1, MIN(DiscoverySessionController.siteMaxPages, self.pagesField.integerValue));
        self.sitePages = (NSUInteger)v;
        self.pagesField.stringValue = [NSString stringWithFormat:@"%ld", (long)v];
    }
}

- (void)cancelOperation:(id)sender {
    if (self.scanning || self.presentationPreparing) [self cancelScan:nil];
}

#pragma mark - 下载列表页（主窗口内切换，不创建独立 NSPanel）

- (void)showDownloads:(id)sender {
    self.homePage.hidden = YES;
    self.settingsPage.hidden = YES;
    self.downloadsPage.hidden = NO;
    [self layoutDownloadsTable];
    [self refreshDownloadsList];
    [self.window makeFirstResponder:nil];
}

- (void)switchBackToHomeFromDownloads:(id)sender {
    self.downloadsPage.hidden = YES;
    self.settingsPage.hidden = YES;
    self.homePage.hidden = NO;
    [self.window makeFirstResponder:self.urlField];
}

- (void)buildDownloadsPage {
    NSView *page = self.downloadsPage;
    NSColor *paperColor = [NSColor colorWithSRGBRed:0.980 green:0.973 blue:0.957 alpha:1.0];
    page.wantsLayer = YES;

    // 返回主页
    self.downloadsBackButton = [NSButton buttonWithTitle:@"← 返回主页" target:self action:@selector(switchBackToHomeFromDownloads:)];
    self.downloadsBackButton.bordered = NO;
    self.downloadsBackButton.font = [NSFont systemFontOfSize:12];
    self.downloadsBackButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"← 返回主页" attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12], NSForegroundColorAttributeName:[NSColor systemGrayColor]}];
    self.downloadsBackButton.frame = NSMakeRect(24, 642, 80, 24);
    // 顶部元素：距顶固定（NSViewMinYMargin = 底边距可伸缩），窗口缩小时随顶边下移，
    // 不会被挤出可视区。原先误用 NSViewMaxYMargin（距底固定），缩小窗口后整体移出可视区。
    self.downloadsBackButton.autoresizingMask = NSViewMinYMargin;
    self.downloadsBackButton.identifier = @"RDDownloadsBackButton";
    [page addSubview:self.downloadsBackButton];

    // 页面标题
    self.downloadsTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 600, 300, 30)];
    self.downloadsTitleLabel.bezeled = NO; self.downloadsTitleLabel.drawsBackground = NO; self.downloadsTitleLabel.editable = NO;
    self.downloadsTitleLabel.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    self.downloadsTitleLabel.textColor = [NSColor labelColor];
    self.downloadsTitleLabel.stringValue = @"下载列表";
    self.downloadsTitleLabel.autoresizingMask = NSViewMinYMargin;
    [page addSubview:self.downloadsTitleLabel];

    // 筛选按钮区（自定义扁平按钮，非 NSPopUpButton / 非系统下拉）
    self.downloadsFilterBar = [[NSView alloc] initWithFrame:NSMakeRect(30, 560, 360, 28)];
    self.downloadsFilterBar.autoresizingMask = NSViewMinYMargin;
    [page addSubview:self.downloadsFilterBar];

    NSArray<NSString *> *filterTitles = @[@"全部", @"下载中", @"已成功", @"已失败"];
    NSMutableArray<NSButton *> *filterButtons = [NSMutableArray array];
    CGFloat fx = 0;
    for (NSUInteger i = 0; i < filterTitles.count; i++) {
        NSButton *b = [NSButton buttonWithTitle:filterTitles[i] target:self action:@selector(downloadsFilterTapped:)];
        b.bordered = NO;
        b.font = [NSFont systemFontOfSize:12];
        b.tag = i;
        b.frame = NSMakeRect(fx, 0, 64, 28);
        b.autoresizingMask = NSViewMaxYMargin;
        [self.downloadsFilterBar addSubview:b];
        [filterButtons addObject:b];
        fx += 72;
    }
    self.downloadsFilterButtons = filterButtons;
    [self updateDownloadsFilterUI];

    // 状态统计
    self.downloadsStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(420, 566, 500, 18)];
    self.downloadsStatusLabel.bezeled = NO; self.downloadsStatusLabel.drawsBackground = NO; self.downloadsStatusLabel.editable = NO;
    self.downloadsStatusLabel.font = [NSFont systemFontOfSize:12];
    self.downloadsStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.downloadsStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [page addSubview:self.downloadsStatusLabel];

    // 任务列表
    self.downloadsTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.downloadsTable.rowHeight = 72;
    self.downloadsTable.headerView = nil;
    self.downloadsTable.backgroundColor = paperColor;
    self.downloadsTable.usesAlternatingRowBackgroundColors = NO;
    self.downloadsTable.dataSource = (id)self;
    self.downloadsTable.delegate = (id)self;
    self.downloadsTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.downloadRecencyTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(refreshDownloadRecency:) userInfo:nil repeats:YES];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"download"];
    col.width = 300; col.minWidth = 80; col.maxWidth = CGFLOAT_MAX; col.resizingMask = NSTableColumnAutoresizingMask;
    [self.downloadsTable addTableColumn:col];
    self.downloadsTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.downloadsTable.allowsColumnResizing = NO;
    self.downloadsTable.allowsColumnReordering = NO;

    self.downloadsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 44, 932, 500)];
    self.downloadsScrollView.documentView = self.downloadsTable;
    self.downloadsTable.frame = NSMakeRect(0, 0, NSWidth(self.downloadsScrollView.contentView.bounds), NSHeight(self.downloadsScrollView.contentView.bounds));
    self.downloadsTable.autoresizingMask = NSViewHeightSizable;
    self.downloadsScrollView.hasVerticalScroller = YES;
    // 横向锁死：无横向滚动条、无横向弹性拖动，内容宽度恒等于可视宽度。
    self.downloadsScrollView.hasHorizontalScroller = NO;
    self.downloadsScrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    self.downloadsScrollView.autohidesScrollers = YES;
    self.downloadsScrollView.drawsBackground = YES;
    self.downloadsScrollView.backgroundColor = paperColor;
    self.downloadsScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.downloadsScrollView.identifier = @"RDDownloadsScrollView";
    [page addSubview:self.downloadsScrollView];

    // 空状态
    self.downloadsEmptyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 932, 20)];
    self.downloadsEmptyLabel.bezeled = NO; self.downloadsEmptyLabel.drawsBackground = NO; self.downloadsEmptyLabel.editable = NO;
    self.downloadsEmptyLabel.alignment = NSTextAlignmentCenter;
    self.downloadsEmptyLabel.font = [NSFont systemFontOfSize:14];
    self.downloadsEmptyLabel.textColor = [NSColor secondaryLabelColor];
    self.downloadsEmptyLabel.stringValue = @"暂无下载任务";
    self.downloadsEmptyLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    self.downloadsEmptyLabel.identifier = @"RDDownloadsEmptyLabel";
    [page addSubview:self.downloadsEmptyLabel];
    [self layoutDownloadsEmptyLabel];
}

- (void)layoutDownloadsEmptyLabel {
    NSRect bounds = self.downloadsScrollView.frame;
    self.downloadsEmptyLabel.frame = NSMakeRect(NSMinX(bounds), NSMinY(bounds) + NSHeight(bounds) / 2.0 - 10, NSWidth(bounds), 20);
}

- (void)setDownloadFilter:(RDDownloadFilter)filter {
    _downloadFilter = filter;
    [self updateDownloadsFilterUI];
    [self refreshDownloadsList];
}

- (void)downloadsFilterTapped:(NSButton *)sender {
    self.downloadFilter = (RDDownloadFilter)sender.tag;
}

- (void)updateDownloadsFilterUI {
    for (NSUInteger i = 0; i < self.downloadsFilterButtons.count; i++) {
        NSButton *b = self.downloadsFilterButtons[i];
        BOOL selected = (NSInteger)i == self.downloadFilter;
        NSColor *fg = selected ? [NSColor whiteColor] : [NSColor secondaryLabelColor];
        NSColor *bg = selected ? [NSColor colorWithRed:0.31 green:0.56 blue:1.0 alpha:1.0] : [NSColor clearColor];
        b.attributedTitle = [[NSAttributedString alloc] initWithString:b.title attributes:@{
            NSFontAttributeName: b.font,
            NSForegroundColorAttributeName: fg
        }];
        b.wantsLayer = YES;
        b.layer.backgroundColor = bg.CGColor;
        b.layer.cornerRadius = 5.0;
    }
}

- (BOOL)downloadFilter:(RDDownloadFilter)filter includesState:(DownloadJobState)state {
    switch (filter) {
        case RDDownloadFilterAll: return YES;
        case RDDownloadFilterActive:
            return state == DownloadJobStateQueued || state == DownloadJobStateRunning ||
                   state == DownloadJobStatePaused || state == DownloadJobStateCancelling;
        case RDDownloadFilterSucceeded:
            return state == DownloadJobStateCompleted;
        case RDDownloadFilterFailed:
            return state == DownloadJobStateFailed || state == DownloadJobStateInterrupted ||
                   state == DownloadJobStateCancelled;
    }
    return NO;
}

- (NSArray<DownloadJob *> *)sortedDownloadJobsForFilter:(RDDownloadFilter)filter {
    NSArray<DownloadJob *> *all = self.downloadManager.allJobs ?: @[];
    NSMutableArray<DownloadJob *> *filtered = [NSMutableArray array];
    for (DownloadJob *job in all) {
        if ([self downloadFilter:filter includesState:job.state]) [filtered addObject:job];
    }
    [filtered sortUsingComparator:^NSComparisonResult(DownloadJob *a, DownloadJob *b) {
        NSInteger activeA = [self downloadFilter:RDDownloadFilterActive includesState:a.state] ? 0 : 1;
        NSInteger activeB = [self downloadFilter:RDDownloadFilterActive includesState:b.state] ? 0 : 1;
        if (activeA != activeB) return activeA < activeB ? NSOrderedAscending : NSOrderedDescending;
        // 活动/非活动分组后，最近速率样本在前；没有样本时按入队时间倒序，
        // 最后用 identifier 做稳定 tie-breaker。
        NSDate *da = a.lastRateSampleDate ?: a.enqueuedAt ?: [NSDate distantPast];
        NSDate *db = b.lastRateSampleDate ?: b.enqueuedAt ?: [NSDate distantPast];
        NSComparisonResult dateCmp = [db compare:da];
        if (dateCmp != NSOrderedSame) return dateCmp;
        return [b.identifier compare:a.identifier];
    }];
    return filtered;
}

- (void)refreshDownloadRecency:(NSTimer *)timer {
    // 只重绘可见行，不整表 reload（避免闪烁/滚动跳动）。
    [self scheduleDownloadsRefresh];
}

- (BOOL)shouldWeakenJob:(DownloadJob *)job {
    // enqueuedAt 必须是真实 NSDate；旧记录或外部注入的字符串不得让时间比较崩溃。
    if (![job.enqueuedAt isKindOfClass:[NSDate class]]) return NO;
    if ([job.identifier isEqualToString:self.downloadManager.latestEnqueuedJobIdentifier]) return NO;
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:job.enqueuedAt];
    return age >= 0 && age < 600.0;
}

- (void)layoutDownloadsTable {
    if (!self.downloadsTable || !self.downloadsScrollView || !self.window) return;
    // 不依赖 autoresizing 的滞后值：直接用窗口内容尺寸算出滚动区与表格尺寸，
    // 保证表格宽度恒等于可视宽度、永远不会出现横向内容。
    NSRect content = self.window.contentView.bounds;
    CGFloat pageWidth = MAX(1.0, NSWidth(content));
    CGFloat pageHeight = MAX(1.0, NSHeight(content));
    NSRect scrollFrame = self.downloadsScrollView.frame;
    scrollFrame.origin = NSMakePoint(24.0, 44.0);
    scrollFrame.size = NSMakeSize(MAX(1.0, pageWidth - 48.0), MAX(1.0, pageHeight - 200.0));
    self.downloadsScrollView.frame = scrollFrame;

    NSRect visible = self.downloadsScrollView.contentView.bounds;
    CGFloat width = MAX(1.0, NSWidth(visible));
    CGFloat height = MAX(1.0, NSHeight(visible));
    self.downloadsTable.frame = NSMakeRect(0, 0, width, height);
    self.downloadsTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    for (NSTableColumn *column in self.downloadsTable.tableColumns) {
        column.minWidth = MIN(column.minWidth, width);
        column.maxWidth = width;
        column.width = width;
    }
}

// 高频进度回调合并：只在需要时重建可见行，避免每帧 reloadData 造成滚动位置
// 跳回顶部、选中丢失与闪烁。页面隐藏时只记脏，重新进入时立即全量同步。
- (void)scheduleDownloadsRefresh {
    if (!self.downloadsTable) return;
    if (self.downloadsPage.hidden) { self.downloadsListDirtyWhileHidden = YES; return; }
    if (self.downloadsRefreshTimer) return;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(applyDownloadsRefresh:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.downloadsRefreshTimer = timer;
}

- (void)applyDownloadsRefresh:(NSTimer *)timer {
    self.downloadsRefreshTimer = nil;
    [self applyDownloadsRefreshNow];
}

- (void)applyDownloadsRefreshNow {
    if (!self.downloadsTable) return;
    if (self.downloadsPage.hidden) { self.downloadsListDirtyWhileHidden = YES; return; }
    [self layoutDownloadsTable];
    NSArray<DownloadJob *> *jobs = [self sortedDownloadJobsForFilter:self.downloadFilter];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:jobs.count];
    for (DownloadJob *job in jobs) [identifiers addObject:job.identifier ?: @""];
    BOOL sameRows = [identifiers isEqualToArray:self.downloadsRenderedIdentifiers ?: @[]];
    if (sameRows && jobs.count) {
        // 行集合与顺序未变：只重建当前表格已有的单元格内容，保留滚动位置与选中行。
        NSInteger rowCount = self.downloadsTable.numberOfRows;
        if (rowCount > 0) {
            [self.downloadsTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)rowCount)]
                                           columnIndexes:[NSIndexSet indexSetWithIndex:0]];
        }
    } else if (!sameRows) {
        // 行集合/筛选归属变化（如下载中→已完成、失败进 “已失败”）：整表重建，
        // 但按 identifier 恢复选中、按可视原点恢复滚动位置，不让列表跳动。
        NSString *selectedIdentifier = nil;
        NSInteger selectedRow = self.downloadsTable.selectedRow;
        if (selectedRow >= 0 && selectedRow < (NSInteger)self.downloadsRenderedIdentifiers.count)
            selectedIdentifier = self.downloadsRenderedIdentifiers[(NSUInteger)selectedRow];
        NSPoint scrollOrigin = self.downloadsScrollView.documentVisibleRect.origin;
        self.downloadsRenderedIdentifiers = identifiers;
        [self.downloadsTable reloadData];
        if (selectedIdentifier) {
            NSInteger restored = [identifiers indexOfObject:selectedIdentifier];
            if (restored != NSNotFound) [self.downloadsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)restored] byExtendingSelection:NO];
        }
        [self.downloadsTable scrollPoint:scrollOrigin];
    }
    self.downloadsListDirtyWhileHidden = NO;
    self.downloadsEmptyLabel.hidden = jobs.count != 0;
    [self layoutDownloadsEmptyLabel];
    [self updateDownloadsStatusLabel];
}

// 全量同步：进入页面、切换筛选、清空记录、新增任务时立即调用。
- (void)refreshDownloadsList {
    [self layoutDownloadsTable];
    NSArray<DownloadJob *> *jobs = [self sortedDownloadJobsForFilter:self.downloadFilter];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:jobs.count];
    for (DownloadJob *job in jobs) [identifiers addObject:job.identifier ?: @""];
    NSString *selectedIdentifier = nil;
    NSInteger selectedRow = self.downloadsTable.selectedRow;
    if (selectedRow >= 0 && selectedRow < (NSInteger)self.downloadsRenderedIdentifiers.count)
        selectedIdentifier = self.downloadsRenderedIdentifiers[(NSUInteger)selectedRow];
    self.downloadsRenderedIdentifiers = identifiers;
    [self.downloadsTable reloadData];
    if (selectedIdentifier) {
        NSInteger restored = [identifiers indexOfObject:selectedIdentifier];
        if (restored != NSNotFound) [self.downloadsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)restored] byExtendingSelection:NO];
    }
    self.downloadsListDirtyWhileHidden = NO;
    self.downloadsEmptyLabel.hidden = jobs.count != 0;
    [self layoutDownloadsEmptyLabel];
    [self updateDownloadsStatusLabel];
}

- (void)updateDownloadsStatusLabel {
    NSArray<DownloadJob *> *all = self.downloadManager.allJobs ?: @[];
    NSUInteger active = 0, completed = 0, failed = 0;
    for (DownloadJob *job in all) {
        if ([self downloadFilter:RDDownloadFilterActive includesState:job.state]) active++;
        else if (job.state == DownloadJobStateCompleted) completed++;
        else if ([self downloadFilter:RDDownloadFilterFailed includesState:job.state]) failed++;
    }
    NSString *filterName = @[@"全部", @"下载中", @"已成功", @"已失败"][self.downloadFilter];
    if (all.count == 0) {
        self.downloadsStatusLabel.stringValue = [NSString stringWithFormat:@"%@ · 共 0 个任务", filterName];
    } else {
        self.downloadsStatusLabel.stringValue = [NSString stringWithFormat:@"%@ · 共 %lu 个任务（下载中 %lu / 已完成 %lu / 已失败 %lu）", filterName, (unsigned long)all.count, (unsigned long)active, (unsigned long)completed, (unsigned long)failed];
    }
}

- (NSString *)stateLabelForJob:(DownloadJob *)job {
    switch (job.state) {
        case DownloadJobStateQueued: return @"排队中";
        case DownloadJobStateRunning: return @"下载中";
        case DownloadJobStatePaused: return @"已暂停";
        case DownloadJobStateCancelling: return @"取消中";
        case DownloadJobStateCancelled: return @"已取消";
        case DownloadJobStateFailed: return @"失败";
        case DownloadJobStateCompleted: return @"已完成";
        case DownloadJobStateInterrupted: return @"已中断";
    }
    return @"未知";
}

- (NSString *)metricsStringForJob:(DownloadJob *)job {
    NSMutableString *s = [NSMutableString string];
    NSString *transferred = [self formatBytes:(double)job.transferredBytes];
    NSString *total = job.expectedContentLength > 0 ? [self formatBytes:(double)job.expectedContentLength] : @"大小未知";
    [s appendFormat:@"%@ / %@", transferred, total];
    if (job.bytesPerSecond > 0 && job.state == DownloadJobStateRunning) {
        [s appendFormat:@"    %@/s", [self formatBytes:job.bytesPerSecond]];
    }
    NSString *pct = (job.expectedContentLength > 0) ? [NSString stringWithFormat:@"%.0f%%", job.progress * 100.0]
                                                    : (job.state == DownloadJobStateCompleted ? @"100%" : @"—");
    [s appendFormat:@"    %@", pct];
    return s;
}

- (DownloadJob *)downloadJobForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    for (DownloadJob *job in self.downloadManager.allJobs) {
        if ([job.identifier isEqual:identifier]) return job;
    }
    return nil;
}

- (RDDownloadRowCellView *)cellViewForSender:(NSView *)sender {
    NSView *v = sender;
    while (v && ![v isKindOfClass:[RDDownloadRowCellView class]]) v = v.superview;
    return (RDDownloadRowCellView *)v;
}

- (void)downloadsPauseTapped:(NSButton *)sender {
    RDDownloadRowCellView *cell = [self cellViewForSender:sender];
    DownloadJob *job = [self downloadJobForIdentifier:cell.jobIdentifier];
    if (job && job.state == DownloadJobStateRunning) [self.downloadManager pauseJob:job.identifier];
}

- (void)downloadsResumeTapped:(NSButton *)sender {
    RDDownloadRowCellView *cell = [self cellViewForSender:sender];
    DownloadJob *job = [self downloadJobForIdentifier:cell.jobIdentifier];
    if (job && (job.state == DownloadJobStatePaused || job.state == DownloadJobStateInterrupted)) [self.downloadManager resumeJob:job.identifier];
}

- (void)downloadsRetryTapped:(NSButton *)sender {
    RDDownloadRowCellView *cell = [self cellViewForSender:sender];
    DownloadJob *job = [self downloadJobForIdentifier:cell.jobIdentifier];
    if (!job || job.state != DownloadJobStateFailed) return;
    if (job.sourcePageURL.length || job.referer.length) [self.linkRefresher refreshJobManually:job.identifier];
    else if (job.destinationURL) [self.downloadManager restartFailedJobWithIdentifier:job.identifier sourceURL:job.sourceURL expectedLength:0 etag:nil lastModified:nil acceptRanges:NO];
    else [self.downloadManager enqueueItemWithSourceURL:job.sourceURL folder:self.downloadSettings.downloadDirectoryURL preferredName:job.fileName sourcePageURL:nil resourceKind:job.resourceKind expectedLength:0];
}

- (void)downloadsCancelTapped:(NSButton *)sender {
    RDDownloadRowCellView *cell = [self cellViewForSender:sender];
    DownloadJob *job = [self downloadJobForIdentifier:cell.jobIdentifier];
    if (job && job.state != DownloadJobStateCancelled && job.state != DownloadJobStateCompleted) [self.downloadManager cancelJob:job.identifier];
}

- (void)downloadsRevealTapped:(NSButton *)sender {
    RDDownloadRowCellView *cell = [self cellViewForSender:sender];
    DownloadJob *job = [self downloadJobForIdentifier:cell.jobIdentifier];
    if (job.destinationURL) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[job.destinationURL]];
}

- (void)downloadSelected:(id)sender {
    NSInteger row = self.table.selectedRow;
    NSArray<DetectedMedia *> *visible = self.visibleMedia;
    if (row < 0 || row >= (NSInteger)visible.count) { self.statusNote.stringValue = @"请先选择一个资源（列表中点击一行）"; return; }
    DetectedMedia *media = self.currentDownloadMedia ?: visible[(NSUInteger)row];
    NSURL *source = [NSURL URLWithString:media.mediaURL ?: @""];
    if (!source || !source.host.length) { self.statusNote.stringValue = @"该资源没有可下载地址"; return; }
    NSURL *folder = self.downloadSettings.downloadDirectoryURL;
    NSString *name = media.title.length ? media.title : source.lastPathComponent;
    // 标题清洗 + 扩展名保障：标题含 `/` 会让落盘目标变成不存在的嵌套目录；
    // 标题以站点域名结尾（如 .org）会被误判为已有扩展名而不补 .mp4。
    name = [DownloadJob fileNameByEnsuringMediaExtension:name
                                       fallbackExtension:(media.format.length ? media.format : @"mp4")];
    DownloadResourceKind kind = media.resourceKind == RDResourceKindImage ? DownloadResourceImage : (media.resourceKind == RDResourceKindManifest ? DownloadResourceManifest : DownloadResourceVideo);
    DownloadJob *job = [self.downloadManager enqueueItemWithSourceURL:source folder:folder preferredName:name sourcePageURL:media.sourcePageURL resourceKind:kind expectedLength:media.sizeBytes];
    // 最新任务由 DownloadManager 持久化维护。
    // 界面选中的是具体档位（HLS 子清单）时，下载计划同时保留来源主清单：
    // 分离音轨只有从 master 才能解析；直接下子清单会让有声视频变无声。
    if (kind == DownloadResourceManifest && [media.format isEqualToString:@"hls"]
        && media.parentMediaURL.length && ![media.parentMediaURL isEqual:media.mediaURL])
        job.streamMasterURL = media.parentMediaURL;
    job.resourceTitle = media.title; job.qualityHint = media.quality;
    self.statusNote.stringValue = job.state == DownloadJobStateFailed ? [NSString stringWithFormat:@"无法下载：%@",job.errorText ?: @"未知错误"] : @"已提交下载任务";
    [self refreshDownloadsList];
}

#pragma mark - 下载列表表格数据源与委托

- (NSInteger)numberOfRowsInDownloadsTable {
    return (NSInteger)([self sortedDownloadJobsForFilter:self.downloadFilter].count);
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    if (tableView == self.downloadsTable) {
        return [[RDDownloadRowView alloc] initWithFrame:NSMakeRect(0.0, 0.0,
                                                                    NSWidth(tableView.bounds),
                                                                    tableView.rowHeight)];
    }
    return nil;
}

- (NSView *)downloadsTableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray<DownloadJob *> *jobs = [self sortedDownloadJobsForFilter:self.downloadFilter];
    if (row < 0 || row >= (NSInteger)jobs.count) return nil;
    DownloadJob *job = jobs[(NSUInteger)row];
    RDDownloadRowCellView *cell = [[RDDownloadRowCellView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(tableView.bounds), tableView.rowHeight)];
    [cell configureWithJob:job width:NSWidth(tableView.bounds) app:self];
    return cell;
}

#pragma mark - 下载

// 供 NSTableView 数据源统一分发：self.table 为探测结果，self.downloadsTable 为下载列表
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.downloadsTable) return [self numberOfRowsInDownloadsTable];
    // 严格统一呈现：探索期间一行都不给（见 finishScanWithResult: 与
    // beginUnifiedPresentationForResult:），探索完成后由 commit 一次性呈现。
    if (self.explorationResultsSuppressed) return 0;
    return self.visibleMedia.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.downloadsTable) return [self downloadsTableView:tableView viewForTableColumn:tableColumn row:row];
    ResourceResultRowView *rowView = [[ResourceResultRowView alloc] initWithFrame:NSZeroRect];
    DetectedMedia *m = self.visibleMedia[(NSUInteger)row];
    [rowView configureWithMedia:m
                  durationHint:[self rowDurationHintForMedia:m]
                      sizeHint:[self rowSizeHintForMedia:m]];
    return rowView;
}

#pragma mark - 表格与回调

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.downloadsTable) {
        // NSTableRowView 自己也会在 selected 改变时重绘；显式刷新旧/新行，
        // 覆盖复用 cell、筛选切换和异步 reload 后 AppKit 未触发重绘的情况。
        NSTableView *table = self.downloadsTable;
        NSInteger selected = table.selectedRow;
        NSInteger visibleRows = table.numberOfRows;
        if (visibleRows > 0) {
            NSIndexSet *rows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)visibleRows)];
            for (NSInteger row = rows.firstIndex; row != NSNotFound; row = [rows indexGreaterThanIndex:(NSUInteger)row]) {
                NSTableRowView *rowView = [table rowViewAtRow:row makeIfNecessary:NO];
                if (rowView) [rowView setNeedsDisplay:YES];
            }
        }
        (void)selected;
        return;
    }
    if (self.restoringSelectionAfterReload) return;
    NSInteger row = self.table.selectedRow;
    NSArray<DetectedMedia *> *visible = self.visibleMedia;
    // 临时（非终态）结果已经先把列表显示出来时也允许看详情：列表可用就该能点，
    // 不必等到动态 WebKit 腿回来。
    BOOL listUsable = !self.scanning || self.previewShown;
    if (listUsable && row >= 0 && row < (NSInteger)visible.count) {
        [self configureDetailForMedia:visible[(NSUInteger)row]];
        self.statusNote.stringValue = @"已选中 · ⌘D 加入下载队列";
    } else if (row < 0) {
        [self showDetailEmpty];
    }
}

- (void)downloadManagerDidChange:(id)manager { [self updateDownloadPauseButton]; dispatch_async(dispatch_get_main_queue(), ^{ [self scheduleDownloadsRefresh]; }); }
- (void)downloadManager:(id)manager didUpdateJob:(DownloadJob *)job {
    if (manager != self.downloadManager || !job) return;
    if (manager == self.downloadManager) {
        [self updateDownloadPauseButton];
        dispatch_async(dispatch_get_main_queue(), ^{ [self scheduleDownloadsRefresh]; });
    }
}
#pragma mark - 下载列表格式化

- (NSString *)formatBytes:(double)bytes {
    if (!isfinite(bytes) || bytes < 0 || bytes >= (double)LLONG_MAX) return @"—";
    return RDFormatByteCount((int64_t)bytes);
}

- (NSString *)formatRemainingSeconds:(NSInteger)secs {
    if (secs < 0) return @"—";
    NSInteger m = secs / 60, s = secs % 60, h = m / 60; m = m % 60;
    return h > 0 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s]
                 : [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

@end


@implementation RDDownloadRowCellView

// 视图表格默认把整个 cell 折叠成一个没有文本的 AXCell，UI 自动化既读不到文件名，
// 也无法逐项核对。这里让 cell 退化为容器，并把文件名标签作为独立可访问元素暴露。
- (BOOL)isAccessibilityElement { return NO; }

- (NSArray *)accessibilityChildren {
    NSMutableArray *children = [NSMutableArray array];
    if (self.fileNameLabel) [children addObject:self.fileNameLabel];
    if (self.stateLabel) [children addObject:self.stateLabel];
    if (self.metricsLabel) [children addObject:self.metricsLabel];
    if (self.errorLabel && self.errorLabel.stringValue.length) [children addObject:self.errorLabel];
    return children;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.fileNameLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.fileNameLabel.bezeled = NO; self.fileNameLabel.drawsBackground = NO; self.fileNameLabel.editable = NO;
        self.fileNameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        self.fileNameLabel.textColor = [NSColor labelColor];
        self.fileNameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.textField = self.fileNameLabel;   // 让 NSTableCellView 的辅助功能直接暴露文件名
        [self addSubview:self.fileNameLabel];

        self.stateLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.stateLabel.bezeled = NO; self.stateLabel.drawsBackground = NO; self.stateLabel.editable = NO;
        self.stateLabel.font = [NSFont systemFontOfSize:11];
        self.stateLabel.textColor = [NSColor secondaryLabelColor];
        [self addSubview:self.stateLabel];

        self.errorLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.errorLabel.bezeled = NO; self.errorLabel.drawsBackground = NO; self.errorLabel.editable = NO;
        self.errorLabel.font = [NSFont systemFontOfSize:10];
        self.errorLabel.textColor = [NSColor secondaryLabelColor];
        self.errorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.errorLabel];

        self.metricsLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.metricsLabel.bezeled = NO; self.metricsLabel.drawsBackground = NO; self.metricsLabel.editable = NO;
        self.metricsLabel.font = [NSFont systemFontOfSize:11];
        self.metricsLabel.textColor = [NSColor secondaryLabelColor];
        [self addSubview:self.metricsLabel];

        self.progressView = [[RDThinProgressView alloc] initWithFrame:NSZeroRect];
        [self addSubview:self.progressView];

        self.pauseButton = [self actionButtonWithTitle:@"暂停"];
        self.resumeButton = [self actionButtonWithTitle:@"继续"];
        self.retryButton = [self actionButtonWithTitle:@"重试"];
        self.cancelButton = [self actionButtonWithTitle:@"取消"];
        self.revealButton = [self actionButtonWithTitle:@"显示文件"];
        for (NSButton *b in @[self.pauseButton, self.resumeButton, self.retryButton, self.cancelButton, self.revealButton]) {
            [self addSubview:b];
        }
    }
    return self;
}

- (NSButton *)actionButtonWithTitle:(NSString *)title {
    NSButton *b = [NSButton buttonWithTitle:title target:nil action:nil];
    b.bordered = NO;
    b.font = [NSFont systemFontOfSize:11];
    b.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName:b.font, NSForegroundColorAttributeName:[NSColor systemGrayColor]}];
    return b;
}

- (void)configureWithJob:(DownloadJob *)job width:(CGFloat)width app:(id)app {
    self.jobIdentifier = job.identifier;
    self.lastJob = job;
    self.lastApp = app;
    NSColor *paperColor = [NSColor colorWithSRGBRed:0.980 green:0.973 blue:0.957 alpha:1.0];
    self.wantsLayer = YES;
    self.layer.backgroundColor = paperColor.CGColor;

    // 文件名直接作为主文本，不渲染资源类型称号或徽章。
    self.fileNameLabel.stringValue = job.fileName ?: @"未命名任务";
    // 显式同步辅助功能值，保证 UI 自动化能读到真实文件名。
    self.fileNameLabel.accessibilityValue = self.fileNameLabel.stringValue;
    self.fileNameLabel.accessibilityLabel = self.fileNameLabel.stringValue;
    self.accessibilityValue = self.fileNameLabel.stringValue;
    self.fileNameLabel.frame = NSMakeRect(12, 50, MAX(80, width - 12 - 200), 18);
    self.stateLabel.stringValue = [app stateLabelForJob:job];
    self.stateLabel.frame = NSMakeRect(12, 34, 90, 16);
    self.errorLabel.stringValue = job.state == DownloadJobStateFailed ? (job.errorText.length ? job.errorText : @"下载失败") : @"";
    self.errorLabel.frame = NSMakeRect(110, 34, MAX(80, width - 110 - 200), 16);

    // 操作按钮（右侧）
    CGFloat bx = width - 12;
    NSArray<NSButton *> *visibleButtons = [self visibleButtonsForJob:job app:app];
    for (NSButton *b in visibleButtons) {
        [b sizeToFit];
        NSRect bf = b.frame;
        bx -= bf.size.width;
        bf.origin.x = bx;
        bf.origin.y = 40;
        b.frame = bf;
        bx -= 10;
        b.target = app;
        if (b == self.pauseButton) b.action = @selector(downloadsPauseTapped:);
        else if (b == self.resumeButton) b.action = @selector(downloadsResumeTapped:);
        else if (b == self.retryButton) b.action = @selector(downloadsRetryTapped:);
        else if (b == self.cancelButton) b.action = @selector(downloadsCancelTapped:);
        else if (b == self.revealButton) b.action = @selector(downloadsRevealTapped:);
    }
    // 隐藏未使用的按钮
    for (NSButton *b in @[self.pauseButton, self.resumeButton, self.retryButton, self.cancelButton, self.revealButton]) {
        b.hidden = ![visibleButtons containsObject:b];
    }

    // 进度条
    self.progressView.frame = NSMakeRect(12, 30, width - 24, 3);
    double progress = isfinite(job.progress) ? MAX(0.0, MIN(1.0, job.progress)) : 0.0;
    BOOL unknownTotal = job.expectedContentLength <= 0;
    if (job.state == DownloadJobStateQueued) progress = 0.0;
    else if (job.state == DownloadJobStateCompleted) progress = 1.0;
    self.progressView.progress = progress;
    self.progressView.indeterminate = unknownTotal && job.state == DownloadJobStateRunning;
    BOOL weakened = [app shouldWeakenJob:job];
    NSColor *primary = weakened ? [NSColor tertiaryLabelColor] : [NSColor labelColor];
    NSColor *secondary = weakened ? [NSColor colorWithWhite:0.55 alpha:0.55] : [NSColor secondaryLabelColor];
    self.fileNameLabel.textColor = primary;
    self.stateLabel.textColor = secondary;
    self.metricsLabel.textColor = secondary;
    self.errorLabel.textColor = secondary;
    self.pauseButton.alphaValue = weakened ? 0.55 : 1.0;
    self.resumeButton.alphaValue = weakened ? 0.55 : 1.0;
    self.retryButton.alphaValue = weakened ? 0.55 : 1.0;
    self.cancelButton.alphaValue = weakened ? 0.55 : 1.0;
    self.revealButton.alphaValue = weakened ? 0.55 : 1.0;
    self.progressView.alphaValue = weakened ? 0.45 : 1.0;

    // 指标文字
    self.metricsLabel.stringValue = [app metricsStringForJob:job];
    self.metricsLabel.frame = NSMakeRect(12, 10, width - 24, 16);
    // 逐项同步辅助功能值，便于 UI 自动化核对“状态 / 指标 / 失败原因”的实时变化。
    self.stateLabel.accessibilityValue = self.stateLabel.stringValue;
    self.metricsLabel.accessibilityValue = self.metricsLabel.stringValue;
    self.errorLabel.accessibilityValue = self.errorLabel.stringValue;
}

// 窗口缩放时按新宽度重排：NSTableView 不会因 resize 重新询问数据源，
// 行视图必须自己用记住的任务/宿主重跑一次布局（纯本地计算，无网络/无状态写入）。
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (self.lastJob && self.lastApp && newSize.width > 0) {
        [self configureWithJob:self.lastJob width:newSize.width app:self.lastApp];
    }
}

- (NSArray<NSButton *> *)visibleButtonsForJob:(DownloadJob *)job app:(id)app {
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    switch (job.state) {
        case DownloadJobStateRunning:
            [buttons addObject:self.pauseButton];
            [buttons addObject:self.cancelButton];
            break;
        case DownloadJobStatePaused:
        case DownloadJobStateInterrupted:
            [buttons addObject:self.resumeButton];
            [buttons addObject:self.cancelButton];
            break;
        case DownloadJobStateQueued:
        case DownloadJobStateCancelling:
            [buttons addObject:self.cancelButton];
            break;
        case DownloadJobStateFailed:
            [buttons addObject:self.retryButton];
            [buttons addObject:self.cancelButton];
            break;
        case DownloadJobStateCompleted:
            [buttons addObject:self.revealButton];
            break;
        case DownloadJobStateCancelled:
            break;
    }
    // 已完成但文件不存在时仍可显示目标位置
    if (job.state == DownloadJobStateCompleted || job.state == DownloadJobStateFailed ||
        job.state == DownloadJobStateInterrupted || job.state == DownloadJobStateCancelled) {
        if (![buttons containsObject:self.revealButton] && job.destinationURL) [buttons addObject:self.revealButton];
    }
    return buttons;
}

@end

// 崩溃现场必须同步落盘（RDLogWriteSync）：常规写走异步队列，进程随即结束时
// 队列里排队的行会全部丢失 —— 实测积压 4000 条后抛异常，handler 曾一条都留不下。
static void RDUncaughtExceptionHandler(NSException *exception) {
    RDLogFlush();   // 先排空积压的常规日志，再同步写崩溃现场，时间线才完整
    RDLogWriteSync(@"crash", @"未捕获异常 %@: %@", exception.name, exception.reason);
    NSArray *frames = exception.callStackSymbols;
    NSUInteger shown = MIN((NSUInteger)10, frames.count);
    for (NSUInteger i = 2; i < shown; i++) RDLogWriteSync(@"crash", @"  %@", frames[i]);
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    RDLogInstallCrashHandlers();   // SIGSEGV/SIGABRT/SIGBUS/… 硬崩溃兜底（异步信号安全落盘）
    NSSetUncaughtExceptionHandler(RDUncaughtExceptionHandler);
    RDLogRotateIfNeeded();
    RDLogWrite(@"app", @"启动 DISPLAY_VERSION=%@ CODE_LINES=%ld FIX_ROUND=%ld", RD_GENERATED_VERSION_STRING, (long)RD_GENERATED_CODE_LINES, (long)RD_GENERATED_FIX_ROUND);
    NSApplication *app = [NSApplication sharedApplication];
    ResourceDetectorAppDelegate *delegate = [ResourceDetectorAppDelegate new];
    app.delegate = delegate;
    [app run];
} return 0; }
