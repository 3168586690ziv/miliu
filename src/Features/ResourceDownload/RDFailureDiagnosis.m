//
//  RDFailureDiagnosis.m
//  Miliu
//

#import "RDFailureDiagnosis.h"

static BOOL RDContainsAny(NSString *haystack, NSArray<NSString *> *needles) {
    if (!haystack.length) return NO;
    for (NSString *needle in needles) {
        if (needle.length && [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

RDFailureDiagnosis RDDiagnoseFailure(NSString *reason, NSInteger statusCode) {
    NSString *text = reason ?: @"";

    // ① 磁盘：本地可立即解决，优先级最高（其它重试都会继续失败）。
    if (RDContainsAny(text, @[@"磁盘", @"空间不足", @"No space left", @"disk full", @"os error 28"])) {
        return (RDFailureDiagnosis){ @"disk_full", RDFailureActionFreeDiskSpace };
    }

    // ② 登录/权限：比 403 指纹更具体，必须先判——否则用户被指去「刷新链接」，
    //    刷十次也刷不出登录态。
    if (RDContainsAny(text, @[@"需要登录", @"登录后", @"会员", @"私有", @"仅限", @"签名校验",
                              @"401", @"Unauthorized", @"login", @"sign in", @"members-only",
                              @"private video", @"auth"])) {
        return (RDFailureDiagnosis){ @"needs_sign_in", RDFailureActionSignIn };
    }

    // ③ 链接失效：404/410 与「链接已过期」类文案 → 重新探测拿新签名。
    if (statusCode == 404 || statusCode == 410 ||
        RDContainsAny(text, @[@"410", @"404", @"链接失效", @"链接已过期", @"已失效", @"找不到资源"])) {
        return (RDFailureDiagnosis){ @"link_expired", RDFailureActionRefreshLink };
    }

    // ④ 反爬 / 限流：等一等比立刻重试有效，避免把封禁拖长。
    if (statusCode == 429 || statusCode == 503 || statusCode == 509 ||
        RDContainsAny(text, @[@"429", @"503", @"509", @"限流", @"频繁", @"too many", @"rate limit",
                              @"校验失败", @"cloudflare", @"人机"])) {
        return (RDFailureDiagnosis){ @"rate_limited", RDFailureActionWaitAndRetry };
    }

    // ⑤ 403：既可能是指纹拦截，也可能是链接签名过期。两者都靠重新获取链接解决，
    //    但文案要区分——所以单独一个原因键。
    if (statusCode == 403 || RDContainsAny(text, @[@"403", @"Forbidden", @"拒绝访问"])) {
        return (RDFailureDiagnosis){ @"forbidden", RDFailureActionRefreshLink };
    }

    // ⑥ 传输截断 / 网络瞬断：直接重试。
    if (RDContainsAny(text, @[@"不完整", @"截断", @"超时", @"timed out", @"网络", @"连接",
                              @"DNS", @"解析超时", @"无法连接", @"网络波动", @"传输"])) {
        return (RDFailureDiagnosis){ @"transient_network", RDFailureActionRetry };
    }

    // ⑦ 内容不是媒体：链接被换成 HTML/错误页，重新探测比原地重试有意义。
    if (RDContainsAny(text, @[@"不是视频", @"不是有效视频", @"网页/错误页", @"格式不支持",
                              @"MIME", @"内容不是"])) {
        return (RDFailureDiagnosis){ @"not_media", RDFailureActionRefreshLink };
    }

    // 未知：不编原因，也不编动作。
    return (RDFailureDiagnosis){ nil, RDFailureActionNone };
}

NSString *RDFailureActionText(RDFailureAction action) {
    switch (action) {
        case RDFailureActionRefreshLink: return @"点「重试」重新获取下载链接";
        case RDFailureActionRetry:       return @"点「重试」再下一次";
        case RDFailureActionSignIn:      return @"在设置里导入浏览器登录态，或先用应用内浏览器登录该站";
        case RDFailureActionFreeDiskSpace: return @"清理磁盘空间后点「重试」";
        case RDFailureActionWaitAndRetry: return @"等几分钟再点「重试」（站点正在限流）";
        case RDFailureActionNone:        return @"";
    }
    return @"";
}

NSString *RDFailureMessageWithAdvice(NSString *reason, NSInteger statusCode) {
    NSString *base = reason.length ? reason : @"下载失败";
    RDFailureDiagnosis diagnosis = RDDiagnoseFailure(base, statusCode);
    NSString *advice = RDFailureActionText(diagnosis.action);
    if (!advice.length) return base;
    return [NSString stringWithFormat:@"%@ · 建议：%@", base, advice];
}

NSString *RDFailureTextTruncatedToWidth(NSString *text, CGFloat budget, RDFailureTextMeasure measure) {
    if (!text.length || !measure || budget <= 0) return @"";
    if (measure(text) <= budget) return text;
    // 按字素（grapheme）从尾部一个个摘，绝不按 UTF-16 下标切——那会把 emoji
    // 的代理对切成孤立半字，在 NSTextField 里显示成方框。
    NSMutableArray<NSString *> *graphemes = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *part, NSRange r, NSRange e, BOOL *stop) {
        if (part.length) [graphemes addObject:part];
    }];
    NSInteger count = (NSInteger)graphemes.count;
    while (count > 0) {
        count -= 1;
        NSString *candidate = [[graphemes subarrayWithRange:NSMakeRange(0, (NSUInteger)count)] componentsJoinedByString:@""];
        if (measure(candidate) <= budget) return candidate;
    }
    return @"";
}

NSString *RDFailureTextFitted(NSString *reason, NSInteger statusCode, CGFloat maxWidth,
                              RDFailureTextMeasure measure) {
    NSString *full = RDFailureMessageWithAdvice(reason, statusCode);
    if (!measure || maxWidth <= 0) return full;
    if (measure(full) <= maxWidth) return full;

    NSString *base = reason.length ? reason : @"下载失败";
    NSString *advice = RDFailureActionText(RDDiagnoseFailure(base, statusCode).action);
    if (!advice.length) {
        // 没有建议可保：退回对原文本身做字素截断（行为与旧的尾部截断一致，
        // 但不会切坏 emoji）。
        return RDFailureTextTruncatedToWidth(full, maxWidth, measure);
    }

    NSString *separator = @" · 建议：";
    NSString *adviceOnly = [separator stringByAppendingString:advice];
    CGFloat adviceWidth = measure(adviceOnly);
    if (adviceWidth >= maxWidth) {
        // 连「· 建议：X」都放不下：只显示建议正文——动作比复述原因有用。
        return RDFailureTextTruncatedToWidth(advice, maxWidth, measure);
    }
    // 关键细节（实测踩到）：分段测量之和 ≠ 拼接后的宽度——字距（kerning）
    // 与跨字素整形会让拼接结果比两段之和宽 1px 量级，于是「按预算刚好塞下」
    // 仍会溢出。所以这里**对拼接结果整体复测**，超了就再摘一个尾部字素，
    // 直到放得下为止（有界：最多摘到空）。
    NSMutableArray<NSString *> *graphemes = [NSMutableArray array];
    [base enumerateSubstringsInRange:NSMakeRange(0, base.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *part, NSRange r, NSRange e, BOOL *stop) {
        if (part.length) [graphemes addObject:part];
    }];
    NSString *trimmedAdvice = [adviceOnly stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSInteger count = (NSInteger)graphemes.count; count > 0; count--) {
        NSString *shortReason = [[graphemes subarrayWithRange:NSMakeRange(0, (NSUInteger)count)]
                                 componentsJoinedByString:@""];
        NSString *candidate = [shortReason stringByAppendingString:adviceOnly];
        if (measure(candidate) <= maxWidth) return candidate;
    }
    return trimmedAdvice;
}
