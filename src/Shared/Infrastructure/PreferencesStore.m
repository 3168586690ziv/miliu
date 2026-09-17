//
//  PreferencesStore.m — 模块 07
//
#import "PreferencesStore.h"

NSString *const SevenZZKeyPerformanceMode                = @"PerformanceMode";
NSString *const SevenZZKeyAppTheme                       = @"AppTheme";
NSString *const SevenZZKeyWhiteInterfaceRefreshV1        = @"WhiteInterfaceRefreshV1";
NSString *const SevenZZKeySourceURLBookmark              = @"SourceURLBookmark";
NSString *const SevenZZKeyConversionOutputURLBookmark    = @"ConversionOutputURLBookmark";
NSString *const SevenZZKeyLastMainPage                   = @"LastMainPage";
NSString *const SevenZZKeyLastWorkspace                   = @"LastWorkspace";
NSString *const SevenZZKeyDeltaNativePayloadJSON         = @"DeltaNativePayloadJSON";
NSString *const SevenZZKeyDeltaNativePayloadRefreshedAt   = @"DeltaNativePayloadRefreshedAt";
NSString *const SevenZZKeyDeltaProfitSnapshot            = @"DeltaProfitSnapshot";
NSString *const SevenZZKeyDeltaNativePayloadDay          = @"DeltaNativePayloadDay";
NSString *const SevenZZKeyDeltaFavoriteItems             = @"DeltaFavoriteItems";
NSString *const SevenZZKeyMarketIndex                    = @"MarketIndex";
NSString *const SevenZZKeyMarketRange                    = @"MarketRange";
NSString *const SevenZZKeyMarketIntradayDefaultV1        = @"MarketIntradayDefaultV1";
NSString *const SevenZZKeyMarketRangeOrderV2             = @"MarketRangeOrderV2";
NSString *const SevenZZKeyMarketCacheNdx                 = @"market.cache.ndx";
NSString *const SevenZZKeyMarketCacheNdxUpdated          = @"market.cache.ndx.updated";
NSString *const SevenZZKeyMarketCacheSpx                 = @"market.cache.spx";
NSString *const SevenZZKeyMarketCacheSpxUpdated          = @"market.cache.spx.updated";
NSString *const SevenZZKeyCompletedResourceURLs          = @"CompletedResourceURLs";
NSString *const SevenZZKeyResourceSelectAllScope         = @"ZZResourceDownload.SelectAllScope";
NSString *const SevenZZKeyResourceDownloadDestination    = @"ZZResourceDownload.Destination";
NSString *const SevenZZKeyResourceDownloadCustomDirectory = @"ZZResourceDownload.CustomDirectory";
NSString *const SevenZZKeyMainPaneRatio              = @"ZZResourceDetector.MainPaneRatio";
NSString *const SevenZZKeyLastMood                       = @"LastMood";
NSString *const SevenZZKeyLastMoodLabel                  = @"LastMoodLabel";
NSString *const SevenZZKeyRecentMoodQuoteIDs             = @"RecentMoodQuoteIDs";
NSString *const SevenZZKeyMoodHistoryRecords             = @"MoodHistoryRecords";
NSString *const SevenZZKeyMoodHistoryDeletedSnapshot     = @"MoodHistoryDeletedSnapshot";
NSString *const SevenZZKeyMoodHistoryDeletedSnapshotDate = @"MoodHistoryDeletedSnapshotDate";
NSString *const SevenZZKeySchemaVersion                  = @"SevenZZSchemaVersion";

@implementation SevenZZPreferenceKeySpec
+ (instancetype)specWithKey:(NSString *)key
                       type:(SevenZZPreferenceType)type
               defaultValue:(nullable id)defaultValue
                 owningPage:(nullable NSString *)page
               migrationRule:(nullable NSString *)rule {
    SevenZZPreferenceKeySpec *s = [[self alloc] init];
    s.key = key;
    s.type = type;
    s.defaultValue = defaultValue;
    s.owningPage = page;
    s.migrationRule = rule;
    return s;
}
@end

@interface PreferencesStore ()
@end

@implementation PreferencesStore

+ (instancetype)shared {
    static PreferencesStore *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 独立 App 使用自身 bundle id 对应的 standard defaults，
        // 不再读取 SevenZZ 主 App 的偏好套件，保证换机可用。
        inst = [[PreferencesStore alloc] initWithUserDefaults:[NSUserDefaults standardUserDefaults]];
    });
    return inst;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults {
    self = [super init];
    if (self) {
        _userDefaults = userDefaults ?: [NSUserDefaults standardUserDefaults];
    }
    return self;
}

#pragma mark - 类型化读写

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self.userDefaults objectForKey:key];
    if (v == nil) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    return def;
}
- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    [self.userDefaults setInteger:value forKey:key];
}

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)def {
    id v = [self.userDefaults objectForKey:key];
    if (v == nil) return def;
    if ([v isKindOfClass:[NSString class]]) return v;
    return def;
}
- (void)setString:(NSString *)value forKey:(NSString *)key {
    if (value) [self.userDefaults setObject:value forKey:key];
    else [self.userDefaults removeObjectForKey:key];
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id v = [self.userDefaults objectForKey:key];
    if (v == nil) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return def;
}
- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [self.userDefaults setBool:value forKey:key];
}

- (double)doubleForKey:(NSString *)key defaultValue:(double)def {
    id v = [self.userDefaults objectForKey:key];
    if (v == nil) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    return def;
}
- (void)setDouble:(double)value forKey:(NSString *)key {
    [self.userDefaults setDouble:value forKey:key];
}

- (nullable NSArray *)arrayForKey:(NSString *)key {
    id v = [self.userDefaults objectForKey:key];
    if (v == nil) return nil;
    if ([v isKindOfClass:[NSArray class]]) return v;
    return nil;
}
- (void)setArray:(NSArray *)value forKey:(NSString *)key {
    if (value) [self.userDefaults setObject:value forKey:key];
    else [self.userDefaults removeObjectForKey:key];
}

- (nullable NSDictionary *)dictionaryForKey:(NSString *)key {
    id v = [self.userDefaults objectForKey:key];
    if (v == nil) return nil;
    if ([v isKindOfClass:[NSDictionary class]]) return v;
    return nil;
}
- (void)setDictionary:(NSDictionary *)value forKey:(NSString *)key {
    if (value) [self.userDefaults setObject:value forKey:key];
    else [self.userDefaults removeObjectForKey:key];
}

- (nullable NSData *)dataForKey:(NSString *)key {
    return [self.userDefaults dataForKey:key];
}
- (void)setData:(NSData *)value forKey:(NSString *)key {
    if (value) [self.userDefaults setObject:value forKey:key];
    else [self.userDefaults removeObjectForKey:key];
}

#pragma mark - 安全书签

- (nullable NSURL *)resolveBookmarkForKey:(NSString *)key stale:(BOOL *)outStale {
    NSData *bookmark = [self dataForKey:key];
    if (bookmark == nil) { if (outStale) *outStale = NO; return nil; }
    BOOL isStale = NO;
    NSError *err = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:NSURLBookmarkResolutionWithSecurityScope
                                     relativeToURL:nil
                               bookmarkDataIsStale:&isStale
                                             error:&err];
    if (err || url == nil) {
        // 回退：无沙箱环境下用无选项解析
        url = [NSURL URLByResolvingBookmarkData:bookmark
                                        options:0
                                  relativeToURL:nil
                            bookmarkDataIsStale:&isStale
                                          error:nil];
    }
    if (outStale) *outStale = isStale;
    if (url == nil) {
        if (outStale) *outStale = YES; // 解析失败等同需要重新选择
        return nil;
    }
    return url;
}

- (void)storeBookmarkForURL:(NSURL *)url forKey:(NSString *)key {
    if (url == nil) { [self.userDefaults removeObjectForKey:key]; return; }
    NSError *err = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&err];
    if (bookmark == nil || err) {
        // 回退：非沙箱环境用 minimal 书签
        bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:nil];
    }
    if (bookmark) {
        [self setData:bookmark forKey:key];
    }
}

#pragma mark - 键规范

+ (NSArray<SevenZZPreferenceKeySpec *> *)allKeySpecs {
    NSMutableArray *specs = [NSMutableArray array];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyPerformanceMode type:SevenZZPreferenceTypeInteger defaultValue:@(1) owningPage:@"settings" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyAppTheme type:SevenZZPreferenceTypeString defaultValue:@"light" owningPage:@"settings" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyWhiteInterfaceRefreshV1 type:SevenZZPreferenceTypeBool defaultValue:@(NO) owningPage:@"settings" migrationRule:@"V1一次性迁移标记"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeySourceURLBookmark type:SevenZZPreferenceTypeData defaultValue:nil owningPage:@"media" migrationRule:@"书签stale检查"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyConversionOutputURLBookmark type:SevenZZPreferenceTypeData defaultValue:nil owningPage:@"media" migrationRule:@"书签stale检查"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyLastMainPage type:SevenZZPreferenceTypeString defaultValue:@"media" owningPage:@"all" migrationRule:@"未知值回退media"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyLastWorkspace type:SevenZZPreferenceTypeString defaultValue:@"daily" owningPage:@"all" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyDeltaNativePayloadJSON type:SevenZZPreferenceTypeString defaultValue:nil owningPage:@"delta" migrationRule:@"缓存，可降级"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyDeltaNativePayloadRefreshedAt type:SevenZZPreferenceTypeDouble defaultValue:@(0) owningPage:@"delta" migrationRule:@"缓存时间"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyDeltaProfitSnapshot type:SevenZZPreferenceTypeDictionary defaultValue:nil owningPage:@"delta" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyDeltaNativePayloadDay type:SevenZZPreferenceTypeString defaultValue:nil owningPage:@"delta" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyDeltaFavoriteItems type:SevenZZPreferenceTypeArray defaultValue:@[] owningPage:@"delta" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketIndex type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"market" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketRange type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"market" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketIntradayDefaultV1 type:SevenZZPreferenceTypeBool defaultValue:@(NO) owningPage:@"market" migrationRule:@"V1一次性迁移标记"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketRangeOrderV2 type:SevenZZPreferenceTypeBool defaultValue:@(NO) owningPage:@"market" migrationRule:@"V2范围排序迁移"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketCacheNdx type:SevenZZPreferenceTypeArray defaultValue:nil owningPage:@"market" migrationRule:@"缓存，可降级"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketCacheNdxUpdated type:SevenZZPreferenceTypeDouble defaultValue:@(0) owningPage:@"market" migrationRule:@"缓存时间"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketCacheSpx type:SevenZZPreferenceTypeArray defaultValue:nil owningPage:@"market" migrationRule:@"缓存，可降级"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMarketCacheSpxUpdated type:SevenZZPreferenceTypeDouble defaultValue:@(0) owningPage:@"market" migrationRule:@"缓存时间"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyCompletedResourceURLs type:SevenZZPreferenceTypeArray defaultValue:@[] owningPage:@"resource" migrationRule:@"上限300"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyResourceSelectAllScope type:SevenZZPreferenceTypeInteger defaultValue:@(1) owningPage:@"settings" migrationRule:@"非法值回退全部结果"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyResourceDownloadDestination type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"settings" migrationRule:@"非法值回退下载文件夹"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMainPaneRatio type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"settings" migrationRule:@"非法值回退 3:7"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyLastMood type:SevenZZPreferenceTypeDouble defaultValue:@(0) owningPage:@"mood" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyLastMoodLabel type:SevenZZPreferenceTypeString defaultValue:@"" owningPage:@"mood" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyRecentMoodQuoteIDs type:SevenZZPreferenceTypeArray defaultValue:@[] owningPage:@"mood" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMoodHistoryRecords type:SevenZZPreferenceTypeArray defaultValue:@[] owningPage:@"mood" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMoodHistoryDeletedSnapshot type:SevenZZPreferenceTypeArray defaultValue:@[] owningPage:@"mood" migrationRule:@"用于恢复"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMoodHistoryDeletedSnapshotDate type:SevenZZPreferenceTypeString defaultValue:nil owningPage:@"mood" migrationRule:@"保留"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeySchemaVersion type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"system" migrationRule:@"当前schema版本"]];
    return specs;
}

@end
