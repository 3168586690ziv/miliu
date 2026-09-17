//
//  StreamingGroupTests.m — 真实流式页面「同片两行 + 详情变慢」回归
//
//  复现的真实故障链（2026-09-09 现场网址 hanime2.org/watch?v=408160）：
//    1) 动态取页在文档尚未解析完（readyState=loading）时被"提前完成"提前投递，
//       投递的 HTML 只有 <head> 前缀（preload 链接 + og:image），没有 <video> 块；
//    2) 于是动态结果里那条 720p 没有 family、没有画质声明、没有 poster；
//    3) RDHybridPageProbe 合并时"先到先占"，同 URL 的静态丰富条目（family +
//       480p/720p 声明 + poster）被丢弃；
//    4) 左侧同一影片出现两行（一行可选画质、一行不能），且选中那行没有
//       poster → 元数据只能走视频抽帧（AVFoundation 从文件头顺序读取）→ 详情极慢。
//
//  本套件全部经过生产代码：RDWebViewProbeLoader / RDProbeAnalyzer /
//  RDHybridPageProbe / 生产 App 的 visibleMedia 与 configureDetailForMedia。
//
#define main RDUnusedProductionMain
#import "../../src/App/ResourceDetectorApp.m"
#undef main
#import "RDHybridPageProbe.h"
#import "WebProbe.h"
#import "ResourceURLGate.h"
#import "DNSResolver.h"
#import "MultiPageResourceProbe.h"
#import <objc/runtime.h>

// 生产页适配器：真实定义在 ResourceDiscoveryCoordinator.m 内部（.m 私有类），
// 这里按真实签名前置声明，让用例直接使用生产实现跑完整消费链，而不是在测试里
// 另写一份等价替身。
@interface RDCPageProbeAdapter : NSObject <ZZSinglePageProbing>
- (instancetype)initWithRawProbe:(id<ZZDiscoveryPageProbing>)rawProbe;
@end

static NSMutableArray<NSString *> *gFailures;
static void Check(BOOL ok, NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!gFailures) gFailures = [NSMutableArray array];
    if (!ok) { [gFailures addObject:message]; NSLog(@"FAIL: %@", message); return; }
    NSLog(@"PASS: %@", message);
}
static void CheckSummary(void) {
    if (gFailures.count) { NSLog(@"FAILED %lu 项断言（首项：%@）", (unsigned long)gFailures.count, gFailures.firstObject); exit(1); }
    NSLog(@"PASS: ALL STREAMING-GROUP TESTS");
}
static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}

#pragma mark - 替身：静态探针（丰富条目）与动态 loader（流式前缀）

@interface SGPolicy : URLPolicy
@end
@implementation SGPolicy
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray *)ips { return [URLPolicyDecision allow]; }
@end

@interface SGStaticProbe : NSObject <ZZDiscoveryPageProbing>
@property (nonatomic, strong) NSArray<DetectedMedia *> *media;
@property (nonatomic, strong) NSError *error;
@end
@implementation SGStaticProbe
- (id)probePageURL:(NSURL *)url completion:(void (^)(NSArray<DetectedMedia *> *, NSError *))done {
    NSArray *media = self.media;
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(media, self.error); });
    return self;
}
- (void)cancelProbe:(id)token {}
@end

// 动态路径只回一个"前缀文档"：只有 preload 链接，没有 <video> 块。
@interface SGThinLoader : NSObject <RDProbeLoader>
@property (nonatomic, copy) NSString *html;
// 动态腿返回延迟：真实网址上动态 WebKit 腿比静态取页腿晚 4–6 秒回来，
// 用例用它固定「静态腿先发布、动态腿后发布」的先后关系（默认 0 = 立即返回）。
@property (nonatomic, assign) NSTimeInterval delay;
@property (nonatomic, strong) AppError *error;
@end
@implementation SGThinLoader
- (HTTPTask *)loadPageAtURL:(NSURL *)url policy:(URLPolicy *)policy completion:(void (^)(NSString *, AppError *))done {
    NSString *html = self.html;
    NSTimeInterval delay = MAX(0, self.delay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (done) done(html, self.error); });
    return nil;
}
@end

#pragma mark - 替身：可注入的 WebView（模拟流式文档 + readyState）

@interface SGFakeWebView : NSObject <RDProbeWebView>
@property (nonatomic, weak) id<WKNavigationDelegate> navigationDelegate;
@property (nonatomic, copy) NSString *readyState;
@property (nonatomic, copy) NSString *outerHTML;
@property (nonatomic, assign) NSUInteger evaluated;
@end
@implementation SGFakeWebView
- (void)loadRequest:(NSURLRequest *)request {}
- (void)stopLoading {}
- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(void (^)(id, NSError *))completionHandler {
    self.evaluated++;
    if (completionHandler) {
        // 生产代码只关心 document.documentElement.outerHTML；返回拼接了 readyState
        // 的文本时也要能被正确解析（修复后为 "状态|HTML"）。
        NSString *result = [NSString stringWithFormat:@"%@|%@", self.readyState, self.outerHTML];
        completionHandler(result, nil);
    }
}
@end

@interface SGFakeFactory : NSObject <RDProbeWebViewFactory>
@property (nonatomic, strong) SGFakeWebView *view;
@end
@implementation SGFakeFactory
- (id<RDProbeWebView>)makeWebViewWithConfiguration:(WKWebViewConfiguration *)configuration { return self.view; }
@end

#pragma mark - 1. 流式文档不得被"提前完成"提前投递

static void StreamingDocumentIsNotDeliveredEarly(void) {
    NSURL *url = [NSURL URLWithString:@"https://fixture.invalid/watch?v=1"];
    NSString *prefixHTML = @"<html lang=\"zhs\"><head><link rel=\"preload\" as=\"video\" "
        "href=\"https://cdn.example.com/movie-720p.mp4\" type=\"video/mp4\">"
        "<meta property=\"og:image\" content=\"https://cdn.example.com/cover.jpg\"></head>";
    NSString *fullHTML = [prefixHTML stringByAppendingString:
        @"<body><video id=\"player\" poster=\"https://cdn.example.com/cover.jpg\">"
         "<source src=\"https://cdn.example.com/movie-720p.mp4\" type=\"video/mp4\" size=\"720\">"
         "<source src=\"https://cdn.example.com/movie-480p.mp4\" type=\"video/mp4\" size=\"480\">"
         "</video></body></html>"];

    SGFakeWebView *view = [SGFakeWebView new];
    view.readyState = @"loading";
    view.outerHTML = prefixHTML;                 // 流式传输中：只有 head 前缀
    SGFakeFactory *factory = [SGFakeFactory new];
    factory.view = view;
    RDWebViewProbeLoader *loader = [[RDWebViewProbeLoader alloc] initWithWebViewFactory:factory];

    __block NSString *delivered = nil;
    __block AppError *deliveredError = nil;
    [loader loadPageAtURL:url policy:[SGPolicy new] maxHTMLBytes:8 * 1024 * 1024
               completion:^(NSString *html, AppError *error) { delivered = html; deliveredError = error; }];
    Check(Wait(^BOOL { return view.navigationDelegate != nil; }, 2), @"loader 会话建立并接管 WebView");

    id<WKNavigationDelegate> delegate = view.navigationDelegate;
    [delegate webView:(id)view didCommitNavigation:nil];
    // 让 0.35 / 0.8 / 1.6 秒三次"提前完成"检查全部发生（此刻文档仍是前缀）
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
    Check(delivered == nil, @"文档未解析完（readyState=loading）时不得提前投递（实际投递 %@ 字节）",
          delivered ? @(delivered.length) : @"0");

    // 文档解析完成：didFinish 后 2 秒按完整 DOM 投递
    view.readyState = @"interactive";
    view.outerHTML = fullHTML;
    [delegate webView:(id)view didFinishNavigation:nil];
    Check(Wait(^BOOL { return delivered != nil; }, 8), @"文档完成后按完整 DOM 投递（错误：%@）", deliveredError.message ?: @"无");
    Check(delivered.length > 0 && [delivered rangeOfString:@"<video" options:NSCaseInsensitiveSearch].location != NSNotFound,
          @"投递的 HTML 含完整 <video> 块（%lu 字节）", (unsigned long)delivered.length);

    RDProbeResult *result = [RDProbeAnalyzer analyzeHTML:delivered baseURL:url];
    NSMutableArray<DetectedMedia *> *videos = [NSMutableArray array];
    for (DetectedMedia *m in result.media) if (m.resourceKind != RDResourceKindImage) [videos addObject:m];
    Check(videos.count == 2, @"完整 DOM 解析出两个画质候选（实际 %lu）", (unsigned long)videos.count);
    DetectedMedia *first = videos.firstObject;
    Check(first.videoFamilyID.length > 0 && first.declaredVariants.count == 2 && first.poster.length > 0,
          @"完整 DOM 的成员带 family/画质声明/poster（fam=%@ variants=%lu poster=%@）",
          first.videoFamilyID ?: @"nil", (unsigned long)first.declaredVariants.count, first.poster ?: @"nil");
}

#pragma mark - 2. 合并不得让"信息更少"的动态条目顶掉静态丰富条目

static void HybridMergeKeepsRicherMember(void) {
    NSURL *page = [NSURL URLWithString:@"https://example.org/watch?v=1"];
    // 静态侧：真实 <video> 块 → family + 480p/720p + poster（生产分析器产出）
    RDProbeResult *staticResult = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video poster=\"https://cdn.example.com/cover.jpg\">"
         "<source src=\"https://cdn.example.com/movie-720p.mp4\" size=\"720\">"
         "<source src=\"https://cdn.example.com/movie-480p.mp4\" size=\"480\">"
         "</video></body></html>"
        baseURL:page];
    Check(staticResult.media.count == 2, @"静态侧解析出两个成员（实际 %lu）", (unsigned long)staticResult.media.count);

    // 动态侧：流式前缀只带回 720p（无 family / 无画质 / 无 poster）
    SGStaticProbe *staticProbe = [SGStaticProbe new];
    staticProbe.media = staticResult.media;
    SGThinLoader *dynamicLoader = [SGThinLoader new];
    dynamicLoader.html = @"<html><head><link rel=\"preload\" as=\"video\" href=\"https://cdn.example.com/movie-720p.mp4\"></head></html>";

    // 动态腿启动前会做一次真实 DNS 校验（生产安全边界），DNS 偶发抖动时重试，
    // 不让网络波动把合并逻辑的回归测试变成随机失败。
    __block NSArray<DetectedMedia *> *merged = nil;
    __block NSError *mergeError = nil;
    for (int attempt = 0; attempt < 3 && merged == nil; attempt++) {
        RDHybridPageProbe *hybrid = [[RDHybridPageProbe alloc] initWithPolicy:[SGPolicy new]];
        [hybrid setValue:staticProbe forKey:@"statik"];
        hybrid.loaderFactory = ^id<RDProbeLoader> { return dynamicLoader; };
        merged = nil; mergeError = nil;
        [hybrid probePageURL:page completion:^(NSArray<DetectedMedia *> *media, NSError *error) { merged = media; mergeError = error; }];
        Check(Wait(^BOOL { return merged != nil; }, 8), @"生产合并完成（第 %d 次，错误：%@）", attempt + 1, mergeError.localizedDescription ?: @"无");
        if (merged.count == 0 && mergeError) {
            Check(attempt < 2, @"DNS/网络校验连续失败 3 次（%@）——本机网络异常，不是合并逻辑问题",
                  mergeError.localizedDescription ?: @"");
            merged = nil;
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        }
    }
    if (!merged) merged = @[];

    NSMutableArray<DetectedMedia *> *videos = [NSMutableArray array];
    for (DetectedMedia *m in merged) if (m.resourceKind != RDResourceKindImage) [videos addObject:m];
    Check(videos.count == 2, @"合并后仍是两个画质成员、不产生第三条（实际 %lu）", (unsigned long)videos.count);
    if (videos.count != 2) return;

    DetectedMedia *merged720 = nil;
    for (DetectedMedia *m in videos) if ([m.mediaURL containsString:@"720p"]) merged720 = m;
    Check(merged720 != nil, @"合并结果包含 720p 成员");
    Check(merged720.videoFamilyID.length > 0, @"被动态条目先占的 720p 仍保留同片 family 身份（fam=%@）", merged720.videoFamilyID ?: @"nil");
    Check(merged720.declaredVariants.count == 2, @"被动态条目先占的 720p 仍保留 480p/720p 声明（实际 %lu）", (unsigned long)merged720.declaredVariants.count);
    Check(merged720.poster.length > 0, @"被动态条目先占的 720p 仍保留 poster（%@）", merged720.poster ?: @"nil");
    NSString *family = videos.firstObject.videoFamilyID;
    for (DetectedMedia *m in videos) Check([m.videoFamilyID isEqualToString:family], @"两个成员共享同一 family（%@）", m.mediaURL.lastPathComponent);

    // 生产 App 的左侧列表：必须只有一行
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [merged mutableCopy];
    NSArray<DetectedMedia *> *rows = app.visibleMedia;
    NSMutableArray<DetectedMedia *> *videoRows = [NSMutableArray array];
    for (DetectedMedia *m in rows) if (m.resourceKind != RDResourceKindImage) [videoRows addObject:m];
    Check(videoRows.count == 1, @"左侧同片只有一个视频选项（实际 %lu 行：%@）",
          (unsigned long)videoRows.count, [videoRows valueForKey:@"mediaURL"]);
}

#pragma mark - 3. 右侧详情必须出现画质选择器，且选择与下载对象一致

static void DetailShowsQualityPickerAndSelectionStaysConsistent(void) {
    NSURL *page = [NSURL URLWithString:@"https://example.org/watch?v=1"];
    RDProbeResult *result = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video poster=\"https://cdn.example.com/cover.jpg\">"
         "<source src=\"https://cdn.example.com/movie-720p.mp4\" size=\"720\">"
         "<source src=\"https://cdn.example.com/movie-480p.mp4\" size=\"480\">"
         "</video></body></html>"
        baseURL:page];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [result.media mutableCopy];
    app.table = (id)[[NSClassFromString(@"NSTableView") alloc] init];
    // 提供真实详情容器，便于检查标题和数值控件的可见性；生产窗口会在
    // applicationDidFinishLaunching 中创建同一容器。
    app.detailPane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 651, 548)];
    [app buildDetailPane];
    DetectedMedia *row = app.visibleMedia.firstObject;
    [app configureDetailForMedia:row];
    Check(!app.variantPicker.hidden, @"右侧详情出现画质选择器");
    Check(app.variantPicker.numberOfItems == 2, @"画质选择器列出两个档位（实际 %ld）", (long)app.variantPicker.numberOfItems);
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)app.variantPicker.numberOfItems; i++) [titles addObject:[app.variantPicker itemAtIndex:i].title];
    Check([titles containsObject:@"480p"] && [titles containsObject:@"720p"], @"档位为 480p/720p（实际 %@）", titles);
    // 画质选择器旁不应再显示实际像素尺寸（例如“1920 × 1080”）。标题和
    // 数值都必须隐藏；底层 pixelWidth/pixelHeight 元数据仍由生产代码保留。
    Check(app.dimensionValue.hidden, @"有画质选择器时隐藏实际像素分辨率数值");
    BOOL dimensionTitleVisible = NO;
    for (NSView *v in app.detailPane.subviews) {
        if ([v isKindOfClass:NSTextField.class] &&
            [((NSTextField *)v).stringValue isEqualToString:@"分辨率"]) {
            dimensionTitleVisible = !v.hidden;
            break;
        }
    }
    Check(!dimensionTitleVisible, @"有画质选择器时隐藏“分辨率”标题");

    for (NSInteger i = 0; i < (NSInteger)app.variantPicker.numberOfItems; i++) {
        [app.variantPicker selectItemAtIndex:i];
        [app selectDeclaredVariant:nil];
        NSString *label = [app.variantPicker itemAtIndex:i].title;
        DetectedMedia *current = app.currentDownloadMedia;
        Check(app.linkField.stringValue.length > 0 && current.mediaURL.length > 0 &&
              [[DetectedMedia dedupKeyForURL:app.linkField.stringValue] isEqual:[DetectedMedia dedupKeyForURL:current.mediaURL]],
              @"选择 %@ 后直链与下载对象一致（%@）", label, app.linkField.stringValue);
        Check([current.mediaURL containsString:label], @"选择 %@ 后下载对象就是该档位（%@）", label, current.mediaURL);
    }
}

#pragma mark - 4. 探测进度：不得再出现百分比进度条（该控件已按设计移除）

// 历史：探测阶段曾使用独立的细横向条 + 百分比文字。该控件已在既有轮次中移除
//（见 src/App/ResourceDetectorApp.m 中「探测阶段只显示 statusNote 文字，不创建
// 百分比进度控件」的注释）。本用例改为守住「不得回归」：探测期间窗口里不得出现
// 可见的探测进度条或百分比文字，同时避免下载行的进度条被误当成探测进度。
// 仍通过公开 AppKit 类型观察生产界面，不依赖具体属性名，避免只检查源码字符串。
static void DiscoveryProgressHasNoPercentBar(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZZHotkeyGuideAnswered"];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:@"SGProgressLaunch" object:nil]];
    app.scanning = YES;

    // 生产回调数值范围是 0...1，且只覆盖「页面探测」这一半整体进度
    //（另一半由画质档位探索驱动），因此会话 0.74 → 界面 37%。
    // 37% 既能验证格式，也能发现整数截断/小数显示问题。
    void (^progress)(double) = app.session.progressHandler;
    Check(progress != nil, @"探测会话已接入进度回调");
    if (progress) progress(0.74);
    // App 回调通过主队列异步更新控件，给主循环一个短窗口完成布局。
    // 展示层会平滑追赶目标值，因此等待略长于追赶时长，再验证最终值。
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];

    NSMutableArray<NSView *> *bars = [NSMutableArray array];
    NSMutableArray<NSTextField *> *texts = [NSMutableArray array];
    NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:app.homePage ?: [NSView new]];
    while (pending.count) {
        NSView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:NSView.class] && [view isKindOfClass:NSClassFromString(@"RDThinProgressView")]) [bars addObject:view];
        if ([view isKindOfClass:NSTextField.class]) [texts addObject:(NSTextField *)view];
        [pending addObjectsFromArray:view.subviews ?: @[]];
    }

    NSView *thin = nil;
    for (NSView *bar in bars) {
        // 下载进度条默认隐藏；只接受探测期间实际可见的横向条，避免把下载
        // 进度误当成探测进度。
        if (!bar.hidden && NSWidth(bar.frame) >= 200 && NSHeight(bar.frame) <= 3.5) {
            thin = bar;
            break;
        }
    }
    Check(thin == nil, @"探测期间不得出现可见的探测进度条（该控件已按设计移除；下载行进度条不得外泄）");

    BOOL percentVisible = NO;
    for (NSTextField *field in texts) {
        if (field.hidden) continue;
        NSString *value = field.stringValue ?: @"";
        if ([value isEqualToString:@"37%"] || [value containsString:@"37%"])
            percentVisible = YES;
    }
    Check(!percentVisible, @"探测期间不得出现百分比进度文本（该控件已按设计移除）");
    app.scanning = NO;
    [app.window orderOut:nil];
}

// 探测进度跳变（0 → 1）时，界面同样不得冒出可见的探测进度条。
static void DiscoveryProgressHasNoVisibleBarOnJump(void) {
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:@"SGProgressSmoothLaunch" object:nil]];
    app.scanning = YES;
    void (^progress)(double) = app.session.progressHandler;
    Check(progress != nil, @"平滑进度测试已接入探测回调");
    if (!progress) return;
    progress(0.0);
    NSDate *start = [NSDate date];
    progress(1.0);
    // 至少让一两个 60 Hz 展示 tick 到达，再确认它已经开始走动但远未完成。
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
    NSView *bar = nil;
    NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:app.homePage ?: [NSView new]];
    while (pending.count) {
        NSView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:NSView.class] && [view isKindOfClass:NSClassFromString(@"RDThinProgressView")] && !view.hidden && NSWidth(view.frame) >= 200) {
            bar = view;
            break;
        }
        [pending addObjectsFromArray:view.subviews ?: @[]];
    }
    Check(bar == nil, @"探测进度跳变时也不得出现可见探测进度条（该控件已按设计移除）");
    app.scanning = NO;
    [app.window orderOut:nil];
}

static void CircularProgressControlIsRemoved(void) {
    // 圆环控件必须从源码中彻底移除；runtime 检查只覆盖已加载的类，
    // 无法发现未参与当前测试编译的孤立 .h/.m 文件。
    NSString *root = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    // 测试二进制位于 build/streaming-group-tests，向上两级回到项目根目录。
    NSString *repo = [[[root stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] copy];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL staleHeader = [fm fileExistsAtPath:[repo stringByAppendingPathComponent:@"src/Shared/UI/RingProgressView.h"]];
    BOOL staleImplementation = [fm fileExistsAtPath:[repo stringByAppendingPathComponent:@"src/Shared/UI/RingProgressView.m"]];
    Check(!staleHeader && !staleImplementation && NSClassFromString(@"RDProgressRingView") == Nil,
          @"圆环进度控件、遗留源码文件及运行时类均已删除");
}

#pragma mark - 3.5 URL 规范化：同一条资源经两条路径发现必须归为同一身份

static void PercentEncodingIdentity(void) {
    NSString *raw = @"https://cdn.example.com/movie-480p.mp4?secure=CvQgOW9f3sne2jel_VmqFg==,1788998438";
    NSString *dom = @"https://cdn.example.com/movie-480p.mp4?secure=CvQgOW9f3sne2jel_VmqFg==%2C1788998438";
    Check([[DetectedMedia dedupKeyForURL:raw] isEqual:[DetectedMedia dedupKeyForURL:dom]],
          @"未保留字符的百分号编码归一化后是同一身份（%%2C 与 ,）");
    Check(![[DetectedMedia dedupKeyForURL:@"https://cdn.example.com/a%2Fb.mp4"]
            isEqual:[DetectedMedia dedupKeyForURL:@"https://cdn.example.com/a/b.mp4"]],
          @"保留字符 %2F 与 / 仍是不同资源（路径语义不改变）");
    Check([[DetectedMedia dedupKeyForURL:@"https://cdn.example.com/a%7Eb.mp4"]
           isEqual:[DetectedMedia dedupKeyForURL:@"https://cdn.example.com/a~b.mp4"]],
          @"%%7E 与 ~ 归一化后是同一身份");

    // 生产链路：静态（原始 HTML）与动态（DOM 序列化）发现同一资源 → 一行
    RDProbeResult *staticResult = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video poster=\"https://cdn.example.com/cover.jpg\">"
         "<source src=\"https://cdn.example.com/movie-720p.mp4?secure=AAA==,1788998438\" size=\"720\">"
         "<source src=\"https://cdn.example.com/movie-480p.mp4?secure=BBB==,1788998438\" size=\"480\">"
         "</video></body></html>"
        baseURL:[NSURL URLWithString:@"https://example.com/watch"]];
    NSMutableArray *dynamic = [NSMutableArray array];
    for (NSString *u in @[@"https://cdn.example.com/movie-720p.mp4?secure=AAA==%2C1788998438",
                          @"https://cdn.example.com/movie-480p.mp4?secure=BBB==%2C1788998438"]) {
        DetectedMedia *m = [DetectedMedia new];
        m.mediaURL = u; m.resourceKind = RDResourceKindVideo; m.format = @"mp4";
        m.discoverySource = @"dynamic-video-source";
        [dynamic addObject:m];
    }
    NSMutableArray *merged = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *indexByKey = [NSMutableDictionary dictionary];
    for (DetectedMedia *m in [dynamic arrayByAddingObjectsFromArray:staticResult.media]) {
        NSString *key = [DetectedMedia dedupKeyForURL:m.mediaURL];
        NSNumber *existing = indexByKey[key];
        if (existing) { merged[existing.unsignedIntegerValue] = [DetectedMedia mediaByEnriching:merged[existing.unsignedIntegerValue] with:m]; continue; }
        indexByKey[key] = @(merged.count);
        [merged addObject:m];
    }
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = merged;
    NSMutableArray<DetectedMedia *> *videoRows = [NSMutableArray array];
    for (DetectedMedia *m in app.visibleMedia) if (m.resourceKind != RDResourceKindImage) [videoRows addObject:m];
    Check(videoRows.count == 1, @"静态+动态两条路径的同一资源只占一个视频行（实际 %lu）", (unsigned long)videoRows.count);
    if (videoRows.count == 1) {
        Check(videoRows.firstObject.declaredVariants.count == 2, @"合并后仍保留 480p/720p 声明");
        Check(videoRows.firstObject.videoFamilyID.length > 0, @"合并后保留分组身份");
    }

    // 真实网址现场：静态取页与动态取页拿到同一地址的不同签名（secure=A 与
    // secure=B），只按完整 URL 去重会显示成两个视频选项。
    DetectedMedia *signedA = [DetectedMedia new];
    signedA.mediaURL = @"https://cdn.example.com/movie-480p.mp4?secure=AAA==,1788998438";
    signedA.resourceKind = RDResourceKindVideo;
    signedA.videoFamilyID = @"family-static";
    signedA.declaredVariants = @[@{@"url": signedA.mediaURL, @"label": @"480p"},
                                 @{@"url": @"https://cdn.example.com/movie-720p.mp4?secure=CCC==,1788998438", @"label": @"720p"}];
    DetectedMedia *signedB = [DetectedMedia new];
    signedB.mediaURL = @"https://cdn.example.com/movie-480p.mp4?secure=BBB==,1789009206";
    signedB.resourceKind = RDResourceKindVideo;
    signedB.videoFamilyID = @"family-dynamic";
    signedB.declaredVariants = @[@{@"url": signedB.mediaURL, @"label": @"480p"},
                                 @{@"url": @"https://cdn.example.com/movie-720p.mp4?secure=DDD==,1789009206", @"label": @"720p"}];
    NSMutableArray *signedMerged = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *signedIndex = [NSMutableDictionary dictionary];
    for (DetectedMedia *m in @[signedB, signedA]) {   // 动态在前、静态在后（生产顺序）
        NSString *key = [DetectedMedia groupingKeyForURL:m.mediaURL];
        NSNumber *existing = signedIndex[key];
        if (existing) { signedMerged[existing.unsignedIntegerValue] = [DetectedMedia mediaByEnriching:signedMerged[existing.unsignedIntegerValue] with:m]; continue; }
        signedIndex[key] = @(signedMerged.count);
        [signedMerged addObject:m];
    }
    ResourceDetectorAppDelegate *signedApp = [ResourceDetectorAppDelegate new];
    signedApp.results = signedMerged;
    Check(signedMerged.count == 1, @"同一地址不同签名合并为一条媒体（实际 %lu）", (unsigned long)signedMerged.count);
    Check(signedApp.visibleMedia.count == 1, @"不同签名的同一资源只占一个视频行（实际 %lu）", (unsigned long)signedApp.visibleMedia.count);
    Check([[DetectedMedia dedupKeyForURL:signedA.mediaURL] isNotEqualTo:[DetectedMedia dedupKeyForURL:signedB.mediaURL]],
          @"下载身份仍保留签名差异（不被分组规则影响）");
    Check([[DetectedMedia groupingKeyForURL:signedA.mediaURL] isEqual:[DetectedMedia groupingKeyForURL:signedB.mediaURL]],
          @"分组身份忽略签名参数后相同");
}

#pragma mark - 4. 单成员 video 与动态播放器身份（不误合并 / 同族合并）

static void SingleSourceVideoAndPlayerIdentity(void) {
    // 单成员 video 块：不写回分组/档位，但只占一行；两个不同视频仍各自成行。
    RDProbeResult *one = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src=\"https://cdn.example.com/only.mp4\"></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://example.com/"]];
    Check(one.media.count == 1, @"单成员 video 块解析出一个媒体");
    ResourceDetectorAppDelegate *oneApp = [ResourceDetectorAppDelegate new];
    oneApp.results = [one.media mutableCopy];
    Check(oneApp.visibleMedia.count == 1, @"单成员 video 只占一行（实际 %lu）", (unsigned long)oneApp.visibleMedia.count);

    RDProbeResult *two = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src=\"https://cdn.example.com/a.mp4\"></video>"
         "<video src=\"https://cdn.example.com/b.mp4\"></video></body></html>"
        baseURL:[NSURL URLWithString:@"https://example.com/"]];
    ResourceDetectorAppDelegate *twoApp = [ResourceDetectorAppDelegate new];
    twoApp.results = [two.media mutableCopy];
    Check(twoApp.visibleMedia.count == 2, @"两个不同视频仍是两行（实际 %lu）", (unsigned long)twoApp.visibleMedia.count);

    // 动态桥接：同一播放器（data-rd-player 相同）的成员归一组；
    // 不同播放器（广告 iframe 等）即使同页面也绝不合并。
    NSDictionary *main720 = @{@"action":@"resource", @"url":@"https://cdn.example.com/m-720.mp4", @"kind":@"video",
                              @"player":@"ab12.p1", @"size":@"720"};
    NSDictionary *main480 = @{@"action":@"resource", @"url":@"https://cdn.example.com/m-480.mp4", @"kind":@"video",
                              @"player":@"ab12.p1", @"size":@"480"};
    NSDictionary *ad = @{@"action":@"resource", @"url":@"https://ads.example.net/ad.mp4", @"kind":@"video",
                         @"player":@"zz99.p1"};
    NSMutableString *html = [NSMutableString string];
    for (NSDictionary *e in @[main720, main480, ad]) [html appendString:[RDBridgeEventSynthesizer syntheticHTMLForEvent:e]];
    RDProbeResult *bridged = [RDProbeAnalyzer analyzeHTML:html baseURL:[NSURL URLWithString:@"https://example.com/watch"]];
    Check(bridged.media.count == 3, @"三个动态媒体都被发现（实际 %lu）", (unsigned long)bridged.media.count);
    NSString *mainFamily = nil;
    for (DetectedMedia *m in bridged.media) {
        if ([m.mediaURL containsString:@"m-720"] || [m.mediaURL containsString:@"m-480"]) {
            Check(m.videoFamilyID.length > 0, @"同播放器成员带分组身份（%@）", m.mediaURL.lastPathComponent);
            Check(m.declaredVariants.count == 2, @"同播放器成员共享 480p/720p 声明（%@ 实际 %lu）",
                  m.mediaURL.lastPathComponent, (unsigned long)m.declaredVariants.count);
            if (!mainFamily) mainFamily = m.videoFamilyID;
            else Check([m.videoFamilyID isEqualToString:mainFamily], @"同播放器成员共享同一 family");
        }
        if ([m.mediaURL containsString:@"ad.mp4"]) {
            Check(![m.videoFamilyID isEqualToString:mainFamily], @"广告播放器不被并进主片分组（%@）", m.videoFamilyID ?: @"nil");
            Check(m.declaredVariants.count == 0, @"广告播放器不继承主片画质声明（实际 %lu）", (unsigned long)m.declaredVariants.count);
        }
    }
    ResourceDetectorAppDelegate *bridgedApp = [ResourceDetectorAppDelegate new];
    bridgedApp.results = [bridged.media mutableCopy];
    Check(bridgedApp.visibleMedia.count == 2, @"同播放器一行 + 广告一行（实际 %lu）", (unsigned long)bridgedApp.visibleMedia.count);
}

#pragma mark - 5. 提前发布：消费链必须接受动态腿的第二次（最终）更新

// 生产故障（2026-09-10 20:42 现场）：RDHybridPageProbe 改成「静态腿先发布一次
// 临时结果、动态腿回来再发布最终合并结果」后，调用它的 MultiPageResourceProbe
// 仍按「每页只接受第一次完成回调」处理（MultiPageProbeResult.h 明写），于是把
// 临时结果当成该页最终结果、并且立刻把任务标记为 finished —— 动态腿独有的
// 1–3 条资源被整体丢弃。现场表现：资源数稳定 104，而改前多批是 105–107。
//
// 本用例全部走生产代码：RDHybridPageProbe → RDCPageProbeAdapter（生产适配器）
// → MultiPageResourceProbe（App 单页探测的真实消费者）。
static void ConsumerKeepsIncrementalFinalPublish(void) {
    NSURL *page = [NSURL URLWithString:@"https://example.org/watch?v=1"];
    // 静态腿：完整 <video> 块（480p/720p + poster）
    NSString *staticHTML =
        @"<html><body><video poster=\"https://cdn.example.com/cover.jpg\">"
         "<source src=\"https://cdn.example.com/movie-720p.mp4\" size=\"720\">"
         "<source src=\"https://cdn.example.com/movie-480p.mp4\" size=\"480\">"
         "</video></body></html>";
    // 动态腿的完整 DOM：同一部影片 + 一条静态 HTML 里没有的资源
    NSString *dynamicHTML =
        @"<html><body><video poster=\"https://cdn.example.com/cover.jpg\">"
         "<source src=\"https://cdn.example.com/movie-720p.mp4\" size=\"720\">"
         "<source src=\"https://cdn.example.com/movie-480p.mp4\" size=\"480\">"
         "</video>"
         "<video src=\"https://cdn.example.com/only-in-dynamic.mp4\"></video>"
         "</body></html>";
    RDProbeResult *staticParsed = [RDProbeAnalyzer analyzeHTML:staticHTML baseURL:page];
    Check(staticParsed.media.count == 2, @"静态腿解析出两个成员（实际 %lu）", (unsigned long)staticParsed.media.count);

    // 动态腿启动前要做一次真实 DNS 校验（生产安全边界）。把解析结果确定化，
    // 让真实网络抖动不会改变本用例的结论。
    Method statusMethod = class_getClassMethod(DNSResolver.class, @selector(resolveIPsForHost:status:));
    IMP originalStatusIMP = method_getImplementation(statusMethod);
    IMP statusIMP = imp_implementationWithBlock(^NSArray *(id cls, NSString *host, DNSResolutionStatus *outStatus) {
        if (outStatus) *outStatus = DNSResolutionSucceeded;
        return @[@"93.184.216.34"];
    });
    method_setImplementation(statusMethod, statusIMP);

    // ── A. 探针口径：静态腿先发布一次、动态腿再发布最终结果 ──
    SGStaticProbe *staticA = [SGStaticProbe new];
    staticA.media = staticParsed.media;
    SGThinLoader *loaderA = [SGThinLoader new];
    loaderA.html = dynamicHTML;
    loaderA.delay = 0.4;                       // 动态腿比静态腿晚回来
    RDHybridPageProbe *probeA = [[RDHybridPageProbe alloc] initWithPolicy:[SGPolicy new]];
    [probeA setValue:staticA forKey:@"statik"];
    probeA.loaderFactory = ^id<RDProbeLoader> { return loaderA; };
    __block NSUInteger publishCount = 0;
    __block NSUInteger firstPublishCount = 0;
    __block NSUInteger finalPublishCount = 0;
    [probeA probePageURL:page incrementalCompletion:^(NSArray<DetectedMedia *> *media, NSError *error, BOOL isFinal) {
        Check(isFinal == (publishCount > 0), @"静态临时发布与动态最终发布标志正确");
        publishCount += 1;
        if (publishCount == 1) firstPublishCount = media.count;
        finalPublishCount = media.count;       // 最后一次发布 = 探针口径的最终结果
    }];
    Check(Wait(^BOOL { return publishCount >= 2; }, 10),
          @"探针按「静态腿先发布、动态腿再发布」回调两次（实际 %lu 次）", (unsigned long)publishCount);
    Check(firstPublishCount > 0, @"静态腿发布时列表已非空，提前发布确实发生（实际 %lu 条）",
          (unsigned long)firstPublishCount);
    Check(finalPublishCount >= firstPublishCount,
          @"最终条数不小于首次发布条数（首次 %lu / 最终 %lu）",
          (unsigned long)firstPublishCount, (unsigned long)finalPublishCount);
    Check(finalPublishCount > firstPublishCount,
          @"动态腿确实带回了静态腿没有的资源（首次 %lu / 最终 %lu）",
          (unsigned long)firstPublishCount, (unsigned long)finalPublishCount);

    // ── B. 消费链口径：编排器交给上层的列表不得少于探针的最终结果 ──
    SGStaticProbe *staticB = [SGStaticProbe new];
    staticB.media = staticParsed.media;
    SGThinLoader *loaderB = [SGThinLoader new];
    loaderB.html = dynamicHTML;
    loaderB.delay = 0.4;
    RDHybridPageProbe *probeB = [[RDHybridPageProbe alloc] initWithPolicy:[SGPolicy new]];
    [probeB setValue:staticB forKey:@"statik"];
    probeB.loaderFactory = ^id<RDProbeLoader> { return loaderB; };
    RDCPageProbeAdapter *adapter = [[RDCPageProbeAdapter alloc] initWithRawProbe:probeB];
    MultiPageResourceProbe *orchestrator = [[MultiPageResourceProbe alloc] initWithPageProbe:adapter];
    __block NSArray<DetectedMedia *> *consumed = nil;
    [orchestrator probePageURLs:@[page] completion:^(MultiPageProbeSummary *summary) {
        consumed = summary.allMedia ?: @[];
    }];
    Check(Wait(^BOOL { return consumed != nil; }, 10), @"生产编排器返回汇总结果");
    if (!consumed) consumed = @[];
    Check(consumed.count >= finalPublishCount,
          @"编排器交给上层的资源数不少于探针最终发布条数（实际 %lu，探针最终 %lu）",
          (unsigned long)consumed.count, (unsigned long)finalPublishCount);
    BOOL keptDynamicOnly = NO;
    for (DetectedMedia *m in consumed) if ([m.mediaURL containsString:@"only-in-dynamic"]) keptDynamicOnly = YES;
    Check(keptDynamicOnly, @"动态腿独有的资源出现在编排器最终列表里（共 %lu 条）", (unsigned long)consumed.count);

    method_setImplementation(statusMethod, originalStatusIMP);
    imp_removeBlock(statusIMP);
}

#pragma mark - 6. 单页阶段：临时结果先到（列表先出现），最终结果更完整

// 页面探测器替身：能两次发布（静态腿先发 final=NO、动态腿合并后发 final=YES）。
@interface SGIncrementalProbe : NSObject <ZZDiscoveryPageProbing>
@property (nonatomic, copy) NSArray<DetectedMedia *> *interim;
@property (nonatomic, copy) NSArray<DetectedMedia *> *finalMedia;
@property (nonatomic, assign) NSTimeInterval finalDelay;
@end
@implementation SGIncrementalProbe
- (nullable id)probePageURL:(NSURL *)pageURL
                 completion:(void (^)(NSArray<DetectedMedia *> *, NSError *))completion {
    return [self probePageURL:pageURL incrementalCompletion:^(NSArray<DetectedMedia *> *media, NSError *error, BOOL isFinal) {
        if (completion) completion(media, error);
    }];
}
- (nullable id)probePageURL:(NSURL *)pageURL
     incrementalCompletion:(void (^)(NSArray<DetectedMedia *> *, NSError *, BOOL))completion {
    NSArray *interim = self.interim ?: @[];
    NSArray *finalMedia = self.finalMedia ?: @[];
    NSTimeInterval delay = MAX(0, self.finalDelay);
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(interim, nil, NO); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (completion) completion(finalMedia, nil, YES); });
    return self;
}
- (void)cancelProbe:(nullable id)probeToken {}
@end

// 当前页模式不会读取列表 HTML；仅为满足生产初始化签名提供替身。
@interface SGUnusedHTMLProvider : NSObject <ZZDiscoveryHTMLProviding>
@end
@implementation SGUnusedHTMLProvider
- (nullable id)loadHTMLForURL:(NSURL *)url completion:(ZZDiscoveryHTMLCompletion)completion {
    if (completion) completion(nil, nil, [NSError errorWithDomain:@"SG" code:1 userInfo:@{NSLocalizedDescriptionKey: @"unused"}]);
    return nil;
}
- (void)cancelHTMLRequest:(nullable id)requestToken {}
@end

// 生产协调器口径：单页阶段必须先把临时结果透出（列表先出现），随后给出更完整的
// 最终结果；两者 allMedia 口径一致（临时结果是最终结果的子集）。
static void InterimResultPrecedesCompleteFinalResult(void) {
    NSURL *page = [NSURL URLWithString:@"https://example.org/watch?v=1"];
    NSArray<DetectedMedia *> *interim =
        [RDProbeAnalyzer analyzeHTML:
            @"<html><body><video poster=\"https://cdn.example.com/cover.jpg\">"
             "<source src=\"https://cdn.example.com/movie-720p.mp4\" size=\"720\">"
             "<source src=\"https://cdn.example.com/movie-480p.mp4\" size=\"480\">"
             "</video></body></html>"
            baseURL:page].media;
    NSMutableArray<DetectedMedia *> *complete = [interim mutableCopy];
    RDProbeResult *dynamicOnly = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src=\"https://cdn.example.com/only-in-dynamic.mp4\"></video></body></html>"
        baseURL:page];
    [complete addObjectsFromArray:dynamicOnly.media];

    SGIncrementalProbe *probe = [SGIncrementalProbe new];
    probe.interim = interim;
    probe.finalMedia = complete;
    probe.finalDelay = 0.3;
    ResourceDiscoveryCoordinator *coordinator =
        [[ResourceDiscoveryCoordinator alloc] initWithPageProbe:probe htmlProvider:[SGUnusedHTMLProvider new]];
    ZZResourceDiscoveryOptions *options = [ZZResourceDiscoveryOptions defaultOptions];
    options.mode = ZZResourceDiscoveryModeCurrentPage;
    options.maxRetries = 0;

    __block NSUInteger interimCalls = 0;
    __block NSArray<DetectedMedia *> *interimSeen = nil;
    __block NSArray<DetectedMedia *> *finalSeen = nil;
    coordinator.interimResultHandler = ^(ZZResourceDiscoveryResult *r) {
        interimCalls += 1;
        interimSeen = r.allMedia ?: @[];
    };
    [coordinator discoverFromURL:page options:options completion:^(ZZResourceDiscoveryResult *r) {
        finalSeen = r.allMedia ?: @[];
    }];
    Check(Wait(^BOOL { return interimSeen != nil; }, 5), @"单页阶段先收到临时结果（列表先出现）");
    Check(Wait(^BOOL { return finalSeen != nil; }, 5), @"随后收到最终结果");
    if (!interimSeen) interimSeen = @[];
    if (!finalSeen) finalSeen = @[];
    Check(interimCalls >= 1, @"临时结果回调发生在最终结果之前（实际 %lu 次）", (unsigned long)interimCalls);
    Check(interimSeen.count == interim.count, @"临时结果就是静态腿的列表（%lu 条）", (unsigned long)interimSeen.count);
    Check(finalSeen.count >= interimSeen.count,
          @"最终结果不少于临时结果、不丢条目（临时 %lu / 最终 %lu）",
          (unsigned long)interimSeen.count, (unsigned long)finalSeen.count);
    Check(finalSeen.count == complete.count, @"最终结果包含动态腿独有资源（%lu 条）", (unsigned long)finalSeen.count);
}

#pragma mark - 7. 列表重建后按资源身份恢复选中（换签名不得丢选中）

// 真实网址上静态取页腿与动态取页腿各拿到一份签名不同的同一地址
//（…secure=A 与 …secure=B）；临时列表里被选中的资源在最终列表里必须仍能定位到，
// 否则最终结果一到，用户的选中与详情会被无谓地清空。
static void SelectionRestoreMatchesSameResourceAcrossSignatures(void) {
    NSURL *page = [NSURL URLWithString:@"https://example.org/watch?v=1"];
    RDProbeResult *finalResult = [RDProbeAnalyzer analyzeHTML:
        @"<html><body><video src=\"https://cdn.example.com/a.mp4?secure=BBB==,1789009206\"></video>"
         "<video src=\"https://cdn.example.com/b.mp4?secure=BBB==,1789009206\"></video></body></html>"
        baseURL:page];
    ResourceDetectorAppDelegate *app = [ResourceDetectorAppDelegate new];
    app.results = [finalResult.media mutableCopy];
    Check(app.visibleMedia.count == 2, @"最终列表是两行不同视频（实际 %lu）", (unsigned long)app.visibleMedia.count);

    DetectedMedia *pickedInPreview = [DetectedMedia new];   // 临时列表里选中的那份（签名不同）
    pickedInPreview.mediaURL = @"https://cdn.example.com/b.mp4?secure=AAA==,1788998438";
    pickedInPreview.resourceKind = RDResourceKindVideo;
    NSUInteger row = [app visibleRowMatchingMedia:pickedInPreview];
    Check(row != NSNotFound && row < app.visibleMedia.count &&
          [app.visibleMedia[row].mediaURL containsString:@"/b.mp4"],
          @"同一资源换签名（secure=AAA → BBB）后仍恢复选中同一行（实际 row=%ld）", (long)row);

    DetectedMedia *other = [DetectedMedia new];             // 另一条视频：不得被错误恢复
    other.mediaURL = @"https://cdn.example.com/c.mp4?secure=AAA==,1788998438";
    other.resourceKind = RDResourceKindVideo;
    Check([app visibleRowMatchingMedia:other] == NSNotFound,
          @"不同资源的选中项不会被错误恢复（找不到就清空选中）");
}

@interface SGBatchPolicy : URLPolicy
@end
@implementation SGBatchPolicy
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray *)ips {
    if ([url.path isEqual:@"/denied"]) return [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:@"per URL rejection"];
    return [super evaluateResolvedURL:url resolvedIPs:ips];
}
@end

static void ConcurrentGateResolutionsAreSharedOnlyWhileInFlight(void) {
    Method method = class_getClassMethod(DNSResolver.class, @selector(resolveIPsForHost:status:));
    IMP original = method_getImplementation(method);
    __block NSUInteger calls = 0;
    __block BOOL privateAnswer = NO;
    IMP replacement = imp_implementationWithBlock(^NSArray *(id cls, NSString *host, DNSResolutionStatus *status) {
        if (status) *status = DNSResolutionSucceeded;
        @synchronized(DNSResolver.class) { calls++; }
        [NSThread sleepForTimeInterval:0.1];
        return privateAnswer ? @[@"8.8.8.8", @"127.0.0.1"] : @[@"8.8.8.8"];
    });
    method_setImplementation(method, replacement);
    ResourceURLGate *gate = [ResourceURLGate new];
    gate.policy = [SGBatchPolicy new];
    __block NSUInteger completed = 0, allowed = 0;
    for (NSUInteger i = 0; i < 40; i++) {
        NSString *path = i == 0 ? @"denied" : [NSString stringWithFormat:@"asset-%lu", (unsigned long)i];
        [gate verifyURLAsync:[NSURL URLWithString:[@"https://dns-batch.example.org/" stringByAppendingString:path]] completion:^(URLPolicyDecision *d) {
            Check(NSThread.isMainThread, @"DNS batch callback remains on main thread");
            completed++; if (d.allowed) allowed++;
        }];
    }
    Check(Wait(^BOOL { return completed == 40; }, 5), @"All 40 candidate validations complete");
    Check(calls == 1, @"Same-host in-flight batch performs one DNS lookup, actual=%lu", (unsigned long)calls);
    Check(allowed == 39, @"Shared DNS answer still applies URL-specific policy to every candidate");
    NSUInteger before = calls;
    privateAnswer = YES;
    __block BOOL refreshed = NO;
    [gate verifyURLAsync:[NSURL URLWithString:@"https://dns-batch.example.org/asset-next"] completion:^(URLPolicyDecision *d) {
        Check(!d.allowed, @"Later DNS change containing any private address is rejected"); refreshed = YES;
    }];
    Check(Wait(^BOOL { return refreshed; }, 5), @"Later request completes independently");
    Check(calls == before + 1, @"Completed DNS answer is not cached for later requests");
    method_setImplementation(method, original);
    imp_removeBlock(replacement);
}

static void BadPageReachesActualAppStatus(void) {
    for (NSUInteger mode=0;mode<4;mode++) {
        SGStaticProbe *statik=[SGStaticProbe new];statik.media=@[];
        SGThinLoader *loader=[SGThinLoader new];
        loader.html=mode==0?@"<html><body><form>Login</form></body></html>":@"";
        if(mode>0&&mode<3)statik.error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:@{NSLocalizedDescriptionKey:@"页面读取失败"}];
        if(mode>=2)loader.error=[AppError errorWithType:AppErrorOffline message:@"页面读取失败"];
        RDHybridPageProbe *hybrid=[[RDHybridPageProbe alloc]initWithPolicy:[SGPolicy new]];
        [hybrid setValue:statik forKey:@"statik"];hybrid.loaderFactory=^id<RDProbeLoader>{return loader;};
        DiscoverySessionController *session=[[DiscoverySessionController alloc]initWithPageProbe:hybrid htmlProvider:hybrid delayScheduler:^(NSTimeInterval delay,dispatch_block_t block){block();}];
        ResourceDetectorAppDelegate *app=[ResourceDetectorAppDelegate new];app.statusNote=[NSTextField labelWithString:@"previous"];
        __block BOOL done=NO;
        session.resultHandler=^(ZZResourceDiscoveryResult *result){[app finishScanWithResult:result];done=YES;};
        [session startWithURL:[NSURL URLWithString:@"https://93.184.216.34/page"] mode:ZZResourceDiscoveryModeCurrentPage];
        Check(Wait(^BOOL{return done;},5),@"Hybrid -> DiscoverySessionController -> actual App result handler completes mode=%lu",(unsigned long)mode);
        NSString *expected=mode==0?@"未发现可下载资源":mode==1?@"无法识别":@"读取失败";
        Check([app.statusNote.stringValue containsString:expected],@"Actual App status distinguishes %@: %@",expected,app.statusNote.stringValue);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BadPageReachesActualAppStatus();
        ConcurrentGateResolutionsAreSharedOnlyWhileInFlight();
        StreamingDocumentIsNotDeliveredEarly();
        HybridMergeKeepsRicherMember();
        ConsumerKeepsIncrementalFinalPublish();
        InterimResultPrecedesCompleteFinalResult();
        SelectionRestoreMatchesSameResourceAcrossSignatures();
        DetailShowsQualityPickerAndSelectionStaysConsistent();
        PercentEncodingIdentity();
        SingleSourceVideoAndPlayerIdentity();
    DiscoveryProgressHasNoPercentBar();
    DiscoveryProgressHasNoVisibleBarOnJump();
    CircularProgressControlIsRemoved();
        CheckSummary();
    }
    return 0;
}
