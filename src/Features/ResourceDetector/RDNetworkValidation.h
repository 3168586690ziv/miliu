#import "URLPolicy.h"
#import "DNSResolver.h"
// Preflight only: resolved addresses are NOT pinned to NSURLSession's peer.
// Redirect callers must invoke this again immediately before following a hop.
// DNSResolver caches for at most 0.5s; neither this callback nor a post-download
// lookup proves which IP served the bytes. TLS certificate verification stays
// enabled. Strict rebinding prevention needs a connection-level transport.
NS_ASSUME_NONNULL_BEGIN
typedef NSArray<NSString *> * _Nullable (^RDURLResolver)(NSString *host);
typedef void (^RDURLValidationCompletion)(URLPolicyDecision *decision, NSArray<NSString *> *resolvedIPs);

// Runs the text + DNS check and returns the exact address set used for the
// decision.  NSURLSession callers retain this set and compare it with the
// connection peer reported by NSURLSessionTaskMetrics before accepting bytes.
static inline void RDValidateNetworkURLWithIPs(NSURL *url, URLPolicy * _Nullable policy, RDURLResolver _Nullable resolver, RDURLValidationCompletion done) {
    policy = policy ?: [URLPolicy new];
    URLPolicyDecision *text = [policy evaluateTextURL:url.absoluteString];
    if (!url.host.length || url.user.length || url.password.length) text = [URLPolicyDecision blockWithVerdict:URLPolicyBlockedReserved message:@"地址缺少主机或包含不支持的登录凭据"];
    if (!text.allowed) { dispatch_async(dispatch_get_main_queue(), ^{ done(text, @[]); }); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSArray *ips = nil;
        URLPolicyDecision *decision;
        if (resolver) {
            ips = resolver(url.host) ?: @[];
            decision = [policy evaluateResolvedURL:url resolvedIPs:ips];
        } else {
            DNSResolutionStatus status = DNSResolutionSucceeded;
            ips = [DNSResolver resolveIPsForHost:url.host status:&status] ?: @[];
            decision = [policy evaluateResolvedURL:url resolvedIPs:ips resolutionStatus:status];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(decision, ips); });
    });
}

static inline void RDValidateNetworkURL(NSURL *url, URLPolicy * _Nullable policy, RDURLResolver _Nullable resolver, void (^done)(URLPolicyDecision *)) {
    RDValidateNetworkURLWithIPs(url, policy, resolver, ^(URLPolicyDecision *decision, NSArray *ips) { done(decision); });
}
NS_ASSUME_NONNULL_END
