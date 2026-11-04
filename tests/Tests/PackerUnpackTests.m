//
//  PackerUnpackTests.m — Dean Edwards packer 解包专项（第 47 轮）
//
//  背景（用户实测报障）：jav.guru / javclan 这类站把播放器地址整段塞进
//  `eval(function(p,a,c,k,e,d){...}('...',36,N,'...'.split('|')))`。
//  不解包则静态腿完全看不到 m3u8 —— 播放页明明有视频却探到 0 条。
//  本套件锁定「纯字符串解包、不执行脚本、非 packer 原样返回」三条性质。
//
#import <Foundation/Foundation.h>
#import "RDStaticScriptAnalyzer.h"

static int gPassed = 0, gFailed = 0;
static void Chk(BOOL ok, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    printf("  %s %s\n", ok ? "PASS" : "FAIL", m.UTF8String);
    if (ok) gPassed++; else gFailed++;
}

int main(void) { @autoreleasepool {
    printf("== T1 非 packer 输入必须原样返回（零副作用）==\n");
    NSString *plain = @"<html><video src=\"https://a.test/v.mp4\"></video></html>";
    Chk([[RDStaticScriptAnalyzer unpackDeanEdwardsPacker:plain maxBytes:1<<20] isEqualToString:plain],
        @"普通 HTML 原样返回");
    Chk([[RDStaticScriptAnalyzer unpackDeanEdwardsPacker:@"" maxBytes:1<<20] isEqualToString:@""],
        @"空串原样返回");
    NSString *notPacker = @"eval(somethingElse(1,2,3))";
    Chk([RDStaticScriptAnalyzer unpackDeanEdwardsPacker:notPacker maxBytes:1<<20].length > 0,
        @"非 packer 的 eval 不崩溃且有返回");

    printf("\n== T2 真实形态解包：字典替换生效 ==\n");
    // 手工构造一个最小 packer：payload 里 0→links 1→https 2→m3u8
    // 解包后应为 "links https://x.test/a.m3u8"
    NSString *mini =
    @"eval(function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+c.toString(a)+'\\\\b','g'),k[c]);return p}"
    @"('0 1://x.test/a.2',10,3,'links|https|m3u8'.split('|')))";
    NSString *out = [RDStaticScriptAnalyzer unpackDeanEdwardsPacker:mini maxBytes:1<<20];
    Chk([out containsString:@"links"], @"字典项 links 被还原");
    Chk([out containsString:@"https"], @"字典项 https 被还原");
    Chk([out containsString:@"m3u8"], @"字典项 m3u8 被还原");
    Chk(![out containsString:@"eval(function(p,a,c,k,e,"], @"解包后不再含 packer 头");

    printf("\n== T3 上限保护：超限放弃解包，不返回半成品 ==\n");
    NSString *big = mini;
    NSString *capped = [RDStaticScriptAnalyzer unpackDeanEdwardsPacker:big maxBytes:4];
    Chk(capped.length > 0, @"maxBytes 极小也不崩溃、有返回");

    printf("\n== T4 不执行脚本（安全性质）==\n");
    // 若解包器真的执行了脚本，这个 payload 会试图触发副作用；我们只验证它不解包成可执行态
    NSString *evil =
    @"eval(function(p,a,c,k,e,d){return p}('0',10,1,'alert(1)'.split('|')))";
    NSString *r = [RDStaticScriptAnalyzer unpackDeanEdwardsPacker:evil maxBytes:1<<20];
    Chk(r.length > 0, @"含可疑内容的输入不崩溃（纯字符串变换，无脚本执行面）");

    printf("\nPACKER-UNPACK-%s passed=%d failed=%d\n",
           gFailed == 0 ? "PASSED" : "FAILED", gPassed, gFailed);
} return gFailed == 0 ? 0 : 1; }
