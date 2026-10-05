//
//  RDWatchAgentController.m — 「Miliu追更助手」全部运行逻辑
//
//  契约依据：Docs/WATCH-V1-CONTRACT.md
//    §1  fetchedKeys 口径：结果媒体中 resourceKind 为视频或清单（不含图片）的
//        [DetectedMedia dedupKeyForURL:mediaURL]，去重、保持发现顺序。
//    §3.1 唤起顺序：先 NSWorkspace 打开Miliu主 App，再 post 分布式通知
//        com.sevenzz.miliu.openAndScan，userInfo { @"pageURL": ... }（原样传递）。
//    §3.2 bundle id com.sevenzz.resource-detector.watchlist；可执行名
//        SevenZZWatchAgent；静音时段 "HH:mm-HH:mm"（跨零点合法）/ "off"，
//        默认 "00:00-08:00"，解析失败按默认处理。
//    §3.3 偏好键：MiliuWatchNotifyEnabled（BOOL 默认 YES）、
//        MiliuWatchQuietHours（NSString 默认 "00:00-08:00"）。
//    §3.5 菜单结构（预览稿第②节）：头部状态行 / 未读条目区（点按=标已读+唤起）/
//        立即全部重探 / 暂停·恢复 / 管理观察列表… / 退出助手；角标=未读总数。
//
//  探测循环：60s tick → dueEntriesBeforeDate: 取到期页 → 逐页静默探测
//  （RDHybridPageProbe，主线程发起、并发 1、页超时 45s 看门狗兜底——动态腿自身
//  hardTimeout=45 与 WebProbe 一致）→ fetchedKeys → recordProbeResult 记账 →
//  新增>0 且通知开且非静音 → UN 通知（identifier=条目 identifier，防重复弹）。
//
//  通知点按语义（二选一，已选前者并在交回说明）：didReceive 收到点按的瞬间先
//  markPendingRead，再按 §3.1 顺序唤起Miliu；菜单未读区每次打开都从 store 重建，
//  与该选择保持一致。
//
//  偏好读取：主 App 的 PreferencesStore.shared 用其自身 standardUserDefaults
//  （bundle id com.sevenzz.resource-detector）。助手 bundle id 不同，
//  standardUserDefaults 读不到主 App 域，故按主 App bundle id 作 suite 读取
//  （双方均非沙盒，直接映射 ~/Library/Preferences/com.sevenzz.resource-detector.plist）。
//

#import "RDWatchAgentController.h"

#import <UserNotifications/UserNotifications.h>

#import "RDWatchlistStore.h"
#import "DetectedMedia.h"
#import "RDHybridPageProbe.h"
#import "RDLog.h"

#pragma mark - 契约常量（WATCH-V1-CONTRACT §3.1 / §3.2 / §3.3）

static NSString * const RDDistOpenAndScan  = @"com.sevenzz.miliu.openAndScan";
static NSString * const RDDistWatchNow     = @"com.sevenzz.miliu.watchNow";
static NSString * const RDDistWatchService = @"com.sevenzz.miliu.watchService";
static NSString * const RDDistKeyPageURL   = @"pageURL";
static NSString * const RDDistKeyEnabled   = @"enabled";

static NSString * const RDPrefNotifyEnabled = @"MiliuWatchNotifyEnabled"; // BOOL，默认 YES
static NSString * const RDPrefQuietHours    = @"MiliuWatchQuietHours";   // NSString，默认 00:00-08:00
static NSString * const RDDefaultQuietHours = @"00:00-08:00";
static NSString * const RDQuietHoursOff     = @"off";

static NSString * const RDMainAppBundleID     = @"com.sevenzz.resource-detector";

static NSString * const RDWatchAgentErrorDomain = @"RDWatchAgentErrorDomain";
typedef NS_ENUM(NSInteger, RDWatchAgentErrorCode) {
    RDWatchAgentErrorInvalidURL = 1,
    RDWatchAgentErrorPageTimeout = 2,
};

// 60s tick（契约）；页超时 45s（与 WebProbe 动态腿硬超时一致）；
// 冷启动宽限：等主 App applicationDidFinishLaunching 注册分布式观察者后再投递。
static const NSTimeInterval RDTickIntervalSeconds = 60.0;
static const NSTimeInterval RDPageTimeoutSeconds = 45.0;
static const NSTimeInterval RDLaunchGraceSeconds = 1.0;
static const NSTimeInterval RDFirstTickDelaySeconds = 3.0;

#pragma mark - 小工具

/// 文本摘要：保头部加省略号；按组合字符序列截断，避免拆散 emoji/代理对。
static NSString *RDSummarizeText(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return text;
    NSRange endRange = [text rangeOfComposedCharacterSequenceAtIndex:limit];
    NSString *head = endRange.location > 0 ? [text substringToIndex:endRange.location] : text;
    return [head stringByAppendingString:@"…"];
}

/// "HH" / "HH:mm" → 当日分钟数；非法（越界/非数字/段数不对）返回 -1。
static NSInteger RDMinutesFromHHmm(NSString *text) {
    if (text.length == 0) return -1;
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    if (parts.count != 2) return -1;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSString *part in parts) {
        if (part.length == 0 || part.length > 2) return -1;
        if ([[part componentsSeparatedByCharactersInSet:digits] componentsJoinedByString:@""].length != 0) return -1;
    }
    NSInteger h = parts[0].integerValue;
    NSInteger m = parts[1].integerValue;
    if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
    return h * 60 + m;
}

/// 契约 §1：fetchedKeys = 视频/清单媒体的 dedupKey（不含图片），去重、保持发现顺序。
static NSArray<NSString *> *RDFetchedKeysFromMedia(NSArray<DetectedMedia *> *media) {
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for (DetectedMedia *m in media) {
        if (m.resourceKind != RDResourceKindVideo && m.resourceKind != RDResourceKindManifest) continue;
        NSString *key = [DetectedMedia dedupKeyForURL:m.mediaURL];
        if (key.length) [keys addObject:key];
    }
    return keys.array;
}

#pragma mark - 私有状态（全部只在主线程读写）

@interface RDWatchAgentController () <UNUserNotificationCenterDelegate, NSMenuDelegate>

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, strong) RDHybridPageProbe *hybridProbe;   // 单实例复用；动态腿内部串行槽位由其 pump 保证
@property (nonatomic, strong) NSUserDefaults *watchDefaults;    // 主 App suite（见文件头说明）

// 探测状态机：一次循环内逐页串行（并发 1），completion/看门狗谁先到谁结算。
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL cycleInFlight;
@property (nonatomic, assign) BOOL cycleRestartRequested;        // 循环中又收到立即重探：循环结束后补一轮
@property (nonatomic, strong) NSMutableArray<RDWatchlistEntry *> *cycleQueue;
@property (nonatomic, copy) NSString *currentEntryID;
@property (nonatomic, strong) id currentProbeToken;             // RDHybridPageProbe 取消凭据
@property (nonatomic, assign) BOOL currentFinished;
@property (nonatomic, strong) NSTimer *pageWatchdog;

@end

@implementation RDWatchAgentController

#pragma mark - 生命周期（RDWatchAgentMain 装配后由 NSApplication 驱动）

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self setUpWatchDefaults];
    // 复用离屏静默探测：RDHybridPageProbe（实现 ZZDiscoveryPageProbing），
    // 内部静态腿 + 动态腿（WebProbe 默认 RDWebViewProbeLoader → RDDefaultWebViewFactory
    // 在主线程创建 NSZeroRect 离屏 WKWebView），动态腿硬超时 45s。
    self.hybridProbe = [[RDHybridPageProbe alloc] initWithPolicy:[URLPolicy new]];
    [self setUpStatusItem];
    [self registerDistributedObservers];
    [self requestNotificationAuthorization];
    [self registerTickTimer];
    [self updateButtonBadge];
    RDLogWrite(@"app", @"追更助手：启动完成（bundle=%@）", [NSBundle mainBundle].bundleIdentifier ?: @"-");
    // 启动即对齐开机自启偏好（2026-10-03 集成补全：App 侧拉起后由此完成首次注册）：
    // 偏好开且未注册 → 自注册；bootstrap 会拉起 launchd 实例，随后本实例退出让位，
    // 保证任何路径下助手单实例。
    [self alignLoginItemOnLaunch];
    // 启动即先跑一轮（延迟 3s 留出托盘/授权时间；tick 内部尊重暂停与在飞状态）
    __weak RDWatchAgentController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RDFirstTickDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf tick];
    });
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self tearDownRuntimeState];
}

- (void)dealloc {
    [self tearDownRuntimeState];
}

- (void)tearDownRuntimeState {
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    [self.pageWatchdog invalidate];
    self.pageWatchdog = nil;
    if (self.hybridProbe) [self.hybridProbe cancelProbe:self.currentProbeToken];
    self.currentProbeToken = nil;
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 偏好（契约 §3.3：读主 App suite 域 + 同值默认注册）

- (void)setUpWatchDefaults {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:RDMainAppBundleID];
    [suite registerDefaults:@{
        RDPrefNotifyEnabled : @YES,
        RDPrefQuietHours    : RDDefaultQuietHours,
    }];
    self.watchDefaults = suite;
}

#pragma mark - 菜单栏（契约 §3.5 + 预览稿第②节）

- (void)setUpStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"追更";
    self.statusItem.button.toolTip = @"Miliu追更助手";
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;          // 每次打开前 menuNeedsUpdate 重建，未读区/状态行总与 store 一致
    menu.autoenablesItems = NO;
    self.menu = menu;
    self.statusItem.menu = menu;
    [self rebuildMenu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self updateButtonBadge];
    [self rebuildMenu];
}

- (void)rebuildMenu {
    if (!self.menu) return;
    [self.menu removeAllItems];

    RDWatchlistStore *store = [RDWatchlistStore sharedStore];
    NSArray<RDWatchlistEntry *> *entries = store.entries;

    // ── 头部状态行 ──
    NSString *header;
    if (self.paused) {
        header = [NSString stringWithFormat:@"已暂停 · %lu 个页面", (unsigned long)entries.count];
    } else if (entries.count == 0) {
        header = @"追更中 · 暂无观察页面";
    } else {
        header = [NSString stringWithFormat:@"追更中 · %lu 个页面 · 下次 %@",
                  (unsigned long)entries.count, [self nextProbeCountdownText]];
    }
    NSMenuItem *headerItem = [self.menu addItemWithTitle:header action:nil keyEquivalent:@""];
    headerItem.enabled = NO;

    [self.menu addItem:NSMenuItem.separatorItem];

    // ── 未读条目区：条目标题 + 新增 N 个资源；点按 = 标已读 + 唤起Miliu（§3.1）──
    NSInteger unreadShown = 0;
    for (RDWatchlistEntry *entry in entries) {
        NSUInteger count = entry.pendingNewKeys.count;
        if (count == 0) continue;
        NSString *title = [NSString stringWithFormat:@"＋%lu 新资源 · %@",
                           (unsigned long)count, [self displayTitleForEntry:entry]];
        NSMenuItem *item = [self.menu addItemWithTitle:title action:@selector(openUnreadEntry:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = entry.identifier;
        item.toolTip = entry.pageURL;
        unreadShown++;
    }
    if (unreadShown == 0) {
        NSMenuItem *empty = [self.menu addItemWithTitle:@"无未读更新" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    }

    [self.menu addItem:NSMenuItem.separatorItem];

    // ── 立即全部重探 ──
    BOOL hasEnabled = NO;
    for (RDWatchlistEntry *entry in entries) if (entry.enabled) { hasEnabled = YES; break; }
    NSMenuItem *probeAll = [self.menu addItemWithTitle:@"立即全部重探" action:@selector(probeAllNow) keyEquivalent:@""];
    probeAll.target = self;
    probeAll.enabled = hasEnabled;

    // ── 暂停 / 恢复 ──
    NSString *pauseTitle = self.paused ? @"恢复探测" : @"暂停探测";
    NSMenuItem *pause = [self.menu addItemWithTitle:pauseTitle action:@selector(togglePaused:) keyEquivalent:@""];
    pause.target = self;

    // ── 管理观察列表…（唤起Miliu）──
    NSMenuItem *manage = [self.menu addItemWithTitle:@"管理观察列表…" action:@selector(openManagerInMainApp:) keyEquivalent:@""];
    manage.target = self;

    [self.menu addItem:NSMenuItem.separatorItem];

    // ── 退出助手（注销 SMAppService 并退出）──
    NSMenuItem *quit = [self.menu addItemWithTitle:@"退出助手" action:@selector(quitAssistant) keyEquivalent:@""];
    quit.target = self;
}

- (void)updateButtonBadge {
    if (!self.statusItem.button) return;
    NSInteger pending = [RDWatchlistStore sharedStore].totalPendingNewCount;
    // NSStatusItem 没有独立角标 API：以按钮标题内数字呈现（角标=totalPendingNewCount）
    self.statusItem.button.title = pending > 0
        ? [NSString stringWithFormat:@"追更 %ld", (long)pending]
        : @"追更";
}

- (NSString *)displayTitleForEntry:(RDWatchlistEntry *)entry {
    NSString *raw = entry.title.length ? entry.title : entry.pageURL;
    return RDSummarizeText(raw, 36);
}

/// 下次探测倒计时：全部启用条目中最近的 lastProbeAt + interval − now。
- (NSString *)nextProbeCountdownText {
    NSDate *now = [NSDate date];
    NSTimeInterval best = -1;
    for (RDWatchlistEntry *entry in [RDWatchlistStore sharedStore].entries) {
        if (!entry.enabled) continue;
        if (!entry.lastProbeAt) return @"即将探测";
        NSTimeInterval delta = [entry.lastProbeAt timeIntervalSinceDate:now] + entry.intervalMinutes * 60;
        if (delta <= 0) return @"即将探测";
        if (best < 0 || delta < best) best = delta;
    }
    if (best < 0) return @"—";
    NSInteger total = (NSInteger)ceil(best);
    NSInteger h = total / 3600;
    NSInteger m = (total % 3600) / 60;
    NSInteger s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld 小时 %ld 分", (long)h, (long)m];
    if (m > 0) return [NSString stringWithFormat:@"%ld 分 %ld 秒", (long)m, (long)s];
    return [NSString stringWithFormat:@"%ld 秒", (long)s];
}

#pragma mark - 探测循环（60s tick；主线程；并发 1；页超时 45s）

- (void)registerTickTimer {
    __weak RDWatchAgentController *weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:RDTickIntervalSeconds repeats:YES block:^(NSTimer *t) {
        [weakSelf tick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.tickTimer = timer;
}

- (void)tick {
    if (self.paused || self.cycleInFlight) return;
    NSArray<RDWatchlistEntry *> *due = [[RDWatchlistStore sharedStore] dueEntriesBeforeDate:[NSDate date]];
    if (due.count == 0) {
        [self updateButtonBadge];
        return;
    }
    [self startCycleWithEntries:due];
}

/// 立即全部重探（菜单动作 / App 侧 watchNow）：显式触发不受暂停门限，暂停只挡自动 tick。
/// 循环已在飞时记一次补跑请求，当前循环结束（或被暂停截断）后补一轮。
- (void)probeAllNow {
    if (self.cycleInFlight) {
        self.cycleRestartRequested = YES;
        return;
    }
    NSMutableArray<RDWatchlistEntry *> *all = [NSMutableArray array];
    for (RDWatchlistEntry *entry in [RDWatchlistStore sharedStore].entries) {
        if (entry.enabled) [all addObject:[entry copy]];
    }
    if (all.count == 0) return;
    RDLogWrite(@"app", @"追更助手：立即全部重探 %lu 页", (unsigned long)all.count);
    [self startCycleWithEntries:all];
}

- (void)startCycleWithEntries:(NSArray<RDWatchlistEntry *> *)entries {
    self.cycleQueue = [entries mutableCopy];
    self.cycleInFlight = YES;
    [self probeNextEntry];
}

- (void)probeNextEntry {
    if (self.cycleQueue.count == 0) {
        self.cycleInFlight = NO;
        [self updateButtonBadge];
        if (self.cycleRestartRequested) {
            self.cycleRestartRequested = NO;
            [self probeAllNow];
        }
        return;
    }
    RDWatchlistEntry *entry = [[self.cycleQueue firstObject] copy];
    [self.cycleQueue removeObjectAtIndex:0];
    [self startProbeForEntry:entry];
}

- (void)startProbeForEntry:(RDWatchlistEntry *)entry {
    // WKWebView 会话只能主线程创建与投递（WebProbe.m NSAssert 约束），探测固定主线程发起
    NSAssert([NSThread isMainThread], @"追更助手：页面探测必须主线程发起（WKWebView 会话约束）");
    NSURL *url = [NSURL URLWithString:entry.pageURL];
    if (!url) {
        [self concludeCurrentPageWithEntry:entry
                                     media:nil
                                     error:[NSError errorWithDomain:RDWatchAgentErrorDomain
                                                               code:RDWatchAgentErrorInvalidURL
                                                           userInfo:@{NSLocalizedDescriptionKey: @"页面地址无效"}]];
        return;
    }
    self.currentEntryID = [entry.identifier copy];
    self.currentFinished = NO;

    __weak RDWatchAgentController *weakSelf = self;
    self.currentProbeToken = [self.hybridProbe probePageURL:url
        completion:^(NSArray<DetectedMedia *> * _Nullable media, NSError * _Nullable error) {
            // RDHybridPageProbe 的最终回调线程取决于最后完成的一条腿；统一归位主队列
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleProbeCompletionForEntry:entry media:media error:error];
            });
        }];

    // 页超时 45s 看门狗：RDHybridPageProbe 动态腿自身 hardTimeout=45、静态腿有独立
    // 超时预算，此计时器兜底任何「两腿都迟迟不归」的路径，保证串行链必然推进。
    RDWatchlistEntry *watchEntry = [entry copy];
    self.pageWatchdog = [NSTimer timerWithTimeInterval:RDPageTimeoutSeconds repeats:NO block:^(NSTimer *t) {
        [weakSelf watchdogFiredForEntry:watchEntry];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.pageWatchdog forMode:NSRunLoopCommonModes];
    RDLogWrite(@"app", @"追更助手：开始探测 %@", entry.pageURL);
}

- (void)handleProbeCompletionForEntry:(RDWatchlistEntry *)entry
                                media:(nullable NSArray<DetectedMedia *> *)media
                                error:(nullable NSError *)error {
    if (self.currentFinished || ![self.currentEntryID isEqualToString:entry.identifier]) return; // 迟到回调作废
    [self concludeCurrentPageWithEntry:entry media:media error:error];
}

- (void)watchdogFiredForEntry:(RDWatchlistEntry *)entry {
    if (self.currentFinished || ![self.currentEntryID isEqualToString:entry.identifier]) return;
    RDLogWriteLevel(RDLogLevelWarn, @"app", @"追更助手：探测超时（%lu 秒）%@", (unsigned long)RDPageTimeoutSeconds, entry.pageURL);
    [self.hybridProbe cancelProbe:self.currentProbeToken];  // 迟到 completion 由其内部作废
    [self concludeCurrentPageWithEntry:entry
                                 media:nil
                                 error:[NSError errorWithDomain:RDWatchAgentErrorDomain
                                                           code:RDWatchAgentErrorPageTimeout
                                                       userInfo:@{NSLocalizedDescriptionKey:
             [NSString stringWithFormat:@"探测超时（%lu 秒）", (unsigned long)RDPageTimeoutSeconds]}]];
}

- (void)concludeCurrentPageWithEntry:(RDWatchlistEntry *)entry
                               media:(nullable NSArray<DetectedMedia *> *)media
                               error:(nullable NSError *)error {
    self.currentFinished = YES;
    [self.pageWatchdog invalidate];
    self.pageWatchdog = nil;
    self.currentProbeToken = nil;
    self.currentEntryID = nil;

    NSArray<NSString *> *fetchedKeys = media ? RDFetchedKeysFromMedia(media) : @[];
    // 以本循环的条目快照预判新增数（store 内部锁内重读磁盘，diff 权威在 recordProbeResult）
    NSInteger freshCount = [entry filterNewKeys:fetchedKeys].count;
    [[RDWatchlistStore sharedStore] recordProbeResult:entry
                                          fetchedKeys:fetchedKeys
                                                error:error.localizedDescription];

    RDLogWrite(@"app", @"追更助手：探测完成 %@ 键=%lu 新增=%ld 错误=%@",
               entry.pageURL, (unsigned long)fetchedKeys.count, (long)freshCount,
               error.localizedDescription ?: @"-");

    if (!error && freshCount > 0) {
        [self maybePostSystemNotificationForEntry:entry freshCount:freshCount];
    }
    [self updateButtonBadge];
    [self probeNextEntry];   // 串行链推进（并发 1）
}

#pragma mark - 暂停 / 恢复

- (void)togglePaused:(id)sender {
    self.paused = !self.paused;
    if (self.paused) {
        // 暂停 = 停止派新页：清空剩余队列，当前页让其自然结算；自动 tick 直接跳过
        [self.cycleQueue removeAllObjects];
        self.cycleRestartRequested = NO;
        RDLogWrite(@"app", @"追更助手：已暂停");
    } else {
        RDLogWrite(@"app", @"追更助手：已恢复");
    }
    [self updateButtonBadge];
    [self rebuildMenu];
}

#pragma mark - 菜单动作

- (void)openUnreadEntry:(NSMenuItem *)sender {
    NSString *identifier = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    RDWatchlistEntry *entry = identifier ? [self entryWithIdentifier:identifier] : nil;
    if (!entry) return;
    [self openEntryInMainApp:entry markRead:YES];
}

- (void)openManagerInMainApp:(id)sender {
    [self launchMainAppThenPostOpenAndScanWithURLString:nil];
}

- (void)quitAssistant {
    RDLogWrite(@"app", @"追更助手：退出（注销 LaunchAgent）");
    [self applyLoginItemEnabled:NO];   // 契约：退出助手 = 注销 SMAppService 并退出
    [[NSApplication sharedApplication] terminate:nil];
}

#pragma mark - 唤起Miliu（契约 §3.1：先打开主 App，再 post openAndScan）

- (nullable NSURL *)mainApplicationURL {
    // 首选：助手嵌在 Miliu.app/Contents/Helpers/Miliu追更助手.app 内，向上三级即主 App
    NSURL *mainURL = [[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent]; // Helpers/
    mainURL = [mainURL URLByDeletingLastPathComponent];  // Contents/
    mainURL = [mainURL URLByDeletingLastPathComponent];  // Miliu.app
    BOOL isDirectory = NO;
    if ([mainURL.pathExtension isEqualToString:@"app"] &&
        [[NSFileManager defaultManager] fileExistsAtPath:mainURL.path isDirectory:&isDirectory] && isDirectory) {
        return mainURL;
    }
    // 兜底：按主 App bundle id 在已注册应用中查找
    return [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:RDMainAppBundleID];
}

/// pageURLString 为 nil 时只打开主 App（管理观察列表）；否则打开后经宽限再投递 openAndScan。
- (void)launchMainAppThenPostOpenAndScanWithURLString:(nullable NSString *)pageURLString {
    NSURL *appURL = [self mainApplicationURL];
    if (!appURL) {
        RDLogWriteLevel(RDLogLevelError, @"app", @"追更助手：找不到Miliu主 App，无法唤起（%@）", pageURLString ?: @"-");
        return;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = NO;
    __weak RDWatchAgentController *weakSelf = self;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL
                                          configuration:configuration
                                      completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
        if (error) {
            RDLogWriteLevel(RDLogLevelError, @"app", @"追更助手：打开主 App 失败 %@", error.localizedDescription);
            return;
        }
        // 宽限 1s：冷启动时等 applicationDidFinishLaunching 注册分布式观察者；
        // App 侧对扫描中的 openAndScan 有 generation 保护，此处只投递一次不重试。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RDLaunchGraceSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf postOpenAndScanWithURLString:pageURLString];
        });
    }];
}

- (void)postOpenAndScanWithURLString:(nullable NSString *)pageURLString {
    if (pageURLString.length == 0) return;   // 管理观察列表：只打开，不指页
    // pageURL 原样传递（规范化已由入库侧完成，契约 §3.1）
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:RDDistOpenAndScan object:nil
                    userInfo:@{RDDistKeyPageURL: pageURLString}
            deliverImmediately:YES];
    RDLogWrite(@"app", @"追更助手：已投递 openAndScan");
}

- (void)openEntryInMainApp:(RDWatchlistEntry *)entry markRead:(BOOL)markRead {
    if (markRead) [[RDWatchlistStore sharedStore] markPendingRead:entry.identifier];
    [self updateButtonBadge];
    [self rebuildMenu];
    [self launchMainAppThenPostOpenAndScanWithURLString:entry.pageURL];
}

- (nullable RDWatchlistEntry *)entryWithIdentifier:(NSString *)identifier {
    for (RDWatchlistEntry *entry in [RDWatchlistStore sharedStore].entries) {
        if ([entry.identifier isEqualToString:identifier]) return entry;
    }
    return nil;
}

#pragma mark - 分布式通知（watchNow / watchService）

- (void)registerDistributedObservers {
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleWatchNowNotification:)
                   name:RDDistWatchNow object:nil];
    [center addObserver:self selector:@selector(handleWatchServiceNotification:)
                   name:RDDistWatchService object:nil];
}

- (void)handleWatchNowNotification:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self probeAllNow];   // 立即轮询（全部启用页）
    });
}

- (void)handleWatchServiceNotification:(NSNotification *)note {
    BOOL enabled = [note.userInfo[RDDistKeyEnabled] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyLoginItemEnabled:enabled];
    });
}

#pragma mark - 开机自启（经典 LaunchAgent：~/Library/LaunchAgents/ + launchctl）

- (void)alignLoginItemOnLaunch {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:RDMainAppBundleID];
    BOOL autoLaunch = [suite boolForKey:@"MiliuWatchAutoLaunch"];
    NSString *uid = [NSString stringWithFormat:@"%lu", (unsigned long)getuid()];
    NSString *domain = [NSString stringWithFormat:@"gui/%@/com.sevenzz.resource-detector.watchlist", uid];
    BOOL loaded = [self launchctlTask:@[ @"print", domain ] ignoreErrors:YES];
    if (autoLaunch) {
        // 已加载（本进程就是 launchd 拉起的，或先前已 bootstrap）：直接跳过——
        // 否则 applyLoginItemEnabled 的「先 bootout 再 bootstrap」会杀掉 launchd
        // 里的自己，服务被自己拆除（2026-10-03 实测双实例互踩的根因）。
        if (loaded) return;
        [self applyLoginItemEnabled:YES];
    } else if (loaded) {
        // 用户在助手未运行时关过开关：这次拉起即补注销
        [self applyLoginItemEnabled:NO];
    }
}

// 2026-10-03 安装后实测：SMAppService 对「嵌套子 App」架构一律报
// "plist content is invalid"（最小 plist 亦然；其为顶层主 App 设计）。
// 改用经典机制：助手运行时把 LaunchAgent plist 写到用户域，Program 指向自身
// 可执行的绝对路径，launchctl bootstrap/bootout 启停。App 固定安装于
// /Applications/Miliu.app，路径稳定；重装同路径无需重写。
- (NSURL *)userAgentPlistURL {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/LaunchAgents/com.sevenzz.resource-detector.watchlist.plist"];
    return [NSURL fileURLWithPath:path];
}

- (BOOL)writeUserAgentPlist {
    NSURL *executable = [[NSBundle mainBundle] executableURL];
    if (!executable.path.length) {
        RDLogWriteLevel(RDLogLevelWarn, @"app", @"追更助手：无法解析自身可执行路径，注册中止");
        return NO;
    }
    NSDictionary *plist = @{
        @"Label": @"com.sevenzz.resource-detector.watchlist",
        @"Program": executable.path,
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO,
    };
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:&err];
    if (!data || err) {
        RDLogWriteLevel(RDLogLevelWarn, @"app", @"追更助手：LaunchAgent plist 序列化失败：%@",
                        err.localizedDescription ?: @"-");
        return NO;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [self userAgentPlistURL].URLByDeletingLastPathComponent.path
                             withIntermediateDirectories:YES attributes:nil error:nil];
    if (![data writeToURL:[self userAgentPlistURL] options:NSDataWritingAtomic error:&err]) {
        RDLogWriteLevel(RDLogLevelWarn, @"app", @"追更助手：LaunchAgent plist 写入失败：%@",
                        err.localizedDescription ?: @"-");
        return NO;
    }
    return YES;
}

- (BOOL)launchctlTask:(NSArray<NSString *> *)arguments ignoreErrors:(BOOL)ignore {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/launchctl";
    task.arguments = arguments;
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    [task launch];
    [task waitUntilExit];
    BOOL ok = task.terminationStatus == 0;
    if (!ok && !ignore) {
        NSData *errData = [[task.standardError fileHandleForReading] readDataToEndOfFile];
        NSString *errText = errData.length ? [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] : @"-";
        RDLogWriteLevel(RDLogLevelWarn, @"app", @"追更助手：launchctl %@ 退出 %ld：%@",
                        arguments.firstObject, (long)task.terminationStatus,
                        [errText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
    return ok;
}

- (void)applyLoginItemEnabled:(BOOL)enabled {
    NSString *uid = [NSString stringWithFormat:@"%lu", (unsigned long)getuid()];
    NSURL *plistURL = [self userAgentPlistURL];
    if (enabled) {
        if (![self writeUserAgentPlist]) return;
        // bootstrap 幂等：已加载时先 bootout 再进，避免「已加载」报错
        [self launchctlTask:@[ @"bootout", [NSString stringWithFormat:@"gui/%@", uid], plistURL.path ] ignoreErrors:YES];
        BOOL ok = [self launchctlTask:@[ @"bootstrap", [NSString stringWithFormat:@"gui/%@", uid], plistURL.path ] ignoreErrors:NO];
        if (ok) {
            RDLogWrite(@"app", @"追更助手：LaunchAgent 注册成功（launchctl bootstrap ok）");
            // 让位：bootstrap 已由 launchd 拉起常驻实例，本（open/手动）实例延迟退出，
            // 保证助手单实例；延迟 2s 留出本通知处理与菜单交互收尾。
            __weak RDWatchAgentController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [NSApp terminate:weakSelf]; });
        }
    } else {
        // 注销多由 launchd 实例自己执行：bootout 会终止本进程，后续代码跑不到——
        // 因此先删 plist、先记日志，最后按 label 自杀式卸载（2026-10-03 实测修正）。
        [[NSFileManager defaultManager] removeItemAtURL:plistURL error:nil];
        RDLogWrite(@"app", @"追更助手：LaunchAgent 已注销并清理 plist");
        [self launchctlTask:@[ @"bootout",
            [NSString stringWithFormat:@"gui/%@/com.sevenzz.resource-detector.watchlist", uid] ] ignoreErrors:YES];
    }
}

#pragma mark - 系统通知（UNUserNotificationCenter）

- (BOOL)notificationCenterAvailable {
    // UNUserNotificationCenter 在无 bundle 环境（裸跑可执行）会抛异常，先防御
    return [NSBundle mainBundle].bundleIdentifier.length > 0;
}

- (void)requestNotificationAuthorization {
    if (!self.notificationCenterAvailable) {
        RDLogWrite(@"app", @"追更助手：无 bundle 标识，跳过通知授权");
        return;
    }
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        RDLogWrite(@"app", @"追更助手：通知授权 granted=%d error=%@", granted, error.localizedDescription ?: @"-");
    }];
}

- (void)maybePostSystemNotificationForEntry:(RDWatchlistEntry *)entry freshCount:(NSInteger)freshCount {
    if (![self.watchDefaults boolForKey:RDPrefNotifyEnabled]) return;   // 默认 YES（registerDefaults 兜底）
    if ([self isInQuietHoursNow]) return;
    if (!self.notificationCenterAvailable) return;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [self displayTitleForEntry:entry];
    content.body = [NSString stringWithFormat:@"＋%ld 新资源，点击查看", (long)freshCount];
    content.userInfo = @{ RDDistKeyPageURL: entry.pageURL,
                          @"identifier": entry.identifier };

    // identifier = 条目 identifier（契约）：同一页面的旧通知先撤再挂，避免重复弹
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center removeDeliveredNotificationsWithIdentifiers:@[ entry.identifier ]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:entry.identifier
                                                                          content:content
                                                                          trigger:nil];
    [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            RDLogWriteLevel(RDLogLevelWarn, @"app", @"追更助手：通知投递失败 %@", error.localizedDescription);
        }
    }];
}

#pragma mark - 静音时段（契约 §3.2）

/// 偏好 "HH:mm-HH:mm"（跨零点合法，如 00:00-08:00 视为 00:00→次日 08:00）；
/// 字面 off=不静音；解析失败按默认 00:00-08:00 处理。
- (BOOL)isInQuietHoursNow {
    NSString *raw = nil;
    id rawValue = [self.watchDefaults objectForKey:RDPrefQuietHours];
    if ([rawValue isKindOfClass:NSString.class]) raw = rawValue;
    if (raw == nil) raw = RDDefaultQuietHours;   // 键缺失 → 合同默认值
    if ([raw isEqualToString:RDQuietHoursOff]) return NO;

    NSInteger startMinutes = -1;
    NSInteger endMinutes = -1;
    NSRange dash = [raw rangeOfString:@"-"];
    if (dash.location != NSNotFound && dash.location > 0 && dash.location + 1 < (NSInteger)raw.length) {
        startMinutes = RDMinutesFromHHmm([raw substringToIndex:dash.location]);
        endMinutes = RDMinutesFromHHmm([raw substringFromIndex:dash.location + 1]);
    }
    if (startMinutes < 0 || endMinutes < 0) {
        // 解析失败按默认处理（默认值恒定合法）
        dash = [RDDefaultQuietHours rangeOfString:@"-"];
        startMinutes = RDMinutesFromHHmm([RDDefaultQuietHours substringToIndex:dash.location]);
        endMinutes = RDMinutesFromHHmm([RDDefaultQuietHours substringFromIndex:dash.location + 1]);
    }
    if (startMinutes == endMinutes) return NO;   // 零长度窗口视为不静音（见交回说明）

    NSDateComponents *components = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute
                                                                   fromDate:[NSDate date]];
    NSInteger nowMinutes = components.hour * 60 + components.minute;
    if (startMinutes < endMinutes) return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    return nowMinutes >= startMinutes || nowMinutes < endMinutes;   // 跨零点窗口
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // 前台呈现横幅（助手常驻后台，一般走系统横幅；这里保证万一处于前台也不丢）
    completionHandler(UNNotificationPresentationOptionBanner);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *identifier = response.notification.request.identifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 已选语义：点按瞬间先标已读（菜单未读区随 store 重建，保持一致），再按
        // §3.1 顺序唤起Miliu：先打开主 App，再 post openAndScan（pageURL 原样）。
        RDWatchlistEntry *entry = [self entryWithIdentifier:identifier];
        if (entry) [self openEntryInMainApp:entry markRead:YES];
        completionHandler();
    });
}

@end
