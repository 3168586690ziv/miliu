#import "RDStreamPlan.h"
#import "RDManifestParser.h"
#import <math.h>
static NSError *PlanError(NSString *text) { return [NSError errorWithDomain:@"RDStream" code:1 userInfo:@{NSLocalizedDescriptionKey:text}]; }
static NSString *HTTPURL(NSString *s, NSURL *base) { NSURL *u=[NSURL URLWithString:s relativeToURL:base].absoluteURL; return [@[@"http",@"https"] containsObject:u.scheme.lowercaseString] && u.host.length && !u.user.length && !u.password.length ? u.absoluteString : nil; }
static NSArray<NSXMLElement *> *Children(NSXMLElement *e,NSString *name) { NSMutableArray *a=[NSMutableArray array];for(NSXMLNode *n in e.children)if(n.kind==NSXMLElementKind && [n.localName isEqual:name])[a addObject:n];return a; }
static NSString *Attr(NSXMLElement *e,NSString *name) { return [e attributeForName:name].stringValue; }
static NSString *Template(NSString *s,NSString *rid,NSString *bw,long long number,long long time) {
    s=[s stringByReplacingOccurrencesOfString:@"$$" withString:@"\x01"];
    s=[s stringByReplacingOccurrencesOfString:@"$RepresentationID$" withString:rid ?: @""];
    s=[s stringByReplacingOccurrencesOfString:@"$Bandwidth$" withString:bw ?: @""];
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"\\$(Number|Time)(?:%0([1-9][0-9]?)d)?\\$" options:0 error:nil];
    NSMutableString *out=[s mutableCopy];
    for(NSTextCheckingResult *m in [[re matchesInString:s options:0 range:NSMakeRange(0,s.length)] reverseObjectEnumerator]){
        NSInteger width=[m rangeAtIndex:2].location==NSNotFound?0:[[s substringWithRange:[m rangeAtIndex:2]] integerValue];
        long long value=[[s substringWithRange:[m rangeAtIndex:1]] isEqual:@"Number"]?number:time;
        [out replaceCharactersInRange:m.range withString:[NSString stringWithFormat:@"%0*lld",(int)MIN(width,20),value]];
    }
    return [out stringByReplacingOccurrencesOfString:@"\x01" withString:@"$"];
}
@implementation RDStreamPlan
+ (NSDictionary *)HLSPlaylist:(NSString *)manifest baseURL:(NSURL *)base error:(NSError **)error {
    NSDictionary *parsed=[RDManifestParser parseManifest:manifest baseURL:base];
    if(![parsed[@"kind"] isEqual:@"hls"]||[parsed[@"isMaster"] boolValue]||[parsed[@"isLive"] boolValue]){if(error)*error=PlanError(@"此清单不是已结束的点播媒体列表，无法生成完整离线视频");return nil;}
    NSMutableArray *items=[NSMutableArray array],*lines=[NSMutableArray array];
    NSRegularExpression *uriRE=[NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:nil];
    long long nextOffset=0; NSString *pendingRange=nil,*previousURL=nil;
    for(NSString *raw in [manifest componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([line hasPrefix:@"#EXT-X-KEY:"] && ![line containsString:@"METHOD=AES-128"] && ![line containsString:@"METHOD=NONE"]){if(error)*error=PlanError(@"该流使用受保护或暂不支持的加密方式，无法导出普通视频");return nil;}
        if([line hasPrefix:@"#EXT-X-BYTERANGE:"]){pendingRange=[line substringFromIndex:17];continue;}
        BOOL media=line.length && ![line hasPrefix:@"#"];
        NSTextCheckingResult *uri=[uriRE firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
        if(media || uri){
            NSString *remote=HTTPURL(media?line:[line substringWithRange:[uri rangeAtIndex:1]],base);
            if(!remote){if(error)*error=PlanError(@"清单含无效的资源地址");return nil;}
            NSString *range=media?pendingRange:nil;
            if([line hasPrefix:@"#EXT-X-MAP:"]){NSRegularExpression *rr=[NSRegularExpression regularExpressionWithPattern:@"BYTERANGE=\"([^\"]+)\"" options:0 error:nil];NSTextCheckingResult *rm=[rr firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];if(rm){range=[line substringWithRange:[rm rangeAtIndex:1]];line=[line stringByReplacingCharactersInRange:rm.range withString:@""];line=[line stringByReplacingOccurrencesOfString:@",," withString:@","];uri=[uriRE firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];}}
            NSMutableDictionary *item=[@{@"url":remote} mutableCopy];
            if(range.length){NSArray *p=[range componentsSeparatedByString:@"@"];long long length=[p[0] longLongValue];long long offset=p.count>1?[p[1] longLongValue]:nextOffset;
                if(length<=0||offset<0||offset>LLONG_MAX-length||(p.count==1 && ![remote isEqual:previousURL])){if(error)*error=PlanError(@"清单分片字节范围无效");return nil;}
                item[@"range"]=[NSString stringWithFormat:@"bytes=%lld-%lld",offset,offset+length-1];item[@"length"]=@(length);nextOffset=offset+length;
            }else nextOffset=0;
            previousURL=remote;pendingRange=nil;
            NSString *ext=[line hasPrefix:@"#EXT-X-KEY:"]?@"key":([line hasPrefix:@"#EXT-X-MAP:"]?@"mp4":@"bin");
            NSString *local=[NSString stringWithFormat:@"resource-%05lu.%@",(unsigned long)items.count,ext];item[@"local"]=local;item[@"key"]=@([ext isEqual:@"key"]);[items addObject:item];
            line=media?local:[line stringByReplacingCharactersInRange:[uri rangeAtIndex:1] withString:local];
            if(items.count>20000){if(error)*error=PlanError(@"分片数量超过 20000 上限");return nil;}
        }
        [lines addObject:line];
    }
    if(!items.count){if(error)*error=PlanError(@"清单未包含媒体分片");return nil;}
    return @{@"resources":items,@"playlist":[lines componentsJoinedByString:@"\n"]};
}
+ (NSArray<NSDictionary *> *)DASHTracks:(NSString *)manifest baseURL:(NSURL *)base error:(NSError **)error {
    NSDictionary *metadata=[RDManifestParser parseManifest:manifest baseURL:base];
    if(![metadata[@"kind"] isEqual:@"dash"]||[metadata[@"isLive"] boolValue]||[metadata[@"isEncrypted"] boolValue]){if(error)*error=PlanError(@"仅支持无 DRM 的点播 DASH 视频");return nil;}
    NSXMLDocument *doc=[[NSXMLDocument alloc]initWithXMLString:manifest options:NSXMLNodeLoadExternalEntitiesNever error:error];
    if(!doc)return nil;
    NSArray *periods=Children(doc.rootElement,@"Period");
    if(periods.count!=1){if(error)*error=PlanError(@"暂不支持多 Period 的 DASH 拼接，未保存不完整视频");return nil;}
    NSArray *representations=[doc nodesForXPath:@"//*[local-name()='Representation']" error:error];
    NSMutableDictionary *selected=[NSMutableDictionary dictionary];
    for(NSXMLElement *rep in representations){NSXMLElement *adapt=(id)rep.parent;NSString *type=Attr(rep,@"mimeType")?:Attr(adapt,@"mimeType")?:Attr(adapt,@"contentType")?:@"";if(!type.length && (Attr(rep,@"width")||Attr(adapt,@"width")))type=@"video";NSString *kind=[type hasPrefix:@"video"]?@"video":([type hasPrefix:@"audio"]?@"audio":nil);if(!kind)continue;NSXMLElement *old=selected[kind];if(!old || Attr(rep,@"bandwidth").longLongValue>Attr(old,@"bandwidth").longLongValue)selected[kind]=rep;}
    NSMutableArray *tracks=[NSMutableArray array];
    for(NSString *kind in @[@"video",@"audio"]){NSXMLElement *rep=selected[kind];if(!rep)continue;
        NSMutableArray *chain=[NSMutableArray array];for(NSXMLNode *n=rep;n.kind==NSXMLElementKind;n=n.parent)[chain insertObject:n atIndex:0];
        NSURL *resolvedBase=base;NSXMLElement *list=nil,*timeline=nil;NSMutableDictionary *tpl=[NSMutableDictionary dictionary];BOOL hasBase=NO;
        for(NSXMLElement *node in chain){NSXMLElement *be=Children(node,@"BaseURL").firstObject;if(be.stringValue.length){NSString *u=HTTPURL([be.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],resolvedBase);if(!u){if(error)*error=PlanError(@"DASH BaseURL 无效");return nil;}resolvedBase=[NSURL URLWithString:u];hasBase=YES;}
            NSXMLElement *te=Children(node,@"SegmentTemplate").firstObject;if(te){for(NSXMLNode *a in te.attributes)tpl[a.name]=a.stringValue;NSXMLElement *tl=Children(te,@"SegmentTimeline").firstObject;if(tl)timeline=tl;}
            NSXMLElement *le=Children(node,@"SegmentList").firstObject;if(le)list=le;
        }
        NSMutableArray *resources=[NSMutableArray array];
        BOOL (^append)(NSString *,NSString *)=^BOOL(NSString *path,NSString *range){NSString *u=path.length?HTTPURL(path,resolvedBase):resolvedBase.absoluteString;if(!u)return NO;NSMutableDictionary *d=[@{@"url":u}mutableCopy];if(range.length)d[@"range"]=[@"bytes=" stringByAppendingString:range];[resources addObject:d];return resources.count<=20000;};
        if(list){NSXMLElement *init=Children(list,@"Initialization").firstObject;if(init&&!append(Attr(init,@"sourceURL"),Attr(init,@"range")))goto invalid;for(NSXMLElement *seg in Children(list,@"SegmentURL"))if(!append(Attr(seg,@"media"),Attr(seg,@"mediaRange")))goto invalid;}
        else if(tpl[@"media"]){
            NSString *rid=Attr(rep,@"id"),*bw=Attr(rep,@"bandwidth");long long number=tpl[@"startNumber"]?[tpl[@"startNumber"] longLongValue]:1;long long scale=tpl[@"timescale"]?[tpl[@"timescale"] longLongValue]:1;double seconds=[metadata[@"durationSeconds"] doubleValue];
            if(scale<=0||!isfinite(seconds)||seconds<0||seconds>31*86400)goto invalid;
            if(tpl[@"initialization"]&&!append(Template(tpl[@"initialization"],rid,bw,number,0),nil))goto invalid;
            if(timeline){NSArray *entries=Children(timeline,@"S");long long t=0;for(NSUInteger i=0;i<entries.count;i++){NSXMLElement *e=entries[i];long long d=Attr(e,@"d").longLongValue;if(Attr(e,@"t"))t=Attr(e,@"t").longLongValue;long long repeats=Attr(e,@"r").longLongValue;if(d<=0||t<0)goto invalid;if(repeats==-1){long long end=i+1<entries.count&&Attr(entries[i+1],@"t")?Attr(entries[i+1],@"t").longLongValue:(long long)ceil(seconds*scale)+[tpl[@"presentationTimeOffset"] longLongValue];if(end<=t)goto invalid;repeats=(end-t+d-1)/d-1;}if(repeats<0||repeats>=20000)goto invalid;for(long long j=0;j<=repeats;j++){if(!append(Template(tpl[@"media"],rid,bw,number++,t),nil)||t>LLONG_MAX-d)goto invalid;t+=d;}}}
            else{long long duration=[tpl[@"duration"] longLongValue];if(duration<=0||seconds<=0)goto invalid;long long count=(long long)ceil(seconds*scale/duration);if(count<=0||count>20000)goto invalid;for(long long i=0;i<count;i++)if(!append(Template(tpl[@"media"],rid,bw,number++,i*duration),nil))goto invalid;}
        }else if(hasBase){if(!append(nil,nil))goto invalid;}else goto invalid;
        if(!resources.count)goto invalid;[tracks addObject:@{@"kind":kind,@"resources":resources}];continue;
invalid: if(error)*error=PlanError(@"DASH 分片结构不完整或超过支持的范围，未保存残缺视频");return nil;
    }
    if(!selected[@"video"]){if(error)*error=PlanError(@"DASH 没有可识别的视频轨道");return nil;}
    return tracks;
}
@end
