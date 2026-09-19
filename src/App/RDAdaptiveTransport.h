//
//  RDAdaptiveTransport.h — 元数据复合传输：原生 NSURLSession 优先 + curl 按跳回退
//
//  根因（2026-09-19 真实站点 www.hanime2.org 实测）：站点的媒体直链把请求 302 到
//  Cloudflare 系流媒体宿主，该宿主对 Apple Network.framework 的 TLS/H2 指纹一律
//  返回 403「Sorry, you have been blocked」或直接挂起连接，与请求头无关
//  （实测改 UA / Referer 均无效；curl 与 WebKit 同请求可过）。原生栈被拦时详情
//  元数据全部失败，界面显示「读取失败」。
//
//  放在 App 层而非 Features 层：只有正式构建会编译本文件，所有测试套件按
//  既有依赖单独链接原生传输，不受影响（生产构造在 ResourceDetectorApp）。
//
//  本传输不做的事：不改写请求头语义（Referer 的 origin 归一仍由
//  HTTPPrivacyPolicy 完成，curl 跳用同一份已归一头）；不绕过 URLPolicy / DNS
//  校验（逐跳校验见 RDCurlHopper 的安全契约）。
//

#import "RDMetadataTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface RDAdaptiveTransport : NSObject <RDMetadataTransporting>

/// 生产构造：native = 常规原生传输（快路径）。
- (instancetype)initWithNativeTransport:(id<RDMetadataTransporting>)nativeTransport;
+ (instancetype)adaptiveWithNativeTransport:(id<RDMetadataTransporting>)nativeTransport;

/// curl 可执行文件路径，默认 /usr/bin/curl。
@property (nonatomic, copy) NSString *curlPath;

/// 测试注入：替代真实 curl 进程（透传给内部 RDCurlHopper）。
@property (nonatomic, copy, nullable) NSInteger (^curlRunner)(NSArray<NSString *> *argv,
                                                              NSString *headerFile,
                                                              NSString *bodyFile);

/// 测试注入：host → IP 列表（透传给内部 RDCurlHopper，与原生传输同语义）。
@property (nonatomic, copy, nullable) NSArray<NSString *> *(^resolver)(NSString *host);

@end

NS_ASSUME_NONNULL_END
