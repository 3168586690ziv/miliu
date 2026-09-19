//
//  RDCurlFallbackBackend.h — 下载传输后端：原生优先 + curl 按跳回退
//
//  与 RDAdaptiveTransport 同一根因（2026-09-19 真实站点实测）：Cloudflare 系流媒体
//  宿主按 TLS/H2 指纹拦截 Apple Network.framework，分段下载请求拿到 403 拦截页
//  或连接被晾死。本后端把原生后端的分段请求原样转发，仅在命中「指纹拦截签名」
//  时按跳回退 /usr/bin/curl 重发同一段 Range（逐跳 URLPolicy+DNS 校验，
//  见 RDCurlHopper 安全契约）。
//
//  回退触发（原生完成结果）：
//    · error 存在且无 response（连接层失败/被晾）且 error 属 NSURLSession 传输域；
//    · 写盘成功但 statusCode == 403（CF「Sorry, you have been blocked」拦截页体）。
//  curl 也没能改善时，原样保留原生结果（含原生已写盘的文件，绝不删错）。
//
//  放在 App 层：只有正式构建编译本文件；DownloadManager 经运行时查类包装，
//  测试套件单独链接时自动退化为纯原生后端。
//

#import "DownloadManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface RDCurlFallbackBackend : NSObject <RDDownloadBackend>

- (instancetype)initWithNativeBackend:(id<RDDownloadBackend>)nativeBackend;
+ (instancetype)backendWithNativeBackend:(id<RDDownloadBackend>)nativeBackend;

/// curl 可执行文件路径，默认 /usr/bin/curl。
@property (nonatomic, copy) NSString *curlPath;

/// 测试注入：透传给内部 RDCurlHopper。
@property (nonatomic, copy, nullable) NSInteger (^curlRunner)(NSArray<NSString *> *argv,
                                                              NSString *headerFile,
                                                              NSString *bodyFile);

/// 测试注入：host → IP 列表（透传给内部 RDCurlHopper）。
@property (nonatomic, copy, nullable) NSArray<NSString *> *(^resolver)(NSString *host);

@end

NS_ASSUME_NONNULL_END
