#import "RDStaticScriptAnalyzer.h"
#import "RDURLUtilities.h"
#import "WebProbe.h"

static NSURL *RDNormalizeURL(NSURL *url) {
    if (!url) return nil;
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return url;
    NSString *path=c.path ?: @"";
    if (![path containsString:@"/../"] && ![path hasSuffix:@"/.."] && ![path containsString:@"/./"] && ![path hasSuffix:@"/."]) return url;
    NSMutableArray *parts=[NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqual:@"."]) continue;
        if ([part isEqual:@".."]) { if (parts.count) [parts removeLastObject]; continue; }
        [parts addObject:part];
    }
    c.path=[@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
    return c.URL ?: url;
}

// Skip whitespace and comments while looking at a small JavaScript expression.
// This is intentionally a tiny lexer, not an evaluator: it is only used for
// literal string concatenation and therefore cannot execute arbitrary script.
static NSUInteger RDSkipTrivia(NSString *source, NSUInteger pos) {
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (pos < source.length) {
        while (pos < source.length && [space characterIsMember:[source characterAtIndex:pos]]) pos++;
        if (pos + 1 < source.length && [source characterAtIndex:pos] == '/' && [source characterAtIndex:pos + 1] == '*') {
            NSRange end = [source rangeOfString:@"*/" options:0 range:NSMakeRange(pos + 2, source.length - pos - 2)];
            if (end.location == NSNotFound) return source.length;
            pos = NSMaxRange(end); continue;
        }
        if (pos + 1 < source.length && [source characterAtIndex:pos] == '/' && [source characterAtIndex:pos + 1] == '/') {
            NSRange end = [source rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet options:0 range:NSMakeRange(pos + 2, source.length - pos - 2)];
            pos = end.location == NSNotFound ? source.length : NSMaxRange(end); continue;
        }
        break;
    }
    return pos;
}

static void RDCollectJSONStrings(id value, NSMutableArray<NSString *> *out) {
    if ([value isKindOfClass:NSString.class]) { [out addObject:value]; return; }
    if ([value isKindOfClass:NSArray.class]) { for (id item in (NSArray *)value) RDCollectJSONStrings(item, out); return; }
    if ([value isKindOfClass:NSDictionary.class]) { for (id item in [(NSDictionary *)value allValues]) RDCollectJSONStrings(item, out); }
}

@implementation RDStaticScriptAnalyzer
+ (NSURL *)documentBaseURLInHTML:(NSString *)html baseURL:(NSURL *)base {
    if (!base || !html.length) return base;
    NSRegularExpression *tags=[NSRegularExpression regularExpressionWithPattern:@"<!--[\\s\\S]*?(?:-->|$)|<script\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>[\\s\\S]*?(?:</script\\s*>|$)|<base\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *attributes=[NSRegularExpression regularExpressionWithPattern:@"(?:^|\\s)([^\\s=/>]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))" options:0 error:nil];
    NSString *(^valueForName)(NSString *,NSString *)=^NSString *(NSString *text,NSString *name){
        for(NSTextCheckingResult *m in [attributes matchesInString:text options:0 range:NSMakeRange(0,text.length)]){
            if(![[text substringWithRange:[m rangeAtIndex:1]].lowercaseString isEqual:name])continue;
            for(NSUInteger i=2;i<=4;i++)if([m rangeAtIndex:i].location!=NSNotFound)return RDDecodeHTMLAttribute([text substringWithRange:[m rangeAtIndex:i]]);
        }
        return nil;
    };
    NSURL *documentBase=base;
    for(NSTextCheckingResult *m in [tags matchesInString:html options:0 range:NSMakeRange(0,html.length)]){
        NSRange range=[m rangeAtIndex:2];
        if(range.location==NSNotFound)continue;
        NSString *href=valueForName([html substringWithRange:range],@"href");
        if(href){ documentBase=[NSURL URLWithString:href relativeToURL:base].absoluteURL ?: base; break; }
    }
    return documentBase;
}
+ (NSArray<NSURL *> *)scriptURLsInHTML:(NSString *)html baseURL:(NSURL *)base limit:(NSUInteger)limit {
    // Consume comments and complete script raw-text elements. Markup quoted
    // inside inline JavaScript is not a document reference and must not be fetched.
    NSRegularExpression *tags=[NSRegularExpression regularExpressionWithPattern:@"<!--[\\s\\S]*?(?:-->|$)|<script\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>[\\s\\S]*?(?:</script\\s*>|$)|<base\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *attributes=[NSRegularExpression regularExpressionWithPattern:@"(?:^|\\s)([^\\s=/>]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))" options:0 error:nil];
    NSString *(^valueForName)(NSString *,NSString *)=^NSString *(NSString *text,NSString *name){
        for(NSTextCheckingResult *m in [attributes matchesInString:text options:0 range:NSMakeRange(0,text.length)]){
            if(![[text substringWithRange:[m rangeAtIndex:1]].lowercaseString isEqual:name])continue;
            for(NSUInteger i=2;i<=4;i++)if([m rangeAtIndex:i].location!=NSNotFound)return RDDecodeHTMLAttribute([text substringWithRange:[m rangeAtIndex:i]]);
        }
        return nil;
    };
    NSArray *matches=[tags matchesInString:html options:0 range:NSMakeRange(0,html.length)];
    NSURL *documentBase=[self documentBaseURLInHTML:html baseURL:base];
    NSMutableOrderedSet *urls=[NSMutableOrderedSet orderedSet];
    for(NSTextCheckingResult *m in matches){
        if(urls.count>=limit)break;
        NSRange range=[m rangeAtIndex:1];if(range.location==NSNotFound)continue;
        NSString *src=valueForName([html substringWithRange:range],@"src");
        if(src.length){NSURL *url=[NSURL URLWithString:src relativeToURL:documentBase];if(url)[urls addObject:url.absoluteURL];}
    }
    return urls.array;
}
+ (NSString *)decodeLiteral:(NSString *)literal {
    NSMutableString *decoded=[NSMutableString string];
    for(NSUInteger i=0;i<literal.length;i++) {
        unichar c=[literal characterAtIndex:i];
        if(c!='\\'){[decoded appendFormat:@"%C",c];continue;}
        if(++i>=literal.length)return nil;
        c=[literal characterAtIndex:i];
        if(c=='u'||c=='x') {
            NSUInteger digits=c=='u'?4:2;
            if(i+digits>=literal.length)return nil;
            NSString *hex=[literal substringWithRange:NSMakeRange(i+1,digits)];
            if([hex rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location!=NSNotFound)return nil;
            unsigned int value=0;[[NSScanner scannerWithString:hex]scanHexInt:&value];
            [decoded appendFormat:@"%C",(unichar)value];i+=digits;
        } else if(c=='/'||c=='\\'||c=='\''||c=='\"') [decoded appendFormat:@"%C",c];
        else return nil; // No expression evaluation, line continuation or unknown escapes.
    }
    return decoded;
}
+ (NSArray<DetectedMedia *> *)mediaInScript:(NSString *)script scriptURL:(NSURL *)url sourcePage:(NSURL *)page {
    return [self mediaInScript:script scriptURL:url sourcePage:page documentBaseURL:url];
}
+ (NSArray<DetectedMedia *> *)mediaInScript:(NSString *)script
                                  scriptURL:(NSURL *)url
                                sourcePage:(NSURL *)page
                          documentBaseURL:(NSURL *)documentBaseURL {
    // Consume comments/templates as complete tokens, so quoted text within them
    // is not mistaken for a literal. Only assignment/configuration values are
    // accepted; only bounded literal concatenation is supported, never variables or function calls.
    NSRegularExpression *tokens=[NSRegularExpression regularExpressionWithPattern:@"\"((?:\\\\.|[^\"\\\\])*)\"|'((?:\\\\.|[^'\\\\])*)'|`(?:\\\\.|[^`\\\\])*`|//[^\\r\\n]*|/\\*[\\s\\S]*?\\*/" options:0 error:nil];
    NSMutableArray *media=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    NSArray<NSTextCheckingResult *> *tokenMatches=[tokens matchesInString:script options:0 range:NSMakeRange(0,script.length)];
    for(NSUInteger tokenIndex=0; tokenIndex<tokenMatches.count; tokenIndex++) {
        NSTextCheckingResult *m=tokenMatches[tokenIndex];
        if(media.count>=500)break;
        NSRange value=[m rangeAtIndex:1];if(value.location==NSNotFound)value=[m rangeAtIndex:2];if(value.location==NSNotFound)continue;
        NSInteger before=(NSInteger)m.range.location-1;NSUInteger after=NSMaxRange(m.range);
        NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
        while(before>=0&&[space characterIsMember:[script characterAtIndex:before]])before--;
        while(after<script.length) {
            if([space characterIsMember:[script characterAtIndex:after]]){after++;continue;}
            BOOL slash=[script characterAtIndex:after]=='/' && after+1<script.length;
            if(slash&&[script characterAtIndex:after+1]=='*'){NSRange end=[script rangeOfString:@"*/" options:0 range:NSMakeRange(after+2,script.length-after-2)];if(end.location==NSNotFound){after=script.length;break;}after=NSMaxRange(end);continue;}
            if(slash&&[script characterAtIndex:after+1]=='/'){NSRange end=[script rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet options:0 range:NSMakeRange(after+2,script.length-after-2)];if(end.location==NSNotFound){after=script.length;break;}after=NSMaxRange(end);continue;}
            break;
        }
        // Accept a bounded chain of literal strings ("https://" + "cdn/" +
        // "movie.mp4").  No variables or function calls are evaluated.
        NSMutableString *joined=[NSMutableString string];
        NSString *first=[self decodeLiteral:[script substringWithRange:value]];
        if(!first.length)continue;
        [joined appendString:first];
        NSUInteger chainEnd=after;
        while(YES){
            NSUInteger p=RDSkipTrivia(script,chainEnd);
            if(p>=script.length || [script characterAtIndex:p]!='+') break;
            p=RDSkipTrivia(script,p+1);
            NSUInteger nextIndex=tokenIndex+1;
            while(nextIndex<tokenMatches.count && tokenMatches[nextIndex].range.location<p) nextIndex++;
            if(nextIndex>=tokenMatches.count || tokenMatches[nextIndex].range.location!=p) break;
            NSTextCheckingResult *nm=tokenMatches[nextIndex];
            NSRange nv=[nm rangeAtIndex:1]; if(nv.location==NSNotFound) nv=[nm rangeAtIndex:2];
            if(nv.location==NSNotFound) break;
            NSString *part=[self decodeLiteral:[script substringWithRange:nv]]; if(!part.length) break;
            [joined appendString:part]; chainEnd=NSMaxRange(nm.range); tokenIndex=nextIndex;
        }
        after=chainEnd;
        if(after<script.length && [@",;}])" rangeOfString:[script substringWithRange:NSMakeRange(after,1)]].location==NSNotFound)continue;
        if(before>=0){unichar prev=[script characterAtIndex:before];if(prev!='='&&prev!=':')continue;}
        NSMutableArray<NSString *> *literalValues=[NSMutableArray arrayWithObject:joined];
        // Recognize JSON player configuration embedded as a literal.  Values
        // are treated as clues only; JSON is never executed.
        NSData *jsonData=[joined dataUsingEncoding:NSUTF8StringEncoding];
        id json=jsonData.length?[NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil]:nil;
        if(json) RDCollectJSONStrings(json,literalValues);
        // Player configs are often JavaScript single-quoted strings, which
        // makes the inner JSON technically invalid JSON after decoding. Pull
        // only URL-shaped values from that bounded object as a safe fallback.
        NSRegularExpression *jsonURL=[NSRegularExpression regularExpressionWithPattern:@"(?:https?:\\/\\/|/)[^\\\"'\\s,}]+\\.(?:mp4|m3u8|mpd)(?:\\?[^\\\"'\\s,}]*)?" options:NSRegularExpressionCaseInsensitive error:nil];
        for(NSTextCheckingResult *jm in [jsonURL matchesInString:joined options:0 range:NSMakeRange(0,joined.length)])
            [literalValues addObject:[joined substringWithRange:jm.range]];
        NSURL *literalBase=documentBaseURL ?: url;
        for(NSString *literal in literalValues){
        NSArray *candidates;
        if([literal containsString:@"<video"]||[literal containsString:@"<source"])
            candidates=[RDProbeAnalyzer analyzeHTML:literal baseURL:literalBase].media;
        else {
            NSURL *candidate=RDNormalizeURL([NSURL URLWithString:literal relativeToURL:literalBase].absoluteURL);
            NSString *extension=candidate.path.pathExtension.lowercaseString;
            if(![@[@"mp4",@"m3u8",@"mpd"]containsObject:extension])continue;
            NSString *escaped=[[candidate.absoluteString stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
            candidates=[RDProbeAnalyzer analyzeHTML:[NSString stringWithFormat:@"<video src=\"%@\"></video>",escaped] baseURL:url].media;
        }
        for(DetectedMedia *item in candidates){NSString *key=[DetectedMedia dedupKeyForURL:item.mediaURL];if([seen containsObject:key])continue;[seen addObject:key];item.sourcePageURL=page.absoluteString;[media addObject:item];}
        }
    }
    return media;
}
@end
