//
//  AXProbe.m — 黑盒 UI 验收探针（本工具不属于 tests/，不修改任何既有测试）
//  只通过辅助功能（AX）通道观测/操作真实 App：读元素文本、读元素屏幕坐标、
//  按标题点击、切下拉、改窗口尺寸。判断以实际读回的数值为准。
//
//  用法：
//    AXProbe <app> trusted
//    AXProbe <app> windows
//    AXProbe <app> tree [maxDepth]
//    AXProbe <app> find <substring>
//    AXProbe <app> press <title> [role]
//    AXProbe <app> pressid <identifier>
//    AXProbe <app> popup-pick <label>
//    AXProbe <app> resize <w> <h>
//    AXProbe <app> scroll [0..1]      # 设滚动区域垂直滚动条位置（验证表单区可滚动）
//    AXProbe <app> focus-text
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSRunningApplication *FindApp(NSString *target) {
    for (NSRunningApplication *c in [NSWorkspace sharedWorkspace].runningApplications) {
        if ([c.bundleURL.path isEqualToString:target] ||
            [c.localizedName isEqualToString:target] ||
            [c.executableURL.lastPathComponent isEqualToString:target]) return c;
    }
    NSURL *url = [NSURL fileURLWithPath:target];
    NSString *bid = [[NSBundle bundleWithURL:url] bundleIdentifier];
    if (bid.length) return [NSRunningApplication runningApplicationsWithBundleIdentifier:bid].firstObject;
    return nil;
}

static NSString *Attr(AXUIElementRef e, CFStringRef a) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, a, &v) != kAXErrorSuccess || !v) return nil;
    NSString *out = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) out = [(__bridge NSString *)v copy];
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) out = [(__bridge NSNumber *)v description];
    CFRelease(v);
    return out;
}

static BOOL ElementFrame(AXUIElementRef e, CGRect *out) {
    CFTypeRef p = NULL, s = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXPositionAttribute, &p) != kAXErrorSuccess || !p) return NO;
    if (AXUIElementCopyAttributeValue(e, kAXSizeAttribute, &s) != kAXErrorSuccess || !s) { CFRelease(p); return NO; }
    CGPoint pt = CGPointZero; CGSize sz = CGSizeZero;
    AXValueGetValue((AXValueRef)p, kAXValueTypeCGPoint, &pt);
    AXValueGetValue((AXValueRef)s, kAXValueTypeCGSize, &sz);
    CFRelease(p); CFRelease(s);
    *out = CGRectMake(pt.x, pt.y, sz.width, sz.height);
    return YES;
}

static void Collect(AXUIElementRef root, NSMutableArray *out, int depth, int maxDepth) {
    if (depth > maxDepth) return;
    [out addObject:(__bridge id)root];
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(root, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        CFArrayRef arr = (CFArrayRef)children;
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++)
            Collect((AXUIElementRef)CFArrayGetValueAtIndex(arr, i), out, depth + 1, maxDepth);
        CFRelease(children);
    }
}

static AXUIElementRef AppRoot(pid_t pid, BOOL wantWindow);

static AXUIElementRef MainWindow(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef windows = NULL;
    AXUIElementRef best = NULL;
    double bestArea = -1;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows) == kAXErrorSuccess && windows) {
        CFArrayRef arr = (CFArrayRef)windows;
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(arr, i);
            CGRect f = CGRectZero;
            if (!ElementFrame(w, &f)) continue;
            double area = f.size.width * f.size.height;
            if (area > bestArea) { bestArea = area; best = (AXUIElementRef)CFRetain(w); }
        }
        CFRelease(windows);
    }
    CFRelease(app);
    return best ? best : AppRoot(pid, YES);
}

static AXUIElementRef AppRoot(pid_t pid, BOOL wantWindow) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef windows = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows) == kAXErrorSuccess && windows) {
        CFArrayRef arr = (CFArrayRef)windows;
        if (CFArrayGetCount(arr) > 0) {
            AXUIElementRef w = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(arr, 0));
            CFRelease(windows);
            if (wantWindow) { CFRelease(app); return w; }
            CFRelease(w);
            return app;
        }
        CFRelease(windows);
    }
    return app;
}

static NSString *Describe(AXUIElementRef e) {
    NSString *role = Attr(e, kAXRoleAttribute) ?: @"?";
    NSString *title = Attr(e, kAXTitleAttribute) ?: @"";
    NSString *value = Attr(e, kAXValueAttribute) ?: @"";
    NSString *desc = Attr(e, kAXDescriptionAttribute) ?: @"";
    NSString *ident = Attr(e, kAXIdentifierAttribute) ?: @"";
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@", role];
    if (ident.length) [s appendFormat:@" id=%@", ident];
    if (title.length) [s appendFormat:@" title=\"%@\"", title];
    if (value.length) [s appendFormat:@" value=\"%@\"", value.length > 90 ? [[value substringToIndex:90] stringByAppendingString:@"…"] : value];
    if (desc.length) [s appendFormat:@" desc=\"%@\"", desc];
    return s;
}

static void DumpTree(AXUIElementRef e, int depth, int maxDepth) {
    if (depth > maxDepth) return;
    CGRect f = CGRectZero;
    BOOL hasFrame = ElementFrame(e, &f);
    // 滚动区域额外标注「有几个滚动条」：ui_audit 据此判断被裁剪出去的内容是否可达
    // （没有任何滚动条的裁剪 = 内容不可达，仍按越界处理）。
    NSMutableString *scrollInfo = [NSMutableString string];
    if ([Attr(e, kAXRoleAttribute) isEqualToString:@"AXScrollArea"]) {
        int v = 0, h = 0;
        CFTypeRef sb = NULL;
        if (AXUIElementCopyAttributeValue(e, kAXVerticalScrollBarAttribute, &sb) == kAXErrorSuccess && sb) { v = 1; CFRelease(sb); }
        sb = NULL;
        if (AXUIElementCopyAttributeValue(e, kAXHorizontalScrollBarAttribute, &sb) == kAXErrorSuccess && sb) { h = 1; CFRelease(sb); }
        [scrollInfo appendFormat:@"  scrollers=v%d h%d", v, h];
    }
    printf("%s%s%s%s\n",
           [[@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0] UTF8String],
           Describe(e).UTF8String,
           hasFrame ? [NSString stringWithFormat:@"  @ x=%.0f y=%.0f w=%.0f h=%.0f", f.origin.x, f.origin.y, f.size.width, f.size.height].UTF8String : "",
           scrollInfo.UTF8String);
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        CFArrayRef arr = (CFArrayRef)children;
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++)
            DumpTree((AXUIElementRef)CFArrayGetValueAtIndex(arr, i), depth + 1, maxDepth);
        CFRelease(children);
    }
}

static BOOL Matches(AXUIElementRef e, NSString *needle) {
    NSArray *attrs = @[(__bridge NSString *)kAXTitleAttribute, (__bridge NSString *)kAXValueAttribute,
                       (__bridge NSString *)kAXDescriptionAttribute, (__bridge NSString *)kAXIdentifierAttribute];
    for (NSString *a in attrs) {
        NSString *v = Attr(e, (__bridge CFStringRef)a);
        if (v.length && [v containsString:needle]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { printf("usage: AXProbe <app> trusted|windows|tree|find|press|pressid|popup-pick|resize|focus-text ...\n"); return 2; }
        NSString *target = [NSString stringWithUTF8String:argv[1]];
        NSString *cmd = [NSString stringWithUTF8String:argv[2]];

        if ([cmd isEqualToString:@"trusted"]) {
            printf("AX-TRUSTED %d\n", AXIsProcessTrusted() ? 1 : 0);
            return 0;
        }
        NSRunningApplication *app = FindApp(target);
        if (!app) { printf("AX-FAIL 找不到运行中的 App：%s\n", target.UTF8String); return 1; }
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        pid_t pid = app.processIdentifier;

        if ([cmd isEqualToString:@"info"]) {
            NSBundle *bundle = [NSBundle bundleWithURL:app.bundleURL];
            NSString *shortV = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
            NSString *buildV = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
            printf("AX-INFO pid=%d path=%s version=%s build=%s\n",
                   (int)app.processIdentifier, app.bundleURL.path.UTF8String,
                   shortV.UTF8String, buildV.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"quit"]) {
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef down = CGEventCreateKeyboardEvent(source, 12 /* q */, true);
            CGEventSetFlags(down, kCGEventFlagMaskCommand);
            CGEventRef up = CGEventCreateKeyboardEvent(source, 12, false);
            CGEventSetFlags(up, kCGEventFlagMaskCommand);
            CGEventPostToPid(pid, down);
            CGEventPostToPid(pid, up);
            CFRelease(down); CFRelease(up); CFRelease(source);
            printf("AX-QUIT 已发送 ⌘Q 到 pid=%d\n", (int)pid);
            return 0;
        }

        if ([cmd isEqualToString:@"windows"]) {
            CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
            int n = 0;
            for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
                if ([info[(id)kCGWindowOwnerPID] intValue] != pid) continue;
                NSDictionary *b = info[(id)kCGWindowBounds];
                printf("WINDOW id=%d x=%.0f y=%.0f w=%.0f h=%.0f name=%s\n",
                       [info[(id)kCGWindowNumber] intValue], [b[@"X"] doubleValue], [b[@"Y"] doubleValue],
                       [b[@"Width"] doubleValue], [b[@"Height"] doubleValue], [info[(id)kCGWindowName] UTF8String] ?: "");
                n++;
            }
            if (list) CFRelease(list);
            if (!n) printf("WINDOW none\n");
            return 0;
        }

        if ([cmd isEqualToString:@"resize"]) {
            if (argc < 5) { printf("usage: AXProbe <app> resize <w> <h>\n"); return 2; }
            AXUIElementRef win = MainWindow(pid);
            CGSize sz = CGSizeMake(atof(argv[3]), atof(argv[4]));
            AXValueRef val = AXValueCreate(kAXValueTypeCGSize, &sz);
            AXError err = AXUIElementSetAttributeValue(win, kAXSizeAttribute, val);
            CFRelease(val);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
            CGRect f = CGRectZero;
            BOOL ok = ElementFrame(win, &f);
            printf("AX-RESIZE 请求=%.0fx%.0f err=%d 实际=%.0fx%.0f\n", sz.width, sz.height, (int)err,
                   ok ? f.size.width : -1, ok ? f.size.height : -1);
            CFRelease(win);
            return err == kAXErrorSuccess ? 0 : 1;
        }

        if ([cmd isEqualToString:@"scroll"]) {
            // 用法: AXProbe <app> scroll [0..1]
            // 读回滚动容器的 AXVerticalScrollBar 并把 AXValue 设为指定比例。
            // 用途：验证「表单区滚动」——最小窗口下垂直滚动条存在且能滚到最底。
            double target = argc > 3 ? atof(argv[3]) : 1.0;
            NSMutableArray *tree = [NSMutableArray array];
            Collect(AppRoot(pid, NO), tree, 0, 20);
            AXUIElementRef area = NULL, bar = NULL;
            for (id obj in tree) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                if ([Attr(e, kAXRoleAttribute) isEqualToString:@"AXScrollArea"]) {
                    CFTypeRef v = NULL;
                    if (AXUIElementCopyAttributeValue(e, kAXVerticalScrollBarAttribute, &v) == kAXErrorSuccess && v) {
                        area = e; bar = (AXUIElementRef)v;
                        break;
                    }
                }
            }
            if (!bar) { printf("AX-FAIL 未找到带垂直滚动条的滚动区域\n"); return 1; }
            NSString *before = Attr(bar, kAXValueAttribute) ?: @"(读不到)";
            // 滚动条的 AXValue 是裸数值：直接用 CFNumber 写回（AXValue 没有“纯 double”类型）。
            CFNumberRef num = CFNumberCreate(NULL, kCFNumberDoubleType, &target);
            AXError err = AXUIElementSetAttributeValue(bar, kAXValueAttribute, num);
            CFRelease(num);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            printf("AX-SCROLL 目标=%.2f err=%d 前=%s 后=%s\n", target, (int)err,
                   before.UTF8String, (Attr(bar, kAXValueAttribute) ?: @"(读不到)").UTF8String);
            (void)area;
            CFRelease(bar);
            return err == kAXErrorSuccess ? 0 : 1;
        }

        AXUIElementRef root = AppRoot(pid, NO);
        NSMutableArray *all = [NSMutableArray array];
        Collect(root, all, 0, 20);

        if ([cmd isEqualToString:@"menupress"]) {
            NSString *itemTitle = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            NSMutableArray *tree = [NSMutableArray array];
            Collect(root, tree, 0, 20);
            AXUIElementRef barItem = NULL;
            for (id obj in tree) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                NSString *r = Attr(e, kAXRoleAttribute);
                NSString *t = Attr(e, kAXTitleAttribute);
                if ([r isEqualToString:@"AXMenuBarItem"] && ![t isEqualToString:@"Apple"] && t.length) {
                    barItem = (AXUIElementRef)CFRetain(e); break;
                }
            }
            if (!barItem) { printf("AX-FAIL 未找到应用菜单\n"); CFRelease(root); return 1; }
            AXUIElementPerformAction(barItem, kAXPressAction);
            CFRelease(barItem);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
            NSMutableArray *tree2 = [NSMutableArray array];
            Collect(root, tree2, 0, 20);
            AXUIElementRef item = NULL;
            for (id obj in tree2) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                NSString *r = Attr(e, kAXRoleAttribute);
                NSString *t = Attr(e, kAXTitleAttribute);
                if ([r isEqualToString:@"AXMenuItem"] && t.length && [t containsString:itemTitle]) {
                    item = (AXUIElementRef)CFRetain(e); break;
                }
            }
            if (!item) { printf("AX-FAIL 未找到菜单项 %s\n", itemTitle.UTF8String); CFRelease(root); return 1; }
            AXError err = AXUIElementPerformAction(item, kAXPressAction);
            printf("AX-MENUPRESS %s err=%d\n", itemTitle.UTF8String, (int)err);
            CFRelease(item);
            CFRelease(root);
            return err == kAXErrorSuccess ? 0 : 1;
        }

        if ([cmd isEqualToString:@"watchstatus"]) {
            double total = argc > 3 ? atof(argv[3]) : 20.0;
            double interval = argc > 4 ? atof(argv[4]) : 0.2;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:total];
            NSDate *t0 = [NSDate date];
            NSString *last = nil;
            printf("WATCH 开始轮询状态行（%.0fs）\n", total);
            fflush(stdout);
            while ([deadline timeIntervalSinceNow] > 0) {
                NSMutableArray *snap = [NSMutableArray array];
                Collect(root, snap, 0, 20);
                NSString *val = nil;
                CGFloat bestY = 1e9;
                for (id obj in snap) {
                    AXUIElementRef e = (__bridge AXUIElementRef)obj;
                    if (![Attr(e, kAXRoleAttribute) isEqualToString:@"AXStaticText"]) continue;
                    NSString *v = Attr(e, kAXValueAttribute);
                    if (!v.length) continue;
                    CGRect f = CGRectZero;
                    if (!ElementFrame(e, &f)) continue;
                    if (f.size.width < 600 || f.size.height > 28) continue;
                    if (f.origin.y < bestY) { bestY = f.origin.y; val = v; }
                }
                if (val.length && ![val isEqualToString:last]) {
                    printf("STATUS t=%.2fs “%s”\n", -[t0 timeIntervalSinceNow], val.UTF8String);
                    fflush(stdout);
                    last = val;
                }
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:interval]];
            }
            printf("STATUS-END “%s”\n", last.UTF8String ?: "(空)");
            fflush(stdout);
            CFRelease(root);
            return 0;
        }

        if ([cmd isEqualToString:@"tree"]) {
            DumpTree(root, 0, argc > 3 ? atoi(argv[3]) : 6);
        } else if ([cmd isEqualToString:@"find"]) {
            NSString *needle = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            int hits = 0;
            for (id obj in all) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                if (!Matches(e, needle)) continue;
                CGRect f = CGRectZero;
                BOOL hf = ElementFrame(e, &f);
                printf("MATCH %s%s\n", Describe(e).UTF8String,
                       hf ? [NSString stringWithFormat:@"  @ x=%.1f y=%.1f w=%.1f h=%.1f maxX=%.1f maxY=%.1f",
                             f.origin.x, f.origin.y, f.size.width, f.size.height,
                             CGRectGetMaxX(f), CGRectGetMaxY(f)].UTF8String : "  @(无坐标)");
                hits++;
            }
            printf("AX-FIND %s hits=%d\n", needle.UTF8String, hits);
            if (!hits) { CFRelease(root); return 1; }
        } else if ([cmd isEqualToString:@"press"] || [cmd isEqualToString:@"pressid"]) {
            BOOL byId = [cmd isEqualToString:@"pressid"];
            NSString *needle = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            NSString *wantRole = argc > 4 ? [NSString stringWithUTF8String:argv[4]] : @"";
            AXUIElementRef hit = NULL;
            for (id obj in all) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                if (byId) {
                    NSString *ident = Attr(e, kAXIdentifierAttribute);
                    if (![ident isEqualToString:needle]) continue;
                } else {
                    NSString *t = Attr(e, kAXTitleAttribute), *v = Attr(e, kAXValueAttribute);
                    if (!([t isEqualToString:needle] || [v isEqualToString:needle])) continue;
                }
                if (wantRole.length) {
                    NSString *r = Attr(e, kAXRoleAttribute);
                    if (![r isEqualToString:wantRole]) continue;
                }
                hit = (AXUIElementRef)CFRetain(e);
                break;
            }
            if (!hit) { printf("AX-FAIL 未找到 %s=%s\n", byId ? "identifier" : "title", needle.UTF8String); CFRelease(root); return 1; }
            AXError err = AXUIElementPerformAction(hit, kAXPressAction);
            printf("AX-PRESS %s=%s err=%d\n", byId ? "id" : "title", needle.UTF8String, (int)err);
            CFRelease(hit);
            if (err != kAXErrorSuccess) { CFRelease(root); return 1; }
        } else if ([cmd isEqualToString:@"popup-pick"]) {
            NSString *label = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            AXUIElementRef popup = NULL;
            for (id obj in all) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                NSString *r = Attr(e, kAXRoleAttribute);
                if ([r isEqualToString:@"AXPopUpButton"]) { popup = (AXUIElementRef)CFRetain(e); break; }
            }
            if (!popup) { printf("AX-FAIL 未找到下拉控件\n"); CFRelease(root); return 1; }
            printf("AX-POPUP before=%s\n", Describe(popup).UTF8String);
            AXUIElementPerformAction(popup, kAXPressAction);
            CFRelease(popup);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
            NSMutableArray *menu = [NSMutableArray array];
            Collect(root, menu, 0, 20);
            AXUIElementRef item = NULL;
            for (id obj in menu) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                NSString *t = Attr(e, kAXTitleAttribute);
                NSString *r = Attr(e, kAXRoleAttribute);
                if (!t) continue;
                if (([r isEqualToString:@"AXMenuItem"] || [r isEqualToString:@"AXButton"]) && [t containsString:label]) {
                    item = (AXUIElementRef)CFRetain(e); break;
                }
            }
            if (!item) { printf("AX-FAIL 未找到菜单项 %s（候选见 events）\n", label.UTF8String); CFRelease(root); return 1; }
            AXError err = AXUIElementPerformAction(item, kAXPressAction);
            printf("AX-POPUP-PICK label=%s err=%d\n", label.UTF8String, (int)err);
            CFRelease(item);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
            if (err != kAXErrorSuccess) { CFRelease(root); return 1; }
        } else if ([cmd isEqualToString:@"submit"]) {
            NSString *urlText = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
            AXUIElementRef field = NULL;
            for (id obj in all) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                if ([Attr(e, kAXRoleAttribute) isEqualToString:@"AXTextField"]) { field = (AXUIElementRef)CFRetain(e); break; }
            }
            if (!field) { printf("AX-FAIL 未找到输入框\n"); CFRelease(root); return 1; }
            AXError e1 = AXUIElementSetAttributeValue(field, kAXValueAttribute, (__bridge CFTypeRef)urlText);
            AXError e2 = AXUIElementSetAttributeValue(field, kAXFocusedAttribute, kCFBooleanTrue);
            NSString *cur = Attr(field, kAXValueAttribute) ?: @"(空)";
            printf("AX-SUBMIT setValue=%d focus=%d value=%s\n", (int)e1, (int)e2, cur.UTF8String);
            CFRelease(field);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef down = CGEventCreateKeyboardEvent(source, 36, true);
            CGEventRef up = CGEventCreateKeyboardEvent(source, 36, false);
            CGEventPostToPid(pid, down);
            CGEventPostToPid(pid, up);
            CFRelease(down); CFRelease(up); CFRelease(source);
            printf("AX-SUBMIT 已发送回车\n");
            fflush(stdout);
            CFRelease(root);
            return (e1 == kAXErrorSuccess) ? 0 : 1;
        } else if ([cmd isEqualToString:@"key"]) {
            CGKeyCode code = (CGKeyCode)(argc > 3 ? atoi(argv[3]) : 0);
            BOOL withCmd = (argc > 4 && strcmp(argv[4], "cmd") == 0);
            CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef down = CGEventCreateKeyboardEvent(src, code, true);
            CGEventRef up = CGEventCreateKeyboardEvent(src, code, false);
            if (withCmd) { CGEventSetFlags(down, kCGEventFlagMaskCommand); CGEventSetFlags(up, kCGEventFlagMaskCommand); }
            CGEventPostToPid(pid, down);
            CGEventPostToPid(pid, up);
            CFRelease(down); CFRelease(up); CFRelease(src);
            printf("AX-KEY code=%d cmd=%d\n", (int)code, (int)withCmd);
            fflush(stdout);
            CFRelease(root);
            return 0;
        } else if ([cmd isEqualToString:@"clickfield"]) {
            AXUIElementRef field = NULL;
            for (id obj in all) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                if ([Attr(e, kAXRoleAttribute) isEqualToString:@"AXTextField"]) { field = (AXUIElementRef)CFRetain(e); break; }
            }
            if (!field) { printf("AX-FAIL 未找到输入框\n"); CFRelease(root); return 1; }
            CGRect f = CGRectZero;
            ElementFrame(field, &f);
            CGPoint pt = CGPointMake(f.origin.x + f.size.width / 2.0, f.origin.y + f.size.height / 2.0);
            CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, pt, kCGMouseButtonLeft);
            CGEventRef up = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, pt, kCGMouseButtonLeft);
            CGEventPostToPid(pid, down); CGEventPostToPid(pid, up);
            CFRelease(down); CFRelease(up); CFRelease(src);
            CFRelease(field);
            printf("AX-CLICKFIELD x=%.0f y=%.0f\n", pt.x, pt.y);
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            AXUIElementRef field2 = NULL;
            NSMutableArray *snap = [NSMutableArray array];
            Collect(root, snap, 0, 20);
            for (id obj in snap) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                if ([Attr(e, kAXRoleAttribute) isEqualToString:@"AXTextField"]) { field2 = (AXUIElementRef)CFRetain(e); break; }
            }
            if (field2) {
                CFTypeRef focused = NULL;
                AXUIElementCopyAttributeValue(field2, kAXFocusedAttribute, &focused);
                printf("AX-CLICKFIELD focused=%s\n", (focused && CFBooleanGetValue((CFBooleanRef)focused)) ? "YES" : "NO");
                if (focused) CFRelease(focused);
                CFRelease(field2);
            }
            CFRelease(root);
            return 0;
        } else if ([cmd isEqualToString:@"focus-text"]) {
            AXUIElementRef field = NULL;
            for (id obj in all) {
                AXUIElementRef e = (__bridge AXUIElementRef)obj;
                NSString *r = Attr(e, kAXRoleAttribute);
                if ([r isEqualToString:@"AXTextField"]) { field = (AXUIElementRef)CFRetain(e); break; }
            }
            if (!field) { printf("AX-FAIL 未找到文本框\n"); CFRelease(root); return 1; }
            AXError err = AXUIElementSetAttributeValue(field, kAXFocusedAttribute, kCFBooleanTrue);
            printf("AX-FOCUS err=%d\n", (int)err);
            CFRelease(field);
            if (err != kAXErrorSuccess) { CFRelease(root); return 1; }
        } else {
            printf("AX-FAIL 未知命令 %s\n", cmd.UTF8String);
            CFRelease(root);
            return 2;
        }
        CFRelease(root);
    }
    return 0;
}
