//
//  RDCurlHopper.h — curl 按跳传输引擎（Shared：元数据回退与下载回退共用）
//
//  背景（2026-09-19 真实站点根因）：部分站点把媒体请求 302 到 Cloudflare 系宿主，
//  该宿主按 TLS/H2 栈指纹拦截 Apple Network.framework（403 拦截页或挂起连接），
//  与请求头无关；/usr/bin/curl（SecureTransport+nghttp2 指纹）实测可过。
//
//  安全契约（两条链共用，绝不可绕）：
//    · 不加 -L 盲跟：每一跳先做与原生传输同一策略的校验（URLPolicy 文本校验 +
//      DNS 解析后全 IP 校验），再独立起一个 curl 进程；
//    · 进程用 argv 数组直传（无 shell 拼接），请求头经 -H 逐个透传；
//    · 响应体只认本跳临时文件，超出预算判 BudgetExceeded；
//    · curl 层失败（DNS/连接/超时/不可执行）返回 Unresolved，由调用方决定是否
//      保留原生结果——引擎绝不伪造成功。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const RDCurlHopErrorDomain;

typedef NS_ENUM(NSInteger, RDCurlHopError) {
    RDCurlHopBlocked = 1,      ///< URLPolicy / DNS 全 IP 校验拒绝（含重定向目标）
    RDCurlHopTimedOut,         ///< DNS busy / 超出整体截止时间
    RDCurlHopHTTPFailure,      ///< 终跳非 2xx（结果仍带 response 供分类）
    RDCurlHopBudgetExceeded,   ///< 响应体超出预算
    RDCurlHopUnresolved,       ///< curl 未完成有效交换（保留调用方原生结果的信号）
};

@interface RDCurlHopResult : NSObject
/// 终跳响应（3xx/4xx/5xx 也带，供调用方分类与日志）。
@property (nonatomic, strong, nullable) NSHTTPURLResponse *response;
/// data 模式下的响应体（≤budget）。
@property (nonatomic, strong, nullable) NSData *body;
/// file 模式下的响应体文件（调用方负责移动/删除；成功时才保证存在）。
@property (nonatomic, copy, nullable) NSString *bodyFile;
/// nil = 2xx 成功。
@property (nonatomic, strong, nullable) NSError *error;
@end

/// 测试注入：替代真实 curl 进程。参数为完整 argv（首元素 = curlPath）与本跳
/// 头转储/响应体文件路径，返回 curl 退出码；runner 自行写这两个文件。
typedef NSInteger (^RDCurlHopRunnerBlock)(NSArray<NSString *> *argv,
                                          NSString *headerFile,
                                          NSString *bodyFile);

@interface RDCurlHopper : NSObject

@property (nonatomic, copy) NSString *curlPath;          ///< 默认 /usr/bin/curl
@property (nonatomic, copy, nullable) RDCurlHopRunnerBlock runner;  ///< nil = 真实 curl
@property (nonatomic, copy) NSString *logComponent;      ///< 默认 @"meta"
/// 响应体落盘路径覆盖（默认临时目录随机名）。设置后成功/失败都使用该路径，
/// 由调用方负责清理（下载回退借此在传输中轮询文件大小上报进度）。
@property (nonatomic, copy, nullable) NSString *bodyFilePath;
/// 测试注入：host → IP 列表（与原生传输 initWithResolver: 同语义）。nil = 真实 DNS。
@property (nonatomic, copy, nullable) NSArray<NSString *> *(^resolver)(NSString *host);

/// 逐跳走完一个请求。deadline 之后不再发起新跳；bodyToFile=YES 时响应体保留在
/// result.bodyFile（不载入内存），否则载入 result.body。回调可能在后台队列。
- (void)walkURL:(NSURL *)url
         method:(NSString *)method
        headers:(NSDictionary<NSString *, NSString *> *)headers
         budget:(NSUInteger)budget
       deadline:(CFAbsoluteTime)deadline
     bodyToFile:(BOOL)bodyToFile
     completion:(void (^)(RDCurlHopResult *result))completion;

/// 取消在途 curl 进程并中止后续跳。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
