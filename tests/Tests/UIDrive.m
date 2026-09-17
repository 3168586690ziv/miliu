//
//  UIDrive.m — 驱动真实 App 界面（AX 仅用于操作；判断仍以屏幕截图/OCR 为准）
//  用法：
//    UIDrive <app> dump [maxDepth]                 # 打印 AX 树（驱动用）
//    UIDrive <app> press <role> <title>            # 按 AXPress 点击匹配元素
//    UIDrive <app> select-row <tableTitle> <idx>   # 选中表格第 idx 行
//    UIDrive <app> select-quality <label>          # 打开画质下拉并选择标签
//    UIDrive <app> read <role> <title>             # 读取 AXValue/AXTitle
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSRunningApplication *FindApp(NSString *target) {
    for (NSRunningApplication *candidate in [NSWorkspace sharedWorkspace].runningApplications) {
        if ([candidate.bundleURL.path isEqualToString:target] ||
            [candidate.localizedName isEqualToString:target] ||
            [candidate.executableURL.lastPathComponent isEqualToString:target]) return candidate;
    }
    NSURL *url = [NSURL fileURLWithPath:target];
    NSString *bundleID = [[NSBundle bundleWithURL:url] bundleIdentifier];
    if (bundleID.length) return [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].firstObject;
    return nil;
}

static NSString *CopyAttr(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    NSString *out = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) out = [(__bridge NSString *)value copy];
    else if (CFGetTypeID(value) == CFNumberGetTypeID()) out = [(__bridge NSNumber *)value description];
    CFRelease(value);
    return out;
}

static void DumpTree(AXUIElementRef element, int depth, int maxDepth) {
    if (depth > maxDepth) return;
    NSString *role = CopyAttr(element, kAXRoleAttribute) ?: @"?";
    NSString *title = CopyAttr(element, kAXTitleAttribute) ?: @"";
    NSString *value = CopyAttr(element, kAXValueAttribute) ?: @"";
    NSString *desc = CopyAttr(element, kAXDescriptionAttribute) ?: @"";
    NSString *ident = CopyAttr(element, kAXIdentifierAttribute) ?: @"";
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@AX %@", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0], role];
    if (title.length) [line appendFormat:@" title=%@", title];
    if (value.length) [line appendFormat:@" value=%@", [value length] > 60 ? [[value substringToIndex:60] stringByAppendingString:@"…"] : value];
    if (desc.length) [line appendFormat:@" desc=%@", desc];
    if (ident.length) [line appendFormat:@" id=%@", ident];
    printf("%s\n", line.UTF8String);
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        CFArrayRef array = (CFArrayRef)children;
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++)
            DumpTree((AXUIElementRef)CFArrayGetValueAtIndex(array, i), depth + 1, maxDepth);
        CFRelease(children);
    }
}

static AXUIElementRef FindElement(AXUIElementRef root, NSString *role, NSString *title, int depth, int maxDepth) {
    if (depth > maxDepth) return NULL;
    NSString *r = CopyAttr(root, kAXRoleAttribute);
    NSString *t = CopyAttr(root, kAXTitleAttribute);
    NSString *v = CopyAttr(root, kAXValueAttribute);
    NSString *d = CopyAttr(root, kAXDescriptionAttribute);
    BOOL roleOK = !role.length || [r isEqualToString:role] ||
        ([role isEqualToString:@"AXButton"] && ([r isEqualToString:@"AXButton"] || [r isEqualToString:@"AXPopUpButton"]));
    BOOL titleOK = !title.length || [t isEqualToString:title] || [v isEqualToString:title] || [d isEqualToString:title];
    if (roleOK && titleOK && (title.length || role.length)) return (AXUIElementRef)CFRetain(root);
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(root, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        CFArrayRef array = (CFArrayRef)children;
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            AXUIElementRef found = FindElement((AXUIElementRef)CFArrayGetValueAtIndex(array, i), role, title, depth + 1, maxDepth);
            if (found) { CFRelease(children); return found; }
        }
        CFRelease(children);
    }
    return NULL;
}

static AXUIElementRef AppRoot(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef windows = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows) == kAXErrorSuccess && windows) {
        CFArrayRef array = (CFArrayRef)windows;
        if (CFArrayGetCount(array) > 0) {
            AXUIElementRef window = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(array, 0));
            CFRelease(windows);
            CFRelease(app);
            return window;
        }
        CFRelease(windows);
    }
    return app;
}

static NSArray *FindAll(AXUIElementRef root, NSString *role, int depth, int maxDepth) {
    NSMutableArray *out = [NSMutableArray array];
    if (depth > maxDepth) return out;
    NSString *r = CopyAttr(root, kAXRoleAttribute);
    if (!role.length || [r isEqualToString:role]) [out addObject:(__bridge id)root];
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(root, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        CFArrayRef array = (CFArrayRef)children;
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++)
            [out addObjectsFromArray:FindAll((AXUIElementRef)CFArrayGetValueAtIndex(array, i), role, depth + 1, maxDepth)];
        CFRelease(children);
    }
    return out;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { printf("usage: UIDrive <app> dump|press|select-row|select-quality|read ...\n"); return 2; }
        NSString *target = [NSString stringWithUTF8String:argv[1]];
        NSString *command = [NSString stringWithUTF8String:argv[2]];
        NSRunningApplication *app = FindApp(target);
        if (!app) { printf("DRIVE-FAIL 找不到运行中的 App：%s\n", target.UTF8String); return 1; }
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        pid_t pid = app.processIdentifier;
        AXUIElementRef root = AppRoot(pid);

        if ([command isEqualToString:@"click-at"]) {
            double x = argc > 3 ? atof(argv[3]) : 0, y = argc > 4 ? atof(argv[4]) : 0;
            CGPoint point = CGPointMake(x, y);
            CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            CGEventPostToPid(pid, down); CGEventPostToPid(pid, up);
            CFRelease(down); CFRelease(up);
            printf("DRIVE-CLICK x=%.0f y=%.0f pid=%d\n", x, y, pid);
        } else if ([command isEqualToString:@"focus-text"]) {
            NSArray *fields = FindAll(root, @"AXTextField", 0, 12);
            if (!fields.count) { printf("DRIVE-FAIL 未找到文本框\n"); return 1; }
            AXUIElementRef field = (__bridge AXUIElementRef)fields.firstObject;
            AXError err = AXUIElementSetAttributeValue(field, kAXFocusedAttribute, kCFBooleanTrue);
            printf("DRIVE-FOCUS fields=%lu err=%d\n", (unsigned long)fields.count, (int)err);
            if (err != kAXErrorSuccess) return 1;
        } else if ([command isEqualToString:@"window"]) {
            CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
            for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
                if ([info[(id)kCGWindowOwnerPID] intValue] != pid) continue;
                NSDictionary *bounds = info[(id)kCGWindowBounds];
                printf("WINDOW id=%d x=%.0f y=%.0f w=%.0f h=%.0f name=%s\n",
                       [info[(id)kCGWindowNumber] intValue],
                       [bounds[@"X"] doubleValue], [bounds[@"Y"] doubleValue],
                       [bounds[@"Width"] doubleValue], [bounds[@"Height"] doubleValue],
                       [info[(id)kCGWindowName] UTF8String] ?: "");
            }
            if (list) CFRelease(list);
        } else if ([command isEqualToString:@"dump"]) {
            int maxDepth = argc > 3 ? atoi(argv[3]) : 6;
            DumpTree(root, 0, maxDepth);
        } else if ([command isEqualToString:@"press"]) {
            NSString *role = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            NSString *title = argc > 4 ? [NSString stringWithUTF8String:argv[4]] : @"";
            AXUIElementRef found = FindElement(root, role, title, 0, 12);
            if (!found) { printf("DRIVE-FAIL 未找到 role=%s title=%s\n", role.UTF8String, title.UTF8String); return 1; }
            AXError err = AXUIElementPerformAction(found, kAXPressAction);
            printf("DRIVE-PRESS role=%s title=%s err=%d\n", role.UTF8String, title.UTF8String, (int)err);
            CFRelease(found);
            if (err != kAXErrorSuccess) return 1;
        } else if ([command isEqualToString:@"select-row"]) {
            NSString *tableTitle = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            NSInteger index = argc > 4 ? atoi(argv[4]) : 0;
            NSArray *tables = FindAll(root, @"AXTable", 0, 12);
            if (!tables.count) tables = FindAll(root, @"AXOutline", 0, 12);
            if (!tables.count) { printf("DRIVE-FAIL 未找到表格\n"); return 1; }
            AXUIElementRef table = (__bridge AXUIElementRef)tables.firstObject;
            (void)tableTitle;
            CFTypeRef rowsValue = NULL;
            if (AXUIElementCopyAttributeValue(table, kAXRowsAttribute, &rowsValue) != kAXErrorSuccess || !rowsValue) {
                printf("DRIVE-FAIL 表格没有 AXRows\n"); return 1;
            }
            CFArrayRef rows = (CFArrayRef)rowsValue;
            if (index < 0 || index >= CFArrayGetCount(rows)) {
                printf("DRIVE-FAIL 行号越界：%ld / %ld\n", (long)index, (long)CFArrayGetCount(rows));
                CFRelease(rowsValue); return 1;
            }
            AXUIElementRef row = (AXUIElementRef)CFArrayGetValueAtIndex(rows, index);
            CFArrayRef selection = CFArrayCreate(NULL, (const void **)&row, 1, &kCFTypeArrayCallBacks);
            AXError err = AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute, selection);
            printf("DRIVE-SELECT-ROW index=%ld rows=%ld err=%d\n", (long)index, (long)CFArrayGetCount(rows), (int)err);
            CFRelease(selection);
            CFRelease(rowsValue);
            if (err != kAXErrorSuccess) return 1;
        } else if ([command isEqualToString:@"select-quality"]) {
            NSString *label = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            NSArray *popups = FindAll(root, @"AXPopUpButton", 0, 12);
            if (!popups.count) { printf("DRIVE-FAIL 未找到画质下拉\n"); return 1; }
            AXUIElementRef popup = (__bridge AXUIElementRef)popups.firstObject;
            AXUIElementPerformAction(popup, kAXPressAction);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
            AXUIElementRef item = FindElement(root, @"AXMenuItem", label, 0, 14);
            if (!item) { printf("DRIVE-FAIL 未找到菜单项 %s\n", label.UTF8String); return 1; }
            AXError err = AXUIElementPerformAction(item, kAXPressAction);
            printf("DRIVE-SELECT-QUALITY label=%s err=%d\n", label.UTF8String, (int)err);
            CFRelease(item);
            if (err != kAXErrorSuccess) return 1;
        } else if ([command isEqualToString:@"read"]) {
            NSString *role = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            NSString *title = argc > 4 ? [NSString stringWithUTF8String:argv[4]] : @"";
            AXUIElementRef found = FindElement(root, role, title, 0, 12);
            if (!found) { printf("DRIVE-FAIL 未找到 role=%s title=%s\n", role.UTF8String, title.UTF8String); return 1; }
            printf("DRIVE-READ value=%s\n", (CopyAttr(found, kAXValueAttribute) ?: CopyAttr(found, kAXTitleAttribute) ?: @"(空)").UTF8String);
            CFRelease(found);
        } else {
            printf("DRIVE-FAIL 未知命令 %s\n", command.UTF8String);
            CFRelease(root);
            return 2;
        }
        CFRelease(root);
    }
    return 0;
}
