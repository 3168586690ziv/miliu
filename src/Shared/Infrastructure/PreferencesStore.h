//
//  PreferencesStore.h — 模块 07｜用户偏好、书签、缓存与迁移
//
//  唯一偏好访问入口。所有 NSUserDefaults 键集中定义为常量，UI 不再散落字符串键名。
//  支持注入独立 suite（测试用），正式 App 使用 standardUserDefaults。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// ── 偏好键常量（来源：Docs/Baseline/USER_DATA_MAP.md）──
extern NSString *const SevenZZKeyPerformanceMode;
extern NSString *const SevenZZKeyAppTheme;
extern NSString *const SevenZZKeyWhiteInterfaceRefreshV1;
extern NSString *const SevenZZKeySourceURLBookmark;
extern NSString *const SevenZZKeyConversionOutputURLBookmark;
extern NSString *const SevenZZKeyLastMainPage;
extern NSString *const SevenZZKeyLastWorkspace;
extern NSString *const SevenZZKeyDeltaNativePayloadJSON;
extern NSString *const SevenZZKeyDeltaNativePayloadRefreshedAt;
extern NSString *const SevenZZKeyDeltaProfitSnapshot;
extern NSString *const SevenZZKeyDeltaNativePayloadDay;
extern NSString *const SevenZZKeyDeltaFavoriteItems;
extern NSString *const SevenZZKeyMarketIndex;
extern NSString *const SevenZZKeyMarketRange;
extern NSString *const SevenZZKeyMarketIntradayDefaultV1;
extern NSString *const SevenZZKeyMarketRangeOrderV2;
extern NSString *const SevenZZKeyMarketCacheNdx;
extern NSString *const SevenZZKeyMarketCacheNdxUpdated;
extern NSString *const SevenZZKeyMarketCacheSpx;
extern NSString *const SevenZZKeyMarketCacheSpxUpdated;
extern NSString *const SevenZZKeyCompletedResourceURLs;
extern NSString *const SevenZZKeyResourceSelectAllScope;
extern NSString *const SevenZZKeyResourceDownloadDestination;
extern NSString *const SevenZZKeyResourceDownloadCustomDirectory;   // 2026-09-03 自选下载目录（U 盘等）
extern NSString *const SevenZZKeyMainPaneRatio;                    // 主界面左右栏比例：0=3:7，1=2:8，2=2.5:7.5
extern NSString *const SevenZZKeyProbeMode;                       // 探测模式：0=当前页，1=总站
extern NSString *const SevenZZKeySitePages;                       // 总站模式页数（正整数，默认 3）
extern NSString *const SevenZZKeyLastMood;
extern NSString *const SevenZZKeyLastMoodLabel;
extern NSString *const SevenZZKeyRecentMoodQuoteIDs;
extern NSString *const SevenZZKeyMoodHistoryRecords;
extern NSString *const SevenZZKeyMoodHistoryDeletedSnapshot;
extern NSString *const SevenZZKeyMoodHistoryDeletedSnapshotDate;
extern NSString *const SevenZZKeySchemaVersion;

typedef NS_ENUM(NSInteger, SevenZZPreferenceType) {
    SevenZZPreferenceTypeInteger = 0,
    SevenZZPreferenceTypeString,
    SevenZZPreferenceTypeBool,
    SevenZZPreferenceTypeDouble,
    SevenZZPreferenceTypeArray,
    SevenZZPreferenceTypeDictionary,
    SevenZZPreferenceTypeData,
};

@interface SevenZZPreferenceKeySpec : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) SevenZZPreferenceType type;
@property (nonatomic, copy, nullable) id defaultValue;
@property (nonatomic, copy, nullable) NSString *owningPage;
@property (nonatomic, copy, nullable) NSString *migrationRule;
+ (instancetype)specWithKey:(NSString *)key
                       type:(SevenZZPreferenceType)type
               defaultValue:(nullable id)defaultValue
                 owningPage:(nullable NSString *)page
               migrationRule:(nullable NSString *)rule;
@end

@interface PreferencesStore : NSObject

@property (nonatomic, strong) NSUserDefaults *userDefaults;

+ (instancetype)shared;

// 测试注入：使用独立 suite，不影响真实用户偏好
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults;

// 类型化读写（全部带默认值保护）
- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)def;
- (void)setString:(NSString *)value forKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key defaultValue:(double)def;
- (void)setDouble:(double)value forKey:(NSString *)key;
- (nullable NSArray *)arrayForKey:(NSString *)key;
- (void)setArray:(NSArray *)value forKey:(NSString *)key;
- (nullable NSDictionary *)dictionaryForKey:(NSString *)key;
- (void)setDictionary:(NSDictionary *)value forKey:(NSString *)key;
- (nullable NSData *)dataForKey:(NSString *)key;
- (void)setData:(NSData *)value forKey:(NSString *)key;

// 安全书签
- (nullable NSURL *)resolveBookmarkForKey:(NSString *)key stale:(BOOL *)outStale;
- (void)storeBookmarkForURL:(NSURL *)url forKey:(NSString *)key;

// 全量键规范（用于审计与迁移）
+ (NSArray<SevenZZPreferenceKeySpec *> *)allKeySpecs;

@end

NS_ASSUME_NONNULL_END
