//
//  DNSResolver.h — 模块 08｜主机名解析工具（纯网络解析、无 GUI）
//
//  供 SSRF 防护链使用：解析主机全部 A/AAAA 记录，交由 IPAddressPolicy
//  逐一分类校验。最多 4 个不可取消的系统解析在途；短缓存 0.5 秒。
//  这只是安全预检查，NSURLSession/WebKit 的实际连接 IP 并未绑定。
//  解析失败返回空数组，调用方应视为拒绝（宁严勿宽）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解析结果状态：调用方据此区分「成功」「超时（瞬态）」「解析失败」。
/// 保留地址判定仍由 URLPolicy 基于解析出的 IP 完成，与本状态无关。
typedef NS_ENUM(NSInteger, DNSResolutionStatus) {
    DNSResolutionSucceeded = 0,   // 至少解析出一个 IP
    DNSResolutionTimedOut,        // 解析超时（慢 DNS/网络切换等瞬态故障）
    DNSResolutionFailed,          // 解析失败/无记录（NXDOMAIN 等，非超时）
    DNSResolutionBusy,            // 有界待处理队列已满，暂时繁忙，可稍后重试
};

@interface DNSResolver : NSObject

/// 解析 host 的所有 IP（IPv4 + IPv6，去重、规范化字符串）。
/// 空 host / 解析失败 / 无记录均返回空数组。
+ (NSArray<NSString *> *)resolveIPsForHost:(NSString *)host;

/// 带状态出参的解析：排队与解析共享 2 秒预算，最多 4 个系统解析、20 个待处理任务。
/// 队列已满报告 Busy；同 host 合并，缓存 0.5 秒。
/// 调用方不得把「超时」与「解析到保留地址」混为同一种终态。
+ (NSArray<NSString *> *)resolveIPsForHost:(NSString *)host
                                    status:(out DNSResolutionStatus * _Nullable)status;

@end

NS_ASSUME_NONNULL_END
