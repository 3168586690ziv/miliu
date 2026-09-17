#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import "WebProbe.h"

// Test-only delegate proxy trusts exactly this run's generated loopback CA.
// SecTrust still verifies certificate chain, validity and the original hostname.
// No keychain installation, global trust changes, or unconditional trust bypass.
@interface FixtureDelegate : NSObject <WKNavigationDelegate>
@property(weak) id target;
@end
@implementation FixtureDelegate
- (BOOL)respondsToSelector:(SEL)selector {return [super respondsToSelector:selector]||[self.target respondsToSelector:selector];}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {return [super methodSignatureForSelector:selector]?:[self.target methodSignatureForSelector:selector];}
- (void)forwardInvocation:(NSInvocation *)invocation {[invocation invokeWithTarget:self.target];}
- (void)webView:(WKWebView *)view didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))done {
    if([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]&&[challenge.protectionSpace.host isEqual:@"127.0.0.1"]){
        NSData *data=[NSData dataWithContentsOfFile:NSProcessInfo.processInfo.environment[@"RD_WEBKIT_CA"]];
        SecCertificateRef anchor=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)data);
        SecTrustRef trust=challenge.protectionSpace.serverTrust;
        SecPolicyRef policy=SecPolicyCreateSSL(true,CFSTR("127.0.0.1"));
        BOOL valid=anchor&&trust;
        if(valid){valid=SecTrustSetPolicies(trust,policy)==errSecSuccess&&SecTrustSetAnchorCertificates(trust,(__bridge CFArrayRef)@[(__bridge id)anchor])==errSecSuccess&&SecTrustSetAnchorCertificatesOnly(trust,true)==errSecSuccess&&SecTrustEvaluateWithError(trust,NULL);}
        if(anchor)CFRelease(anchor);CFRelease(policy);
        printf("FIXTURE_TLS_IDENTITY_VERIFIED=%s\n",valid?"YES":"NO");
        done(valid?NSURLSessionAuthChallengeUseCredential:NSURLSessionAuthChallengeCancelAuthenticationChallenge,valid?[NSURLCredential credentialForTrust:trust]:nil);return;
    }
    done(NSURLSessionAuthChallengePerformDefaultHandling,nil);
}
@end
@interface FixtureWebView : WKWebView
@property FixtureDelegate *fixtureDelegate;
@end
@implementation FixtureWebView
- (void)setNavigationDelegate:(id<WKNavigationDelegate>)delegate {
    if(!delegate){self.fixtureDelegate=nil;[super setNavigationDelegate:nil];return;}
    self.fixtureDelegate=[FixtureDelegate new];self.fixtureDelegate.target=delegate;
    [super setNavigationDelegate:self.fixtureDelegate];
}
@end
@interface FixtureFactory : NSObject <RDProbeWebViewFactory> @end
@implementation FixtureFactory
- (id<RDProbeWebView>)makeWebViewWithConfiguration:(WKWebViewConfiguration *)cfg {return (id)[[FixtureWebView alloc]initWithFrame:NSZeroRect configuration:cfg];}
@end
@interface LoopbackNavigationPolicy : URLPolicy
@property NSSet *ports;
@property NSMutableArray *paths;
@end
@implementation LoopbackNavigationPolicy
- (URLPolicyDecision *)evaluateTextURL:(NSString *)text {
    NSURL *url=[NSURL URLWithString:text];
    if([url.host isEqual:@"127.0.0.1"]&&[self.ports containsObject:url.port]&&[@[@"http",@"https"]containsObject:url.scheme]&&!url.user&&!url.password)return [URLPolicyDecision allow];
    return [super evaluateTextURL:text];
}
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray *)ips {return [self evaluateTextURL:url.absoluteString];}
- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)source {
    [self.paths addObject:target.path ?: @""];
    printf("POLICY_REDIRECT from=%s target=%s\n",source.absoluteString.UTF8String,target.absoluteString.UTF8String);fflush(stdout);
    return [super evaluateRedirect:target fromURL:source];
}
@end
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];
    NSDictionary *env=NSProcessInfo.processInfo.environment;
    NSString *http=env[@"RD_WEBKIT_HTTP"],*https=env[@"RD_WEBKIT_HTTPS"];
    NSArray *urls=@[[http stringByAppendingString:@"/start"],[https stringByAppendingString:@"/start"],[http stringByAppendingString:@"/upgrade"],[https stringByAppendingString:@"/downgrade"],[https stringByAppendingString:@"/failure"]];
    int failures=0;
    for(NSUInteger i=0;i<urls.count;i++){
        LoopbackNavigationPolicy *policy=[LoopbackNavigationPolicy new];policy.ports=[NSSet setWithArray:@[[NSURL URLWithString:http].port,[NSURL URLWithString:https].port]];policy.paths=[NSMutableArray array];
        WebProbe *probe=[[WebProbe alloc]initWithPolicy:policy];probe.hardTimeout=10;
        probe.loader=[[RDWebViewProbeLoader alloc]initWithWebViewFactory:[FixtureFactory new]];
        __block BOOL done=NO;__block RDProbeResult *result;__block AppError *error;
        [probe probeURL:urls[i] completion:^(RDProbeResult *r,AppError *e,NSUInteger gen){result=r;error=e;done=YES;}];
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:12];while(!done&&end.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        BOOL ok=i==4?(done&&error.type==AppErrorHTTP):i==3?(done&&error.type==AppErrorPermission&&[policy.paths containsObject:@"/downgrade-final"]):(done&&!error&&[result.pageTitle isEqual:@"redirect-fixture"]&&[policy.paths containsObject:@"/final"]);
        printf("%s real WKWebView server redirect case=%lu error=%s\n",ok?"PASS":"FAIL",(unsigned long)i,(error.message?:@"").UTF8String);if(!ok)failures++;
        [probe detachWebView];
    }
    printf("FAILURES=%d\n",failures);return failures?1:0;
}}
