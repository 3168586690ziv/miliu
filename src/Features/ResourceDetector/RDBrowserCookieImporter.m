//
//  RDBrowserCookieImporter.m — 浏览器登录态一键导入实现
//
//  自包含约束：本文件同时编入主 App 与常驻助手（build.sh 按 Features 目录自动
//  收集），只依赖同目录 Features 层与系统框架。链接依赖：libsqlite3（见 build.sh）。
//

#import "RDBrowserCookieImporter.h"
#import "RDManualVerification.h"
#import "RDLog.h"
#import <CommonCrypto/CommonCrypto.h>
#import <sqlite3.h>
#import <Security/Security.h>

// 常见 Chromium 系浏览器（显示名 → Application Support 子目录）。钥匙串服务名
// 统一为 "<显示名> Safe Storage"（实测 BrowserClaw/Chromium/Edge/Chrome 均存在）。
static NSArray *RDBrowserCandidates(void) {
    return @[ @{@"name": @"BrowserClaw", @"dir": @"BrowserClaw"},
              @{@"name": @"Microsoft Edge", @"dir": @"Microsoft Edge"},
              @{@"name": @"Chrome", @"dir": @"Google Chrome"},
              @{@"name": @"Chromium", @"dir": @"Chromium"} ];
}

@implementation RDBrowserCookieSource
@end

@implementation RDBrowserCookieImporter

#pragma mark - 来源扫描（不碰 Keychain）

+ (NSUInteger)cookieCountOfDatabase:(NSString *)dbPath {
    // 复制后读取：原库可能被运行中的浏览器加写锁；只取计数，不读值。
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rd-cookie-count-%@.db", NSUUID.UUID.UUIDString]];
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
    }
    sqlite3_close(db);
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return count;
}

+ (NSArray<RDBrowserCookieSource *> *)availableSources {
    NSMutableArray<RDBrowserCookieSource *> *out = [NSMutableArray array];
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    for (NSDictionary *cand in RDBrowserCandidates()) {
        NSString *dir = [support stringByAppendingPathComponent:cand[@"dir"]];
        NSArray *subs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        for (NSString *sub in [subs sortedArrayUsingSelector:@selector(compare:)]) {
            BOOL isProfile = [sub isEqualToString:@"Default"] || [sub hasPrefix:@"Profile "];
            if (!isProfile) continue;
            NSString *dbPath = [[dir stringByAppendingPathComponent:sub] stringByAppendingPathComponent:@"Cookies"];
            NSUInteger n = [self cookieCountOfDatabase:dbPath];
            if (n == 0) continue;
            RDBrowserCookieSource *s = [RDBrowserCookieSource new];
            s.browserName = cand[@"name"];
            s.profilePath = [dir stringByAppendingPathComponent:sub];
            s.profileLabel = sub;
            s.cookieCount = n;
            [out addObject:s];
        }
    }
    return out;
}

+ (NSString *)safeStorageServiceNameForBrowserName:(NSString *)browserName {
    return [NSString stringWithFormat:@"%@ Safe Storage", browserName];
}

// 候选钥匙串服务名：带品牌名优先，回退上游 "Chromium Safe Storage"（开源分支
// 如 BrowserClaw 未必注册品牌名条目——实测两者都存在，密钥只在真正派生者手里）。
+ (NSArray<NSString *> *)candidateServiceNamesForBrowserName:(NSString *)browserName {
    NSString *branded = [self safeStorageServiceNameForBrowserName:browserName];
    NSString *upstream = @"Chromium Safe Storage";
    return [branded isEqualToString:upstream] ? @[branded] : @[branded, upstream];
}

#pragma mark - 纯函数：解密与时间

+ (nullable NSData *)decryptChromiumV10Value:(NSData *)encrypted key:(NSData *)key {
    if (encrypted.length <= 3 || key.length != 16) return nil;
    NSString *prefix = [[NSString alloc] initWithData:[encrypted subdataWithRange:NSMakeRange(0, 3)] encoding:NSASCIIStringEncoding];
    if (![prefix isEqualToString:@"v10"]) return nil;   // v11/app-bound 明确不支持
    NSData *ciphertext = [encrypted subdataWithRange:NSMakeRange(3, encrypted.length - 3)];
    // Chromium v10：AES-128-CBC，IV = 16 个空格（0x20），PKCS7 填充。
    unsigned char iv[kCCBlockSizeAES128];
    memset(iv, 0x20, sizeof(iv));
    NSMutableData *out = [NSMutableData dataWithLength:ciphertext.length + kCCBlockSizeAES128];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 key.bytes, key.length, iv,
                                 ciphertext.bytes, ciphertext.length,
                                 out.mutableBytes, out.length, &moved);
    if (st != kCCSuccess) return nil;
    out.length = moved;
    return out;
}

+ (nullable NSDate *)dateFromChromiumTimestamp:(int64_t)microsecondsSince1601 {
    if (microsecondsSince1601 <= 0) return nil;   // 0 = 会话 Cookie（不设过期）
    // Chromium 纪元 1601-01-01 与 Unix 纪元相差 11644473600 秒。
    NSTimeInterval seconds = (microsecondsSince1601 / 1000000.0) - 11644473600.0;
    if (seconds < 0) return nil;   // 负值 = 1970 前的垃圾数据；0 本身（1970 锚点）合法
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

#pragma mark - Keychain

// PBKDF2-HMAC-SHA1("saltysalt", 1003 轮) → 16 字节 AES 密钥（Chromium v10 派生规约）。
+ (nullable NSData *)derivedKeyFromPassword:(NSData *)password {
    unsigned char out[16];
    NSData *salt = [@"saltysalt" dataUsingEncoding:NSUTF8StringEncoding];
    CCCryptorStatus st = CCKeyDerivationPBKDF(kCCPBKDF2, password.bytes, password.length,
                                              salt.bytes, salt.length,
                                              kCCPRFHmacAlgSHA1, 1003,
                                              out, sizeof(out));
    if (st != kCCSuccess) return nil;
    return [NSData dataWithBytes:out length:sizeof(out)];
}

#pragma mark - 导入主流程

+ (void)importFromSource:(RDBrowserCookieSource *)source
              completion:(void (^)(NSUInteger, NSUInteger, NSError *))completion {
    NSParameterAssert(source != nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 复制 Cookies 库到临时文件读取（不碰浏览器原库），用完即删。
        NSString *dbPath = [source.profilePath stringByAppendingPathComponent:@"Cookies"];
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rd-cookie-import-%@.db", NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        if (![[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:tmp error:nil]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, [NSError errorWithDomain:@"RDCookieImport" code:3
                    userInfo:@{NSLocalizedDescriptionKey: @"无法读取浏览器 Cookie 数据库（浏览器正在写入或路径变化）"}]);
            });
            return;
        }
        sqlite3 *db = NULL;
        sqlite3_stmt *stmt = NULL;
        BOOL dbOpened = (sqlite3_open_v2(tmp.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
        BOOL prepared = dbOpened && (sqlite3_prepare_v2(db,
            "SELECT host_key, name, value, encrypted_value, path, is_secure, is_httponly, expires_utc FROM cookies;",
            -1, &stmt, NULL) == SQLITE_OK);
        if (!dbOpened || !prepared) {
            if (db) sqlite3_close(db);
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, [NSError errorWithDomain:@"RDCookieImport" code:3
                    userInfo:@{NSLocalizedDescriptionKey: @"无法解析浏览器 Cookie 数据库"}]);
            });
            return;
        }

        // ---- 密钥自动探测：读第一条 v10 密文，用每个候选钥匙串服务名试解，谁解开用谁 ----
        NSData *sampleEncrypted = nil;
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            sampleEncrypted = [self blobColumn:stmt index:3];
        }
        (void)sqlite3_reset(stmt);   // 复位游标：后续 while 从第一行完整遍历
        NSError *keyError = nil;
        NSData *aesKey = [self derivedKeyAutoDetectForBrowserName:source.browserName
                                                   sampleEncrypted:sampleEncrypted
                                                      chosenService:nil
                                                              error:&keyError];
        if (!aesKey) {
            sqlite3_finalize(stmt);
            sqlite3_close(db);
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, 0, keyError ?: [NSError errorWithDomain:@"RDCookieImport" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"无法用任何候选钥匙串密钥解密该浏览器的 Cookie"}]);
            });
            return;
        }

        // ---- 逐条解密（诊断日志只含计数与前缀分布，绝不含 Cookie 内容）----
        NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
        NSUInteger failed = 0;
        NSUInteger prefixV10 = 0, prefixOther = 0, emptyValue = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *host = [self stringColumn:stmt index:0];
            NSString *name = [self stringColumn:stmt index:1];
            NSString *plain = [self stringColumn:stmt index:2];
            NSData *enc = [self blobColumn:stmt index:3];
            NSString *path = [self stringColumn:stmt index:4];
            BOOL secure = sqlite3_column_int(stmt, 5) != 0;

            BOOL httponly = sqlite3_column_int(stmt, 6) != 0;   // is_httponly：审计修复后如实保留
            int64_t expires = sqlite3_column_int64(stmt, 7);
            if (host.length == 0 || name.length == 0) { failed++; continue; }

            // 优先解密 encrypted_value；明文 value 列仅作旧记录兜底。
            NSString *value = plain.length ? plain : nil;
            if (!value && enc.length) {
                NSString *prefix3 = [[NSString alloc] initWithData:[enc subdataWithRange:NSMakeRange(0, MIN(3, enc.length))] encoding:NSASCIIStringEncoding];
                BOOL isV10 = [prefix3 isEqualToString:@"v10"];
                if (isV10) prefixV10++; else prefixOther++;
                NSData *dec = isV10 ? [self decryptChromiumV10Value:enc key:aesKey] : nil;
                value = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
                if (!value) emptyValue++;
            }
            if (value.length == 0) { failed++; continue; }

            NSMutableDictionary *props = [NSMutableDictionary dictionary];
            props[NSHTTPCookieName] = name;
            props[NSHTTPCookieValue] = value;
            props[NSHTTPCookieDomain] = host;      // host_key 自带前导点（域 Cookie）
            props[NSHTTPCookiePath] = path.length ? path : @"/";
            if (secure) props[NSHTTPCookieSecure] = @"TRUE";
            // 2026-10-07 审计修复：原注释称「NSHTTPCookie 无 HTTPOnly 属性键」，
            // 该断言经实测为**错误**——该键存在且构造后 properties 回读完整保留。
            // 现从 sqlite 的 is_httponly 列如实还原。
            if (httponly) props[@"HttpOnly"] = @"TRUE";
            NSDate *expiry = [self dateFromChromiumTimestamp:expires];
            if (expiry) props[NSHTTPCookieExpires] = expiry;   // 无过期 = 会话 Cookie
            NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
            if (cookie) [cookies addObject:cookie]; else failed++;
        }
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        RDLogWrite(@"app", @"Cookie 解密统计：总数 %lu / 成功 %lu / 失败 %lu（v10 密文 %lu、其他前缀 %lu、解密后为空 %lu；仅计数不含内容）",
                   (unsigned long)(cookies.count + failed), (unsigned long)cookies.count, (unsigned long)failed,
                   (unsigned long)prefixV10, (unsigned long)prefixOther, (unsigned long)emptyValue);

        // 灌入共享会话存储：串行等待每个 setCookie 完成。WebKit2 要求首次触碰与
        // API 调用在主线程（后台线程冷初始化会在 runInitializationCode 直接
        // SIGTRAP，实测；与 RDCdpCookieImporter 的同源注释一致），因此整段灌入
        // 收口到主线程；group 等待带超时兜底，绝不永久挂起导入线程。
        NSUInteger imported = cookies.count;
        void (^installAndWait)(void) = ^{
            WKHTTPCookieStore *store = [RDManualVerificationController sharedSessionDataStore].httpCookieStore;
            dispatch_group_t group = dispatch_group_create();
            for (NSHTTPCookie *cookie in cookies) {
                dispatch_group_enter(group);
                [store setCookie:cookie completionHandler:^{
                    dispatch_group_leave(group);
                }];
            }
            dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        };
        if ([NSThread isMainThread]) {
            installAndWait();
            if (completion) completion(imported, failed, nil);
        } else {
            dispatch_sync(dispatch_get_main_queue(), installAndWait);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(imported, failed, nil);
            });
        }
    });
}

// Keychain 候选密钥自动探测：每个候选服务名读密码（未授权的候选会触发系统授权框）
// → PBKDF2 派生 → 用样例密文试解密（v10 + PKCS7 + UTF-8 全过才算命中）。
+ (nullable NSData *)derivedKeyAutoDetectForBrowserName:(NSString *)browserName
                                        sampleEncrypted:(nullable NSData *)sampleEncrypted
                                          chosenService:(NSString **)outService
                                                  error:(NSError **)error {
    BOOL hasSample = (sampleEncrypted.length > 3);
    NSError *lastError = nil;
    for (NSString *service in [self candidateServiceNamesForBrowserName:browserName]) {
        NSData *password = [self safeStoragePasswordWithService:service error:&lastError];
        if (!password) continue;                     // 未授权/不存在：换下一个候选
        NSData *aesKey = [self derivedKeyFromPassword:password];
        if (!aesKey) continue;
        if (!hasSample) {
            if (outService) *outService = service;
            return aesKey;                           // 无样例可试：第一个能读到的即胜出
        }
        NSData *dec = [self decryptChromiumV10Value:sampleEncrypted key:aesKey];
        NSString *asText = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
        if (dec && asText.length) {
            if (outService) *outService = service;
            return aesKey;
        }
    }
    if (error) *error = lastError ?: [NSError errorWithDomain:@"RDCookieImport" code:7
        userInfo:@{NSLocalizedDescriptionKey: @"无法用任何候选钥匙串密钥解密该浏览器的 Cookie（密钥均不匹配）"}];
    return nil;
}

// Keychain 读取的错误包装：区分用户拒绝与条目不存在，给出中文可操作提示。
+ (nullable NSData *)safeStoragePasswordWithService:(NSString *)service error:(NSError **)error {
    NSDictionary *query = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: service,
        (id)kSecReturnData: @YES,
    };
    CFTypeRef found = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
    if (st == errSecItemNotFound) {
        if (error) *error = [NSError errorWithDomain:@"RDCookieImport" code:4
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"钥匙串里没有「%@」条目", service]}];
        return nil;
    }
    if (st == errSecInteractionNotAllowed || st == errSecAuthFailed || st == errSecUserCanceled) {
        if (error) *error = [NSError errorWithDomain:@"RDCookieImport" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"钥匙串授权未通过（弹框时请点「始终允许」后重试）"}];
        return nil;
    }
    if (st != errSecSuccess || !found) {
        if (error) *error = [NSError errorWithDomain:@"RDCookieImport" code:6
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"钥匙串读取失败（OSStatus=%d）", (int)st]}];
        return nil;
    }
    NSData *data = CFBridgingRelease(found);
    // Chromium 的 macOS「Safe Storage」口令是随机生成的（普遍超过 16 字节），
    // v10 派生规约要求**完整口令**进入 PBKDF2。此前截断到 16 字节会让派生密钥
    // 与浏览器真实密钥必然不同，对真实浏览器的导入整体失败（2026-10-24 审计）。
    if (data.length == 0) return nil;
    return data;
}

+ (nullable NSString *)stringColumn:(sqlite3_stmt *)stmt index:(int)index {
    const unsigned char *text = sqlite3_column_text(stmt, index);
    if (!text) return nil;
    return [NSString stringWithUTF8String:(const char *)text];
}

+ (nullable NSData *)blobColumn:(sqlite3_stmt *)stmt index:(int)index {
    const void *blob = sqlite3_column_blob(stmt, index);
    int bytes = sqlite3_column_bytes(stmt, index);
    if (!blob || bytes <= 0) return nil;
    return [NSData dataWithBytes:blob length:(NSUInteger)bytes];
}

@end
