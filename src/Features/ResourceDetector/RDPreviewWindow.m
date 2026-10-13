//
//  RDPreviewWindow.m — 视频预览播放窗口实现（第 35 轮）
//
//  自包含约束（同 RDInAppBrowserWindow）：本文件编入主 App，
//  只依赖系统框架，不反向引用 App 层。窗口由用户点击「预览」触发（App 已在
//  前台），只 makeKeyAndOrderFront:，不得抢前台；attachPlayer 与 showError
//  互斥：先调哪个显示哪个。
//

#import "RDPreviewWindow.h"
#import <AppKit/AppKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

static RDPreviewWindow *_sharedInstance = nil;

NSString * const RDPreviewWindowDidCloseNotification = @"RDPreviewWindowDidClose";

@interface RDPreviewWindow () <NSWindowDelegate>
@end

@implementation RDPreviewWindow {
    NSWindow *_window;
    AVPlayerView *_playerView;
    NSTextField *_errorLabel;
}

#pragma mark - 类接口（主线程调用）

+ (void)attachPlayer:(AVPlayer *)player title:(NSString *)title {
    if (!_sharedInstance) _sharedInstance = [[RDPreviewWindow alloc] init];
    [_sharedInstance showWithPlayer:player title:title];
}

+ (void)showError:(NSString *)message title:(NSString *)title {
    if (!_sharedInstance) _sharedInstance = [[RDPreviewWindow alloc] init];
    [_sharedInstance showWithErrorMessage:message title:title];
}

+ (void)close {
    // 单例为 nil（窗口已关）时即 no-op；关窗统一走 windowWillClose。
    if (!_sharedInstance) return;
    [_sharedInstance closeWindow];
}

- (void)closeWindow {
    [_window close];
}

#pragma mark - 窗口与内容构建

- (instancetype)init {
    self = [super init];
    if (!self) return self;
    NSRect frame = NSMakeRect(0, 0, 1040, 640);   // 16:10，比浏览器窗口更贴合视频
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskTitled
                                                        | NSWindowStyleMaskClosable
                                                        | NSWindowStyleMaskMiniaturizable
                                                        | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = @"预览播放";
    win.identifier = @"RDPreviewWindow";
    win.releasedWhenClosed = NO;
    win.delegate = self;

    // 播放视图铺满内容区；AVPlayer 自行缓冲，无需自定义 loading UI。
    AVPlayerView *playerView = [[AVPlayerView alloc] initWithFrame:frame];
    playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // 错误态文案：初始隐藏；四向 margin 弹性 + 宽度弹性，窗口缩放时保持居中。
    NSTextField *errorLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(40, (frame.size.height - 80) / 2, frame.size.width - 80, 80)];
    errorLabel.editable = NO;
    errorLabel.selectable = NO;
    errorLabel.bordered = NO;
    errorLabel.drawsBackground = NO;
    errorLabel.font = [NSFont systemFontOfSize:13];
    errorLabel.textColor = NSColor.secondaryLabelColor;
    errorLabel.alignment = NSTextAlignmentCenter;
    errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    errorLabel.maximumNumberOfLines = 0;
    errorLabel.hidden = YES;
    errorLabel.identifier = @"RDPreviewErrorText";
    errorLabel.autoresizingMask = NSViewMinXMargin | NSViewWidthSizable | NSViewMaxXMargin
                                | NSViewMinYMargin | NSViewMaxYMargin;

    [win.contentView addSubview:playerView];   // 底层
    [win.contentView addSubview:errorLabel];   // 错误态在上层

    _window = win;
    _playerView = playerView;
    _errorLabel = errorLabel;
    return self;
}

- (void)showWithPlayer:(AVPlayer *)player title:(NSString *)title {
    _errorLabel.hidden = YES;
    _playerView.hidden = NO;
    _playerView.player = player;
    _window.title = title.length ? title : @"预览播放";
    // 不调 activateIgnoringOtherApps:——预览由用户点击触发，App 已在前台。
    [_window makeKeyAndOrderFront:nil];
}

- (void)showWithErrorMessage:(NSString *)message title:(NSString *)title {
    _playerView.player = nil;   // 顺带释放解码资源
    _playerView.hidden = YES;
    _errorLabel.stringValue = message ?: @"";
    _errorLabel.hidden = NO;
    _window.title = title.length ? title : @"预览播放";
    [_window makeKeyAndOrderFront:nil];
}

#pragma mark - NSWindowDelegate

// 手动点红绿灯与代码 +close 走同一路径：清单例、释放解码资源、发关闭通知。
- (void)windowWillClose:(NSNotification *)notification {
    if (_sharedInstance == self) _sharedInstance = nil;
    _window = nil;
    _playerView.player = nil;
    _playerView = nil;
    _errorLabel = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:RDPreviewWindowDidCloseNotification object:nil];
}

@end
