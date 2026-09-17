//
//  UIThemeSupport.m — 迁移自 App/SevenZZToolbox.m 的全局主题支撑实现
//  逻辑逐字符保留原主文件实现，仅将 static 符号改为全局符号。
//
#import "UIThemeSupport.h"

BOOL gLightTheme = NO;
BOOL gLavenderTheme = NO;

NSColor *RC(double r, double g, double b, double a) { return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a]; }

NSColor *C(double r, double g, double b, double a) {
    if (gLightTheme) {
        double luminance = r * 0.299 + g * 0.587 + b * 0.114;
        if (luminance < 0.42) return gLavenderTheme ? RC(.972-r*.08,.950-g*.05,1.0-b*.018,a) : RC(.96-r*.12,.97-g*.12,.985-b*.12,a);
        if (luminance > 0.62 && fabs(r-g) < 0.18 && fabs(g-b) < 0.18) return gLavenderTheme ? RC(.188,.162,.270,a) : RC(.16,.18,.22,a);
    }
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}

NSFont *ZZCuteFont(CGFloat size) { return [NSFont systemFontOfSize:MAX(1,size) weight:NSFontWeightRegular]; }

NSImage *Symbol(NSString *name) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightSemibold scale:NSImageSymbolScaleLarge];
    image = [image imageWithSymbolConfiguration:config] ?: image;
    image.template = YES;
    return image;
}

NSImage *SymbolSized(NSString *name, CGFloat pointSize, NSFontWeight weight) {
    // R9.3（审计 B5）：系统记录时间线每行多次创建符号图像（上千行时显著拖慢首次构建），
    // 按 name|size|weight 缓存；缓存随进程生命周期，符号配置固定，安全。
    static NSMutableDictionary *cache=nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache=[NSMutableDictionary dictionary]; });
    NSString *key=[NSString stringWithFormat:@"%@|%.1f|%ld",name,pointSize,(long)weight];
    NSImage *cached=cache[key];
    if(cached) return cached;
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight scale:NSImageSymbolScaleMedium];
    image = [image imageWithSymbolConfiguration:config] ?: image;
    image.template = YES;
    cache[key]=image;
    return image;
}

// ── R6 后台无抢焦点测试模式 ──
// 任何验证/测试入口（或显式 ZZ_NO_ACTIVATION=1）都进入该模式：
// 应用激活策略改为 Accessory（不占 Dock/不抢前台），窗口保持 normal level，
// 测试路径禁止 activateIgnoringOtherApps / makeKeyAndOrderFront。
BOOL ZZIsTestMode(void) {
#if defined(MARVIS_TEST_MODE)
    // 内联编译的单元/交互测试没有启动环境变量，但仍必须完全隔离 Keychain、网络和前台激活。
    return YES;
#else
    static dispatch_once_t once; static BOOL testMode=NO;
    dispatch_once(&once, ^{
        const char *keys[] = {"ZZ_NO_ACTIVATION","SMOKE_7ZZ_UI","SCREENSHOT_7ZZ_UI",
                              "SYSTEM_RECORDS_LAYOUT_VERIFY","SYSTEM_RECORDS_CAPTURE_MODE",
                              "SETTINGS_LAYOUT_DUMP","SETTINGS_CAPTURE_MODE","APP_LAYOUT_DUMP",
                              "APP_LAYOUT_MATRIX","APP_LAYOUT_MEMTEST","MOOD_FORTUNE_VERIFY","PREWARM_TEST","TESTMODE_PROBE",NULL};
        for(int i=0;keys[i];i++){
            const char *v=getenv(keys[i]);
            if(v && strcmp(v,"1")==0){testMode=YES;break;}
        }
    });
    return testMode;
#endif
}

NSWindowLevel ZZTestWindowLevel(void) { return NSNormalWindowLevel-1; }

// 将测试窗口明确排到当前用户前台 App 的最前普通窗口之后。单纯 orderBack: 只保证
// 本应用内部顺序，跨应用时仍可能覆盖用户窗口，因此必须使用 WindowServer 的真实窗口号。
void ZZOrderTestWindowBehindFrontApp(NSWindow *window) {
    if(!window)return;
    window.level=ZZTestWindowLevel();
    pid_t selfPID=NSProcessInfo.processInfo.processIdentifier;
    pid_t frontPID=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSInteger relativeWindow=0;
    NSArray *infos=(__bridge_transfer NSArray*)CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
    for(NSDictionary *info in infos){
        if([info[(id)kCGWindowLayer] integerValue]!=0)continue;
        pid_t pid=[info[(id)kCGWindowOwnerPID] intValue];
        if(pid==frontPID && pid!=selfPID){
            relativeWindow=[info[(id)kCGWindowNumber] integerValue];
            if(relativeWindow>0)break;
        }
    }
    if(relativeWindow>0)[window orderWindow:NSWindowBelow relativeTo:relativeWindow];
    else [window orderBack:nil];
}
