//
//  RDCdpCookieImporter.m — CDP 自动化导入实现
//
//  自包含约束：同时编入主 App 与常驻助手（build.sh 按 Features 目录收集），
//  只依赖同目录 Features 层与系统框架。链接依赖：libsqlite3（见 build.sh）。
//

#import "RDCdpCookieImporter.h"
#import "RDManualVerification.h"
#import "RDLog.h"
#import <sqlite3.h>
#import <AppKit/AppKit.h>

// 候选浏览器：显示名 / 可执行路径 / Application Support profile 目录。
// （BrowserOS neo 的 Bundle ID 是 com.browseros.BrowserClaw——App 名与数据目录名不同源。）
static NSArray *RDCdpBrowserCandidates(void) {
    return @[ @{@"name": @"BrowserClaw（BrowserOS neo）",
                @"exe": @"/Applications/BrowserOS neo.app/Contents/MacOS/BrowserOS neo",
                @"profile": @"BrowserClaw"},
              @{@"name": @"Microsoft Edge",
                @"exe": @"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
                @"profile": @"Microsoft Edge"},
              @{@"name": @"Chrome",
                @"exe": @"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                @"profile": @"Google/Chrome"},
              @{@"name": @"Chromium",
                @"exe": @"/Applications/Chromium.app/Contents/MacOS/Chromium",
                @"profile": @"Chromium"} ];
}

static NSError *RDCdpError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"RDCdpImport" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RDCdpCookieSource
@end

@implementation RDCdpCookieImporter

#pragma mark - 来源扫描（只读计数，不启动进程）

+ (NSUInteger)cookieCountOfDatabase:(NSString *)dbPath {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rd-cdp-count-%@.db", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:tmp error:nil]) return 0;
    sqlite3 *db = NULL;
    NSUInteger count = 0;
    if (sqlite3_open_v2(tmp.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT count(*) FROM cookies;", -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW) {
            count = (NSUInteger)sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
        sqlite3_close(db);
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return count;
}

+ (NSArray<RDCdpCookieSource *> *)availableSources {
    NSMutableArray<RDCdpCookieSource *> *out = [NSMutableArray array];
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *cand in RDCdpBrowserCandidates()) {
        if (![fm fileExistsAtPath:cand[@"exe"]]) continue;
        NSString *profile = [support stringByAppendingPathComponent:cand[@"profile"]];
        NSString *cookiesPath = [profile stringByAppendingPathComponent:@"Default/Cookies"];
        NSUInteger n = [self cookieCountOfDatabase:cookiesPath];
        if (n == 0) continue;
        RDCdpCookieSource *s = [RDCdpCookieSource new];
        s.browserName = cand[@"name"];
        s.executablePath = cand[@"exe"];
        s.profilePath = profile;
        s.cookieCount = n;
        [out addObject:s];
    }
    return out;
}

+ (NSArray<NSString *> *)whitelistedProfileRelativePaths {
    // Local State 含 os_crypt 密钥引用（浏览器解密必需）；Cookies 库两代路径都带。
    return @[ @"Local State",
              @"Default/Cookies", @"Default/Cookies-journal",
              @"Default/Network/Cookies", @"Default/Network/Cookies-journal" ];
}

#pragma mark - 纯函数：CDP 条目 → NSHTTPCookie

+ (nullable NSHTTPCookie *)httpCookieFromCdpDictionary:(NSDictionary<NSString *, id> *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : nil;
    NSString *value = [entry[@"value"] isKindOfClass:[NSString class]] ? entry[@"value"] : nil;
    NSString *domain = [entry[@"domain"] isKindOfClass:[NSString class]] ? entry[@"domain"] : nil;
    NSString *path = [entry[@"path"] isKindOfClass:[NSString class]] ? entry[@"path"] : nil;
    if (name.length == 0 || domain.length == 0) return nil;

    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    props[NSHTTPCookieName] = name;
    props[NSHTTPCookieValue] = value ?: @"";
    props[NSHTTPCookieDomain] = domain;
    props[NSHTTPCookiePath] = path.length ? path : @"/";
    if ([entry[@"secure"] boolValue]) props[NSHTTPCookieSecure] = @"TRUE";
    // CDP expires：-1（或缺席）= 会话 Cookie；否则 Unix 秒。
    id expires = entry[@"expires"];
    if ([expires respondsToSelector:@selector(doubleValue)]) {
        double e = [expires doubleValue];
        if (e > 0) props[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:e];
    }
    return [NSHTTPCookie cookieWithProperties:props];
}

#pragma mark - 导入主流程

+ (void)importFromSource:(RDCdpCookieSource *)source
              completion:(void (^)(NSUInteger, NSUInteger, NSError *))completion {
    NSParameterAssert(source != nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ── 1. 临时 profile：只复制白名单文件，其余（缓存/扩展/历史）一律不带 ──
        NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rd-cdp-profile-%@", NSUUID.UUID.UUIDString]];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL copiedAny = NO;
        for (NSString *rel in [self whitelistedProfileRelativePaths]) {
            NSString *from = [source.profilePath stringByAppendingPathComponent:rel];
            if (![fm fileExistsAtPath:from]) continue;
            NSString *to = [tmpRoot stringByAppendingPathComponent:rel];
            [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
            if ([fm copyItemAtPath:from toPath:to error:nil]) copiedAny = YES;
        }
        if (!copiedAny) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, RDCdpError(1, @"无法复制浏览器 profile 关键文件（Cookies 库不存在或被锁定）"));
            });
            return;
        }

        // ── 2. headless 拉起浏览器（随机高位调试端口；about:blank 无任何页面加载）──
        u_int32_t r = (u_int32_t)arc4random_uniform(40000);
        NSInteger port = 20000 + (NSInteger)r;
        NSArray *args = @[ [NSString stringWithFormat:@"--user-data-dir=%@", tmpRoot],
                           [NSString stringWithFormat:@"--remote-debugging-port=%ld", (long)port],
                           @"--headless=new",
                           @"--no-first-run", @"--no-default-browser-check",
                           @"--disable-gpu", @"--disable-extensions",
                           @"about:blank" ];
        NSTask *task = [NSTask new];
        task.launchPath = source.executablePath;
        task.arguments = args;
        task.standardOutput = [NSPipe pipe];
        task.standardError = [NSPipe pipe];
        @try {
            [task launch];
        } @catch (NSException *e) {
            [fm removeItemAtPath:tmpRoot error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, RDCdpError(2, [NSString stringWithFormat:@"无法启动浏览器（%@）", source.browserName]));
            });
            return;
        }

        // ── 3. 轮询 /json/version 直到调试端点就绪（≤20s）──
        NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)port];
        NSString *wsURL = nil;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (wsURL == nil && [deadline timeIntervalSinceNow] > 0 && task.isRunning) {
            usleep(400000);
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/json/version"]]];
            req.timeoutInterval = 2;
            __block NSData *data = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSURLSessionDataTask *dt = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                       completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
                if (!err && [((NSHTTPURLResponse *)resp) statusCode] == 200) data = d;
                dispatch_semaphore_signal(sem);
            }];
            [dt resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
            NSDictionary *ver = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            NSString *u = [ver isKindOfClass:[NSDictionary class]] ? ver[@"webSocketDebuggerUrl"] : nil;
            if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) wsURL = u;
        }
        if (wsURL == nil) {
            if (task.isRunning) [task terminate];
            [task waitUntilExit];
            [fm removeItemAtPath:tmpRoot error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, RDCdpError(3, @"浏览器调试端点未就绪（启动超时）"));
            });
            return;
        }

        // ── 4. WebSocket + Storage.getCookies（≤25s）──
        __block NSMutableArray<NSDictionary *> *cookies = [NSMutableArray array];
        __block NSError *wsError = nil;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession *wsSession = [NSURLSession sessionWithConfiguration:cfg];
        NSURLSessionWebSocketTask *ws = [wsSession webSocketTaskWithURL:[NSURL URLWithString:wsURL]];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [ws resume];

        void (^sendAndReceive)(void) = ^{
            NSString *body = [NSString stringWithFormat:
                @"{\"id\":1,\"method\":\"Storage.getCookies\",\"params\":{}}"];
            [ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:body]
                 completionHandler:^(NSError *err) {
                if (err) {
                    wsError = RDCdpError(4, @"CDP 命令发送失败");
                    dispatch_semaphore_signal(done);
                    return;
                }
                [ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err2) {
                    if (err2 || msg.type != NSURLSessionWebSocketMessageTypeString) {
                        wsError = RDCdpError(5, @"CDP 响应接收失败");
                        dispatch_semaphore_signal(done);
                        return;
                    }
                    NSDictionary *resp = [NSJSONSerialization JSONObjectWithData:
                        [msg.string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
                    NSDictionary *result = [resp isKindOfClass:[NSDictionary class]] ? resp[@"result"] : nil;
                    NSArray *list = [result isKindOfClass:[NSDictionary class]] ? result[@"cookies"] : nil;
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *e in list) {
                            if ([e isKindOfClass:[NSDictionary class]]) [cookies addObject:e];
                        }
                    } else {
                        wsError = RDCdpError(6, @"CDP 响应格式异常");
                    }
                    dispatch_semaphore_signal(done);
                }];
            }];
        };
        // 先等 socket 建立（短轮询 receive 一次空转握手），再发命令。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), sendAndReceive);
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0) {
            wsError = wsError ?: RDCdpError(7, @"CDP 导出超时");
        }
        [ws cancel];   // 直接取消：临时进程随即被 terminate，无需优雅 close 帧
        [wsSession invalidateAndCancel];
        if (task.isRunning) [task terminate];
        [task waitUntilExit];
        [fm removeItemAtPath:tmpRoot error:nil];   // 临时 profile 用完即删
        if (wsError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, wsError);
            });
            return;
        }

        // ── 5. 转换并灌入共享会话存储 ──
        NSMutableArray<NSHTTPCookie *> *httpCookies = [NSMutableArray array];
        NSUInteger failed = 0;
        for (NSDictionary *e in cookies) {
            NSHTTPCookie *c = [self httpCookieFromCdpDictionary:e];
            if (c) [httpCookies addObject:c]; else failed++;
        }
        RDLogWrite(@"app", @"CDP 导出统计：浏览器返回 %lu 条 / 转换成功 %lu / 跳过 %lu（仅计数不含内容）",
                   (unsigned long)cookies.count, (unsigned long)httpCookies.count, (unsigned long)failed);
        // ── 5. 灌入共享会话存储（WebKit2 要求首次触碰与 API 调用在主线程；
        //       后台线程冷初始化会在 runInitializationCode 直接 SIGTRAP）──
        dispatch_async(dispatch_get_main_queue(), ^{
            WKHTTPCookieStore *store = [RDManualVerificationController sharedSessionDataStore].httpCookieStore;
            // Fire-and-forget：WKHTTPCookieStore 自身保证排队持久化；不做 per-cookie 完成确认
            // ——无 WebKit 网络进程的环境（如测试 harness）completion 可能迟到，等待/释放
            // 时序会产生 use-after-free 崩溃（实测 SIGTRAP）。会话站点显示由 fetchDataRecords
            // 独立刷新，不依赖这里的完成回调。
            for (NSHTTPCookie *cookie in httpCookies) {
                [store setCookie:cookie completionHandler:nil];
            }
            NSUInteger imported = httpCookies.count;
            if (completion) completion(imported, failed, nil);   // completion 约定主线程回调
        });
    });
}

@end
