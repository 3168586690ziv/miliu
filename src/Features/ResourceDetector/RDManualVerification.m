//
//  RDManualVerification.m — hotfix-resource-manual-verification-resume-01
//
//  网页资源探测「用户手动完成人机验证后继续探测」的生产逻辑实现。
//  接口声明见 RDManualVerification.h（设计红线见头文件）。
//  本文件从 App/SevenZZToolbox.m 原样迁出（2026-08-12，commit 基线后），
//  未改动任何算法、文案或业务行为。
//

#import "RDManualVerification.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - RDVerificationDetector（hotfix-resource-manual-verification-resume-01）

@implementation RDVerificationDetector

+ (NSArray<NSString *> *)rd_strongSignals {
    return @[@"captcha",
             @"verify you are human",
             @"人机验证",
             @"请完成验证",
             @"安全验证",
             @"security check"];
}

+ (NSArray<NSString *> *)rd_accessDeniedCompanions {
    return @[@"verify",
             @"human",
             @"browser",
             @"checking",
             @"challenge",
             @"robot",
             @"captcha",
             @"security check"];
}

+ (BOOL)pageRequiresHumanVerificationWithHTML:(NSString * _Nullable)html
                                        title:(NSString * _Nullable)title
                                httpStatusCode:(NSInteger)statusCode {
    (void)statusCode;
    NSString *h = html ?: @"";
    NSString *t = title ?: @"";
    NSString *combined = [[h stringByAppendingString:@" "] stringByAppendingString:t];
    NSString *lower = [combined lowercaseString];
    if (lower.length == 0) return NO;

    for (NSString *sig in [self rd_strongSignals]) {
        if ([lower containsString:sig]) return YES;
    }

    if ([lower containsString:@"access denied"]) {
        for (NSString *c in [self rd_accessDeniedCompanions]) {
            if ([lower containsString:c]) return YES;
        }
    }
    return NO;
}

+ (NSString *)localizedReasonForVerificationPageWithHTML:(NSString * _Nullable)html
                                                   title:(NSString * _Nullable)title {
    NSString *h = html ?: @"";
    NSString *t = title ?: @"";
    NSString *combined = [[h stringByAppendingString:@" "] stringByAppendingString:t];
    NSString *lower = [combined lowercaseString];

    if ([lower containsString:@"security check"]) {
        return @"检测到 Security Check 页面，请手动完成验证后继续。";
    }
    if ([lower containsString:@"人机验证"]) {
        return @"检测到“人机验证”页面，请手动完成验证后继续。";
    }
    if ([lower containsString:@"请完成验证"]) {
        return @"检测到需要完成验证的页面，请手动完成验证后继续。";
    }
    if ([lower containsString:@"安全验证"]) {
        return @"检测到“安全验证”页面，请手动完成验证后继续。";
    }
    if ([lower containsString:@"verify you are human"]) {
        return @"检测到“Verify you are human”页面，请手动完成验证后继续。";
    }
    if ([lower containsString:@"captcha"]) {
        return @"检测到验证码（CAPTCHA）页面，请手动完成验证后继续。";
    }
    if ([lower containsString:@"access denied"]) {
        return @"检测到访问被拦截的验证页面，请手动完成验证后继续。";
    }
    return @"检测到需要手动安全验证的页面，请手动完成验证后继续。";
}

@end

#pragma mark - RDManualVerificationController（hotfix-resource-manual-verification-resume-01）

@interface RDManualVerificationController ()
@property (nonatomic, assign, readwrite) NSUInteger resumeCallCount;
@property (nonatomic, assign, readwrite) NSUInteger actualResumeCount;
@end

@implementation RDManualVerificationController

- (instancetype)init {
    self = [super init];
    if (self) {
        _resumeCallCount = 0;
        _actualResumeCount = 0;
        _isPresenting = NO;
        _verificationPresent = NO;
    }
    return self;
}

- (void)prepareVerificationForURL:(NSString *)url dataStore:(WKWebsiteDataStore *)store {
    self.pendingURL = [url copy];
    self.sharedDataStore = store;
    self.isPresenting = YES;
    self.verificationPresent = YES;
}

- (WKWebViewConfiguration *)verificationWebViewConfiguration {
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    if (self.sharedDataStore) {
        cfg.websiteDataStore = self.sharedDataStore;
    }
    return cfg;
}

- (void)attachVerificationWindow:(NSWindow *)window webView:(WKWebView *)webView {
    self.verificationWindow = window;
    self.verificationWebView = webView;
}

- (BOOL)verificationStillPresentInWebView:(WKWebView * _Nullable)webView {
    (void)webView;
    return self.verificationPresent;
}

- (BOOL)resumeAfterVerification {
    self.resumeCallCount++;
    if (!self.isPresenting) return NO;
    if ([self verificationStillPresentInWebView:self.verificationWebView]) {
        return NO;
    }
    self.actualResumeCount++;
    self.isPresenting = NO;
    NSString *url = [self.pendingURL copy];
    [self closeVerificationWindowInternal];
    if (self.resumeHandler && url) {
        self.resumeHandler(url);
    }
    return YES;
}

- (void)cancelManualVerification {
    [self closeVerificationWindowInternal];
    self.pendingURL = nil;
    self.isPresenting = NO;
}

- (void)cleanupManualVerification {
    [self closeVerificationWindowInternal];
    self.pendingURL = nil;
    self.isPresenting = NO;
    self.verificationPresent = NO;
}

- (void)closeVerificationWindowInternal {
    if (self.verificationWebView) {
        [self.verificationWebView stopLoading];
    }
    if (self.verificationWindow) {
        [self.verificationWindow close];
    }
    self.verificationWebView = nil;
    self.verificationWindow = nil;
}


@end

NS_ASSUME_NONNULL_END
