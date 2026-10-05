//
//  CookieImportTests.m — 浏览器 Cookie 导入纯函数测试（不碰真实浏览器数据）
//
//  覆盖（2026-10-05 第 25 轮）：v10 解密往返（自加密→解密还原）、错误密钥/前缀
//  拒绝、Chromium 时间戳换算（1601 纪元）、钥匙串服务名拼接、来源扫描冒烟。
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import "RDBrowserCookieImporter.h"

static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }

// 按浏览器同款参数加密（key + IV=0x20×16 + PKCS7），构造 v10 前缀密文。
static NSData *encryptLikeChromium(NSData *plain, NSData *key) {
    unsigned char iv[kCCBlockSizeAES128];
    memset(iv, 0x20, sizeof(iv));
    NSMutableData *cipher = [NSMutableData dataWithLength:plain.length + kCCBlockSizeAES128];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 key.bytes, key.length, iv,
                                 plain.bytes, plain.length,
                                 cipher.mutableBytes, cipher.length, &moved);
    if (st != kCCSuccess) return nil;
    cipher.length = moved;
    NSMutableData *out = [NSMutableData dataWithData:[@"v10" dataUsingEncoding:NSASCIIStringEncoding]];
    [out appendData:cipher];
    return out;
}

int main(void) { @autoreleasepool {
    NSData *key = [@"0123456789abcdef" dataUsingEncoding:NSUTF8StringEncoding];   // 16 字节测试密钥

    // 1) v10 解密往返：典型 cookie 值（含符号与长串）
    NSString *value = @"auth_token=abc123%2Fxyz+9==; theme=dark; sessionid=gKv2Lm8Q7pR|sT4z";
    NSData *enc = encryptLikeChromium([value dataUsingEncoding:NSUTF8StringEncoding], key);
    NSData *dec = [RDBrowserCookieImporter decryptChromiumV10Value:enc key:key];
    check(dec && [[[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding] isEqualToString:value],
          "v10 decrypt round-trips an encrypted cookie value");

    // 2) 错误密钥 / 非法前缀 / 长度不足 → 拒绝
    NSData *wrongKey = [@"ffffffffffffffff" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *wrongPlain = [RDBrowserCookieImporter decryptChromiumV10Value:enc key:wrongKey];
    check(wrongPlain == nil || ![[[NSString alloc] initWithData:wrongPlain encoding:NSUTF8StringEncoding] isEqualToString:value],
          "wrong key never recovers the original value");
    NSData *noPrefix = [enc subdataWithRange:NSMakeRange(3, enc.length - 3)];
    check([RDBrowserCookieImporter decryptChromiumV10Value:noPrefix key:key] == nil,
          "missing v10 prefix is rejected");
    check([RDBrowserCookieImporter decryptChromiumV10Value:[@"v10" dataUsingEncoding:NSASCIIStringEncoding] key:key] == nil,
          "truncated ciphertext is rejected");
    NSData *v11 = [@"v11xxxxxx" dataUsingEncoding:NSUTF8StringEncoding];
    check([RDBrowserCookieImporter decryptChromiumV10Value:v11 key:key] == nil,
          "v11 (app-bound era) prefix is explicitly rejected");

    // 3) Chromium 时间戳：纪元锚点 + 0 = 会话 Cookie
    NSDate *epoch = [RDBrowserCookieImporter dateFromChromiumTimestamp:11644473600000000LL];
    check(epoch && [epoch isEqualToDate:[NSDate dateWithTimeIntervalSince1970:0]],
          "chromium epoch anchor converts to unix epoch");
    check([RDBrowserCookieImporter dateFromChromiumTimestamp:0] == nil,
          "zero timestamp means session cookie (no expiry)");
    NSDate *future = [RDBrowserCookieImporter dateFromChromiumTimestamp:13443235200000000LL];
    check(future && future.timeIntervalSince1970 > [NSDate date].timeIntervalSince1970,
          "future expiry converts to a later date");

    // 4) 钥匙串服务名拼接
    check([[RDBrowserCookieImporter safeStorageServiceNameForBrowserName:@"BrowserClaw"]
           isEqualToString:@"BrowserClaw Safe Storage"], "service name is <browser> Safe Storage");

    // 5) 来源扫描冒烟：只验证可调用且结构合法（本机存在哪些浏览器不作断言）
    NSArray *sources = [RDBrowserCookieImporter availableSources];
    check(sources != nil, "availableSources returns a list");
    for (RDBrowserCookieSource *s in sources) {
        check(s.browserName.length > 0 && s.profilePath.length > 0 && s.cookieCount > 0,
              "source entry fields are populated");
        break;
    }

    printf("%s\n", failures == 0 ? "ALL PASS" : "HAS FAILURES");
    return failures == 0 ? 0 : 1;
}}
