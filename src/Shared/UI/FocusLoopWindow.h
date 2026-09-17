//
//  FocusLoopWindow.h — 迁移自 App/SevenZZToolbox.m
//
//  主窗口：测试模式（ZZIsTestMode）下 makeKeyAndOrderFront / orderFrontRegardless /
//  canBecomeKey / canBecomeMain 一律降级，绝不抢前台；含边缘缩放与 Tab 键遍历修正。
//
#import <Cocoa/Cocoa.h>

@interface FocusLoopWindow : NSWindow
- (BOOL)handleEdgeResizeIfNeeded:(NSEvent *)event;
@end
