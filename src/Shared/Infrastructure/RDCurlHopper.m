//
//  RDCurlHopper.m — curl 按跳传输引擎实现
//

#import "RDCurlHopper.h"
#import "DNSResolver.h"
#import "RDLog.h"
#import "URLPolicy.h"

NSString * const RDCurlHopErrorDomain = @"RDCurlHop";

// 跳数上限与原生传输一致（RDMetadataTransfer 的 ++_redirects > 5）。
static const NSUInteger kRDCurlHopMaxHops = 5;
static const NSTimeInterval kRDCurlHopMinHopTimeout = 1.0;

static NSError *RDCurlHopMakeError(RDCurlHopError code) {
    return [NSError errorWithDomain:RDCurlHopErrorDomain code:code userInfo:nil];
}

@implementation RDCurlHopResult
@end

@implementation RDCurlHopper {
    NSLock *_lock;
    NSTask *_task;
    BOOL _cancelled;
}

- (instancetype)init {
    if ((self = [super init])) {
        _curlPath = @"/usr/bin/curl";
        _logComponent = @"meta";
        _lock = [NSLock new];
    }
    return self;
}

- (void)cancel {
    [_lock lock];
    _cancelled = YES;
    NSTask *task = _task;
    [_lock unlock];
    if (task && task.isRunning) [task terminate];
}

- (void)walkURL:(NSURL *)url
         method:(NSString *)method
        headers:(NSDictionary<NSString *, NSString *> *)headers
         budget:(NSUInteger)budget
       deadline:(CFAbsoluteTime)deadline
     bodyToFile:(BOOL)bodyToFile
     completion:(void (^)(RDCurlHopResult *))completion {
    NSAssert(method.length, @"method required");
    [self hopWithURL:url method:method headers:headers ?: @{} budget:budget
            deadline:deadline hop:0 previousURL:nil bodyToFile:bodyToFile completion:completion];
}

// 逐跳执行；每个出口路径都必须调用 completion。
- (void)hopWithURL:(NSURL *)url method:(NSString *)method headers:(NSDictionary *)headers budget:(NSUInteger)budget
          deadline:(CFAbsoluteTime)deadline hop:(NSUInteger)hop previousURL:(nullable NSURL *)previousURL
        bodyToFile:(BOOL)bodyToFile completion:(void (^)(RDCurlHopResult *))completion {
    [_lock lock];
    BOOL cancelled = _cancelled;
    [_lock unlock];
    if (cancelled) { completion([self unresolvedResult]); return; }
    if (hop > kRDCurlHopMaxHops) { completion([self unresolvedResult]); return; }
    NSTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
    if (remaining < kRDCurlHopMinHopTimeout) { completion([self unresolvedResult]); return; }

    // 每一跳（含首跳）都重查策略：封死"原生阶段 DNS busy / 目标未校验也借道 curl"的旁路。
    NSError *policyError = nil;
    if (![self validateHopURL:url redirectFrom:previousURL error:&policyError]) {
        RDCurlHopResult *result = [RDCurlHopResult new];
        result.error = policyError;
        completion(result);
        return;
    }

    NSString *stamp = NSUUID.UUID.UUIDString;
    NSString *headerFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rd-curl-%@.headers", stamp]];
    NSString *bodyFile = self.bodyFilePath ?: [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rd-curl-%@.body", stamp]];

    NSMutableArray<NSString *> *argv = [NSMutableArray array];
    [argv addObject:self.curlPath];
    [argv addObjectsFromArray:@[@"-sS", @"-D", headerFile, @"-o", bodyFile]];
    [argv addObjectsFromArray:@[@"--connect-timeout", @"10",
                                 @"--max-time", [NSString stringWithFormat:@"%.2f", remaining]]];
    if (budget > 0 && ![method isEqual:@"HEAD"]) {
        [argv addObjectsFromArray:@[@"--max-filesize", [NSString stringWithFormat:@"%lu", (unsigned long)budget]]];
    }
    if ([method isEqual:@"HEAD"]) [argv addObject:@"-I"];
    for (NSString *key in headers) {
        NSString *value = headers[key];
        if (![value isKindOfClass:[NSString class]] || !value.length) continue;
        [argv addObjectsFromArray:@[@"-H", [NSString stringWithFormat:@"%@: %@", key, value]]];
    }
    [argv addObject:url.absoluteString];

    NSInteger exitCode;
    if (self.runner) {
        exitCode = self.runner(argv, headerFile, bodyFile);
    } else {
        exitCode = [self launchCurlWithArgv:argv];
    }
    if (exitCode != 0) {
        RDLogWriteLevel(RDLogLevelWarn, self.logComponent,
                        @"curl 跳未成功 exit=%ld host=%@ hop=%lu", (long)exitCode, url.host ?: @"-", (unsigned long)hop);
        [self cleanupFiles:@[ headerFile, bodyFile ]];
        completion([self unresolvedResult]);
        return;
    }

    NSInteger status = 0;
    NSString *httpVersion = nil;
    NSDictionary *hopHeaders = nil;
    if (![self parseHeaderFile:headerFile status:&status httpVersion:&httpVersion headers:&hopHeaders]) {
        [self cleanupFiles:@[ headerFile, bodyFile ]];
        completion([self unresolvedResult]);
        return;
    }

    // 3xx：解析 Location → 校验 → 下一跳；无 Location = 失败。
    if (status >= 300 && status < 400) {
        NSString *location = [self headerValue:hopHeaders name:@"Location"];
        NSURL *target = location.length ? [NSURL URLWithString:location relativeToURL:url] : nil;
        [self cleanupFiles:@[ headerFile, bodyFile ]];
        if (!target) {
            RDLogWriteLevel(RDLogLevelWarn, self.logComponent,
                            @"curl 跳 %ld 缺 Location host=%@", (long)status, url.host ?: @"-");
            completion([self unresolvedResult]);
            return;
        }
        RDLogWrite(self.logComponent, @"curl 跳 host=%@ status=%ld → 校验下一跳", url.host ?: @"-", (long)status);
        [self hopWithURL:target method:method headers:headers budget:budget deadline:deadline
                      hop:hop + 1 previousURL:url bodyToFile:bodyToFile completion:completion];
        return;
    }

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:(NSInteger)status
                                                            HTTPVersion:httpVersion ?: @"HTTP/1.1"
                                                           headerFields:hopHeaders];
    RDCurlHopResult *result = [RDCurlHopResult new];
    result.response = response;
    if (status < 200 || status >= 300) {
        [self cleanupFiles:@[ headerFile, bodyFile ]];
        result.error = RDCurlHopMakeError(RDCurlHopHTTPFailure);
        RDLogWriteLevel(RDLogLevelWarn, self.logComponent,
                        @"curl 终跳非 2xx host=%@ status=%ld", url.host ?: @"-", (long)status);
        completion(result);
        return;
    }

    if (bodyToFile) {
        [self cleanupFiles:@[ headerFile ]];
        result.bodyFile = bodyFile;
        RDLogWrite(self.logComponent, @"curl 终跳成功 host=%@ status=%ld 写入=%@", url.host ?: @"-", (long)status, bodyFile.lastPathComponent);
        completion(result);
        return;
    }

    NSData *body = [NSData dataWithContentsOfFile:bodyFile];
    [self cleanupFiles:@[ headerFile, bodyFile ]];
    if (!body) body = [NSData data];
    if (budget > 0 && body.length > budget) {
        result.error = RDCurlHopMakeError(RDCurlHopBudgetExceeded);
        RDLogWriteLevel(RDLogLevelWarn, self.logComponent,
                        @"curl 响应体超预算 host=%@ %lu > %lu", url.host ?: @"-",
                        (unsigned long)body.length, (unsigned long)budget);
        completion(result);
        return;
    }
    result.body = body;
    RDLogWrite(self.logComponent, @"curl 终跳成功 host=%@ status=%ld 已收=%lu 字节",
               url.host ?: @"-", (long)status, (unsigned long)body.length);
    completion(result);
}

- (RDCurlHopResult *)unresolvedResult {
    RDCurlHopResult *result = [RDCurlHopResult new];
    result.error = RDCurlHopMakeError(RDCurlHopUnresolved);
    return result;
}

- (NSInteger)launchCurlWithArgv:(NSArray<NSString *> *)argv {
    [_lock lock];
    if (_cancelled) { [_lock unlock]; return -1; }
    NSTask *task = [NSTask new];
    task.launchPath = self.curlPath;
    // NSTask 的 arguments 不含可执行名（argv[0] 由系统填入）。runner 契约里 argv
    // 首元素是 curlPath，这里必须剥掉，否则 curl 把路径当成第一个 URL：-o 被
    // 第一个（失败的）传输吃掉，真实 URL 的响应体会落到继承来的 stdout 上。
    task.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
    task.standardError = [NSPipe pipe];
    _task = task;
    [_lock unlock];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return -1;   // curl 不可执行
    }
    [_lock lock];
    _task = nil;
    [_lock unlock];
    return task.terminationStatus;
}

// 与 RDMetadataTransfer.validate: / DownloadManager 的下载层防线同一策略：
// 文本校验 →（重定向时校验跳转合法性）→ DNS 解析后全 IP 校验，fail-closed。
- (BOOL)validateHopURL:(NSURL *)url redirectFrom:(nullable NSURL *)from error:(NSError **)err {
    URLPolicy *policy = [URLPolicy new];
    if (from && ![[policy evaluateRedirect:url fromURL:from] allowed]) {
        if (err) *err = RDCurlHopMakeError(RDCurlHopBlocked);
        return NO;
    }
    if (![policy evaluateTextURL:url.absoluteString].allowed || !url.host.length || url.user.length || url.password.length) {
        if (err) *err = RDCurlHopMakeError(RDCurlHopBlocked);
        return NO;
    }
    DNSResolutionStatus status = DNSResolutionSucceeded;
    NSArray<NSString *> *ips = self.resolver ? self.resolver(url.host) : [DNSResolver resolveIPsForHost:url.host status:&status];
    URLPolicyDecision *decision = [policy evaluateResolvedURL:url resolvedIPs:ips resolutionStatus:status];
    if (decision.verdict == URLPolicyBlockedDNSBusy || decision.verdict == URLPolicyBlockedDNSTimeout) {
        if (err) *err = RDCurlHopMakeError(RDCurlHopTimedOut);
        return NO;
    }
    if (!decision.allowed) {
        if (err) *err = RDCurlHopMakeError(RDCurlHopBlocked);
        return NO;
    }
    return YES;
}

// curl -D 转储可能含 100-continue 等多块：取最后一个 "HTTP/" 状态行块。
- (BOOL)parseHeaderFile:(NSString *)path status:(NSInteger *)status httpVersion:(NSString **)httpVersion headers:(NSDictionary **)outHeaders {
    NSString *text = [[NSString alloc] initWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                     ?: [[NSString alloc] initWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil];
    if (!text.length) return NO;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSInteger lastBlockStart = -1;
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        if ([lines[i] hasPrefix:@"HTTP/"]) lastBlockStart = i;
    }
    if (lastBlockStart < 0) return NO;
    NSArray<NSString *> *parts = [lines[lastBlockStart] componentsSeparatedByString:@" "];
    if (parts.count < 2) return NO;
    NSInteger parsed = [parts[1] integerValue];
    if (parsed <= 0) return NO;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = (NSUInteger)lastBlockStart + 1; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) break;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) continue;
        NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!key.length) continue;
        headers[key] = value;
    }
    if (status) *status = parsed;
    if (httpVersion) *httpVersion = parts[0];
    if (outHeaders) *outHeaders = headers;
    return YES;
}

- (nullable NSString *)headerValue:(NSDictionary *)headers name:(NSString *)name {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
    }
    return nil;
}

- (void)cleanupFiles:(NSArray<NSString *> *)paths {
    for (NSString *p in paths) [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
}

@end
