#import "RDBoundedMovie.h"
#import <Cocoa/Cocoa.h>
#import <math.h>
static uint32_t U32(const uint8_t *p) { uint32_t v; memcpy(&v,p,4); return CFSwapInt32BigToHost(v); }
static uint64_t U64(const uint8_t *p) { return ((uint64_t)U32(p)<<32)|U32(p+4); }
static NSError *Invalid(void) { return [NSError errorWithDomain:RDMetadataErrorDomain code:RDMetadataBlocked userInfo:@{NSLocalizedDescriptionKey:@"Invalid range, changed representation, or unsafe movie atoms"}]; }
// Strict bounded ISO BMFF traversal. No byte-pattern searching inside mdat.
static BOOL Atoms(const uint8_t *p, NSUInteger n, NSUInteger depth, NSMutableDictionary *out) {
    if (depth > 12) return NO;
    NSUInteger offset=0;
    while (offset<n) {
        if (n-offset<8) return NO;
        const uint8_t *a=p+offset; uint64_t size=U32(a); NSUInteger h=8;
        if (size==1) { if (n-offset<16) return NO; size=U64(a+8); h=16; }
        if (size<h || size>n-offset) return NO;
        const uint8_t *b=a+h; NSUInteger length=(NSUInteger)size-h;
        if (!memcmp(a+4,"rmra",4)||!memcmp(a+4,"rmda",4)||!memcmp(a+4,"rdrf",4)||!memcmp(a+4,"cmov",4)) return NO;
        if (!memcmp(a+4,"dref",4)) {
            if (length<8 || U32(b)!=0) return NO;
            uint32_t count=U32(b+4); NSUInteger pos=8;
            if (!count || count>1024) return NO;
            for (uint32_t i=0;i<count;i++) {
                if (length-pos<12 || U32(b+pos)!=12 || (memcmp(b+pos+4,"url ",4) && memcmp(b+pos+4,"alis",4)) || U32(b+pos+8)!=1) return NO;
                pos+=12;
            }
            if (pos!=length) return NO;
        }
        if (!memcmp(a+4,"mvhd",4)) {
            if (length<100 || b[0]>1 || (b[0]==1 && length<112)) return NO;
            uint32_t scale=U32(b+(b[0]?20:12)); uint64_t ticks=b[0]?U64(b+24):U32(b+16);
            double duration=scale?(double)ticks/scale:NAN;
            if (!isfinite(duration) || duration<0 || ticks==(b[0]?UINT64_MAX:UINT32_MAX)) return NO;
            out[@"duration"]=@(duration);
        }
        if (!memcmp(a+4,"trak",4)) {
            NSMutableDictionary *track=[NSMutableDictionary dictionary];
            if (!Atoms(b,length,depth+1,track)) return NO;
            if ([track[@"video"] boolValue] && track[@"dimensions"] && !out[@"dimensions"]) out[@"dimensions"]=track[@"dimensions"];
        } else if (!memcmp(a+4,"tkhd",4)) {
            if (length<84 || b[0]>1 || (b[0]==1 && length<96)) return NO;
            NSUInteger matrix=b[0]?52:40, dimensions=b[0]?88:76;
            double width=U32(b+dimensions)/65536.0, height=U32(b+dimensions+4)/65536.0;
            double aa=(int32_t)U32(b+matrix)/65536.0, bb=(int32_t)U32(b+matrix+4)/65536.0;
            double cc=(int32_t)U32(b+matrix+12)/65536.0, dd=(int32_t)U32(b+matrix+16)/65536.0;
            if (U32(b+matrix+8) || U32(b+matrix+20) || U32(b+matrix+32)!=0x40000000) return NO;
            double w=fabs(aa*width)+fabs(cc*height), hgt=fabs(bb*width)+fabs(dd*height);
            if (isfinite(w*hgt) && w>0 && hgt>0 && w*hgt<=100000000) out[@"dimensions"]=[NSValue valueWithSize:NSMakeSize(w,hgt)];
        } else if (!memcmp(a+4,"hdlr",4)) {
            if (length<24) return NO;
            if (!memcmp(b+8,"vide",4)) out[@"video"]=@YES;
        } else if (!memcmp(a+4,"moov",4)||!memcmp(a+4,"mdia",4)||!memcmp(a+4,"minf",4)||!memcmp(a+4,"dinf",4)) {
            if (!Atoms(b,length,depth+1,out)) return NO;
        }
        offset+=(NSUInteger)size;
    }
    return offset==n;
}
@interface RDBoundedMovie ()
@property (copy) RDRangeRequest request;
@property (copy) void (^completion)(NSDictionary *, NSError *);
@property uint64_t total;
@property NSUInteger used;
@property NSUInteger atoms;
@property NSString *etag;
// 已取回并校验的字节窗口（@[offset, NSData]，数量很小）。连续文件结构已在
// 窗口内时直接本地解析，不再为每个 atom 头单独发起网络往返。
@property NSMutableArray<NSArray *> *windows;
@end
@implementation RDBoundedMovie
+ (void)readWithRequest:(RDRangeRequest)request completion:(void (^)(NSDictionary *, NSError *))completion {
    RDBoundedMovie *reader=[RDBoundedMovie new]; reader.request=request; reader.completion=completion;
    reader.windows=[NSMutableArray array];
    [reader walkAt:0];
}
// 服务层前缀探测（bytes=0-1023）已带回经校验的头部数据与 Content-Range
// 总长：作为初始窗口复用，避免为同一批头部字节再发一次请求。
+ (void)readWithHeadData:(NSData *)head total:(uint64_t)total etag:(NSString *)etag request:(RDRangeRequest)request completion:(void (^)(NSDictionary *, NSError *))completion {
    RDBoundedMovie *reader=[RDBoundedMovie new]; reader.request=request; reader.completion=completion;
    reader.windows=[NSMutableArray array];
    if (head.length && total >= head.length && total <= LLONG_MAX && head.length <= 5*1024*1024) {
        reader.total=total; reader.etag=etag;
        [reader.windows addObject:@[@0,head]];
    }
    [reader walkAt:0];
}
- (void)finish:(NSDictionary *)result error:(NSError *)error {
    if (!_completion) return;
    void (^done)(NSDictionary *,NSError *)=_completion; _completion=nil; _request=nil; done(result,error);
}
- (void)range:(uint64_t)offset count:(NSUInteger)count done:(void (^)(NSData *))done {
    if (count>5*1024*1024-_used || !count || offset>LLONG_MAX-count) { [self finish:nil error:Invalid()]; return; }
    _used+=count;
    // Hanime 类 CDN 对 If-Match 条件请求返回 412 且 ETag 可缺失：改用 Content-Range
    // 几何（偏移吻合 + 全程 total 一致）保证没有跨表示读取，不再强依赖 ETag/If-Match。
    NSDictionary *headers=[@{@"Range":[NSString stringWithFormat:@"bytes=%llu-%llu",offset,offset+count-1],@"Accept-Encoding":@"identity"} mutableCopy];
    _request(headers,count,^(RDMetadataResponse *r) {
        if (r.error) { [self finish:nil error:r.error]; return; }
        NSString *cr=[r.response valueForHTTPHeaderField:@"Content-Range"]?:@"";
        NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^bytes ([0-9]+)-([0-9]+)/([1-9][0-9]*)$" options:0 error:nil];
        NSTextCheckingResult *m=[re firstMatchInString:cr options:0 range:NSMakeRange(0,cr.length)];
        uint64_t values[3]={0}; BOOL valid=m!=nil;
        for (NSUInteger i=0;m && i<3;i++) { NSScanner *s=[NSScanner scannerWithString:[cr substringWithRange:[m rangeAtIndex:i+1]]]; unsigned long long v=0; valid &= [s scanUnsignedLongLong:&v] && s.isAtEnd && v<=LLONG_MAX; values[i]=v; }
        NSString *etag=[r.response valueForHTTPHeaderField:@"ETag"];
        NSString *encoding=[r.response valueForHTTPHeaderField:@"Content-Encoding"];
        valid &= r.response.statusCode==206 && r.data.length==count && values[0]==offset && values[1]==offset+count-1 && values[2]>values[1];
        valid &= (!encoding.length || [encoding.lowercaseString isEqual:@"identity"]);
        valid &= !self.total || (self.total==values[2]);
        if (r.response.expectedContentLength>=0) valid &= r.response.expectedContentLength==(long long)count;
        if (!valid) { [self finish:nil error:Invalid()]; return; }
        self.total=values[2]; self.etag=etag;
        if (done && r.data) done(r.data);
    });
}
// 返回 [offset, offset+length) 的完整数据（跨窗口按序本地拼接）；任一缺口
// 返回 nil。窗口按起点排序后线性吸收。
- (NSData *)bufferedRange:(uint64_t)offset length:(NSUInteger)length {
    if (!length) return [NSData data];
    NSArray *sorted=[self.windows sortedArrayUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){
        uint64_t x=[a[0] unsignedLongLongValue],y=[b[0] unsignedLongLongValue];
        return x<y?NSOrderedAscending:(x>y?NSOrderedDescending:NSOrderedSame);
    }];
    NSMutableData *composed=[NSMutableData dataWithCapacity:length];
    uint64_t cursor=offset;
    for (NSArray *window in sorted) {
        uint64_t start=[window[0] unsignedLongLongValue];
        NSData *data=window[1];
        uint64_t end=start+data.length;
        if (end<=cursor) continue;
        if (start>cursor) return nil;
        uint64_t pieceEnd=MIN(end,offset+length);
        [composed appendBytes:(const uint8_t *)data.bytes+(NSUInteger)(cursor-start) length:(NSUInteger)(pieceEnd-cursor)];
        cursor=pieceEnd;
        if (cursor>=offset+length) return composed;
    }
    return nil;
}
// 从 offset 起连续已缓冲的终点（无缺口）。
- (uint64_t)contiguousCoveredEndFrom:(uint64_t)offset {
    NSArray *sorted=[self.windows sortedArrayUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){
        uint64_t x=[a[0] unsignedLongLongValue],y=[b[0] unsignedLongLongValue];
        return x<y?NSOrderedAscending:(x>y?NSOrderedDescending:NSOrderedSame);
    }];
    uint64_t covered=offset;
    for (NSArray *window in sorted) {
        uint64_t start=[window[0] unsignedLongLongValue];
        uint64_t end=start+[(NSData *)window[1] length];
        if (start<=covered && end>covered) covered=end;
    }
    return covered;
}
// 保证 [offset, offset+count) 全部缓冲后回调完整数据。缺口部分才发起网络
// 请求（已缓冲字节绝不重复传输）；缺口补齐后本地拼接。典型至多两段缺口
// （头部窗口尾部 + moov 体），递归深度受窗口数量约束。
- (void)ensureRange:(uint64_t)offset count:(NSUInteger)count next:(void (^)(NSData *))next {
    if (!next) return;
    NSData *buffered=[self bufferedRange:offset length:count];
    if (buffered) { next(buffered); return; }
    uint64_t covered=[self contiguousCoveredEndFrom:offset];
    if (covered>=offset+count) { [self finish:nil error:Invalid()]; return; }
    // 缺口 [covered, nextStart)：nextStart 为 covered 之后最近的窗口起点或区间终点。
    uint64_t nextStart=offset+count;
    for (NSArray *window in self.windows) {
        uint64_t start=[window[0] unsignedLongLongValue];
        if (start>covered && start<nextStart) nextStart=start;
    }
    if (covered>=nextStart) { [self finish:nil error:Invalid()]; return; }
    [self range:covered count:(NSUInteger)(nextStart-covered) done:^(NSData *data) {
        [self.windows addObject:@[@(covered),data]];
        [self ensureRange:offset count:count next:next];
    }];
}
// atom 头（16 字节，覆盖 64 位 size）已在缓冲内时零请求本地解析；缺失才
// 从 offset 预读至多 1KB（对齐到 total），让后续连续 atom 一次往返覆盖。
- (void)ensureHeader:(uint64_t)offset next:(void (^)(NSData *))next {
    if (!next) return;
    NSData *buffered=[self bufferedRange:offset length:16];
    if (buffered) { next(buffered); return; }
    uint64_t end=_total ? MIN(offset+1024,_total) : offset+1024;
    [self ensureRange:offset count:(NSUInteger)MAX(16,end-offset) next:next];
}
- (void)walkAt:(uint64_t)offset {
    if (++_atoms>256 || (_total && (_total-offset<16 || offset>=_total))) { [self finish:nil error:Invalid()]; return; }
    [self ensureHeader:offset next:^(NSData *chunk) {
        const uint8_t *p=chunk.bytes; uint64_t size=U32(p); NSUInteger h=8;
        if (size==1) { size=U64(p+8); h=16; }
        if (size<h || size>self.total-offset) { [self finish:nil error:Invalid()]; return; }
        if (!memcmp(p+4,"moov",4)) {
            // 实测 Hanime 480p 全片 moov 约 1.44MB：1MB 上限会把整类文件判死。
            if (size>4*1024*1024) { [self finish:nil error:Invalid()]; return; }
            [self ensureRange:offset count:(NSUInteger)size next:^(NSData *moov) {
                NSMutableDictionary *result=[NSMutableDictionary dictionary];
                if (!Atoms(moov.bytes,moov.length,0,result) || !result[@"duration"]) { [self finish:nil error:Invalid()]; return; }
                result[@"size"]=@(self.total); result[@"transferredBytes"]=@(self.used); result[@"etag"]=self.etag;
                [self finish:result error:nil];
            }];
        } else {
            if (memcmp(p+4,"ftyp",4) && memcmp(p+4,"mdat",4) && memcmp(p+4,"free",4) && memcmp(p+4,"wide",4) && memcmp(p+4,"skip",4)) { [self finish:nil error:Invalid()]; return; }
            [self walkAt:offset+size];
        }
    }];
}
@end
