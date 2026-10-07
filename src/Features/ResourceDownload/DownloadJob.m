//
//  DownloadJob.m
//  7zz
//

#import "DownloadJob.h"

static NSString *RDTruncateName(NSString *name) {
    if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 230) return name;
    NSString *ext = name.pathExtension;
    if ([ext lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16) ext = @"";
    NSString *suffix = ext.length ? [@"." stringByAppendingString:ext] : @"";
    NSUInteger budget = 230 - [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSString *stem = ext.length ? name.stringByDeletingPathExtension : name;
    NSMutableString *shortName = [NSMutableString string];
    [stem enumerateSubstringsInRange:NSMakeRange(0,stem.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *part, NSRange r, NSRange e, BOOL *stop) {
        if ([[shortName stringByAppendingString:part] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > budget) { *stop = YES; return; }
        [shortName appendString:part];
    }];
    return [shortName stringByAppendingString:suffix];
}

@implementation DownloadJob

- (instancetype)init {
    self = [super init];
    if (self) {
        _resourceKind = DownloadResourceVideo;
        _identifier = [NSUUID UUID].UUIDString;
        _state = DownloadJobStateQueued;
        _progress = 0;
        _generation = 1;
        _segmentCount = 0;
        _finishedSegments = 0;
        _transferredBytes = 0;
        _bytesPerSecond = 0;
        _estimatedRemainingSeconds = 0;
        _enqueuedAt = [NSDate date];
    }
    return self;
}

- (BOOL)canTransitionTo:(DownloadJobState)next {
    switch (_state) {
        case DownloadJobStateQueued:
            return (next == DownloadJobStateRunning ||
                    next == DownloadJobStateCancelling ||
                    next == DownloadJobStateFailed ||
                    next == DownloadJobStateInterrupted);
        case DownloadJobStateRunning:
            return (next == DownloadJobStateQueued || next == DownloadJobStatePaused ||
                    next == DownloadJobStateCancelling ||
                    next == DownloadJobStateCompleted ||
                    next == DownloadJobStateFailed ||
                    next == DownloadJobStateInterrupted);
        case DownloadJobStatePaused:
            return (next == DownloadJobStateRunning ||
                    next == DownloadJobStateCancelling ||
                    next == DownloadJobStateInterrupted);
        case DownloadJobStateCancelling:
            return (next == DownloadJobStateCancelled ||
                    next == DownloadJobStateFailed ||
                    next == DownloadJobStateInterrupted);
        // 终态原则上不可再跳转。显式例外（均为用户可见的单资源恢复
        // 语义，不改变既有其它跳转）：
        //  · Failed -> Queued：下载链接刷新成功后“原地重启”同一任务
        //    （restartFailedJobWithIdentifier:…，绝不创建第二个任务）；
        //  · Failed -> Cancelled：链接刷新期间用户显式取消失败项，
        //    迟到的刷新回调不得复活任务。
        //  · Interrupted -> Running：用户显式恢复中断任务（resumeJob:）。
        case DownloadJobStateFailed:
            return (next == DownloadJobStateQueued || next == DownloadJobStateCancelled);
        case DownloadJobStateInterrupted:
            return (next == DownloadJobStateRunning || next == DownloadJobStateCancelling);
        case DownloadJobStateCancelled:
        case DownloadJobStateCompleted:
            return NO;
    }
    return NO;
}

- (void)transitionTo:(DownloadJobState)next {
    if (![self canTransitionTo:next]) {
        // 非法跳转：保持原状态，仅记录（不崩溃、不伪状态）。
        return;
    }
    _state = next;
}

- (void)restoreTerminalState:(DownloadJobState)state {
    switch (state) {
        case DownloadJobStateCompleted:
        case DownloadJobStateFailed:
        case DownloadJobStateCancelled:
        case DownloadJobStateInterrupted:
            _state = state;
            return;
        default:
            return; // 仅终态可恢复
    }
}

- (NSURL *)partFileURLForIndex:(NSInteger)i {
    NSString *name = [NSString stringWithFormat:@"%03ld.part", (long)i];
    return [self.tempRootURL URLByAppendingPathComponent:name];
}

- (NSURL *)mergedTempURL {
    return [self.tempRootURL URLByAppendingPathComponent:@"merged.tmp"];
}

// 可播放媒体容器的魔数识别（视频 + 音频统一）。
// 2026-10-07 审计修复：此前只认 ISO(ftyp)/EBML/AVI/MPEG 四种——而第 29 轮已把
// mp3/flac/ogg/wav/ts/flv 等加入**探测**白名单，探测得到却在校验层必然被拒
//（审计员逐字复刻判定函数实测：mp3 两种头、flac、ogg、wav、TS、FLV 全部失败，
//  只有 m4a 因容器头恰好是 ISO ftyp 侥幸通过）。错误文案还甩锅给网站。
// 现补齐常见音频与流格式，与探测白名单对齐。
+ (BOOL)isLikelyVideoFileAtURL:(NSURL *)url {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return NO;
    // 192 字节：TS 的二次同步确认需要第 189 字节（b[188]）；其余格式头部都很短。
    NSData *data = [handle readDataOfLength:192];
    [handle closeFile];
    if (data.length < 12) return NO;
    const unsigned char *b = data.bytes;

    // ── 视频容器 ──
    BOOL iso  = (b[4]=='f'&&b[5]=='t'&&b[6]=='y'&&b[7]=='p');                 // MP4/MOV/M4A/3GP
    BOOL ebml = (b[0]==0x1A&&b[1]==0x45&&b[2]==0xDF&&b[3]==0xA3);            // WebM/MKV
    BOOL avi  = (b[0]=='R'&&b[1]=='I'&&b[2]=='F'&&b[3]=='F'&&b[8]=='A'&&b[9]=='V'&&b[10]=='I'&&b[11]==' ');
    BOOL mpeg = (b[0]==0x00&&b[1]==0x00&&b[2]==0x01&&(b[3]==0xBA||b[3]==0xB3));  // MPEG-PS/ES
    // MPEG-TS：188 字节包，同步字节 0x47。首字节 0x47 且第 189 字节（若可读）也是
    // 0x47 —— 单看首字节会误判（很多文件首字节恰为 0x47），故做二次确认；
    // 若文件不足 189 字节（极短分片），退化为只查首字节 + 传输流特征位。
    BOOL ts = (b[0] == 0x47);
    if (ts && data.length >= 189) { ts = (b[188] == 0x47); }
    else if (ts && data.length >= 4) { ts = ((b[1] & 0x80) != 0 || (b[3] & 0x40) != 0); }

    // ── 音频容器（与探测白名单对齐：mp3/flac/ogg/wav/opus/m4a/aac）──
    // MP3：ID3v2 标签（"ID3"）或 MPEG 帧同步（0xFF 后 3 位全 1，即 0xE0 掩码）
    BOOL mp3 = (b[0]=='I'&&b[1]=='D'&&b[2]=='3') ||
               (b[0]==0xFF && (b[1] & 0xE0) == 0xE0 &&
                ((b[1] >> 3) & 0x03) != 0x01);   // layer 位不能是保留值
    BOOL flac = (data.length >= 4 && memcmp(b, "fLaC", 4) == 0);
    BOOL ogg  = (data.length >= 4 && memcmp(b, "OggS", 4) == 0);   // Ogg/Opus/Vorbis
    BOOL wav  = (b[0]=='R'&&b[1]=='I'&&b[2]=='F'&&b[3]=='F'&&b[8]=='W'&&b[9]=='A'&&b[10]=='V'&&b[11]=='E');
    BOOL aac  = (data.length >= 2 && b[0] == 0xFF && (b[1] & 0xF6) == 0xF0);  // ADTS 帧同步

    // ── 专有/流媒体容器 ──
    BOOL flv = (data.length >= 3 && b[0]=='F'&&b[1]=='L'&&b[2]=='V');          // FLV

    return iso || ebml || avi || mpeg || ts || mp3 || flac || ogg || wav || aac || flv;
}

+ (BOOL)isLikelyImageFileAtURL:(NSURL *)url {
    NSData *d=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil]; if(d.length<12)return NO;
    const unsigned char *b=d.bytes; BOOL jpg=b[0]==0xff&&b[1]==0xd8&&b[2]==0xff; BOOL png=!memcmp(b,"\x89PNG\r\n\x1a\n",8); BOOL gif=!memcmp(b,"GIF8",4); BOOL webp=!memcmp(b,"RIFF",4)&&!memcmp(b+8,"WEBP",4); return jpg||png||gif||webp;
}

+ (BOOL)isLikelyHTMLErrorFileAtURL:(NSURL *)url {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return NO;
    NSData *data = [handle readDataOfLength:64];
    [handle closeFile];
    if (data.length < 1) return NO;
    const unsigned char *b = data.bytes;
    NSUInteger i = 0;
    while (i < data.length && (b[i] == ' ' || b[i] == '\t' || b[i] == '\r' || b[i] == '\n')) i++;
    return i < data.length && b[i] == '<';
}

+ (NSString *)reserveUniqueNameForPreferred:(NSString *)preferred
                                   inFolder:(NSString *)folder
                            againstReserved:(NSMutableSet<NSString *> *)reserved {
    if (preferred.length == 0) preferred = @"video.mp4";
    NSString *stem = preferred.stringByDeletingPathExtension;
    NSString *ext  = preferred.pathExtension;
    NSString *candidate = preferred;
    NSInteger suffix = 2;
    while (YES) {
        BOOL existsReserved = [reserved containsObject:candidate];
        BOOL existsDisk = [[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:candidate]];
        if (!existsReserved && !existsDisk) break;
        candidate = [NSString stringWithFormat:@"%@-%ld%@", stem, (long)suffix++,
                     ext.length ? [NSString stringWithFormat:@".%@", ext] : @""];
    }
    [reserved addObject:candidate];
    return candidate;
}

#pragma mark - 文件名清洗（2026-09-08 事故回归）

// 解码文件名中的 HTML 实体：网页标题抓取层可能保留原始实体（&nbsp; / &amp; /
// 数字与十六进制实体），它们会原样进入文件名。未识别的实体原样保留。
+ (NSString *)rd_decodeHTMLEntitiesInName:(NSString *)input {
    if (input.length == 0 || ![input containsString:@"&"]) return input;
    NSDictionary<NSString *, NSString *> *named = @{
        @"nbsp": @" ", @"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"",
        @"apos": @"'", @"mdash": @"—", @"ndash": @"–", @"hellip": @"…",
        @"lsquo": @"'", @"rsquo": @"'", @"ldquo": @"\"", @"rdquo": @"\"",
        @"laquo": @"«", @"raquo": @"»", @"middot": @"·", @"copy": @"©",
        @"reg": @"®", @"trade": @"™",
    };
    NSMutableString *out = [NSMutableString stringWithCapacity:input.length];
    NSUInteger i = 0;
    while (i < input.length) {
        unichar c = [input characterAtIndex:i];
        if (c != '&') { [out appendFormat:@"%C", c]; i++; continue; }
        // 实体最长约 10 字符（&reallylongname; 截断按普通文本处理）
        NSRange semi = [input rangeOfString:@";" options:0 range:NSMakeRange(i, MIN(input.length - i, 12))];
        if (semi.location == NSNotFound || semi.location <= i + 1) { [out appendString:@"&"]; i++; continue; }
        NSString *entity = [input substringWithRange:NSMakeRange(i + 1, semi.location - i - 1)];
        if ([entity characterAtIndex:0] == '#') {
            NSString *digits = [entity substringFromIndex:1];
            unsigned long value = 0;
            BOOL ok = NO;
            if (digits.length >= 2 && ([digits characterAtIndex:0] == 'x' || [digits characterAtIndex:0] == 'X')) {
                unsigned int hexValue = 0;
                ok = [[NSScanner scannerWithString:[digits substringFromIndex:1]] scanHexInt:&hexValue];
                value = hexValue;
            } else {
                NSInteger signedValue = 0;
                ok = [[NSScanner scannerWithString:digits] scanInteger:&signedValue];
                value = (unsigned long)MAX(0, signedValue);
            }
            if (ok && value > 0 && value < 0x110000) {
                if (value == 160) {
                    [out appendString:@" "]; // &nbsp; → 普通空格
                } else if (value > 0xFFFF) {
                    unsigned long v = value - 0x10000;
                    [out appendFormat:@"%C%C", (unichar)(0xD800 + (v >> 10)), (unichar)(0xDC00 + (v & 0x3FF))];
                } else {
                    [out appendFormat:@"%C", (unichar)value];
                }
            } else {
                [out appendString:[input substringWithRange:NSMakeRange(i, semi.location + 1 - i)]];
            }
            i = semi.location + 1;
        } else {
            NSString *mapped = named[entity];
            if (mapped) {
                [out appendString:mapped];
                i = semi.location + 1;
            } else {
                [out appendString:@"&"]; // 未识别实体原样保留，从下一个字符继续解析
                i++;
            }
        }
    }
    return out;
}

+ (nullable NSString *)sanitizedFileNameFromPreferred:(NSString *)preferred {
    if (!preferred.length) return nil;
    NSString *decoded = [self rd_decodeHTMLEntitiesInName:preferred];
    NSMutableString *clean = [NSMutableString stringWithCapacity:decoded.length];
    for (NSUInteger i = 0; i < decoded.length; i++) {
        unichar c = [decoded characterAtIndex:i];
        if (c == 0x00A0) { [clean appendString:@" "]; continue; }          // 不换行空格 → 空格
        if (c < 0x20 || c == 0x7F) continue;                               // 控制字符删除
        if (c == '/' || c == ':') { [clean appendString:@"-"]; continue; } // 路径分隔/Finder 保留字 → -
        [clean appendFormat:@"%C", c];
    }
    NSString *result = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while (result.length && [result hasSuffix:@"."]) { // 末尾点避免 "name." 畸形扩展名
        result = [result substringToIndex:result.length - 1];
        result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return result.length ? RDTruncateName(result) : nil;
}

+ (NSString *)fileNameByEnsuringMediaExtension:(NSString *)name
                              fallbackExtension:(NSString *)ext {
    NSString *clean = [self sanitizedFileNameFromPreferred:name] ?: @"video";
    NSString *extension = [clean.pathExtension lowercaseString];
    static NSSet<NSString *> *mediaExtensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mediaExtensions = [NSSet setWithArray:@[@"mp4",@"m4v",@"mov",@"webm",@"mkv",@"avi",@"mpeg",@"mpg",@"ts",@"m2ts",@"mts",@"ogv",@"flv",@"m3u8",@"mpd",@"png",@"jpg",@"jpeg",@"gif",@"webp",@"avif",@"heic",@"tif",@"tiff",@"bmp",@"svg",@"mp3",@"m4a",@"aac",@"ogg",@"wav"]]; });
    if (![mediaExtensions containsObject:extension]) {
        NSString *fallback = ext.lowercaseString;
        if ([fallback isEqual:@"hls"]) fallback = @"m3u8";
        if ([fallback isEqual:@"dash"]) fallback = @"mpd";
        clean = [clean stringByAppendingPathExtension:[mediaExtensions containsObject:fallback] ? fallback : @"mp4"];
    }
    return RDTruncateName(clean);
}

@end
