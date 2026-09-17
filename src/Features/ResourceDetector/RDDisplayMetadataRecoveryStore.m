//
//  RDDisplayMetadataRecoveryStore.m
//  7zz
//

#import "RDDisplayMetadataRecoveryStore.h"

static NSString * const kPageMetadataKey = @"pageMetadata";
static NSString * const kTitleKey = @"title";
static NSString * const kPosterKey = @"poster";
static NSString * const kConfidenceKey = @"confidence";

@implementation RDDisplayMetadataRecoveryStore {
    NSMutableDictionary<NSString *, RDResourceDisplayMetadata *> *_metadataBySourcePage;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _metadataBySourcePage = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (NSString *)normalizedSourcePageURLString:(NSString *)sourcePageURL {
    if (!sourcePageURL.length) return @"";
    NSURL *url = [NSURL URLWithString:sourcePageURL];
    if (!url || !url.scheme.length || !url.host.length) return sourcePageURL;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return sourcePageURL;

    components.fragment = nil;
    components.host = components.host.lowercaseString;

    // 去掉末尾斜杠差异。
    NSString *path = components.path ?: @"";
    if (path.length > 1 && [path hasSuffix:@"/"]) {
        components.path = [path substringToIndex:path.length - 1];
    }

    NSString *normalized = components.string ?: sourcePageURL;
    return normalized;
}

- (void)recordMetadataForItems:(NSArray<NSDictionary *> *)items {
    if (!items.count) return;

    for (NSDictionary *item in items) {
        [self recordMetadataForItem:item];
        NSArray *variants = [item[@"variants"] isKindOfClass:NSArray.class] ? item[@"variants"] : @[];
        for (NSDictionary *variant in variants) {
            [self recordMetadataForItem:variant];
        }
    }
}

- (void)recordMetadataForItem:(NSDictionary *)item {
    NSString *source = [item[@"sourcePage"] isKindOfClass:NSString.class] ? item[@"sourcePage"] : @"";
    if (!source.length) return;

    NSString *sourceKey = [RDDisplayMetadataRecoveryStore normalizedSourcePageURLString:source];
    if (!sourceKey.length) return;

    NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
    NSString *poster = [item[@"poster"] isKindOfClass:NSString.class] ? item[@"poster"] : @"";

    // 标题如果是纯数字文件名，则忽略（例如 407460-sc-480p.mp4）。
    if (title.length) {
        RDResourceDisplayMetadata *probe = [RDResourceDisplayMetadata metadataWithTitle:title
                                                                        posterURLString:nil
                                                                    sourcePageURLString:nil
                                                                             confidence:RDDisplayMetadataConfidenceNone];
        if ([probe titleLooksLikeOpaqueFilename]) title = @"";
    }

    RDResourceDisplayMetadata *existing = _metadataBySourcePage[sourceKey];
    NSString *bestTitle = [self betterTitleBetween:existing.title candidate:title];
    NSString *bestPoster = [self betterPosterBetween:existing.posterURLString candidate:poster];

    RDDisplayMetadataConfidence confidence = existing.confidence;
    if (bestTitle.length && bestPoster.length) {
        confidence = MAX(confidence, RDDisplayMetadataConfidenceMedium);
    } else if (bestTitle.length || bestPoster.length) {
        confidence = MAX(confidence, RDDisplayMetadataConfidenceLow);
    }

    _metadataBySourcePage[sourceKey] = [RDResourceDisplayMetadata metadataWithTitle:bestTitle
                                                                    posterURLString:bestPoster
                                                                sourcePageURLString:sourceKey
                                                                         confidence:confidence];
}

- (NSString *)betterTitleBetween:(NSString *)existing candidate:(NSString *)candidate {
    if (!candidate.length) return existing ?: @"";
    if (!existing.length) return candidate;

    RDResourceDisplayMetadata *existingProbe = [RDResourceDisplayMetadata metadataWithTitle:existing
                                                                            posterURLString:nil
                                                                        sourcePageURLString:nil
                                                                                 confidence:RDDisplayMetadataConfidenceNone];
    RDResourceDisplayMetadata *candidateProbe = [RDResourceDisplayMetadata metadataWithTitle:candidate
                                                                               posterURLString:nil
                                                                           sourcePageURLString:nil
                                                                                    confidence:RDDisplayMetadataConfidenceNone];
    BOOL existingIsFilename = [existingProbe titleLooksLikeOpaqueFilename];
    BOOL candidateIsFilename = [candidateProbe titleLooksLikeOpaqueFilename];

    if (existingIsFilename && !candidateIsFilename) return candidate;
    if (!existingIsFilename && candidateIsFilename) return existing;

    NSString *cleanExisting = [existingProbe cleanedTitle];
    NSString *cleanCandidate = [candidateProbe cleanedTitle];
    return cleanCandidate.length >= cleanExisting.length ? candidate : existing;
}

- (NSString *)betterPosterBetween:(NSString *)existing candidate:(NSString *)candidate {
    if (!candidate.length) return existing ?: @"";
    if (!existing.length) return candidate;

    // 优先选择 /image/cover/ 这类列表作品封面；拒绝 /image/thumbnail/。
    BOOL existingIsWorkCover = [self urlStringIsUsableWorkCover:existing];
    BOOL candidateIsWorkCover = [self urlStringIsUsableWorkCover:candidate];
    if (existingIsWorkCover && !candidateIsWorkCover) return existing;
    if (!existingIsWorkCover && candidateIsWorkCover) return candidate;

    // 同等级时保留现有者（更可能是已验证的列表封面）。
    return existing;
}

- (BOOL)urlStringIsUsableWorkCover:(NSString *)poster {
    NSURL *url = [NSURL URLWithString:poster];
    NSString *path = url.path.lowercaseString ?: @"";
    if (!url.scheme.length || !url.host.length) return NO;
    return [path rangeOfString:@"/image/thumbnail/"].location == NSNotFound;
}

- (RDResourceDisplayMetadata *)metadataForSourcePageURL:(NSString *)sourcePageURL {
    if (!sourcePageURL.length) return nil;
    NSString *key = [RDDisplayMetadataRecoveryStore normalizedSourcePageURLString:sourcePageURL];
    return _metadataBySourcePage[key];
}

// 恢复链路专用写入：标题/封面相互独立，按规范化 sourcePage URL 合并落地。
// 封面允许“当前新请求来源页”提供的受限兜底（同作品 ID thumbnail）；历史
// 加载路径（loadFromHistoryDictionary）的严格 thumbnail 拒绝规则不受影响。
- (void)recordRecoveredMetadata:(RDResourceDisplayMetadata *)metadata
                forSourcePageURL:(NSString *)sourcePageURL {
    if(!metadata) return;
    if(!sourcePageURL.length) return;
    NSString *sourceKey=[RDDisplayMetadataRecoveryStore normalizedSourcePageURLString:sourcePageURL];
    if(!sourceKey.length) return;

    NSString *title=metadata.title ?: @"";
    if(title.length){
        RDResourceDisplayMetadata *probe=[RDResourceDisplayMetadata metadataWithTitle:title
                                                                      posterURLString:nil
                                                                  sourcePageURLString:nil
                                                                           confidence:RDDisplayMetadataConfidenceNone];
        // 数字文件名不是可见作品标题：不作为恢复结果落地。
        if([probe titleLooksLikeOpaqueFilename]) title=@"";
    }
    NSString *poster=metadata.posterURLString ?: @"";

    RDResourceDisplayMetadata *existing=_metadataBySourcePage[sourceKey];
    NSString *bestTitle=[self betterTitleBetween:existing.title candidate:title];
    NSString *bestPoster=[self betterPosterBetween:existing.posterURLString candidate:poster];

    RDDisplayMetadataConfidence confidence=existing.confidence;
    if(bestTitle.length && bestPoster.length){
        if(metadata.confidence>RDDisplayMetadataConfidenceNone)
            confidence=MAX(confidence, metadata.confidence);
        confidence=MAX(confidence, RDDisplayMetadataConfidenceMedium);
    } else if(bestTitle.length || bestPoster.length){
        confidence=MAX(confidence, RDDisplayMetadataConfidenceLow);
    }

    _metadataBySourcePage[sourceKey]=[RDResourceDisplayMetadata metadataWithTitle:bestTitle
                                                                  posterURLString:bestPoster
                                                              sourcePageURLString:sourceKey
                                                                       confidence:confidence];
}

- (NSString *)titleForSourcePageURL:(NSString *)sourcePageURL {
    RDResourceDisplayMetadata *m = [self metadataForSourcePageURL:sourcePageURL];
    NSString *title = m.title ?: @"";
    return [m cleanedTitle] ?: title;
}

- (NSString *)posterURLStringForSourcePageURL:(NSString *)sourcePageURL {
    RDResourceDisplayMetadata *m = [self metadataForSourcePageURL:sourcePageURL];
    NSString *poster = m.posterURLString ?: @"";
    if (!poster.length) return nil;
    // 作品封面直接放行；thumbnail 仅当图片路径作品 ID 与来源页 watch?v= 作品
    // ID 一致时才作为受限兜底返回（恢复链路写入的同作品预览图），否则拒绝。
    if ([self urlStringIsUsableWorkCover:poster]) return poster;
    if ([m posterURLProvesSameWorkForSourcePageURL:sourcePageURL]) return poster;
    return nil;
}

- (NSDictionary *)historyDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (NSString *key in _metadataBySourcePage) {
        RDResourceDisplayMetadata *m = _metadataBySourcePage[key];
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        if (m.title.length) entry[kTitleKey] = m.title;
        if (m.posterURLString.length) entry[kPosterKey] = m.posterURLString;
        if (m.confidence > RDDisplayMetadataConfidenceNone) entry[kConfidenceKey] = @(m.confidence);
        if (entry.count) dict[key] = [entry copy];
    }
    return [dict copy];
}

- (void)loadLegacyHistoryDictionary:(NSDictionary *)history {
    NSDictionary *titles = [history[@"titles"] isKindOfClass:NSDictionary.class] ? history[@"titles"] : @{};
    NSDictionary *sources = [history[@"sources"] isKindOfClass:NSDictionary.class] ? history[@"sources"] : @{};
    NSDictionary *posters = [history[@"posters"] isKindOfClass:NSDictionary.class] ? history[@"posters"] : @{};

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *urlsBySource = [NSMutableDictionary dictionary];
    for (NSString *mediaURL in sources) {
        NSString *sourcePage = [sources[mediaURL] isKindOfClass:NSString.class] ? sources[mediaURL] : @"";
        if (!sourcePage.length) continue;
        NSString *sourceKey = [RDDisplayMetadataRecoveryStore normalizedSourcePageURLString:sourcePage];
        if (!sourceKey.length) continue;
        NSMutableArray *list = urlsBySource[sourceKey];
        if (!list) { list = [NSMutableArray array]; urlsBySource[sourceKey] = list; }
        [list addObject:mediaURL];
    }

    for (NSString *sourceKey in urlsBySource) {
        NSString *bestTitle = @"";
        NSString *bestPoster = @"";
        for (NSString *mediaURL in urlsBySource[sourceKey]) {
            NSString *title = [titles[mediaURL] isKindOfClass:NSString.class] ? titles[mediaURL] : @"";
            NSString *poster = [posters[mediaURL] isKindOfClass:NSString.class] ? posters[mediaURL] : @"";
            bestTitle = [self betterTitleBetween:bestTitle candidate:title];
            bestPoster = [self betterPosterBetween:bestPoster candidate:poster];
        }
        if (!bestTitle.length && !bestPoster.length) continue;
        RDDisplayMetadataConfidence confidence = (bestTitle.length && bestPoster.length) ? RDDisplayMetadataConfidenceMedium : RDDisplayMetadataConfidenceLow;
        _metadataBySourcePage[sourceKey] = [RDResourceDisplayMetadata metadataWithTitle:bestTitle
                                                                      posterURLString:bestPoster
                                                                  sourcePageURLString:sourceKey
                                                                           confidence:confidence];
    }
}

- (void)loadFromHistoryDictionary:(NSDictionary *)dict {
    [_metadataBySourcePage removeAllObjects];
    if (![dict isKindOfClass:NSDictionary.class]) return;

    for (NSString *key in dict) {
        if (![key isKindOfClass:NSString.class]) continue;
        id raw = dict[key];
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry = (NSDictionary *)raw;
        NSString *title = [entry[kTitleKey] isKindOfClass:NSString.class] ? entry[kTitleKey] : @"";
        NSString *poster = [entry[kPosterKey] isKindOfClass:NSString.class] ? entry[kPosterKey] : @"";
        NSNumber *confidenceNum = [entry[kConfidenceKey] isKindOfClass:NSNumber.class] ? entry[kConfidenceKey] : nil;
        RDDisplayMetadataConfidence confidence = RDDisplayMetadataConfidenceNone;
        if (confidenceNum) confidence = (RDDisplayMetadataConfidence)MAX(RDDisplayMetadataConfidenceNone, MIN(RDDisplayMetadataConfidenceHigh, confidenceNum.integerValue));

        // 历史中的 thumbnail 不得无条件复用：仅当图片路径作品 ID 与来源页
        // watch?v= 作品 ID 一致（受限兜底）时才保留，否则拒绝并只留标题。
        if (poster.length && ![self urlStringIsUsableWorkCover:poster]) {
            RDResourceDisplayMetadata *entryProbe = [RDResourceDisplayMetadata metadataWithTitle:title
                                                                                 posterURLString:poster
                                                                             sourcePageURLString:key
                                                                                      confidence:RDDisplayMetadataConfidenceLow];
            if (![entryProbe posterURLProvesSameWorkForSourcePageURL:key]) {
                poster = @"";
                confidence = MIN(confidence, RDDisplayMetadataConfidenceLow);
            }
        }

        _metadataBySourcePage[key] = [RDResourceDisplayMetadata metadataWithTitle:title
                                                                  posterURLString:poster
                                                              sourcePageURLString:key
                                                                       confidence:confidence];
    }
}

@end
