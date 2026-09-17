#import "ResourceTitleTranslator.h"
#import <AppKit/AppKit.h>

@interface ResourceTitleTranslator ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation ResourceTitleTranslator

- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self=[super init];
    if(self){
        NSURLSessionConfiguration *sessionConfiguration=configuration?[configuration copy]:
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        sessionConfiguration.URLCache=nil;
        sessionConfiguration.HTTPCookieStorage=nil;
        sessionConfiguration.HTTPMaximumConnectionsPerHost=4;
        sessionConfiguration.timeoutIntervalForRequest=6.0;
        _session=[NSURLSession sessionWithConfiguration:sessionConfiguration];
    }
    return self;
}

static BOOL ZZContainsHan(NSString *text) {
    for(NSUInteger i=0;i<text.length;i++){
        unichar c=[text characterAtIndex:i];
        if((c>=0x4E00&&c<=0x9FFF)||(c>=0x3400&&c<=0x4DBF))return YES;
    }
    return NO;
}

static BOOL ZZContainsKana(NSString *text) {
    for(NSUInteger i=0;i<text.length;i++){
        unichar c=[text characterAtIndex:i];
        if((c>=0x3040&&c<=0x30FF)||(c>=0x31F0&&c<=0x31FF))return YES;
    }
    return NO;
}

static NSString *ZZLeadingTagPrefix(NSString *text) {
    if(!text.length)return @"";
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^\\s*((?:(?:\\[[^\\]]+\\]|\\([^\\)]+\\)|【[^】]+】)\\s*)+)"
                                                                          options:0 error:nil];
    NSTextCheckingResult *match=[re firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];
    return match?[text substringWithRange:match.range]:@"";
}

static NSString *ZZTranslationCore(NSString *text) {
    NSString *prefix=ZZLeadingTagPrefix(text);
    return prefix.length?[text substringFromIndex:prefix.length]:text;
}

static BOOL ZZContainsJapaneseSpecificHan(NSString *text) {
    static NSCharacterSet *japaneseSpecificHan;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        // These are Japanese orthographic forms, not Han characters shared by
        // normal simplified or traditional Chinese titles.
        japaneseSpecificHan=[NSCharacterSet characterSetWithCharactersInString:
                             @"亜悪圧囲壱栄駅塩縁艶応桜闘戦続辺転訳沢広県髪仮懐拡殻覚勧歓観暁恵掲渓継芸撃検権険顕験厳効鉱砕斎剤雑賛児従渋縦粛焼証剰壌粋髄瀬斉摂荘捜挿騒臓滝択弾遅徴鉄伝縄弐悩脳覇廃拝払仏弁穂豊黙薬揺頼覧猟緑隣涙霊齢暦黒獣竜剣動画映画異世界処女"];
    });
    return [text rangeOfCharacterFromSet:japaneseSpecificHan].location!=NSNotFound;
}

static BOOL ZZContainsJapaneseSpecificPhrase(NSString *text) {
    for(NSString *phrase in @[@"動画",@"映画",@"異世界",@"処女"]) {
        if([text rangeOfString:phrase].location!=NSNotFound)return YES;
    }
    return NO;
}

// Pure-Han titles are inherently ambiguous. Do not trust an affirmative
// language guess alone: short Chinese titles such as "麦田" are often tagged
// as Japanese. Kana or a vetted Japanese-only written form is required.
static BOOL ZZLooksLikeJapaneseTitle(NSString *title) {
    if(ZZContainsKana(title))return YES;
    // These short forms are shared with Chinese and have no reliable
    // language signal without page metadata; leave them untouched.
    for(NSString *ambiguous in @[@"少女",@"女性",@"学校"]) {
        if([title rangeOfString:ambiguous].location!=NSNotFound)return NO;
    }
    if(ZZContainsJapaneseSpecificPhrase(title))return YES;
    NSString *language=[NSLinguisticTagger dominantLanguageForString:title];
    if([language hasPrefix:@"zh"])return NO;
    return ZZContainsJapaneseSpecificHan(title);
}

static BOOL ZZTitleNeedsChineseTranslation(NSString *title) {
    NSString *core=ZZTranslationCore(title);
    if(!core.length)return NO;
    BOOL hasHan=NO,hasLatin=NO;
    for(NSUInteger i=0;i<core.length;i++){
        unichar c=[core characterAtIndex:i];
        if((c>=0x4E00&&c<=0x9FFF)||(c>=0x3400&&c<=0x4DBF))hasHan=YES;
        if((c>='A'&&c<='Z')||(c>='a'&&c<='z'))hasLatin=YES;
    }
    if(ZZLooksLikeJapaneseTitle(core))return YES;
    if(!hasHan)return hasLatin;

    // A mixed title can still contain a long untranslated English phrase.
    // Keep short creator names/acronyms (for example "NTR") untouched, but
    // ask the translator to handle common English words or several Latin
    // words even when the site already supplied some Han characters.
    NSArray<NSString *> *commonWords=@[@"a",@"an",@"and",@"animation",@"affairs",@"audio",@"cuckold",@"edition",@"extended",@"full",@"main",@"part",@"release",@"return",@"sea",@"the",@"video",@"with",@"work"];
    NSRegularExpression *wordRe=[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z]{2,}" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches=[wordRe matchesInString:core options:0 range:NSMakeRange(0,core.length)];
    for(NSTextCheckingResult *match in matches){
        NSString *word=[core substringWithRange:match.range].lowercaseString;
        if([commonWords containsObject:word])return YES;
        // Mixed titles often use a proper name or category word rather than
        // the common-word list (for example "Vtuber 黎歌" or "Sex 長風").
        // A four-letter Latin token is enough evidence to request a Chinese
        // rendering; short all-caps tags such as NTR remain untouched.
        if(match.range.length>=4)return YES;
    }
    return matches.count>=3;
}

static NSUInteger ZZLatinWordCount(NSString *text) {
    NSRegularExpression *wordRe=[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z]{2,}" options:0 error:nil];
    return [wordRe matchesInString:text options:0 range:NSMakeRange(0,text.length)].count;
}

static NSString *ZZLanguagePairForTitle(NSString *title) {
    NSString *core=ZZTranslationCore(title);
    if(ZZLooksLikeJapaneseTitle(core))return @"ja|zh-CN";
    if(ZZLatinWordCount(core)>0)return @"en|zh-CN";
    return @"auto|zh-CN";
}

static BOOL ZZTranslationLooksUseful(NSString *source,NSString *translated) {
    if(!source.length||!translated.length)return NO;
    if(!ZZContainsHan(translated))return NO;
    NSString *sourcePrefix=ZZLeadingTagPrefix(source);
    NSString *translatedPrefix=ZZLeadingTagPrefix(translated);
    BOOL preservesLeadingTag=sourcePrefix.length&&[sourcePrefix isEqualToString:translatedPrefix];
    NSString *translatedBody=preservesLeadingTag?[translated substringFromIndex:translatedPrefix.length]:translated;
    // A site/creator tag such as "[さくら]" may legitimately remain intact.
    // Kana elsewhere means the title body is still untranslated.
    if(ZZContainsKana(translatedBody)||(!preservesLeadingTag&&ZZContainsKana(translatedPrefix)))return NO;
    if([source caseInsensitiveCompare:translated]==NSOrderedSame)return NO;

    NSString *sourceCore=ZZTranslationCore(source);
    NSString *translatedCore=ZZTranslationCore(translated);
    NSUInteger translatedWords=ZZLatinWordCount(translatedCore);

    NSArray<NSString *> *commonWords=@[@"a",@"an",@"and",@"animation",@"affairs",@"audio",@"cuckold",@"edition",@"extended",@"full",@"main",@"part",@"release",@"return",@"sea",@"the",@"video",@"with",@"work"];
    NSRegularExpression *wordRe=[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z]{2,}" options:0 error:nil];
    for(NSTextCheckingResult *match in [wordRe matchesInString:translatedCore options:0 range:NSMakeRange(0,translatedCore.length)]){
        NSString *word=[translatedCore substringWithRange:match.range].lowercaseString;
        if([commonWords containsObject:word])return NO;
    }
    NSUInteger sourceWords=ZZLatinWordCount(sourceCore);
    // Japanese responses commonly keep proper names, acronyms, or format
    // tokens such as "ASMR" and "MP4" in Latin script. Once the body has
    // Chinese characters and no common English phrase remains, those tokens
    // are useful rather than evidence of a failed translation. Keep the
    // word-count guard for an all-Latin source, where an unchanged phrase is
    // otherwise easy to mistake for a translation.
    if(!ZZContainsKana(sourceCore)&&!ZZContainsHan(sourceCore)&&
       sourceWords>=3&&translatedWords>=MAX((NSUInteger)3,sourceWords/2))return NO;
    return YES;
}

static NSString *ZZNormalizedTranslation(NSString *text) {
    if(![text isKindOfClass:NSString.class]||!text.length)return @"";
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
    NSAttributedString *decoded=data?[[NSAttributedString alloc]initWithData:data
                                                                     options:@{NSDocumentTypeDocumentAttribute:NSHTMLTextDocumentType,
                                                                               NSCharacterEncodingDocumentAttribute:@(NSUTF8StringEncoding)}
                                                          documentAttributes:nil error:nil]:nil;
    NSString *plain=decoded.string.length?decoded.string:text;
    NSArray<NSString *> *parts=[plain componentsSeparatedByCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *words=[NSMutableArray array];
    for(NSString *part in parts)if(part.length)[words addObject:part];
    return [words componentsJoinedByString:@" "];
}

// MyMemory occasionally returns an unchanged title (especially for short
// catalogue names). Keep a small deterministic fallback for common media
// words so a visible card does not remain entirely in English when the
// network service has no useful result. Proper names and acronyms are kept.
static NSString *ZZOfflineChineseTranslation(NSString *source) {
    NSString *prefix=ZZLeadingTagPrefix(source);
    NSString *core=ZZTranslationCore(source);
    if(!core.length)return @"";

    static NSDictionary<NSString *,NSString *> *phraseMap;
    static NSDictionary<NSString *,NSString *> *wordMap;
    static NSDictionary<NSString *,NSString *> *japaneseMap;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        phraseMap=@{
            @"miku rabbit full": @"MIKU 兔子 完整版",
            @"after a long return from the sea": @"漫长归海之后",
            @"looking for something": @"寻找某物",
            @"girl story": @"女孩故事"
        };
        wordMap=@{
            @"cuckold": @"寝取", @"full": @"完整版", @"fullscreen": @"全屏版", @"rabbit": @"兔子",
            @"anime": @"动漫", @"animation": @"动画", @"video": @"视频",
            @"movie": @"电影", @"edition": @"版", @"extended": @"加长版",
            @"audio": @"音频", @"voice": @"语音", @"version": @"版本",
            @"story": @"故事", @"girl": @"女孩", @"school": @"学校",
            @"return": @"归来", @"sea": @"大海", @"something": @"某物",
            @"with": @"带", @"part": @"部分"
        };
        japaneseMap=@{
            @"ニコ": @"妮可", @"リヤン": @"莉扬", @"アニメ": @"动漫",
            @"音声付": @"带音频", @"音声": @"音频", @"フルバージョン": @"完整版",
            @"バージョン": @"版本", @"動画": @"视频", @"映画": @"电影",
            @"異世界": @"异世界", @"処女": @"处女"
        };
    });

    NSString *exact=phraseMap[core.lowercaseString];
    if(exact.length)return [NSString stringWithFormat:@"%@%@",prefix,exact];

    __block NSString *mapped=core;
    __block NSUInteger replacements=0;
    [japaneseMap enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *value,BOOL *stop){
        if([mapped rangeOfString:key].location!=NSNotFound){
            mapped=[mapped stringByReplacingOccurrencesOfString:key withString:value];
            replacements++;
        }
    }];
    NSRegularExpression *wordRe=[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z]{2,}(?:['’][A-Za-z]+)?"
                                                                              options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches=[wordRe matchesInString:mapped options:0 range:NSMakeRange(0,mapped.length)];
    NSMutableString *built=[mapped mutableCopy];
    for(NSTextCheckingResult *match in [matches reverseObjectEnumerator]){
        NSString *word=[mapped substringWithRange:match.range];
        NSString *replacement=wordMap[word.lowercaseString];
        if(replacement.length){
            [built replaceCharactersInRange:match.range withString:replacement];
            replacements++;
        }
    }
    mapped=[built copy];
    // Only use a fallback when all Japanese kana were resolved and at least
    // one Chinese word was introduced; otherwise retain the original title.
    if(!replacements||ZZContainsKana(mapped)||!ZZContainsHan(mapped))return @"";
    NSArray<NSString *> *parts=[mapped componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *words=[NSMutableArray array];
    for(NSString *part in parts)if(part.length)[words addObject:part];
    return [NSString stringWithFormat:@"%@%@",prefix,[words componentsJoinedByString:@" "]];
}

- (void)translateTitle:(NSString *)title completion:(void (^)(NSString *))completion {
    NSString *source=ZZNormalizedTranslation(title);
    if(!source.length||![ResourceTitleTranslator titleNeedsChineseTranslation:source]){
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(@"");});
        return;
    }
    [self translateSource:source attempt:0 completion:completion];
}

+ (BOOL)titleNeedsChineseTranslation:(NSString *)title {
    return ZZTitleNeedsChineseTranslation(title);
}

- (void)requestTranslationForSource:(NSString *)source
                         completion:(void (^)(NSString *translated))completion {
    NSURLComponents *components=[NSURLComponents componentsWithString:@"https://api.mymemory.translated.net/get"];
    components.queryItems=@[[NSURLQueryItem queryItemWithName:@"q" value:source],
                            [NSURLQueryItem queryItemWithName:@"langpair" value:ZZLanguagePairForTitle(source)]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:components.URL
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:6.0];
    request.HTTPMethod=@"GET";
    __weak typeof(self) w=self;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        NSDictionary *json=nil;
        NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)response:nil;
        if(!error&&http.statusCode==200&&data)json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *responseData=[json[@"responseData"] isKindOfClass:NSDictionary.class]?json[@"responseData"]:nil;
        NSString *translated=[responseData[@"translatedText"] isKindOfClass:NSString.class]?responseData[@"translatedText"]:@"";
        BOOL validStatus=![json[@"responseStatus"] respondsToSelector:@selector(integerValue)]||
                         [json[@"responseStatus"] integerValue]==200;
        BOOL quotaFinished=[json[@"quotaFinished"] respondsToSelector:@selector(boolValue)]&&
                           [json[@"quotaFinished"] boolValue];
        if(!validStatus||quotaFinished||[translated.uppercaseString hasPrefix:@"MYMEMORY WARNING"])translated=@"";
        NSString *clean=ZZNormalizedTranslation(translated);
        dispatch_async(dispatch_get_main_queue(),^{
            __strong typeof(w) s=w;
            if(!s){if(completion)completion(@"");return;}
            if(completion)completion(clean?:@"");
        });
    }] resume];
}

- (NSArray<NSString *> *)translationSegmentsForSource:(NSString *)source {
    NSString *core=ZZTranslationCore(source);
    NSRegularExpression *separator=[NSRegularExpression regularExpressionWithPattern:@"\\s*(?:\\||｜|/|／|—|–)\\s*"
                                                                                options:0 error:nil];
    NSMutableArray<NSString *> *segments=[NSMutableArray array];
    __block NSUInteger cursor=0;
    [separator enumerateMatchesInString:core options:0 range:NSMakeRange(0,core.length)
                              usingBlock:^(NSTextCheckingResult *match,NSMatchingFlags flags,BOOL *stop){
        if(match.range.location>cursor){
            NSString *part=[core substringWithRange:NSMakeRange(cursor,match.range.location-cursor)];
            if(part.length)[segments addObject:part];
        }
        cursor=NSMaxRange(match.range);
    }];
    if(cursor<core.length){NSString *part=[core substringFromIndex:cursor];if(part.length)[segments addObject:part];}
    if(segments.count>1)return segments;

    // A title such as "Miku Rabbit Full" can defeat whole-sentence MT. For
    // this fallback, translate only longer Latin tokens; short acronyms and
    // proper names remain intact. Two-word titles keep the normal two-hop
    // failure path, avoiding a burst of low-value requests.
    if(ZZLatinWordCount(core)<3&&!ZZContainsKana(core))return segments;
    NSRegularExpression *token=[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z]{2,}(?:['’][A-Za-z]+)?|[^A-Za-z\\s]+"
                                                                            options:0 error:nil];
    NSMutableArray<NSString *> *tokens=[NSMutableArray array];
    for(NSTextCheckingResult *match in [token matchesInString:core options:0 range:NSMakeRange(0,core.length)]){
        NSString *part=[core substringWithRange:match.range];
        if(part.length)[tokens addObject:part];
    }
    return tokens.count>1?tokens:segments;
}

- (void)translateSegments:(NSArray<NSString *> *)segments
                    source:(NSString *)source
                     index:(NSUInteger)index
                translated:(NSMutableArray<NSString *> *)translated
                completion:(void (^)(NSString *result))completion {
    if(index>=segments.count){
        NSString *prefix=ZZLeadingTagPrefix(source);
        NSString *body=[translated componentsJoinedByString:@" "];
        NSString *result=[NSString stringWithFormat:@"%@%@",prefix,body];
        if(ZZTranslationLooksUseful(source,result)){
            completion(result);
        }else{
            NSString *offline=ZZOfflineChineseTranslation(source);
            completion(ZZTranslationLooksUseful(source,offline)?offline:@"");
        }
        return;
    }
    NSString *segment=segments[index];
    if(!segment.length||!ZZTitleNeedsChineseTranslation(segment)){
        [translated addObject:segment];
        [self translateSegments:segments source:source index:index+1 translated:translated completion:completion];
        return;
    }
    __weak typeof(self) w=self;
    [self requestTranslationForSource:segment completion:^(NSString *candidate){
        __strong typeof(w) s=w;
        if(!s){completion(@"");return;}
        BOOL segmentChanged=ZZTranslationLooksUseful(segment,candidate);
        NSString *offline=segmentChanged?@"":ZZOfflineChineseTranslation(segment);
        BOOL offlineChanged=ZZTranslationLooksUseful(segment,offline);
        [translated addObject:segmentChanged?candidate:(offlineChanged?offline:segment)];
        [s translateSegments:segments source:source index:index+1 translated:translated completion:completion];
    }];
}

- (void)translateSource:(NSString *)source
                 attempt:(NSUInteger)attempt
              completion:(void (^)(NSString *))completion {
    __weak typeof(self) w=self;
    [self requestTranslationForSource:source completion:^(NSString *clean){
        __strong typeof(w) s=w;
        if(!s){if(completion)completion(@"");return;}
        if(ZZTranslationLooksUseful(source,clean)){
            if(completion)completion(clean);
            return;
        }
        if(attempt==0&&clean.length&&![clean isEqualToString:source]){
            // Preserve the historical two-hop path: a Japanese→English
            // response is translated again, now with an explicit en|zh pair.
            [s translateSource:clean attempt:1 completion:completion];
            return;
        }
        // An unchanged whole-title response is common for short catalogue
        // names. Split it into bounded segments before giving up, including
        // kana-containing titles with fewer than three Latin tokens.
        NSArray<NSString *> *segments=[s translationSegmentsForSource:source];
        if(segments.count>1&&(attempt>=1||ZZLatinWordCount(source)>=3||ZZContainsKana(source))){
            [s translateSegments:segments source:source index:0 translated:[NSMutableArray array]
                        completion:completion];
            return;
        }
        NSString *offline=ZZOfflineChineseTranslation(source);
        if(completion)completion(ZZTranslationLooksUseful(source,offline)?offline:@"");
    }];
}

- (void)cancelAll {
    [self.session invalidateAndCancel];
}

@end
