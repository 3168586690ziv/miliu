//
//  PreferencesStore.m — 模块 07
//
#import "PreferencesStore.h"

NSString *const SevenZZKeyPerformanceMode                = @"PerformanceMode";
NSString *const SevenZZKeyCompletedResourceURLs          = @"CompletedResourceURLs";
NSString *const SevenZZKeyResourceDownloadDestination    = @"ZZResourceDownload.Destination";
NSString *const SevenZZKeyResourceDownloadCustomDirectory = @"ZZResourceDownload.CustomDirectory";
NSString *const SevenZZKeyMainPaneRatio              = @"ZZResourceDetector.MainPaneRatio";
NSString *const SevenZZKeyProbeMode                  = @"ZZResourceDetector.ProbeMode";
NSString *const SevenZZKeySitePages                  = @"ZZResourceDetector.SitePages";
NSString *const SevenZZKeyDisplayMetadataHistory         = @"DisplayMetadataHistory";
NSString *const SevenZZKeyRefererMode                    = @"ZZResourceDetector.RefererMode";

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
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyCompletedResourceURLs type:SevenZZPreferenceTypeArray defaultValue:@[] owningPage:@"resource" migrationRule:@"上限300"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyResourceDownloadDestination type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"settings" migrationRule:@"非法值回退下载文件夹"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyMainPaneRatio type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"settings" migrationRule:@"非法值回退 3:7"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyProbeMode type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"settings" migrationRule:@"非法值回退当前页"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeySitePages type:SevenZZPreferenceTypeInteger defaultValue:@(3) owningPage:@"settings" migrationRule:@"非法值回退 3"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyDisplayMetadataHistory type:SevenZZPreferenceTypeDictionary defaultValue:nil owningPage:@"media" migrationRule:@"保留；按来源页存标题/封面"]];
    [specs addObject:[SevenZZPreferenceKeySpec specWithKey:SevenZZKeyRefererMode type:SevenZZPreferenceTypeInteger defaultValue:@(0) owningPage:@"settings" migrationRule:@"非法值回退仅 origin"]];
    return specs;
}

// 键规范自检（2026-10-26 新增，把 allKeySpecs 从「零调用死方法」接成真消费者）：
// 历史问题——`allKeySpecs` 声明为「用于审计与迁移」却**全项目零调用**，导致规格表
// 与实际键长期脱节：实测曾有 26 个键（MarketCache* / Delta* / Mood* / AppTheme 等
// Seven zz 时代遗留）只存在于规格表、零消费者，仍被当作在用偏好维护下去。
// 本方法让规格表变成可断言的对象：返回两个方向的偏差——
//   · 「登记但无消费者」：规格表里有、传进来的在用键集合里没有；
//   · 「在用但未登记」：真实在用、规格表漏登。
// 测试用生产键集合调用它，任一方向非空即判回归。
+ (NSArray<NSString *> *)specAuditAgainstLiveKeys:(NSSet<NSString *> *)liveKeys {
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    NSMutableSet<NSString *> *declared = [NSMutableSet set];
    for (SevenZZPreferenceKeySpec *spec in [self allKeySpecs]) {
        [declared addObject:spec.key];
        if (![liveKeys containsObject:spec.key]) {
            [issues addObject:[NSString stringWithFormat:@"登记但无消费者：%@", spec.key]];
        }
    }
    for (NSString *key in liveKeys) {
        if (![declared containsObject:key]) {
            [issues addObject:[NSString stringWithFormat:@"在用但未登记：%@", key]];
        }
    }
    return issues;
}

@end
