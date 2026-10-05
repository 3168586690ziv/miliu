//
//  RDWatchlistStore.h — 追更观察库（App 与常驻助手共享的唯一数据契约）
//
//  v1（2026-10-03 小肥鱼地基）：纯 Foundation、无 UI 依赖 —— Miliu主程序与
//  「Miliu追更助手」（嵌入主 bundle 的 LSUIElement 后台进程）都链接本文件，
//  通过同一份 watchlist.json 交换观察列表 / 资源快照 / 未读计数。
//  禁止任何一侧另建第二套存储或字段名。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单个被观察页面。knownKeys 单调增长（页面删掉旧资源后再出现不重复提醒）。
@interface RDWatchlistEntry : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;      // UUID，创建后不变
@property (nonatomic, copy) NSString *pageURL;         // 规范化后的页面地址
@property (nonatomic, copy, nullable) NSString *title; // 页面标题（仅展示）
/// 探测间隔（分钟）。合法值 15/30/60/120，默认 30；非法值按 30 处理。
@property (nonatomic, assign) NSInteger intervalMinutes;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL videoOnly;          // v1 判定范围恒为 YES（仅视频/清单）
@property (nonatomic, copy, nullable) NSDate *lastProbeAt;   // 最近一次探测（无论成败）
@property (nonatomic, copy, nullable) NSDate *lastResultAt;  // 最近一次探测成功
@property (nonatomic, copy) NSArray<NSString *> *knownKeys;     // 已知资源 dedupKey 快照（单调）
@property (nonatomic, copy) NSArray<NSString *> *pendingNewKeys;// 未读新资源 dedupKey（用户读后清空）
@property (nonatomic, copy, nullable) NSString *lastError;      // 最近一次失败原因（展示用）

+ (instancetype)entryWithPageURL:(NSString *)pageURL;
/// keys 中不在 knownKeys 里的部分（保持传入顺序）。
- (NSArray<NSString *> *)filterNewKeys:(NSArray<NSString *> *)keys;
@end

@interface RDWatchlistStore : NSObject

/// App 与助手共用的默认存储：
/// ~/Library/Application Support/MiliuWatchlist/watchlist.json（附 .lock 文件）。
+ (instancetype)sharedStore;
- (instancetype)initWithStoreURL:(NSURL *)storeURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSArray<RDWatchlistEntry *> *entries;

/// 按规范化地址查条目；无则 nil。
- (nullable RDWatchlistEntry *)entryForURL:(NSString *)pageURL;
/// 添加或更新：同地址已存在则只更新 title 并返回既有条目（identifier 不变）。
- (RDWatchlistEntry *)upsertEntryForURL:(NSString *)pageURL title:(nullable NSString *)title;
/// 整体写回一条条目（内部按 identifier 定位替换；拷贝语义，入参可再改）。
- (void)updateEntry:(RDWatchlistEntry *)entry;
- (BOOL)removeEntryWithIdentifier:(NSString *)identifier;

/// 到期探测名单：enabled 且（从未探测 或 now ≥ lastProbeAt + interval）。
- (NSArray<RDWatchlistEntry *> *)dueEntriesBeforeDate:(NSDate *)date;

/// 探测结果原子记账（助手每探完一页调用一次；跨进程文件锁内完成 读-改-写）：
/// · error 非 nil → 只更新 lastProbeAt / lastError，键集与未读不动；
/// · error 为 nil → lastError 清空、lastProbeAt / lastResultAt 更新，
///   knownKeys = knownKeys ∪ fetchedKeys（单调），
///   pendingNewKeys = pendingNewKeys + (fetchedKeys − 旧 knownKeys)。
- (void)recordProbeResult:(RDWatchlistEntry *)entry
              fetchedKeys:(NSArray<NSString *> *)fetchedKeys
                    error:(nullable NSString *)error;

/// 用户查看后清未读（只清 pendingNewKeys，knownKeys 保留）。
- (void)markPendingRead:(NSString *)identifier;

/// 全部条目未读新增总数（菜单栏角标）。
- (NSInteger)totalPendingNewCount;

@end

NS_ASSUME_NONNULL_END
