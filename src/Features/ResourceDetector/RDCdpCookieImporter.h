//
//  RDCdpCookieImporter.h — CDP 自动化导入浏览器登录态（浏览器自愿导出，无解密）
//
//  背景（2026-10-05 第 27 轮，主人拍板）：第 25-26 轮实测证明 2026 年的 Chromium 系
//  浏览器已进入 app-bound 加密时代，钥匙串解密路线不可行。本组件改走官方自动化
//  通道（DevTools 协议）：把目标浏览器的 profile **白名单文件**（Local State +
//  Cookies 库）复制到临时目录，以 headless + 随机调试端口拉起**该浏览器自己**——
//  浏览器用自己的密钥正常解密——再经 CDP `Storage.getCookies` 导出全部 Cookie，
//  灌入 App 共享会话存储后立即终止进程并删除临时目录。
//
//  隐私与安全边界（绝不可越）：
//    · 不读取、不解密任何加密数据——解密只发生在浏览器进程内部；
//    · 调试端口只绑 127.0.0.1（Chromium 默认行为），导入窗口期外不可达；
//    · Cookie 值只在内存变量，不写日志、不显示、不落盘、不外传；
//    · 临时 profile 副本用完即删；不修改浏览器原目录的任何文件。
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个可导入来源：浏览器（可执行文件 + 显示名）与其 profile 目录。
@interface RDCdpCookieSource : NSObject
@property (nonatomic, copy) NSString *browserName;    ///< 显示名（如 Microsoft Edge）
@property (nonatomic, copy) NSString *executablePath; ///< 浏览器可执行文件绝对路径
@property (nonatomic, copy) NSString *profilePath;    ///< Application Support 下 profile 根目录
@property (nonatomic, assign) NSUInteger cookieCount; ///< Cookies 库记录数（只读计数）
@end

@interface RDCdpCookieImporter : NSObject

/// 扫描已安装且带非空 Cookies 库的候选浏览器（只读文件存在性与计数，不启动任何进程）。
+ (NSArray<RDCdpCookieSource *> *)availableSources;

/// CDP 导入。completion 固定主线程：imported=灌入条数，failed=字段不全被跳过条数，
/// error=nil 表示流程完成。整体限时约 60 秒（启动/握手/导出各阶段内部分别设限）。
+ (void)importFromSource:(RDCdpCookieSource *)source
              completion:(void (^)(NSUInteger imported, NSUInteger failed, NSError *error))completion;

/// 纯函数（供测试）：CDP Storage.getCookies 结果数组 → NSHTTPCookie。
/// expires <= -1 视为会话 Cookie；name/domain/path 任一为空则跳过（返回 nil）。
+ (nullable NSHTTPCookie *)httpCookieFromCdpDictionary:(NSDictionary<NSString *, id> *)entry;

/// 纯函数（供测试）：导入需要复制的白名单相对路径（相对 profile 根目录）。
+ (NSArray<NSString *> *)whitelistedProfileRelativePaths;

@end

NS_ASSUME_NONNULL_END
