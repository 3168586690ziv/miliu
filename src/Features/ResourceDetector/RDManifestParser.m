#import "RDManifestParser.h"
#import <math.h>

// A tree preserves BaseURL inheritance even when it follows a Representation.
@interface RDMPDReader : NSObject <NSXMLParserDelegate>
@property NSMutableArray *variants;
@property NSMutableArray *stack;
@property NSMutableDictionary *root;
@property NSURL *documentURL;
@end
@implementation RDMPDReader
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary *)attrs {
    NSMutableDictionary *node = [@{@"name":element,@"attrs":attrs,@"children":[NSMutableArray array],@"text":[NSMutableString string]} mutableCopy];
    if (self.stack.count) [self.stack.lastObject[@"children"] addObject:node];
    else if ([element isEqual:@"MPD"]) self.root = node;
    [self.stack addObject:node];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)text { [self.stack.lastObject[@"text"] appendString:text]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified { if (self.stack.count) [self.stack removeLastObject]; }
- (void)collect:(NSDictionary *)node attributes:(NSDictionary *)attrs base:(NSURL *)base hasBase:(BOOL)hasBase template:(NSMutableDictionary *)template {
    NSMutableDictionary *inherited = [attrs mutableCopy] ?: [NSMutableDictionary dictionary];
    [inherited addEntriesFromDictionary:node[@"attrs"]];
    for (NSDictionary *child in node[@"children"]) if ([child[@"name"] isEqual:@"BaseURL"]) {
        NSString *text = [child[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length) { base = [NSURL URLWithString:text relativeToURL:base].absoluteURL; hasBase = YES; break; }
    }
    // SegmentTemplate 沿 MPD→Period→AdaptationSet→Representation 继承，子级属性覆盖父级；
    // SegmentTimeline 的 S 条目作为 timeline 数组一并记录。表示级最终得到
    // segmentTemplate（模板属性）+ segmentBase（生效基址：显式 BaseURL 链，
    // 否则为 MPD 请求 URL）——与 RDStreamPlan.DASHTracks 的解析语义保持一致，
    // 使元数据探测与下载计划使用同一套分片基址。
    NSMutableDictionary *tpl = [template mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSDictionary *child in node[@"children"]) if ([child[@"name"] isEqual:@"SegmentTemplate"]) {
        NSMutableDictionary *merged = [tpl mutableCopy];
        [merged addEntriesFromDictionary:child[@"attrs"] ?: @{}];
        for (NSDictionary *tl in child[@"children"]) if ([tl[@"name"] isEqual:@"SegmentTimeline"]) {
            NSMutableArray *entries = [NSMutableArray array];
            for (NSDictionary *s in tl[@"children"]) if ([s[@"name"] isEqual:@"S"]) [entries addObject:s[@"attrs"] ?: @{}];
            merged[@"timeline"] = entries;
        }
        tpl = merged;
    }
    if ([node[@"name"] isEqual:@"Representation"]) {
        if (hasBase && [@[@"http",@"https"] containsObject:base.scheme.lowercaseString]) inherited[@"url"] = base.absoluteString;
        if (tpl.count) {
            inherited[@"segmentTemplate"] = tpl;
            inherited[@"segmentBase"] = base.absoluteString ?: @"";
        }
        [self.variants addObject:inherited];
    }
    for (NSDictionary *child in node[@"children"]) if (![@[@"BaseURL",@"SegmentTemplate",@"SegmentList",@"SegmentBase"] containsObject:child[@"name"]]) [self collect:child attributes:inherited base:base hasBase:hasBase template:tpl];
}
@end

static NSMutableDictionary *RDHLSAttributes(NSString *text) {
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    NSScanner *scanner = [NSScanner scannerWithString:text]; scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        [scanner scanCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@", \t"] intoString:nil];
        NSString *key = nil, *value = nil;
        if (![scanner scanUpToString:@"=" intoString:&key] || ![scanner scanString:@"=" intoString:nil]) break;
        if ([scanner scanString:@"\"" intoString:nil]) { [scanner scanUpToString:@"\"" intoString:&value]; if (![scanner scanString:@"\"" intoString:nil]) break; }
        else [scanner scanUpToString:@"," intoString:&value];
        key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        if (key.length) attrs[key] = value ?: @"";
    }
    return attrs;
}

@implementation RDManifestParser

+ (NSString *)absolute:(NSString *)raw base:(NSURL *)base {
    if (!raw.length) return @"";
    NSURL *u = base ? [NSURL URLWithString:raw relativeToURL:base] : [NSURL URLWithString:raw];
    NSString *s = u.absoluteURL.absoluteString ?: @"";
    NSString *scheme = u.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ? s : @"";
}

+ (NSDictionary *)parseManifest:(NSString *)text baseURL:(NSURL *)baseURL {
    return [self parseManifest:text baseURL:baseURL error:nil];
}

+ (NSUInteger)maxManifestBytes { return 2 * 1024 * 1024; }

+ (NSDictionary *)parseManifest:(NSString *)text baseURL:(NSURL *)baseURL error:(NSString **)error {
    if (error) *error = nil;
    if (![text isKindOfClass:NSString.class] || text.length == 0) {
        if (error) *error = @"清单为空";
        return @{};
    }
    if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > [self maxManifestBytes]) {
        if (error) *error = @"清单超过 2MB 上限";
        return @{};
    }
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL isHLS = [trim containsString:@"#EXTM3U"];
    BOOL isDASH = [trim rangeOfString:@"<MPD" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!isHLS && !isDASH) {
        if (error) *error = @"无法识别 HLS/DASH 清单";
        return @{};
    }
    NSMutableDictionary *out = [@{ @"kind": isHLS ? @"hls" : @"dash", @"isValid": @YES,
                                   @"variants": @[], @"audioTracks": @[], @"subtitleTracks": @[],
                                   @"isLive": @NO, @"isEncrypted": @NO } mutableCopy];
    NSMutableArray *variants = [NSMutableArray array], *audio = [NSMutableArray array], *subs = [NSMutableArray array];
    if (isHLS) {
        NSArray *lines = [trim componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSDictionary *pending = nil;
        for (NSString *line0 in lines) {
            NSString *line = [line0 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
                NSString *attrs = [line substringFromIndex:18];
                NSMutableDictionary *v = RDHLSAttributes(attrs);
                pending = v;
            } else if (pending && line.length && ![line hasPrefix:@"#"]) {
                NSMutableDictionary *v = [pending mutableCopy];
                NSString *resolved = [self absolute:line base:baseURL];
                if (resolved.length) { v[@"url"] = resolved; [variants addObject:v]; }
                pending = nil;
            } else if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
                NSString *attrs = [line substringFromIndex:13];
                NSMutableDictionary *v = RDHLSAttributes(attrs);
                NSString *type = v[@"type"];
                NSString *uri = [self absolute:v[@"uri"] base:baseURL];
                if (uri.length) v[@"url"] = uri;
                if ([type.lowercaseString isEqualToString:@"audio"]) [audio addObject:v];
                if ([type.lowercaseString isEqualToString:@"subtitles"]) [subs addObject:v];
            } else if ([line hasPrefix:@"#EXT-X-ENDLIST"]) out[@"isLive"] = @NO;
            else if ([line hasPrefix:@"#EXT-X-KEY:"] || [line hasPrefix:@"#EXT-X-SESSION-KEY:"]) out[@"isEncrypted"] = @YES;
        }
        BOOL master = [trim containsString:@"#EXT-X-STREAM-INF:"];
        out[@"isMaster"] = @(master);
        out[@"isLive"] = @(!master && ![trim containsString:@"#EXT-X-ENDLIST"]);
        double total = 0; NSUInteger count = 0; BOOL validDurations = YES;
        for (NSString *raw in lines) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (![line hasPrefix:@"#EXTINF:"]) continue;
            NSString *number = [[[line substringFromIndex:8] componentsSeparatedByString:@","] firstObject];
            NSScanner *scanner = [NSScanner scannerWithString:number]; double seconds = 0;
            if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !isfinite(seconds) || seconds < 0 || !isfinite(total + seconds)) validDurations = NO;
            else total += seconds;
            count++;
        }
        if (!master && ![out[@"isLive"] boolValue] && count && validDurations) out[@"durationSeconds"] = @(total);
        // media playlist 的分片 URL 只作为结构化附属信息记录，不加入独立下载结果。
        NSMutableArray *segments = [NSMutableArray array];
        NSString *pendingURI = nil;
        for (NSString *line0 in [trim componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [line0 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([line hasPrefix:@"#EXTINF:"]) continue;
            if (line.length && ![line hasPrefix:@"#"]) {
                NSString *resolved = [self absolute:line base:baseURL];
                if (resolved.length && segments.count < 2000) [segments addObject:resolved];
            }
        }
        out[@"segments"] = master ? @[] : segments;
    } else if (isDASH) {
        RDMPDReader *reader = [RDMPDReader new]; reader.variants = [NSMutableArray array]; reader.stack = [NSMutableArray array];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:[trim dataUsingEncoding:NSUTF8StringEncoding]];
        parser.shouldResolveExternalEntities = NO; parser.delegate = reader;
        if (![parser parse] || !reader.root) { if (error) *error = @"无效 MPD XML"; return @{}; }
        [reader collect:reader.root attributes:@{} base:baseURL hasBase:NO template:nil];
        variants = reader.variants;
        NSDictionary *rootAttributes = reader.root[@"attrs"];
        out[@"isLive"] = @([rootAttributes[@"type"] isEqual:@"dynamic"]);
        NSString *iso = rootAttributes[@"mediaPresentationDuration"] ?: @"";
        NSRegularExpression *durationRE = [NSRegularExpression regularExpressionWithPattern:@"^P(?:([0-9]+(?:[.][0-9]+)?)D)?(?:T(?:([0-9]+(?:[.][0-9]+)?)H)?(?:([0-9]+(?:[.][0-9]+)?)M)?(?:([0-9]+(?:[.][0-9]+)?)S)?)?$" options:0 error:nil];
        NSTextCheckingResult *durationMatch = [durationRE firstMatchInString:iso options:0 range:NSMakeRange(0,iso.length)];
        if (durationMatch) {
            double seconds = 0; BOOL hasValue = NO; double factors[] = {86400,3600,60,1};
            for (NSUInteger i=1;i<=4;i++) if ([durationMatch rangeAtIndex:i].location != NSNotFound) { seconds += [[iso substringWithRange:[durationMatch rangeAtIndex:i]] doubleValue]*factors[i-1]; hasValue = YES; }
            if (hasValue && isfinite(seconds) && ![out[@"isLive"] boolValue]) out[@"durationSeconds"] = @(seconds);
        }
        out[@"segments"] = @[];
        out[@"isEncrypted"] = @([trim rangeOfString:@"ContentProtection" options:NSCaseInsensitiveSearch].location != NSNotFound);
        // 多 Representation 的 MPD 就是 master：不置位 isMaster，档位列表永远
        // 不会发布给快照/UI（与 HLS master 的 #EXT-X-STREAM-INF 语义对齐）。
        out[@"isMaster"] = @(variants.count > 0);
    }
    out[@"variants"] = variants; out[@"audioTracks"] = audio; out[@"subtitleTracks"] = subs;
    return out;
}

@end
