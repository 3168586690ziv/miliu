// Exercise the real production default wrapper without reading/writing user defaults.
// Only the NSUserDefaults boundary is replaced; the policy under test is not copied.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

@interface TLSMemoryDefaults : NSObject
@property(nonatomic,strong) id value;
+ (instancetype)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation TLSMemoryDefaults
+ (instancetype)standardUserDefaults {
    static TLSMemoryDefaults *memory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ memory=[TLSMemoryDefaults new]; });
    return memory;
}
- (id)objectForKey:(NSString *)key { (void)key; return self.value; }
- (BOOL)boolForKey:(NSString *)key {
    id value=[self objectForKey:key];
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}
@end

#define NSUserDefaults TLSMemoryDefaults
#import "RDTLSTrust.h"
#undef NSUserDefaults

int main(void) {
    @autoreleasepool {
        TLSMemoryDefaults *memory=TLSMemoryDefaults.standardUserDefaults;
        NSUInteger failed=0, checks=0;
        NSArray *values=@[NSNull.null,@NO,@YES];
        for(NSUInteger i=0;i<values.count;i++) {
            memory.value=values[i]==NSNull.null?nil:values[i];
            BOOL actual=RDTLSAllowRevokedCertificateEnabled();
            BOOL expected=i==2;
            checks++;
            if(actual!=expected)failed++;
            printf("%s: production wrapper configuration=%s expected=%d actual=%d\n",actual==expected?"PASS":"FAIL",i==0?"missing":(i==1?"NO":"YES"),expected,actual);
        }
        memory.value=nil;
        printf("TLS-DEFAULT-POLICY checks=%lu failed=%lu REAL_USER_DEFAULTS_ACCESSED=NO\n",(unsigned long)checks,(unsigned long)failed);
        return failed?1:0;
    }
}
