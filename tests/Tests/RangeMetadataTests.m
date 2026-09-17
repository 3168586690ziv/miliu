// Included by headless harness. A virtual sparse 64MiB mdat is never allocated/read.
#import "RDBoundedMovie.h"
static void Put32(NSMutableData *d, NSUInteger offset, uint32_t value) { value=CFSwapInt32HostToBig(value); memcpy((uint8_t *)d.mutableBytes+offset,&value,4); }
static NSData *Box(const char *type, NSData *body) { NSMutableData *d=[NSMutableData dataWithLength:8]; Put32(d,0,(uint32_t)body.length+8); memcpy((uint8_t *)d.mutableBytes+4,type,4); [d appendData:body]; return d; }
static NSData *Join(NSArray *items) { NSMutableData *d=[NSMutableData data]; for (NSData *item in items) [d appendData:item]; return d; }
static NSData *MovieMoov(BOOL external, BOOL oversized) {
    NSMutableData *mvhd=[NSMutableData dataWithLength:100]; Put32(mvhd,12,1000); Put32(mvhd,16,12500);
    NSMutableData *tkhd=[NSMutableData dataWithLength:84]; Put32(tkhd,40,0); Put32(tkhd,44,65536); Put32(tkhd,52,(uint32_t)-65536); Put32(tkhd,72,0x40000000); Put32(tkhd,76,320*65536); Put32(tkhd,80,180*65536);
    NSMutableData *hdlr=[NSMutableData dataWithLength:24]; memcpy((uint8_t *)hdlr.mutableBytes+8,"vide",4);
    NSMutableData *url=[NSMutableData dataWithLength:4]; Put32(url,0,external?0:1);
    NSMutableData *dref=[NSMutableData dataWithLength:8]; Put32(dref,4,1); [dref appendData:Box("url ",url)];
    NSData *mdia=Box("mdia",Join(@[Box("hdlr",hdlr),Box("minf",Box("dinf",Box("dref",dref)))]));
    // oversized 模拟 Hanime 实测：480p 全片 moov 约 1.44MB，超出旧版 1MB 上限。
    NSData *padding = oversized ? Box("free",[NSMutableData dataWithLength:1500*1024]) : [NSData data];
    return Box("moov",Join(@[Box("mvhd",mvhd),Box("trak",Join(@[Box("tkhd",tkhd),mdia])),padding]));
}
static void RangeMetadataTests(NSURL *fixtureDirectory) {
    for (NSString *mode in @[@"head",@"tail",@"badRange",@"416",@"changed",@"external",@"ignored",@"totalChanged",@"noEtag",@"ifmatch412",@"bigmoov"]) {
        BOOL oversized=[mode isEqual:@"bigmoov"];
        NSData *moov=MovieMoov([mode isEqual:@"external"],oversized);
        NSData *ftyp=Box("ftyp",[NSMutableData dataWithLength:16]);
        NSMutableData *mdat=[NSMutableData dataWithLength:16]; Put32(mdat,0,64*1024*1024); memcpy((uint8_t *)mdat.mutableBytes+4,"mdat",4);
        // totalChanged 用尾部布局：头部布局下单次前缀往返已含全部结构，
        // 不存在可观察的跨请求 total 变化；尾部 moov 需要第二次请求，
        // 才能真正检验“表示中途改变必须被拒绝”。
        BOOL head=[mode isEqual:@"head"]||oversized;
        if ([mode isEqual:@"totalChanged"]) head=NO;
        uint64_t moovOffset=head?ftyp.length:ftyp.length+64*1024*1024;
        uint64_t total=ftyp.length+64*1024*1024+moov.length;
        NSDictionary *segments=@{@0:ftyp,@(moovOffset):moov,@(head?ftyp.length+moov.length:ftyp.length):mdat};
        __block NSUInteger bytes=0, requests=0; __block BOOL finished=NO; __block NSDictionary *result; __block NSError *failure;
        NSDate *start=NSDate.date;
        [RDBoundedMovie readWithRequest:^(NSDictionary *headers, NSUInteger budget, void (^done)(RDMetadataResponse *)) {
            requests++;
            // Hanime 类 CDN 兼容护栏：绝不允许重新引入 If-Match（实测返回 412 Precondition Failed）。
            Check(headers[@"If-Match"]==nil,@"range reader never sends If-Match");
            unsigned long long lo=0,hi=0; sscanf([headers[@"Range"] UTF8String],"bytes=%llu-%llu",&lo,&hi);
            if ([mode isEqual:@"ifmatch412"] && [headers[@"If-Match"] length]) {
                RDMetadataResponse *guard=[RDMetadataResponse new];
                guard.response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://offline.invalid/virtual.mp4"] statusCode:412 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
                done(guard); return;
            }
            NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)(hi-lo+1)];
            for (NSNumber *key in segments) {
                NSData *part=segments[key]; uint64_t at=key.unsignedLongLongValue;
                uint64_t begin=MAX(lo,at),end=MIN(hi+1,at+part.length);
                if (end>begin) memcpy((uint8_t *)data.mutableBytes+begin-lo,(const uint8_t *)part.bytes+begin-at,(NSUInteger)(end-begin));
            }
            bytes+=data.length;
            NSString *etag=nil;
            if ([mode isEqual:@"changed"] && requests>1) etag=@"\"v2\"";
            else if (![mode isEqual:@"noEtag"]) etag=@"\"v1\"";
            NSString *range=[NSString stringWithFormat:@"bytes %llu-%llu/%llu",lo,hi,total+([mode isEqual:@"totalChanged"]&&requests>1?1:0)];
            if ([mode isEqual:@"badRange"]) range=@"bytes 1-3/2";
            NSMutableDictionary *hdrs=[NSMutableDictionary dictionary];
            hdrs[@"Content-Range"]=range; hdrs[@"Content-Length"]=@(data.length).stringValue;
            if (etag) hdrs[@"ETag"]=etag;
            RDMetadataResponse *r=[RDMetadataResponse new]; r.data=data;
            NSInteger status=[mode isEqual:@"416"]?416:([mode isEqual:@"ignored"]?200:206);
            r.response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://offline.invalid/virtual.mp4"] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:hdrs];
            done(r);
        } completion:^(NSDictionary *metadata, NSError *error) { result=metadata; failure=error; finished=YES; }];
        Check(finished,@"bounded reader completes synchronously injected fixture");
        BOOL succeeds=[mode isEqual:@"head"]||[mode isEqual:@"tail"]||[mode isEqual:@"changed"]||[mode isEqual:@"noEtag"]||[mode isEqual:@"ifmatch412"]||oversized;
        if (succeeds) {
            NSSize size=[(NSValue *)result[@"dimensions"] sizeValue];
            Check(!failure && [result[@"duration"] doubleValue]==12.5 && size.width==180 && size.height==320,[NSString stringWithFormat:@"virtual >32MiB moov %@ actual duration and rotated dimensions",mode]);
            [moov writeToURL:[fixtureDirectory URLByAppendingPathComponent:[mode stringByAppendingString:@"-moov.bin"]] atomically:YES];
            if (!oversized) Check(bytes<4096 && bytes<total/1000,@"mdat skipped; transport bytes far below file size");
            NSLog(@"PERF range %@ total=%llu bytes=%lu requests=%lu elapsed=%.6f",mode,total,bytes,requests,-[start timeIntervalSinceNow]);
        } else Check(failure && !result,[NSString stringWithFormat:@"reject %@",mode]);
    }
}
