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

+ (BOOL)isLikelyVideoFileAtURL:(NSURL *)url {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return NO;
    NSData *data = [handle readDataOfLength:32];
    [handle closeFile];
    if (data.length < 12) return NO;
    const unsigned char *b = data.bytes;
    BOOL iso  = (b[4]=='f'&&b[5]=='t'&&b[6]=='y'&&b[7]=='p');
    BOOL ebml = (b[0]==0x1A&&b[1]==0x45&&b[2]==0xDF&&b[3]==0xA3);
    BOOL avi  = (b[0]=='R'&&b[1]=='I'&&b[2]=='F'&&b[3]=='F'&&b[8]=='A'&&b[9]=='V'&&b[10]=='I'&&b[11]==' ');
    BOOL mpeg = (b[0]==0x00&&b[1]==0x00&&b[2]==0x01&&(b[3]==0xBA||b[3]==0xB3));
    return iso||ebml||avi||mpeg;
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
