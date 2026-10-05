//
//  RDWatchAgentMain.m — 「Miliu追更助手」进程入口
//
//  只做 NSApplication 的 accessory 装配（LSUIElement、无 Dock 图标）：
//    · 设激活策略为 Accessory（配合 Helper-Info.plist 的 LSUIElement=true）
//    · 创建 RDWatchAgentController 并挂为 application delegate
//  全部业务逻辑（状态栏、探测循环、通知、SMAppService）在控制器内，由
//  applicationDidFinishLaunching 起步。
//
#import <Cocoa/Cocoa.h>
#import "RDWatchAgentController.h"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        RDWatchAgentController *controller = [[RDWatchAgentController alloc] init];
        application.delegate = controller;
        [application run];
    }
    return 0;
}
