#import <Foundation/Foundation.h>
#import "HTTPPrivacyPolicy.h"
#import "URLPolicy.h"
#import "RDMetadataTransport.h"
#import "DownloadCapabilityProbe.h"
@interface RedirectTask : NSObject
@property NSURLRequest *currentRequest;
@property NSURLRequest *originalRequest;
@end
@implementation RedirectTask @end
static int failures,checks;
static void check(BOOL ok,NSString *message){checks++;printf("%s %s\n",ok?"PASS":"FAIL",message.UTF8String);if(!ok)failures++;}
static void WaitForRedirect(BOOL (^done)(void)){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2];while(!done()&&end.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];}
int main(void){@autoreleasepool{
    for(NSString *name in @[@"ZZCapabilityDelegate",@"RDMetadataTransfer"]){
        id<NSURLSessionTaskDelegate> delegate=[NSClassFromString(name)new];
        if([name isEqual:@"ZZCapabilityDelegate"])[(id)delegate setValue:[URLPolicy new] forKey:@"policy"];
        else [(id)delegate setValue:[^NSArray *(NSString *host){return @[@"93.184.216.34"];} copy] forKey:@"resolver"];
        NSMutableURLRequest *current=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://93.184.216.34/a"]];
        [current setValue:@"https://page.example.com/private?token=SECRET" forHTTPHeaderField:@"Referer"];
        [current setValue:@"Bearer SECRET" forHTTPHeaderField:@"Authorization"];[current setValue:@"token=SECRET" forHTTPHeaderField:@"Cookie"];
        NSURLRequest *original=[current copy];
        NSArray *targets=@[@"https://93.184.216.34:443/b",@"https://94.184.216.34/b",@"https://93.184.216.34/back",@"https://93.184.216.34:444/b"];
        NSUInteger hop=0;
        for(NSString *target in targets){
            RedirectTask *task=[RedirectTask new];task.originalRequest=original;task.currentRequest=current;
            NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:current.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
            NSMutableURLRequest *proposed=[original mutableCopy];proposed.URL=[NSURL URLWithString:target];
            __block NSURLRequest *next;__block BOOL done=NO;
            [delegate URLSession:NSURLSession.sharedSession task:(id)task willPerformHTTPRedirection:response newRequest:proposed completionHandler:^(NSURLRequest *request){next=request;done=YES;}];
            WaitForRedirect(^BOOL{return done;});
            check(done&&next!=nil,[NSString stringWithFormat:@"%@ hop %lu follows valid redirect",name,(unsigned long)hop]);
            check([[next valueForHTTPHeaderField:@"Referer"]isEqual:@"https://page.example.com"],[@"origin-only Referer survives " stringByAppendingString:name]);
            check(hop==0?[[next valueForHTTPHeaderField:@"Authorization"]isEqual:@"Bearer SECRET"]:[next valueForHTTPHeaderField:@"Authorization"]==nil,@"Authorization scoped to origin; never resurrected");
            check(hop==0?[[next valueForHTTPHeaderField:@"Cookie"]isEqual:@"token=SECRET"]:[next valueForHTTPHeaderField:@"Cookie"]==nil,@"Cookie scoped to origin including port");
            current=[next mutableCopy];hop++;
        }
    }
    for(NSString *referer in @[@"https://u:p@example.com/private?token=SECRET",@"https://user@example.com/",@"https://us%65r:p%61ss@example.com/",@"https:///path",@"javascript:alert(1)"]){
        NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://93.184.216.34/a"]];
        [r setValue:referer forHTTPHeaderField:@"Referer"];[HTTPPrivacyPolicy sanitizeMediaRequest:r];
        check([r valueForHTTPHeaderField:@"Referer"]==nil,@"credential/malformed Referer not transmitted");
    }
    printf("CHECKS=%d FAILURES=%d\n",checks,failures);return failures?1:0;
}}
