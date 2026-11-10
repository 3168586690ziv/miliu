// In-memory transport requirement, not an HTTP header or persistent auth store.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline BOOL RDHeadersContainAuthentication(NSDictionary<NSString *, NSString *> *headers) {
    for (NSString *name in headers) {
        // Presence alone is enough: an empty credential still belongs to an
        // authenticated context, and must not silently become anonymous curl.
        if ([name caseInsensitiveCompare:@"Cookie"] == NSOrderedSame ||
            [name caseInsensitiveCompare:@"Authorization"] == NSOrderedSame ||
            [name caseInsensitiveCompare:@"Proxy-Authorization"] == NSOrderedSame) return YES;
    }
    return NO;
}

static inline void RDMarkRequestRequiresNativeTransport(NSMutableURLRequest *request) {
    [NSURLProtocol setProperty:@YES forKey:@"MiliuRequiresNativeTransport" inRequest:request];
}

static inline BOOL RDRequestRequiresNativeTransport(NSURLRequest *request) {
    return [NSURLProtocol propertyForKey:@"MiliuRequiresNativeTransport" inRequest:request] != nil ||
        RDHeadersContainAuthentication(request.allHTTPHeaderFields ?: @{});
}

NS_ASSUME_NONNULL_END
