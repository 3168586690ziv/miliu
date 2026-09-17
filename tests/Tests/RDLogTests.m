//
//  RDLogTests.m — 统一日志（RDLog）缺陷修复回归
//
//  锁定以下曾真实发生过的事故（见 AGENTS.md 轮次历史与修复报告）：
//   · P0-1 「打开日志」按钮把已有日志截断为 0 字节（用户点一次清一次）
//   · P0-2 崩溃/exit 时异步写队列未执行，崩溃现场一条都留不下
//   · P0-3 孤立代理项使 UTF8String 返回 NULL，strlen(NULL) 直接 SIGSEGV
//   · P1-1 脱敏正则吞掉 URL 之后的正文，并抹掉排查必需的 host
//   · P1-2 轮转只在启动时执行一次，单次会话日志无界增长（曾涨到 18.8MB）
//   · P1-3 导出诊断包不排空写队列，最近的日志恰好缺失
//   · P2-2 SIGSEGV/SIGABRT 等硬崩溃零记录
//   · P2-3 时间戳随系统地区变（泰国佛历/日本和历/阿拉伯-印度数字）
//
//  本测试只链接 RDLog.{h,m}，不涉及 GUI；崩溃类用例在 fork 出的子进程里跑，
//  父进程断言退出码语义（SIGSEGV 仍是 139、SIGABRT 仍是 134）。
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/wait.h>
#import "RDLog.h"

static int gChecks = 0;
static int gFailed = 0;

static void Check(BOOL ok, NSString *message) {
    gChecks++;
    if (!ok) gFailed++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", message.UTF8String);
}

static unsigned long long FileBytes(NSString *path) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return a ? a.fileSize : 0;
}

static NSArray<NSString *> *Lines(NSString *path) {
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!s) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [s componentsSeparatedByString:@"\n"]) if (l.length) [out addObject:l];
    return out;
}

static NSString *ReadFile(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

// ── 子进程：崩溃/异常类用例必须独立进程，父进程才能断言退出码 ──

static int RunChild(NSString *exe, NSArray<NSString *> *args, NSDictionary<NSString *, NSString *> *env) {
    pid_t pid = fork();
    if (pid == 0) {
        [env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            setenv(k.UTF8String, v.UTF8String, 1);
        }];
        NSMutableArray *argv = [NSMutableArray arrayWithObject:exe];
        [argv addObjectsFromArray:args];
        char **cargv = calloc(argv.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = strdup([argv[i] UTF8String]);
        execv(exe.UTF8String, cargv);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return WEXITSTATUS(status);
}

// ── 子进程模式：模拟未捕获异常（与 App 的 handler 同样的同步写法）──

static int ChildBurstThenCrash(int count) {
    for (int i = 0; i < count; i++) RDLogWrite(@"dl", @"积压第 %d 条 payload=0123456789abcdef", i);
    RDLogFlush();
    RDLogWriteSync(@"crash", @"未捕获异常 %@: %@", @"TestException", @"崩溃现场必须落盘");
    for (int i = 0; i < 4; i++) RDLogWriteSync(@"crash", @"  栈帧占位 %d", i);
    return 0;
}

static int ChildLoneSurrogate(void) {
    unichar lone = 0xD800;                       // 孤立高代理项：非法 UTF-16
    NSString *bad = [NSString stringWithCharacters:&lone length:1];
    RDLogWrite(@"probe", @"解析失败 片段=%@ 尺寸=1920x1080", bad);
    RDLogWrite(@"probe", @"孤立代理项之后的下一行必须还在");
    RDLogFlush();
    return 0;
}

static int ChildEmbeddedNUL(void) {
    unichar chars[] = {'A', 0x0000, 'B'};        // 内嵌 \0：旧实现 strlen 在此截断整行
    RDLogWrite(@"meta", @"前半段%@后半段标记END", [NSString stringWithCharacters:chars length:3]);
    RDLogFlush();
    return 0;
}

static int ChildSegv(void) {
    RDLogInstallCrashHandlers();
    RDLogFlush();
    volatile int *p = (int *)0x1;
    *p = 42;
    return 0;
}

static int ChildAbort(void) {
    RDLogInstallCrashHandlers();
    RDLogFlush();
    abort();
    return 0;
}

static int ChildRotate(void) {
    for (int i = 0; i < 4000; i++) {
        RDLogWrite(@"dl", @"轮转压测第 %d 条 填充=abcdefghijklmnopqrstuvwxyz0123456789", i);
    }
    RDLogFlush();
    return 0;
}

static int ChildRedact(void) {
    RDLogWrite(@"probe", @"解码失败 url=https://a.com/v.mp4原因：格式不支持 尺寸=1920x1080");
    RDLogWrite(@"probe", @"已脱敏 url=https://cdn.xxx.com/[redacted] 后续说明保留");
    RDLogWrite(@"probe", @"流 rtsp://cam.local/live?auth=SECRET 结束");
    RDLogWrite(@"probe", @"裸域名 host/path?token=SECRET 收尾");
    RDLogWrite(@"probe", @"ws 地址 ws://live.example.com/s?key=SECRET2 说明");
    RDLogWrite(@"probe", @"普通 http://example.org/a/b.mp4 (含括号) 之后文字");
    RDLogFlush();
    return 0;
}

static int ChildExport(void) {
    for (int i = 0; i < 300; i++) RDLogWrite(@"probe", @"导出完整性第 %d 条", i);
    NSError *err = nil;
    if (!RDLogExportDiagnostics(@"vTEST.0", &err)) return 2;
    return 0;
}

// ── P1 脱敏覆盖用例表（子进程逐行写出，父进程逐行断言）──
//
// 每条：@"in" 为写入的原文，@"leak" 为该条输入里绝不能出现在落盘行中的标记。
// 标记按"输入自带的真值"逐条给出（不用全局 SECRET 前缀集合：
// "ABC123" 是 "ABC123KEY" 的子串，混用会互相误判）。
static NSArray<NSDictionary *> *CredentialRedactCases(void) {
    return @[
        // 1–8：会话 / cookie 键族（旧实现全部明文落盘）
        @{@"in": @"cookie=session=SECRET1",                  @"leak": @[@"SECRET1"]},
        @{@"in": @"Cookie: SECRET2",                          @"leak": @[@"SECRET2"]},
        @{@"in": @"session=SECRET3",                          @"leak": @[@"SECRET3"]},
        @{@"in": @"sid=SECRET4",                              @"leak": @[@"SECRET4"]},
        @{@"in": @"set-cookie=SECRET6",                       @"leak": @[@"SECRET6"]},
        @{@"in": @"csrf_token=SECRET9",                       @"leak": @[@"SECRET9"]},
        @{@"in": @"JSESSIONID=ABC123",                        @"leak": @[@"ABC123"]},
        @{@"in": @"PHPSESSID=XYZ789",                         @"leak": @[@"XYZ789"]},
        // 9–11：Authorization / Proxy-Authorization，凭据真值必须整体消失
        @{@"in": @"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.PAYLOAD",
          @"leak": @[@"eyJ", @"PAYLOAD", @"Bearer"]},
        @{@"in": @"Authorization: Basic dXNlcjpwYXNzd29yZA==",
          @"leak": @[@"dXNlc", @"Basic"]},
        @{@"in": @"Proxy-Authorization: Bearer PROXYTOKEN",
          @"leak": @[@"PROXYTOKEN", @"Bearer"]},
        // 12–14：修复前已正确的三条，锁定不回归
        @{@"in": @"x-auth=SECRETX",                           @"leak": @[@"SECRETX"]},
        @{@"in": @"Cookie: a=1; sessionid=SECRETC",           @"leak": @[@"SECRETC"]},
        @{@"in": @"X-Api-Key: ABC123KEY",                     @"leak": @[@"ABC123KEY"]},
        // 15–17：等号形式与全角冒号形式同样覆盖（全角冒号由中文输入法产出，真实会落盘）
        @{@"in": @"authorization=SECRETDIRECT",               @"leak": @[@"SECRETDIRECT"]},
        @{@"in": @"proxy-authorization=PROXYDIRECT",          @"leak": @[@"PROXYDIRECT"]},
        @{@"in": @"Cookie：SECRET2F",                        @"leak": @[@"SECRET2F"]},
        // 18–19：无 header 名的裸方案前缀
        @{@"in": @"Bearer eyJhbGciOiJIUzI1NiJ9.PAYLOAD",      @"leak": @[@"eyJ", @"PAYLOAD"]},
        @{@"in": @"Basic dXNlcjpwYXNzd29yZA==",               @"leak": @[@"dXNlc"]},
        // 20–21：值边界 —— 不得贪婪吞掉凭据之后的正文
        @{@"in": @"Authorization: Bearer tok 后文说明保留",    @"leak": @[], @"keep": @"后文说明保留"},
        @{@"in": @"Cookie: SECRET2; 后续正文保留",            @"leak": @[@"SECRET2"], @"keep": @"后续正文保留"},
        // 22：非凭据的普通英文短语不得被误伤（误伤即"吞正文"回归）。
        // marked=NO：这条是反向对照，正确行为是原样保留、不出现 [redacted]。
        @{ @"in": @"说明 Basic info 保留原文",                  @"leak": @[], @"keep": @"Basic info",
           @"marked": @NO },
        // 23–27：中文敏感键与全角分隔符（中文输入法真实产出，旧实现全部明文）
        @{ @"in": @"密码=MyPass123",                            @"leak": @[@"MyPass123"] },
        @{ @"in": @"口令=TopSecret",                            @"leak": @[@"TopSecret"] },
        @{ @"in": @"密钥=ABCKEY999",                            @"leak": @[@"ABCKEY999"] },
        @{ @"in": @"密码：MyPass456",                           @"leak": @[@"MyPass456"] },
        @{ @"in": @"token＝FullWidthValue",                      @"leak": @[@"FullWidthValue"] },
        // 28：全角/普通标点的正常说明不得被误伤
        @{ @"in": @"原因：格式不支持 尺寸=1920x1080",              @"leak": @[], @"keep": @"原因：格式不支持 尺寸=1920x1080", @"marked": @NO },
    ];
}

// 只抹方案词、真值留在后面的退化形态（本次修复要杜绝的形态）
static NSRegularExpression *DegradedMarkerPattern(void) {
    return [NSRegularExpression regularExpressionWithPattern:
            @"\\[redacted\\]\\s+[A-Za-z0-9._~+/=\\-]{4,}" options:0 error:nil];
}

static int ChildCredentialRedact(void) {
    for (NSDictionary *c in CredentialRedactCases()) RDLogWrite(@"probe", @"%@", c[@"in"]);
    RDLogFlush();
    return 0;
}

// ── 源码内联编译辅助：仅为隔离验证 URL 脱敏与导出，不新增外部依赖 ──

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc > 2 && strcmp(argv[1], "--child") == 0) {
        const char *mode = argv[2];
        if (!strcmp(mode, "burst"))     return ChildBurstThenCrash(argc > 3 ? atoi(argv[3]) : 4000);
        if (!strcmp(mode, "surrogate")) return ChildLoneSurrogate();
        if (!strcmp(mode, "nul"))       return ChildEmbeddedNUL();
        if (!strcmp(mode, "segv"))      return ChildSegv();
        if (!strcmp(mode, "abort"))     return ChildAbort();
        if (!strcmp(mode, "rotate"))    return ChildRotate();
        if (!strcmp(mode, "redact"))    return ChildRedact();
        if (!strcmp(mode, "creds"))     return ChildCredentialRedact();
        if (!strcmp(mode, "export"))    return ChildExport();
        fprintf(stderr, "unknown child mode: %s\n", mode);
        return 127;
    }

    printf("== RDLog 统一日志回归测试 ==\n");
    NSString *self = [NSString stringWithUTF8String:argv[0]];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"rdlog-tests-%d", getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES attributes:nil error:nil];
    // 主进程整体隔离到临时日志：A 项会真实调用 RDLogRevealInFinder（打开访达），
    // 绝不能让它操作用户真实的 ~/Library/Logs/ResourceDetector.log。
    // LogPath() 是惰性的，这里在任何 RDLog 调用之前设置仍然有效。
    setenv("RD_LOG_PATH", [root stringByAppendingPathComponent:@"main.log"].UTF8String, 1);

    // A. P0-1 打开日志不得截断已有内容
    {
        NSString *logPath = RDLogFilePath();
        NSData *seed = [@"已有内容行 1\n已有内容行 2\n已有内容行 3\n" dataUsingEncoding:NSUTF8StringEncoding];
        [seed writeToFile:logPath atomically:YES];
        unsigned long long before = FileBytes(logPath);
        RDLogRevealInFinder();   // 真实调用（会打开访达窗口，属预期副作用）
        unsigned long long after = FileBytes(logPath);
        Check(before > 0 && after == before,
              [NSString stringWithFormat:@"A 已有日志调用 RDLogRevealInFinder 后字节数不变：%llu → %llu",
               before, after]);
    }

    // B. P0-2 积压后崩溃，崩溃行必须落盘
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"burst.log"];
        int rc = RunChild(self, @[@"--child", @"burst", @"4000"], @{@"RD_LOG_PATH": logPath});
        NSUInteger crashLines = 0;
        for (NSString *l in Lines(logPath)) if ([l containsString:@"[crash]"]) crashLines++;
        Check(rc == 0 && crashLines >= 5,
              [NSString stringWithFormat:@"B 积压 4000 条后崩溃日志落盘 %lu 行（要求 ≥5）", (unsigned long)crashLines]);
    }

    // C. P0-3 非法字符串绝不崩溃、绝不静默截断
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"surrogate.log"];
        int rc = RunChild(self, @[@"--child", @"surrogate"], @{@"RD_LOG_PATH": logPath});
        NSString *content = ReadFile(logPath);
        Check(rc == 0, [NSString stringWithFormat:@"C1 孤立代理项未导致 SIGSEGV（退出码 %d，139 即崩溃）", rc]);
        Check([content containsString:@"尺寸=1920x1080"] && [content containsString:@"下一行必须还在"]
              && [content containsString:@"[probe]"],
              @"C2 孤立代理项所在行（含组件前缀与上下文）与后续行都正常落盘");
    }
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"nul.log"];
        RunChild(self, @[@"--child", @"nul"], @{@"RD_LOG_PATH": logPath});
        Check([ReadFile(logPath) containsString:@"后半段标记END"],
              @"C3 内嵌 \\0 的行未被静默截断（后半段标记仍在）");
    }

    // D. P1-1 脱敏：保留 host、不吞正文、覆盖 rtsp/ws/无 scheme 形态
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"redact.log"];
        RunChild(self, @[@"--child", @"redact"], @{@"RD_LOG_PATH": logPath});
        NSString *c = ReadFile(logPath);
        Check([c containsString:@"https://a.com"] && [c containsString:@"原因：格式不支持"]
              && [c containsString:@"尺寸=1920x1080"],
              @"D1 url 后的正文与 host 都保留（旧实现两者被一起吞掉）");
        Check([c containsString:@"https://cdn.xxx.com"] && [c containsString:@"后续说明保留"],
              @"D2 已由 RDRedactedURL 脱敏的 host 仍可见");
        Check([c containsString:@"rtsp://cam.local"] && ![c containsString:@"SECRET"],
              @"D3 rtsp:// 覆盖且 auth 密钥不出现");
        Check([c containsString:@"host/"] && ![c containsString:@"token=SECRET"],
              @"D4 无 scheme 的 host/path?token= 被脱敏");
        Check([c containsString:@"ws://live.example.com"] && ![c containsString:@"SECRET2"],
              @"D5 ws:// 覆盖且 key 密钥不出现");
        Check([c containsString:@"http://example.org"] && [c containsString:@"之后文字"],
              @"D6 URL 后的正文保留（收尾括号不再被吞）");
    }

    // D2. P1 凭据脱敏覆盖：Authorization / Proxy-Authorization / Cookie / 会话键族
    //
    // 旧实现只抹掉方案词（"Authorization: Bearer <令牌>" → "Authorization: [redacted] <令牌>"），
    // 行里出现脱敏标记却把真凭据原地留在日志中；Cookie 与会话键族则整条明文落盘。
    // 断言口径：该行不得含真值标记、必须含 [redacted]、且不得出现"只抹方案词"的退化形态。
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"creds.log"];
        int rc = RunChild(self, @[@"--child", @"creds"], @{@"RD_LOG_PATH": logPath});
        NSArray<NSString *> *logLines = Lines(logPath);
        NSArray<NSDictionary *> *cases = CredentialRedactCases();

        Check(rc == 0 && logLines.count == cases.count,
              [NSString stringWithFormat:@"D2-0 凭据用例全部落盘 %lu 行（预期 %lu）",
               (unsigned long)logLines.count, (unsigned long)cases.count]);

        NSMutableArray<NSString *> *leaked = [NSMutableArray array];
        NSMutableArray<NSString *> *degraded = [NSMutableArray array];
        NSMutableArray<NSString *> *notMarked = [NSMutableArray array];
        NSMutableArray<NSString *> *lostBody = [NSMutableArray array];
        for (NSUInteger i = 0; i < cases.count && i < logLines.count; i++) {
            NSDictionary *c = cases[i];
            NSString *line = logLines[i];
            for (NSString *m in c[@"leak"]) {
                if ([line containsString:m]) [leaked addObject:[NSString stringWithFormat:@"#%lu:%@", (unsigned long)i + 1, m]];
            }
            // 默认要求出现脱敏标记；反向对照用例（marked=NO）要求原样保留、不被误伤
            BOOL wantMarker = c[@"marked"] ? [c[@"marked"] boolValue] : YES;
            if (wantMarker != [line containsString:@"[redacted]"]) {
                [notMarked addObject:[NSString stringWithFormat:@"#%lu", (unsigned long)i + 1]];
            }
            if ([DegradedMarkerPattern() numberOfMatchesInString:line options:0
                                                           range:NSMakeRange(0, line.length)] > 0) {
                [degraded addObject:[NSString stringWithFormat:@"#%lu", (unsigned long)i + 1]];
            }
            NSString *keep = c[@"keep"];
            if (keep && ![line containsString:keep]) [lostBody addObject:[NSString stringWithFormat:@"#%lu:%@", (unsigned long)i + 1, keep]];
        }
        Check(leaked.count == 0,
              [NSString stringWithFormat:@"D2-1 无任何真值明文落盘（泄漏项：%@）",
               leaked.count ? [leaked componentsJoinedByString:@" "] : @"无"]);
        Check(notMarked.count == 0,
              [NSString stringWithFormat:@"D2-2 每条凭据行都含 [redacted]（缺标记：%@）",
               notMarked.count ? [notMarked componentsJoinedByString:@" "] : @"无"]);
        Check(degraded.count == 0,
              [NSString stringWithFormat:@"D2-3 无「只抹方案词、真值留在后面」的退化形态（退化项：%@）",
               degraded.count ? [degraded componentsJoinedByString:@" "] : @"无"]);
        Check(lostBody.count == 0,
              [NSString stringWithFormat:@"D2-4 凭据之后的正文未被吞掉（丢失项：%@）",
               lostBody.count ? [lostBody componentsJoinedByString:@" "] : @"无"]);

        // 逐条明细：失败时直接指出是哪条输入、哪一行
        for (NSUInteger i = 0; i < cases.count; i++) {
            NSString *line = i < logLines.count ? logLines[i] : @"(缺行)";
            NSLog(@"D2 case #%lu IN=%@ OUT=%@", (unsigned long)i + 1, cases[i][@"in"], line);
        }
    }

    // E. P1-2 不重启进程也要轮转，且只保留一代
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"rotate.log"];
        NSString *rotated = [logPath stringByAppendingString:@".1"];
        int rc = RunChild(self, @[@"--child", @"rotate"],
                          @{@"RD_LOG_PATH": logPath, @"RD_LOG_MAX_BYTES": @"65536"});
        unsigned long long cur = FileBytes(logPath);
        unsigned long long old = FileBytes(rotated);
        Check(rc == 0 && old > 0 && cur < 65536,
              [NSString stringWithFormat:@"E1 会话内触发轮转：.1=%llu 字节，当前文件回落至 %llu 字节", old, cur]);
        Check(![[NSFileManager defaultManager] fileExistsAtPath:[logPath stringByAppendingString:@".2"]],
              @"E2 仍只保留一代（无 .2）");
    }

    // F. P1-3 导出包日志与源文件逐行一致
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"export.log"];
        NSString *exportDir = [root stringByAppendingPathComponent:@"exported"];
        [[NSFileManager defaultManager] createDirectoryAtPath:exportDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        int rc = RunChild(self, @[@"--child", @"export"],
                          @{@"RD_LOG_PATH": logPath, @"RD_LOG_EXPORT_DIR": exportDir});
        NSString *dirName = nil;
        for (NSString *e in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:exportDir error:nil]) {
            if ([e hasPrefix:@"资源探测诊断-"]) dirName = e;
        }
        NSUInteger sourceLines = Lines(logPath).count;
        NSUInteger exportedLines = 0;
        if (dirName) {
            NSString *sub = [exportDir stringByAppendingPathComponent:dirName];
            for (NSString *e in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:sub error:nil]) {
                if ([e hasSuffix:@".log"]) exportedLines = Lines([sub stringByAppendingPathComponent:e]).count;
            }
        }
        Check(rc == 0 && dirName && exportedLines == sourceLines && exportedLines >= 301,
              [NSString stringWithFormat:@"F 导出日志行数 %lu == 源文件 %lu（要求 ≥301 且一致）",
               (unsigned long)exportedLines, (unsigned long)sourceLines]);
    }

    // G1/G2. P2-2 硬崩溃留下记录且退出码语义不变
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"segv.log"];
        int rc = RunChild(self, @[@"--child", @"segv"], @{@"RD_LOG_PATH": logPath});
        NSString *c = ReadFile(logPath);
        Check(rc == 139 && [c containsString:@"致命信号"] && [c containsString:@"SIGSEGV"],
              [NSString stringWithFormat:@"G1 SIGSEGV 留下日志且仍以 139 退出（实际 %d）", rc]);
    }
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"abort.log"];
        int rc = RunChild(self, @[@"--child", @"abort"], @{@"RD_LOG_PATH": logPath});
        Check(rc == 134 && [ReadFile(logPath) containsString:@"SIGABRT"],
              [NSString stringWithFormat:@"G2 SIGABRT 留下日志且仍以 134 退出（实际 %d）", rc]);
    }

    // G3. P2-3 系统地区为泰国时，导出目录名仍是公历 + 阿拉伯数字
    {
        NSString *logPath = [root stringByAppendingPathComponent:@"tz.log"];
        NSString *exportDir = [root stringByAppendingPathComponent:@"exported-tz"];
        [[NSFileManager defaultManager] createDirectoryAtPath:exportDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        /* ChildExport 只写日志；此处复用同一子进程模式并叠加泰国地区环境 */
        int rc = RunChild(self, @[@"--child", @"export"],
                          @{@"RD_LOG_PATH": logPath, @"RD_LOG_EXPORT_DIR": exportDir,
                            @"TZ": @"Asia/Bangkok", @"LANG": @"th_TH.UTF-8"});
        NSString *dirName = nil;
        for (NSString *e in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:exportDir error:nil]) {
            if ([e hasPrefix:@"资源探测诊断-"]) dirName = e;
        }
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                                   @"^资源探测诊断-[0-9]{8}-[0-9]{6}$" options:0 error:nil];
        BOOL nameOK = dirName && [re numberOfMatchesInString:dirName options:0
                                                       range:NSMakeRange(0, dirName.length)] == 1;
        Check(rc == 0 && nameOK,
              [NSString stringWithFormat:@"G3 泰国地区导出目录名仍为公历阿拉伯数字：%@", dirName ?: @"(缺失)"]);
    }

    // G4. P2-1 生产默认路径不受影响：显式设置 RD_LOG_PATH 时用户真实日志零增长
    {
        NSString *realLog = [NSHomeDirectory() stringByAppendingPathComponent:
                             @"Library/Logs/ResourceDetector.log"];
        unsigned long long before = FileBytes(realLog);
        NSString *isolated = [root stringByAppendingPathComponent:@"isolated.log"];
        RunChild(self, @[@"--child", @"redact"], @{@"RD_LOG_PATH": isolated});
        unsigned long long after = FileBytes(realLog);
        Check(before == after && FileBytes(isolated) > 0,
              [NSString stringWithFormat:@"G4 RD_LOG_PATH 生效：隔离日志已写、用户真实日志保持 %llu 字节不变",
               after]);
    }

    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    printf("%s checks=%d failed=%d\n", gFailed == 0 ? "PASS: ALL RDLOG TESTS" : "TEST-SUITE-FAILED",
           gChecks, gFailed);
    return gFailed == 0 ? 0 : 1;
} }
