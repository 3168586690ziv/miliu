//
//  UIType.m — 向指定 App 注入键盘输入（真实 UI 验收用；需要辅助功能权限）
//  用法：UIType <bundle 路径或进程名> <文本>            # 输入文本
//        UIType <bundle 路径或进程名> --key return       # 回车
//        UIType --trusted                                # 只打印辅助功能授权状态
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static BOOL ActivateTarget(NSString *target, pid_t *outPID) {
    NSRunningApplication *app = nil;
    for (NSRunningApplication *candidate in [NSWorkspace sharedWorkspace].runningApplications) {
        if ([candidate.bundleURL.path isEqualToString:target] ||
            [candidate.localizedName isEqualToString:target] ||
            [candidate.executableURL.lastPathComponent isEqualToString:target]) { app = candidate; break; }
    }
    if (!app) {
        NSURL *url = [NSURL fileURLWithPath:target];
        app = [NSRunningApplication runningApplicationsWithBundleIdentifier:
               [[NSBundle bundleWithURL:url] bundleIdentifier]].firstObject;
    }
    if (!app) { printf("TYPE-FAIL 找不到运行中的目标 App：%s\n", target.UTF8String); return NO; }
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    if (outPID) *outPID = app.processIdentifier;
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--trusted") == 0) {
            printf("AX-TRUSTED %d\n", AXIsProcessTrusted() ? 1 : 0);
            return 0;
        }
        if (argc < 3) { printf("usage: UIType <app> <text>|--key return\n"); return 2; }
        NSString *target = [NSString stringWithUTF8String:argv[1]];
        pid_t pid = 0;
        if (!ActivateTarget(target, &pid)) return 1;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];

        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        BOOL key = strcmp(argv[2], "--key") == 0;
        if (key) {
            if (argc < 4 || strcmp(argv[3], "return") != 0) { printf("TYPE-FAIL 仅支持 --key return\n"); return 2; }
            CGEventRef down = CGEventCreateKeyboardEvent(source, 36, true);
            CGEventRef up = CGEventCreateKeyboardEvent(source, 36, false);
            CGEventPostToPid(pid, down); CGEventPostToPid(pid, up);
            CFRelease(down); CFRelease(up);
            printf("TYPE-OK 已向 pid=%d 发送回车\n", pid);
        } else {
            NSString *text = [NSString stringWithUTF8String:argv[2]];
            for (NSUInteger i = 0; i < text.length; i++) {
                UniChar ch = [text characterAtIndex:i];
                CGEventRef down = CGEventCreateKeyboardEvent(source, 0, true);
                CGEventKeyboardSetUnicodeString(down, 1, &ch);
                CGEventPostToPid(pid, down);
                CFRelease(down);
                CGEventRef up = CGEventCreateKeyboardEvent(source, 0, false);
                CGEventKeyboardSetUnicodeString(up, 1, &ch);
                CGEventPostToPid(pid, up);
                CFRelease(up);
                usleep(12000);
            }
            printf("TYPE-OK 已向 pid=%d 注入 %lu 个字符\n", pid, (unsigned long)text.length);
        }
        if (source) CFRelease(source);
    }
    return 0;
}
