//
//  RDWatchAgentController.h — 「觅流追更助手」常驻后台控制器
//
//  觅流主 App 嵌入的 LSUIElement 菜单栏助手（无 Dock 图标）：
//    · NSStatusItem 菜单（头部状态行 / 未读条目区 / 立即全部重探 / 暂停·恢复 /
//      管理观察列表… / 退出助手），按钮角标 = totalPendingNewCount
//    · 60s tick 定时静默探测（RDWatchlistStore + RDHybridPageProbe 复用）
//    · 新资源系统通知（UNUserNotificationCenter）
//    · 点按「查看」→ 唤起觅流主 App + 分布式通知 openAndScan（契约 §3.1）
//    · 监听 watchNow（立即轮询）/ watchService（SMAppService 注册/注销）
//
//  数据契约：RDWatchlistStore.h（与主 App 共享同一份 watchlist.json，禁止改语义）。
//  线程约定：控制器全部状态只在主线程读写（WKWebView 会话只能主线程创建与投递，
//  见 WebProbe.m 的 NSAssert 约束）。
//
//  本文件只暴露最小接口；装配入口见 RDWatchAgentMain.m。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RDWatchAgentController : NSObject <NSApplicationDelegate>
@end

NS_ASSUME_NONNULL_END
