#import "RDLog.h"
#import <AppKit/AppKit.h>
#import <execinfo.h>
#import <limits.h>
#import <signal.h>
#import <fcntl.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

// 统一日志实现。
//
// 线程模型：所有异步写与轮转都在一个串行队列上排队，保证并发组件（下载队列 /
// 探测状态队列 / 主队列）的行不会互相穿插截断。崩溃/致命路径走 RDLogWriteSync，
// 在当前线程直接落盘 —— 进程随即结束时，队列中未执行的写会全部丢失，
// 而崩溃现场恰恰是最需要留下的那几行。
//
// 历史：ResourceDetector-download.log 是旧的仅下载日志；默认路径下首次初始化时
// 若它存在而新文件不存在，则改名迁移，保留历史并统一到单文件。

static const unsigned long long RDLogDefaultMaxBytes = 8ull * 1024 * 1024;   // 8MB
static const unsigned long long RDLogMinSizeCheckInterval = 4ull * 1024;     // 至少每 4KB 复核一次
static const unsigned long long RDLogMaxSizeCheckInterval = 64ull * 1024;    // 至多每 64KB 复核一次

// MARK: - 路径与阈值（RD_LOG_PATH / RD_LOG_MAX_BYTES 仅供测试覆盖）

static NSString *LogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        const char *override = getenv("RD_LOG_PATH");
        if (override && *override) {
            NSString *custom = [NSString stringWithUTF8String:override];
            if (custom.length) {
                // 覆盖路径（测试隔离）：不迁移旧日志、不产生任何副作用到用户日志目录
                [fm createDirectoryAtPath:custom.stringByDeletingLastPathComponent
              withIntermediateDirectories:YES attributes:nil error:nil];
                path = custom;
                return;
            }
        }
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        path = [dir stringByAppendingPathComponent:@"ResourceDetector.log"];
        NSString *legacy = [dir stringByAppendingPathComponent:@"ResourceDetector-download.log"];
        if (![fm fileExistsAtPath:path] && [fm fileExistsAtPath:legacy]) {
            [fm moveItemAtPath:legacy toPath:path error:nil];   // 迁移旧下载日志历史
        }
    });
    return path;
}

static unsigned long long LogMaxBytes(void) {
    static unsigned long long maxBytes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        maxBytes = RDLogDefaultMaxBytes;
        const char *override = getenv("RD_LOG_MAX_BYTES");
        if (override && *override) {
            long long parsed = strtoll(override, NULL, 10);
            if (parsed > 0) maxBytes = (unsigned long long)parsed;
        }
    });
    return maxBytes;
}

// 复核间隔跟随阈值缩放：小阈值（测试）下也要及时轮转，大阈值下不做无谓 stat。
static unsigned long long LogSizeCheckInterval(void) {
    unsigned long long interval = LogMaxBytes() / 4;
    if (interval < RDLogMinSizeCheckInterval) interval = RDLogMinSizeCheckInterval;
    if (interval > RDLogMaxSizeCheckInterval) interval = RDLogMaxSizeCheckInterval;
    return interval;
}

static dispatch_queue_t LogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.sevenzz.resourcedetector.log", DISPATCH_QUEUE_SERIAL);
        // 供 RDLogFlush 识别"已在日志队列上"，避免自等待死锁
        dispatch_queue_set_specific(q, (void *)&LogQueue, (void *)&LogQueue, NULL);
    });
    return q;
}

// MARK: - 行编码：绝不用 strlen(UTF8String)

// UTF8String 在含孤立代理项（非法 UTF-16）时返回 NULL，strlen(NULL) 会立即 SIGSEGV ——
// "记录错误"这个动作本身把 App 干掉；内嵌 \0 又会让 strlen 静默截断整行后半段。
// 这里统一走 NSData：长度由 data.length 给出，两种情形都不会崩溃、不会截断。
//
// 孤立代理项无法编码为 UTF-8，必须先替换成 U+FFFD 再拼行，否则整行都写不出去
// （连时间戳与组件前缀一起丢，而恰恰是这种行最需要定位）。
// 注意：不能用 canBeConvertedToEncoding: 做判断 —— 实测它对孤立代理项返回 YES，
// 会把非法串放行到后续编码步骤。这里只做纯粹的逐字符替换，代价在非法的罕见路径上。
static NSString *SanitizedForLog(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    NSUInteger i = 0, n = text.length;
    while (i < n) {
        unichar c = [text characterAtIndex:i];
        BOOL isHigh = (c >= 0xD800 && c <= 0xDBFF);
        BOOL isLow  = (c >= 0xDC00 && c <= 0xDFFF);
        if (isHigh && i + 1 < n) {
            unichar next = [text characterAtIndex:i + 1];
            if (next >= 0xDC00 && next <= 0xDFFF) {
                unichar pair[2] = {c, next};            // 合法代理对，原样保留
                [out appendString:[NSString stringWithCharacters:pair length:2]];
                i += 2;
                continue;
            }
        }
        if (!isHigh && !isLow) {
            [out appendString:[NSString stringWithCharacters:&c length:1]];
        } else {
            unichar replacement = 0xFFFD;               // 孤立代理项 → U+FFFD
            [out appendString:[NSString stringWithCharacters:&replacement length:1]];
        }
        i += 1;
    }
    return out;
}

static NSData *EncodedBytes(NSString *text) {
    // 快路径：严格编码成功即用（绝大多数行）；严格编码不给出错才做替换。
    // 长度一律取 data.length：内嵌 \0 因此不会被截断（旧实现 strlen 会在此丢半行）。
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data) return data;
    data = [SanitizedForLog(text) dataUsingEncoding:NSUTF8StringEncoding];
    if (data) return data;
    // 最后保险：正常路径不会到这里，但日志系统无论如何都不允许让调用方崩溃
    return [@"[日志行无法编码]\n" dataUsingEncoding:NSUTF8StringEncoding];
}

static void AppendData(NSData *data, NSString *path) {
    if (!data.length) return;
    FILE *f = fopen(path.fileSystemRepresentation, "ab");
    if (!f) return;
    fwrite(data.bytes, 1, data.length, f);
    fflush(f);
    fclose(f);
}

// MARK: - 时间戳（公历 + 阿拉伯数字，与系统地区无关）

static NSDateFormatter *MakeFormatter(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    // locale 必须最先设，且固定 en_US_POSIX：否则日历/数字随系统地区变
    // （泰国佛历 2569…、日本和历 0008…、阿拉伯-印度数字）。
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    f.timeZone = [NSTimeZone localTimeZone];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    return f;
}

// NSDateFormatter 非线程安全，不可跨线程共享：每个线程各自持有一个实例。
static NSString *TimestampForDate(NSDate *date) {
    static NSString *const key = @"RDLogThreadFormatter";
    NSMutableDictionary *threadData = [NSThread currentThread].threadDictionary;
    NSDateFormatter *formatter = threadData[key];
    if (!formatter) {
        formatter = MakeFormatter();
        threadData[key] = formatter;
    }
    return [formatter stringFromDate:date];
}

// MARK: - URL 脱敏
//
// 旧实现 @"https?://\S+" → "[URL redacted]" 有三个问题：
//   A 吞正文：\S+ 一直吃到空白符，"url=https://a.com/v.mp4原因：格式不支持" 会把
//     紧跟 URL 的说明一起吃掉（真实历史日志里 1048 行以 [URL redacted] 结尾，收尾括号也被吞）。
//   B 丢 host：调用方已用 RDRedactedURL() 脱敏成 https://cdn.xxx.com/[redacted] 后又被
//     本层二次抹掉，而 host 正是排查"哪条链路/哪个站点"的关键字段。
//   C 覆盖不全：rtsp/ws/wss 与无 scheme 的 host/path?token=… 完全不脱敏。
// 新策略：只保留 scheme://host，路径与查询一律 [redacted]；只吃 ASCII URL 字符，
// 遇到非 ASCII（中文说明）或空白即停，因此绝不吞掉 URL 之后的正文。

static BOOL IsTrailingURLPunctuation(unichar c) {
    switch (c) {
        case '.': case ',': case ';': case ':': case '!': case '?':
        case ')': case ']': case '}': case '>': case '"': case '\'':
            return YES;
        default:
            return NO;
    }
}

static NSString *TrimTrailingURLPunctuation(NSString *tail) {
    NSUInteger n = tail.length;
    while (n > 0 && IsTrailingURLPunctuation([tail characterAtIndex:n - 1])) n--;
    return n == tail.length ? tail : [tail substringToIndex:n];
}

// 带 scheme 的 URL：保留 scheme://host，其余以 /[redacted] 替代。
// authority 中的 userinfo（user:pass@）与端口一律丢弃，避免凭据泄漏。
static NSRegularExpression *SchemeURLPattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"\\b((?:https?|rtsps?|wss?|ftps?|sftp|ssh)://)(?:[^\\s:@/?#\\[\\]]*@)?([^\\s/?#\\[\\]:]*)([!-~]*)"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
    });
    return re;
}

// 无 scheme 的 host/path?query 形态：宿主必须真像主机名（含点）或查询串含 "="，
// 以免把正文里普通的 "a/b" 误判为 URL。
static NSRegularExpression *BareHostQueryPattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?<![\\w.@/:-])([A-Za-z0-9][A-Za-z0-9._-]*)((?:/[!-~]*)?\\?[!-~]*)"
                                                      options:0
                                                        error:nil];
    });
    return re;
}

// 授权 / 代理授权：整段替换「方案前缀 + 凭据」。
//
// 必须在普通键值规则【之前】执行：普通键值规则的值字符集在空白处停止，遇到
// "Authorization: Bearer <令牌>" 只吃掉方案词（Bearer），真令牌原地留在行尾 ——
// 行里出现了脱敏标记，看起来已经脱敏，实际凭据明文落盘，比完全不脱敏更危险。
// 把 bearer / basic 加进键列表【不能】修复此项：它们是方案前缀而不是键名
// （键列表要求键后紧跟 ':' 或 '='），只能按"可选方案前缀 + token"在这里吃掉。
//
// 值边界 = 可选的方案前缀 + 一个 token 形状的串，不吃空白：
//   "Authorization: Bearer tok 后文说明" → "Authorization: [redacted] 后文说明"（后文保留）。
// 分隔符同时接受半角 [:=] 与全角 [：]：中文输入法产出的全角冒号同样会落盘。
// 替换整体丢弃方案词与凭据，绝不产生 "[redacted] <真令牌>" 这种"只抹方案词"的退化形态。
static NSRegularExpression *AuthorizationHeaderPattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)\\b((?:proxy-)?authorization)\\b(\\s*[:=：]\\s*)"
              @"(?:[A-Za-z][A-Za-z0-9._-]*[ \\t]+)?[A-Za-z0-9._~+/=\\-]+"
                                                       options:0
                                                         error:nil];
    });
    return re;
}

// Cookie / Set-Cookie：整段替换整个 cookie 串，不依赖逐键识别。
// 逐键识别必漏："Cookie: a=1;b=机密" 里 b 不是敏感键名，只有整段替换才拦得住。
// 值边界：第一个分号段照吃；后续分号段只有在仍是"名=值"形状（cookie 对的形状）时才继续吃，
// 因此 "Cookie: SECRET2; 后续正文保留" 的后文不是 cookie 对，停在分号处不吞正文。
static NSRegularExpression *CookieHeaderPattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)\\b(set-cookie|cookie)\\b(\\s*[:=：]\\s*)[^\\s;]+(?:\\s*;\\s*[^\\s;=]+=[^\\s;]+)*"
                                                       options:0
                                                         error:nil];
    });
    return re;
}

// 裸方案前缀（没有 header 名时的 "Bearer <令牌>" / "Basic <base64>"）。
// 只吃"确定性凭据形状"：≥12 个 token 字符且至少含一个非纯字母字符（数字或 ._~+/=-）。
// 真实 JWT（含点号与数字）、base64（含 +/=/数字）都命中；正文里的
// "Basic info"（4 字母）、"Basic authentication"（14 个纯字母）不会被误判而吞掉后文。
static NSRegularExpression *BareCredentialSchemePattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)\\b(bearer|basic)[ \\t]+"
              @"(?=[A-Za-z0-9._~+/=\\-]{12,}(?![A-Za-z0-9._~+/=\\-]))"
              @"(?=[A-Za-z0-9._~+/=\\-]*[0-9._~+/=\\-])[A-Za-z0-9._~+/=\\-]+"
                                                       options:0
                                                         error:nil];
    });
    return re;
}

// 兜底：任何位置的敏感键值一律抹掉（即使 URL 形态没被上面的规则识别）。
// 键列表补齐 HTTPPrivacyPolicy.m 明确列为敏感头的 Authorization / Cookie 一族，
// 并按"长/具体 → 短/通用"排列：cookie、set-cookie、session、sessionid、sid、
// jsessionid、phpsessid、csrf、xsrf、x-auth*、proxy-authorization。
// csrf_token、xsrf_token 不能只写 csrf、xsrf：下划线也是单词字符，键名末尾的
// 单词边界不成立，必须写成 csrf 加可选分隔符再加 token（或显式列出 csrf_token）。
//
// 分隔符同时接受半角 [:=] 与全角 [：＝]：全角字符由中文输入法产出，真实会落盘。
// 保留组编号必须是 1=键、2=分隔符、3=值，替换块按此取值。
static NSRegularExpression *SecretAssignmentPattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)\\b(proxy[_-]?authorization|set-cookie|cookie|xsrf[_-]?token|csrf[_-]?token|"
              @"jsessionid|phpsessid|session[_-]?id|sessionid|session|sid|xsrf|csrf|x-auth[a-z-]*|"
              @"access[_-]?token|refresh[_-]?token|id[_-]?token|access[_-]?key|"
              @"api[_-]?key|apikey|authorization|credentials?|private[_-]?key|"
              @"signature|password|passwd|secret|token|auth|sig|hmac|pwd)\\b"
              @"(\\s*[:=：＝]\\s*)(?!\\[redacted\\](?![\\w]))([^\\s&;,'\"<>\\]]+)"
                                                      options:0
                                                        error:nil];
    });
    return re;
}

// 中文键名单独一条规则。
// 不能把中文键并进上一条：上一条全角分隔符分支一旦放宽，就没有"键名"约束可依赖，
// 无条件对全角冒号脱敏会把正常文案整句抹掉（"原因：格式不支持"、"尺寸=1920x1080"
// 都长这样）。因此这里显式列出键名，只对这些键生效。
// 中文没有可靠的 \\b 语义，用否定后顾显式排除前一个字符是汉字/字母/数字/下划线的情形，
// 避免把"输入密码"这类复合词的后半截误当键名而吞掉正文。
static NSRegularExpression *ChineseSecretKeyPattern(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?<![\\p{Han}A-Za-z0-9_])(密码|口令|密钥|令牌|凭据|签名|通行证)"
              @"(\\s*[:=：＝]\\s*)(?!\\[redacted\\](?![\\w]))([^\\s&;,'\"<>\\]]+)"
                                                      options:0
                                                        error:nil];
    });
    return re;
}

typedef NSString * _Nullable (^RDReplacementBlock)(NSTextCheckingResult *match, NSString *input);

static NSString *ApplyPattern(NSString *input, NSRegularExpression *re, RDReplacementBlock replacement) {
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:input options:0 range:NSMakeRange(0, input.length)];
    if (!matches.count) return input;
    NSMutableString *out = [input mutableCopy];
    // 逆序替换：前面的匹配区间不会因后方长度变化而失效
    for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
        NSString *rep = replacement(m, input);
        if (rep) [out replaceCharactersInRange:m.range withString:rep];
    }
    return out;
}

static NSString *RedactForLog(NSString *message) {
    if (!message.length) return message;

    // 顺序有语义，不可调换：
    //   1) Authorization / 裸方案前缀先吃掉整段凭据。若先跑普通键值规则，值字符集会在
    //      空白处停下，只抹掉方案词、真令牌留在行尾（凭据明文落盘）。
    //   2) Cookie / Set-Cookie 整段替换，不依赖逐键识别（非敏感键名里的值同样要抹）。
    //   3) 之后才是 URL 形态与兜底键值规则：此时行内已无凭据，不会与前者互相干扰。
    NSString *redacted = ApplyPattern(message, AuthorizationHeaderPattern(),
                                      ^NSString *(NSTextCheckingResult *m, NSString *input) {
        return [NSString stringWithFormat:@"%@%@[redacted]",
                [input substringWithRange:[m rangeAtIndex:1]],
                [input substringWithRange:[m rangeAtIndex:2]]];
    });

    redacted = ApplyPattern(redacted, CookieHeaderPattern(),
                            ^NSString *(NSTextCheckingResult *m, NSString *input) {
        return [NSString stringWithFormat:@"%@%@[redacted]",
                [input substringWithRange:[m rangeAtIndex:1]],
                [input substringWithRange:[m rangeAtIndex:2]]];
    });

    redacted = ApplyPattern(redacted, BareCredentialSchemePattern(),
                            ^NSString *(NSTextCheckingResult *m, NSString *input) {
        return @"[redacted]";
    });

    redacted = ApplyPattern(redacted, SchemeURLPattern(),
                                      ^NSString *(NSTextCheckingResult *m, NSString *input) {
        NSString *scheme = [input substringWithRange:[m rangeAtIndex:1]];
        NSString *host = [input substringWithRange:[m rangeAtIndex:2]];
        NSString *tail = TrimTrailingURLPunctuation([input substringWithRange:[m rangeAtIndex:3]]);
        if (!host.length) return @"[redacted]";
        return tail.length ? [NSString stringWithFormat:@"%@%@/[redacted]", scheme, host]
                           : [NSString stringWithFormat:@"%@%@", scheme, host];
    });

    redacted = ApplyPattern(redacted, BareHostQueryPattern(),
                            ^NSString *(NSTextCheckingResult *m, NSString *input) {
        NSString *host = [input substringWithRange:[m rangeAtIndex:1]];
        NSString *tail = [input substringWithRange:[m rangeAtIndex:2]];
        if ([host rangeOfString:@"."].location == NSNotFound &&
            [tail rangeOfString:@"="].location == NSNotFound) return nil;   // 不像 URL，保持原样
        return [NSString stringWithFormat:@"%@/[redacted]", host];
    });

    return ApplyPattern(ApplyPattern(redacted, ChineseSecretKeyPattern(),
                                     ^NSString *(NSTextCheckingResult *m, NSString *input) {
        return [NSString stringWithFormat:@"%@%@[redacted]",
                [input substringWithRange:[m rangeAtIndex:1]],
                [input substringWithRange:[m rangeAtIndex:2]]];
    }), SecretAssignmentPattern(),
                        ^NSString *(NSTextCheckingResult *m, NSString *input) {
        NSString *key = [input substringWithRange:[m rangeAtIndex:1]];
        NSString *separator = [input substringWithRange:[m rangeAtIndex:2]];
        return [NSString stringWithFormat:@"%@%@[redacted]", key, separator];
    });
}

// MARK: - 轮转（仅日志队列调用；只保留一代 .1）

static unsigned long long BytesSinceSizeCheck;   // 仅日志队列访问

static void RotateIfOverLimit(NSString *path) {
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attr) return;
    unsigned long long size = attr.fileSize;
    if (size < LogMaxBytes()) return;
    NSString *old = [path stringByAppendingString:@".1"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:old error:nil];                        // 只留一代
    if (![fm moveItemAtPath:path toPath:old error:nil]) return; // 移动失败则保持追加，绝不丢日志
    NSString *line = [NSString stringWithFormat:@"%@ [log] 轮转：原文件 %llu 字节 → %@\n",
                      TimestampForDate([NSDate date]), size, old.lastPathComponent];
    AppendData(EncodedBytes(line), path);
}

void RDLogRotateIfNeeded(void) {
    dispatch_async(LogQueue(), ^{
        BytesSinceSizeCheck = 0;
        RotateIfOverLimit(LogPath());
    });
}

// MARK: - 写入

static NSString *LevelMarker(RDLogLevel level) {
    switch (level) {
        case RDLogLevelError: return @"[error] ";
        case RDLogLevelWarn:  return @"[warn] ";
        case RDLogLevelInfo:  return @"";
    }
    return @"";
}

static void EmitAsync(RDLogLevel level, NSString *component, NSString *format, va_list args) {
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@%@",
                      TimestampForDate([NSDate date]), component, LevelMarker(level), RedactForLog(message)];
    NSLog(@"%@", line);
    NSData *data = EncodedBytes([line stringByAppendingString:@"\n"]);
    dispatch_async(LogQueue(), ^{
        NSString *path = LogPath();
        // 轮转在下一次写入之前判定：不重启进程也不会无界增长（旧实现只在 main 里判断一次）
        BytesSinceSizeCheck += (unsigned long long)data.length;
        if (BytesSinceSizeCheck >= LogSizeCheckInterval()) {
            BytesSinceSizeCheck = 0;
            RotateIfOverLimit(path);
        }
        AppendData(data, path);
    });
}

void RDLogWriteLevel(RDLogLevel level, NSString *component, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    EmitAsync(level, component, format, args);
    va_end(args);
}

void RDLogWrite(NSString *component, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    EmitAsync(RDLogLevelInfo, component, format, args);
    va_end(args);
}

void RDLogWriteSync(NSString *component, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [%@] [error] %@",
                      TimestampForDate([NSDate date]), component, RedactForLog(message)];
    NSLog(@"%@", line);
    // 同步写 + fsync：崩溃/致命路径返回即已落盘，进程随即结束也不丢
    NSData *data = EncodedBytes([line stringByAppendingString:@"\n"]);
    int fd = open(LogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) break;
        cursor += written;
        remaining -= (size_t)written;
    }
    fsync(fd);
    close(fd);
    // 此处不做轮转：同步路径可能在任意线程、且本就处于极端状态，
    // 由启动时的 RDLogRotateIfNeeded 与常规写入路径完成轮转。
}

void RDLogFlush(void) {
    dispatch_queue_t queue = LogQueue();
    if (dispatch_get_specific((void *)&LogQueue)) return;   // 已在日志队列上，自等待会死锁
    dispatch_sync(queue, ^{});
}

NSString *RDLogFilePath(void) {
    return LogPath();
}

// MARK: - 硬崩溃兜底（异步信号安全：只 open/write/fsync/close，不分配、不调 ObjC）

static char FatalSignalLogPath[PATH_MAX];
static volatile sig_atomic_t FatalSignalHandlersInstalled;
static int FatalSignalBacktraceEnabled;

static const char *SignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default:      return "SIGUNKNOWN";
    }
}

static size_t AppendLiteral(char *buffer, size_t offset, size_t capacity, const char *text) {
    while (*text && offset < capacity) buffer[offset++] = *text++;
    return offset;
}

static size_t AppendSigned(char *buffer, size_t offset, size_t capacity, long value) {
    char digits[24];
    int count = 0;
    if (value < 0) {
        if (offset < capacity) buffer[offset++] = '-';
        value = -value;
    }
    if (value == 0) digits[count++] = '0';
    while (value > 0) { digits[count++] = (char)('0' + (value % 10)); value /= 10; }
    while (count > 0 && offset < capacity) buffer[offset++] = digits[--count];
    return offset;
}

static size_t AppendHex(char *buffer, size_t offset, size_t capacity, unsigned long value) {
    char digits[20];
    int count = 0;
    if (value == 0) digits[count++] = '0';
    while (value > 0) {
        unsigned long nibble = value & 0xF;
        digits[count++] = (char)(nibble < 10 ? '0' + nibble : 'a' + (nibble - 10));
        value >>= 4;
    }
    while (count > 0 && offset < capacity) buffer[offset++] = digits[--count];
    return offset;
}

static void WriteAllFd(int fd, const char *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written <= 0) return;
        bytes += written;
        length -= (size_t)written;
    }
}

static void FatalSignalHandler(int sig, siginfo_t *info, void *context) {
    (void)context;
    char buffer[512];
    size_t offset = 0;
    offset = AppendLiteral(buffer, offset, sizeof(buffer), "[crash] 致命信号 ");
    offset = AppendSigned(buffer, offset, sizeof(buffer), (long)sig);
    offset = AppendLiteral(buffer, offset, sizeof(buffer), " (");
    offset = AppendLiteral(buffer, offset, sizeof(buffer), SignalName(sig));
    offset = AppendLiteral(buffer, offset, sizeof(buffer), ") 出错地址=0x");
    offset = AppendHex(buffer, offset, sizeof(buffer),
                       (unsigned long)(uintptr_t)(info ? info->si_addr : NULL));
    offset = AppendLiteral(buffer, offset, sizeof(buffer), " 时间(epoch)=");
    offset = AppendSigned(buffer, offset, sizeof(buffer), (long)time(NULL));

    int fd = open(FatalSignalLogPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        offset = AppendLiteral(buffer, offset, sizeof(buffer), "\n");
        // 主记录先落盘：即便后续取样卡住，崩溃事实与信号号也已持久化
        WriteAllFd(fd, buffer, offset);
        fsync(fd);
        if (FatalSignalBacktraceEnabled) {
            void *frames[32];
            int count = backtrace(frames, 32);
            char frameBuffer[512];
            for (int i = 0; i < count && i < 8; i++) {
                size_t frameOffset = 0;
                frameOffset = AppendLiteral(frameBuffer, frameOffset, sizeof(frameBuffer), "[crash]   回溯 0x");
                frameOffset = AppendHex(frameBuffer, frameOffset, sizeof(frameBuffer),
                                        (unsigned long)(uintptr_t)frames[i]);
                frameOffset = AppendLiteral(frameBuffer, frameOffset, sizeof(frameBuffer), "\n");
                WriteAllFd(fd, frameBuffer, frameOffset);
            }
            fsync(fd);
        }
        close(fd);
    }
    // 恢复默认动作后重新送达：系统崩溃报告与原始退出码语义保持不变
    struct sigaction defaultAction;
    memset(&defaultAction, 0, sizeof(defaultAction));
    defaultAction.sa_handler = SIG_DFL;
    sigemptyset(&defaultAction.sa_mask);
    sigaction(sig, &defaultAction, NULL);
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, sig);
    sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    raise(sig);
}

void RDLogInstallCrashHandlers(void) {
    if (FatalSignalHandlersInstalled) return;
    FatalSignalHandlersInstalled = 1;
    const char *backtraceEnv = getenv("RD_LOG_CRASH_BACKTRACE");
    FatalSignalBacktraceEnabled = (backtraceEnv && *backtraceEnv && strcmp(backtraceEnv, "0") != 0);
    strlcpy(FatalSignalLogPath, LogPath().fileSystemRepresentation, sizeof(FatalSignalLogPath));

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = FatalSignalHandler;
    action.sa_flags = SA_SIGINFO;    // 不设 SA_NODEFER：默认屏蔽同类信号，避免处理中反复重入
    sigemptyset(&action.sa_mask);
    // 只捕获真正的致命崩溃信号。SIGTRAP 故意不在此列：它常被调试器断点与 JIT
    // 用作正常控制流，捕获它只会产生误导性的 "崩溃" 日志。
    const int signals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        if (sigaction(signals[i], &action, NULL) == 0) {
            sigaddset(&action.sa_mask, signals[i]);   // 处理某信号时同时屏蔽其余致命信号
        }
    }
}

// MARK: - 访达与诊断包

void RDLogRevealInFinder(void) {
    NSString *path = LogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    // createFileAtPath:contents:nil 对已存在的文件会把内容截断为 0（不是"仅当不存在才创建"）。
    // 用户点一次「打开日志」就清空一次全部日志，这里必须显式判存在。
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:[NSData data] attributes:nil];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

NSString * _Nullable RDLogExportDiagnostics(NSString *appVersion, NSError * _Nullable *error) {
    RDLogFlush();   // 先排空日志队列，否则刚发生的错误（最需要的那些行）会缺在包里

    NSDateFormatter *df = MakeFormatter();
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [df stringFromDate:[NSDate date]];
    // 导出根目录默认是桌面；RD_LOG_EXPORT_DIR 仅供测试指向临时目录
    // （NSHomeDirectory() 走 getpwuid，不受 HOME 影响，无法靠 HOME 隔离）。
    NSString *exportRoot = nil;
    const char *exportOverride = getenv("RD_LOG_EXPORT_DIR");
    if (exportOverride && *exportOverride) {
        exportRoot = [NSString stringWithUTF8String:exportOverride];
    }
    if (!exportRoot.length) {
        exportRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    }
    NSString *dir = [exportRoot stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"资源探测诊断-%@", stamp]];
    NSError *mkErr = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
        if (error) *error = mkErr;
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *log = LogPath();
    NSString *zone = [NSTimeZone localTimeZone].name ?: @"未知时区";
    NSMutableString *info = [NSMutableString string];
    [info appendFormat:@"应用版本：%@（CODE_LINES/FIX_ROUND 由构建期生成）\n", appVersion ?: @"未知"];
    [info appendFormat:@"导出时间：%@（本地时间 %@）\n", stamp, zone];
    [info appendFormat:@"日志文件：%@\n", RDLogFilePath()];
    [info appendFormat:@"日志阈值：%llu 字节（超过则轮转为 .1，只保留一代）\n", LogMaxBytes()];
    [info appendFormat:@"说明：ResourceDetector.log 为全组件统一日志（[dl]=下载 [probe]=探测 "
                      @"[meta]=元数据 [app]=应用 [crash]=崩溃 [diag]=诊断 [log]=日志系统）；"
                      @"error/warn 级在组件后带 [error]/[warn] 标记。\n"];
    [info appendString:@"下载记录：见应用偏好域 CompletedResourceURLs / InterruptedDownloadJobs（不随诊断包导出，避免体积过大）。\n"];
    [info writeToFile:[dir stringByAppendingPathComponent:@"诊断信息.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // 先写"导出"这一行并排空，再复制：导出包里的日志与源文件逐行一致
    // （包含本次导出自身的记录），不会出现"最需要的最后几行恰好不在包里"。
    RDLogWrite(@"diag", @"导出诊断包 → %@", dir);
    RDLogFlush();

    if ([fm fileExistsAtPath:log]) {
        [fm copyItemAtPath:log toPath:[dir stringByAppendingPathComponent:log.lastPathComponent] error:nil];
    }
    NSString *rotated = [log stringByAppendingString:@".1"];
    if ([fm fileExistsAtPath:rotated]) {
        [fm copyItemAtPath:rotated toPath:[dir stringByAppendingPathComponent:rotated.lastPathComponent] error:nil];
    }
    return dir;
}
