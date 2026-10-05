//
//  RDBrowserCookieImporter.h — 浏览器登录态一键导入（Chromium 系 v10 Cookie）
//
//  背景（2026-10-05 第 25 轮，主人拍板）：应用内浏览器需要手动登录一次；而主人
//  在 BrowserClaw / Edge 等 Chromium 系浏览器里早已登录过目标站点。Chromium 的
//  Cookie 用 AES-128-CBC（v10，PBKDF2-HMAC-SHA1("saltysalt", 1003) 派生密钥，
//  密钥在钥匙串 "<浏览器名> Safe Storage"）加密存储——本组件把指定浏览器 profile
//  的 Cookie 解密后灌入 App 共享会话存储（WKWebsiteDataStore.defaultDataStore），
//  探测随即携带登录态，免去重复手动登录。
//
//  隐私与安全边界（绝不可越）：
//    · Keychain 读取只在**用户点击导入**时发生（系统会弹授权框，由用户决定）；
//    · Cookie 明文只存在于内存变量，不写日志、不显示、不落盘、不外传；
//    · Cookies 数据库先复制到临时文件再读，用完即删，不碰浏览器原库；
//    · 过程仅向用户展示条目计数与站点域名（与设置页会话显示同一口径）。
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个可导入的来源：浏览器 + profile 目录（Cookies 库所在）。
@interface RDBrowserCookieSource : NSObject
@property (nonatomic, copy) NSString *browserName;    ///< 显示名（如 BrowserClaw）
@property (nonatomic, copy) NSString *profilePath;    ///< profile 目录绝对路径
@property (nonatomic, copy) NSString *profileLabel;   ///< 显示标签（如 Default / Profile 1）
@property (nonatomic, assign) NSUInteger cookieCount; ///< 库内记录数（只读计数）
@end

@interface RDBrowserCookieImporter : NSObject

/// 扫描常见 Chromium 系浏览器 profile（只检查 Cookies 文件存在与记录数，不碰 Keychain）。
+ (NSArray<RDBrowserCookieSource *> *)availableSources;

/// 导入指定来源的全部 Cookie 到共享会话存储。Keychain 读取会触发系统授权框；
/// completion 固定主线程回调：imported=成功灌入条数，failed=解密/构造失败条数，
/// error=nil 表示流程完成（个别条目失败不视为整体失败）。
+ (void)importFromSource:(RDBrowserCookieSource *)source
              completion:(void (^)(NSUInteger imported, NSUInteger failed, NSError *error))completion;

/// 纯函数（供测试）：v10 前缀 + AES-128-CBC 解密（PKCS7 去填充），失败返回 nil。
+ (nullable NSData *)decryptChromiumV10Value:(NSData *)encrypted key:(NSData *)key;
/// 纯函数（供测试）：Chromium 时间戳（1601-01-01 起 microsecond）→ NSDate；0 返回 nil。
+ (nullable NSDate *)dateFromChromiumTimestamp:(int64_t)microsecondsSince1601;
/// 纯函数（供测试）：浏览器名 → 钥匙串 Safe Storage 服务名。
+ (NSString *)safeStorageServiceNameForBrowserName:(NSString *)browserName;

@end

NS_ASSUME_NONNULL_END
