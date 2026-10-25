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
    // ══════════════════════════════════════════════════════════════════════
    // Referer 强度档位（HTTPRefererMode）：三档语义 + 默认零回归 + 非法值回退
    // ══════════════════════════════════════════════════════════════════════
    // 未注入任何 override 时必须是默认 Origin（现状行为）。
    [HTTPPrivacyPolicy setRefererModeOverride:nil];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeOrigin,@"T61 默认档位为 Origin（零回归前提）");

    // —— 默认 Origin 档：与改动前逐字一致 ——
    // 注意两种入口的旧行为**不同**：refererHeaderForRequestURL:fromPageURL: 有跨域判定
    // （跨域 nil），而 sanitizeMediaRequest: 只做 origin 归一（跨域也发）。
    // 两者都以 git HEAD 的旧实现实测为基线，见下方注释。
    NSURL *samePage=[NSURL URLWithString:@"https://site.test/watch?ep=7&token=SECRET#t=30"];
    NSURL *sameMedia=[NSURL URLWithString:@"https://site.test/media/ep7.mp4"];
    NSURL *crossMedia=[NSURL URLWithString:@"https://cdn.test/media/ep7.mp4"];
    NSURL *crossPage=[NSURL URLWithString:@"https://site.test/watch?ep=7"];

    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:sameMedia];
    [r setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    check([[r valueForHTTPHeaderField:@"Referer"]isEqual:@"https://site.test"],
          @"T61 默认档 sanitizeMediaRequest 同域 → 仅 origin（path/query/fragment 全丢）");

    r=[NSMutableURLRequest requestWithURL:crossMedia];
    [r setValue:crossPage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    // 如实记录：改动前的 sanitizeMediaRequest: 只把 Referer 归一成 origin，
    // 没有跨域判定（旧实现实测：media=cdn.test + Referer=site.test → 仍发 https://site.test）。
    // 因此「默认档零回归」与「跨域 → nil」在 sanitizeMediaRequest: 上不可兼得；
    // 本断言守的是真实基线 —— 默认档行为与改动前逐字一致。
    check([[r valueForHTTPHeaderField:@"Referer"]isEqual:@"https://site.test"],
          @"T61 默认档 sanitizeMediaRequest 跨域仍发 origin（与改动前基线逐字一致）");

    check([[HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia fromPageURL:samePage]isEqual:@"https://site.test"],
          @"T61 默认档 refererHeaderForRequestURL 同域 → 仅 origin");
    check([HTTPPrivacyPolicy refererHeaderForRequestURL:crossMedia fromPageURL:crossPage]==nil,
          @"T61 默认档 refererHeaderForRequestURL 跨域 → nil");

    // —— FullPath 档：同源发完整来源页 URL（含 path/query，去掉 fragment）——
    [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeFullPath)];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeFullPath,@"T62 FullPath 档注入生效");

    r=[NSMutableURLRequest requestWithURL:sameMedia];
    [r setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    NSString *fullReferer=[r valueForHTTPHeaderField:@"Referer"];
    check([fullReferer isEqual:@"https://site.test/watch?ep=7&token=SECRET"],
          @"T62 FullPath 档同源 → 完整来源页 URL（path+query 保留、参数顺序不变）");
    check(fullReferer.length>0&&[fullReferer rangeOfString:@"#"].location==NSNotFound,
          @"T62 FullPath 档 Referer 不含 #fragment");
    check(fullReferer.length>0&&[fullReferer rangeOfString:@"/watch"].location!=NSNotFound,
          @"T62 FullPath 档 Referer 确实保留 path（不是退化回 origin）");
    check(fullReferer.length>0&&[fullReferer rangeOfString:@"ep=7"].location!=NSNotFound,
          @"T62 FullPath 档 Referer 确实保留 query");

    // —— FullPath 档：跨域一律 nil（绝不跨域泄露来源路径）——
    r=[NSMutableURLRequest requestWithURL:crossMedia];
    [r setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    check([r valueForHTTPHeaderField:@"Referer"]==nil,
          @"T63 FullPath 档跨域 sanitizeMediaRequest → nil（不泄露来源路径）");
    check([HTTPPrivacyPolicy refererHeaderForRequestURL:crossMedia fromPageURL:samePage]==nil,
          @"T63 FullPath 档跨域 refererHeaderForRequestURL → nil（不泄露来源路径）");

    // —— FullPath 档：同一 host 不同路径不得被误判跨域（同源判定按 origin 比较）——
    NSURL *sameHostOtherPath=[NSURL URLWithString:@"https://site.test/other/dir/clip.mp4"];
    check([[HTTPPrivacyPolicy refererHeaderForRequestURL:sameHostOtherPath fromPageURL:samePage]
           isEqual:@"https://site.test/watch?ep=7&token=SECRET"],
          @"T63 FullPath 档同站不同路径仍判同源（按 origin 比较，不按完整 URL）");

    // —— FullPath 档：来源页带 userinfo → nil（与 originForURL: 的安全检查一致）——
    for(NSString *badPage in @[@"https://u:p@site.test/x",@"https://user@site.test/x"]){
        r=[NSMutableURLRequest requestWithURL:sameMedia];
        [r setValue:badPage forHTTPHeaderField:@"Referer"];
        [HTTPPrivacyPolicy sanitizeMediaRequest:r];
        check([r valueForHTTPHeaderField:@"Referer"]==nil,
              [NSString stringWithFormat:@"T64 FullPath 档 userinfo 来源页不发 Referer：%@",badPage]);
        check([HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia fromPageURL:[NSURL URLWithString:badPage]]==nil,
              [NSString stringWithFormat:@"T64 FullPath 档 userinfo 来源页 refererHeaderForRequestURL → nil：%@",badPage]);
    }

    // —— FullPath 档：query 必须原样搬运（不重排顺序、不重新 percent-encode）——
    // 这条守的是「不能用 NSURLComponents.string 重组整条 URL」的实现要求：
    // b 在 a 前、%2F 与 + 与 %20 混用、有重复键，全部必须逐字保留。
    for(NSString *rawPage in @[@"https://site.test/p?b=2&a=1&b=3",
                               @"https://site.test/a%2Fb?x=%20&y=1+2",
                               @"https://site.test/p?a=%2F&b=%2B"]){
        NSString *got=[HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia
                                                        fromPageURL:[NSURL URLWithString:rawPage]];
        check([got isEqual:rawPage],
              [NSString stringWithFormat:@"T64b FullPath 档 query 原样保留（期望 %@ 实得 %@）",rawPage,got]);
    }
    // 空 query（"?" 保留）与无 query 的区分
    check([[HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia
                                             fromPageURL:[NSURL URLWithString:@"https://site.test/p?"]]
           isEqual:@"https://site.test/p?"],
          @"T64b FullPath 档空 query 保留 '?'");
    check([[HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia
                                             fromPageURL:[NSURL URLWithString:@"https://site.test/p"]]
           isEqual:@"https://site.test/p"],
          @"T64b FullPath 档无 query 不得凭空补 '?'");
    // 非默认端口必须保留；默认端口省略（与 originForURL: 归一一致）
    check([[HTTPPrivacyPolicy refererHeaderForRequestURL:[NSURL URLWithString:@"https://site.test:8443/m.mp4"]
                                             fromPageURL:[NSURL URLWithString:@"https://site.test:8443/p?a=1"]]
           isEqual:@"https://site.test:8443/p?a=1"],
          @"T64b FullPath 档非默认端口保留");
    check([[HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia
                                             fromPageURL:[NSURL URLWithString:@"https://site.test:443/p?a=1"]]
           isEqual:@"https://site.test/p?a=1"],
          @"T64b FullPath 档默认端口省略");
    // 非 http/https 来源页照旧拒绝（安全检查在 FullPath 档同样生效）
    for(NSString *badScheme in @[@"file:///etc/passwd",@"ftp://site.test/p",@"javascript:alert(1)"]){
        check([HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia
                                                fromPageURL:[NSURL URLWithString:badScheme]]==nil,
              [NSString stringWithFormat:@"T64b FullPath 档非 http(s) 来源页 → nil：%@",badScheme]);
    }

    // —— None 档：同源与跨域一律 nil ——
    [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeNone)];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeNone,@"T65 None 档注入生效");
    r=[NSMutableURLRequest requestWithURL:sameMedia];
    [r setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    check([r valueForHTTPHeaderField:@"Referer"]==nil,@"T65 None 档同源 sanitizeMediaRequest → nil");
    r=[NSMutableURLRequest requestWithURL:crossMedia];
    [r setValue:crossPage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    check([r valueForHTTPHeaderField:@"Referer"]==nil,@"T65 None 档跨域 sanitizeMediaRequest → nil");
    check([HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia fromPageURL:samePage]==nil,@"T65 None 档同源 refererHeaderForRequestURL → nil");
    check([HTTPPrivacyPolicy refererHeaderForRequestURL:crossMedia fromPageURL:crossPage]==nil,@"T65 None 档跨域 refererHeaderForRequestURL → nil");

    // —— 非法导入值：回退 Origin 行为且不崩 ——
    [HTTPPrivacyPolicy setRefererModeOverride:@(99)];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeOrigin,@"T66 非法档位 99 → 回退 Origin");
    r=[NSMutableURLRequest requestWithURL:sameMedia];
    [r setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    check([[r valueForHTTPHeaderField:@"Referer"]isEqual:@"https://site.test"],
          @"T66 非法档位 99 → sanitizeMediaRequest 走 Origin 行为（同域仅 origin）");
    check([HTTPPrivacyPolicy refererHeaderForRequestURL:crossMedia fromPageURL:crossPage]==nil,
          @"T66 非法档位 99 → refererHeaderForRequestURL 跨域仍 nil");
    [HTTPPrivacyPolicy setRefererModeOverride:@(-1)];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeOrigin,@"T66 非法档位 -1 → 回退 Origin（下界外不崩）");

    // —— setRefererModeOverride:nil 恢复 Origin ——
    [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeFullPath)];
    [HTTPPrivacyPolicy setRefererModeOverride:nil];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeOrigin,@"T67 注入 nil → 恢复 Origin");
    r=[NSMutableURLRequest requestWithURL:sameMedia];
    [r setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:r];
    check([[r valueForHTTPHeaderField:@"Referer"]isEqual:@"https://site.test"],
          @"T67 恢复 Origin 后 sanitizeMediaRequest 重新退回仅 origin");

    // —— 三档 × （同域/跨域）在 refererHeaderForRequestURL:fromPageURL: 的完整对照表 ——
    // 期望值顺序：Origin / FullPath / None；同域期望 {origin, 完整URL, nil}，跨域三档全 nil。
    NSArray<NSNumber *> *modes=@[@(HTTPRefererModeOrigin),@(HTTPRefererModeFullPath),@(HTTPRefererModeNone)];
    NSArray *sameExpect=@[@"https://site.test",@"https://site.test/watch?ep=7&token=SECRET",[NSNull null]];
    NSArray<NSString *> *names=@[@"Origin",@"FullPath",@"None"];
    for(NSUInteger i=0;i<modes.count;i++){
        [HTTPPrivacyPolicy setRefererModeOverride:modes[i]];
        id expect=sameExpect[i];
        NSString *got=[HTTPPrivacyPolicy refererHeaderForRequestURL:sameMedia fromPageURL:samePage];
        BOOL ok=([expect isKindOfClass:[NSNull class]])?(got==nil):[got isEqual:expect];
        check(ok,[NSString stringWithFormat:@"T68 %@ 档同域对照（期望 %@）",names[i],expect]);
        check([HTTPPrivacyPolicy refererHeaderForRequestURL:crossMedia fromPageURL:crossPage]==nil,
              [NSString stringWithFormat:@"T68 %@ 档跨域对照（期望 nil）",names[i]]);
    }

    // —— sanitizeRedirectRequest: 的 Authorization/Cookie 语义不许被档位影响 ——
    [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeFullPath)];
    NSMutableURLRequest *prev=[NSMutableURLRequest requestWithURL:samePage];
    [prev setValue:@"Bearer SECRET" forHTTPHeaderField:@"Authorization"];
    [prev setValue:@"token=SECRET" forHTTPHeaderField:@"Cookie"];
    [prev setValue:samePage.absoluteString forHTTPHeaderField:@"Referer"];
    NSMutableURLRequest *hop=[NSMutableURLRequest requestWithURL:sameMedia];
    [HTTPPrivacyPolicy sanitizeRedirectRequest:hop fromRequest:prev];
    check([[hop valueForHTTPHeaderField:@"Authorization"]isEqual:@"Bearer SECRET"],
          @"T69 FullPath 档同源跳转仍保留 Authorization");
    check([[hop valueForHTTPHeaderField:@"Cookie"]isEqual:@"token=SECRET"],
          @"T69 FullPath 档同源跳转仍保留 Cookie");
    check([[hop valueForHTTPHeaderField:@"Referer"]isEqual:@"https://site.test/watch?ep=7&token=SECRET"],
          @"T69 FullPath 档同源跳转 Referer 继承完整来源页 URL");
    NSMutableURLRequest *crossHop=[NSMutableURLRequest requestWithURL:crossMedia];
    [HTTPPrivacyPolicy sanitizeRedirectRequest:crossHop fromRequest:prev];
    check([crossHop valueForHTTPHeaderField:@"Authorization"]==nil,@"T69 FullPath 档跨域跳转仍清除 Authorization");
    check([crossHop valueForHTTPHeaderField:@"Cookie"]==nil,@"T69 FullPath 档跨域跳转仍清除 Cookie");
    check([crossHop valueForHTTPHeaderField:@"Referer"]==nil,@"T69 FullPath 档跨域跳转 Referer → nil（不泄露路径）");

    // 收尾：恢复默认档，避免后续（或未来新增）断言受本次注入影响。
    [HTTPPrivacyPolicy setRefererModeOverride:nil];
    check([HTTPPrivacyPolicy refererMode]==HTTPRefererModeOrigin,@"T69 收尾恢复默认 Origin");

    printf("CHECKS=%d FAILURES=%d\n",checks,failures);return failures?1:0;
}}
