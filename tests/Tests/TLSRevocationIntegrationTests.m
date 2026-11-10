// Production evaluator with Security-framework boundary fixtures. This is not
// a real revoked-chain/OCSP test: no algorithm or allow/reject policy is copied.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
static BOOL systemTrusted;
static NSArray *fixtureProperties;
static NSArray *fixtureSAN;
static NSError *fixtureError;
static BOOL FixtureEvaluate(SecTrustRef trust, CFErrorRef *error) {
    (void)trust;
    if(!systemTrusted&&error)*error=(CFErrorRef)CFBridgingRetain(fixtureError);
    return systemTrusted;
}
static CFArrayRef FixtureProperties(SecTrustRef trust) {
    (void)trust; return (__bridge_retained CFArrayRef)fixtureProperties;
}
static CFArrayRef FixtureChain(SecTrustRef trust) {
    (void)trust; return (__bridge_retained CFArrayRef)@[@"fixture-leaf"];
}
static CFDictionaryRef FixtureValues(SecCertificateRef certificate, CFArrayRef keys, CFErrorRef *error) {
    (void)certificate;(void)keys;(void)error;
    return (__bridge_retained CFDictionaryRef)@{(__bridge NSString *)kSecOIDSubjectAltName:@{(__bridge NSString *)kSecPropertyKeyValue:fixtureSAN}};
}
#define SecTrustEvaluateWithError FixtureEvaluate
#define SecTrustCopyProperties FixtureProperties
#define SecTrustCopyCertificateChain FixtureChain
#define SecCertificateCopyValues FixtureValues
#import "RDTLSTrust.h"
#undef SecTrustEvaluateWithError
#undef SecTrustCopyProperties
#undef SecTrustCopyCertificateChain
#undef SecCertificateCopyValues
static NSUInteger checks,failed;
static void Expect(BOOL allow,RDTLSTrustVerdict expected,NSString *message) {
    RDTLSTrustVerdict actual=RDTLSEvaluateServerTrustWithRevocationAllowed((SecTrustRef)(uintptr_t)1,@"good.example",allow,NULL);
    checks++; if(actual!=expected)failed++;
    printf("%s: %s expected=%ld actual=%ld\n",actual==expected?"PASS":"FAIL",message.UTF8String,(long)expected,(long)actual);
}
static void SetError(NSString *description) {
    fixtureError=[NSError errorWithDomain:NSOSStatusErrorDomain code:-67820 userInfo:@{NSLocalizedDescriptionKey:description}];
}
static NSArray *SAN(NSString *label,NSString *name) {
    return @[@{(__bridge NSString *)kSecPropertyKeyLabel:label,(__bridge NSString *)kSecPropertyKeyValue:name}];
}
int main(void) {
    @autoreleasepool {
        fixtureProperties=@[@{@"error":@"CSSMERR_TP_CERT_REVOKED"},@{}];
        fixtureSAN=SAN(@"DNS Name",@"good.example");
        SetError(@"Certificate 0 \"good.example\" has errors: Certificate is revoked;");
        Expect(RDTLSAllowRevokedCertificateForValue(nil),RDTLSTrustVerdictReject,@"missing setting rejects otherwise eligible revoked leaf");
        Expect(NO,RDTLSTrustVerdictReject,@"explicit NO rejects revoked leaf");
        Expect(YES,RDTLSTrustVerdictAcceptRevoked,@"explicit YES permits only eligible leaf+SAN+index");
        SetError(@"Certificate 1 \"intermediate\" has errors: Certificate is revoked;");
        Expect(YES,RDTLSTrustVerdictReject,@"explicit YES does not bypass intermediate index");
        SetError(@"certificate revoked without a known index");
        Expect(YES,RDTLSTrustVerdictReject,@"explicit YES does not bypass unknown index");
        SetError(@"Certificate 0 \"good.example\" has errors: Certificate is revoked;");
        fixtureSAN=SAN(@"Email Address",@"good.example");
        Expect(YES,RDTLSTrustVerdictReject,@"explicit YES does not turn non-DNS SAN into hostname");
        fixtureSAN=SAN(@"DNS Name",@"wrong.example");
        Expect(YES,RDTLSTrustVerdictReject,@"explicit YES still requires matching SAN");
        fixtureSAN=SAN(@"DNS Name",@"good.example");
        fixtureProperties=@[@{@"error":@"CSSMERR_TP_CERT_REVOKED"},@{@"error":@"CSSMERR_TP_INVALID_ANCHOR_CERT"}];
        Expect(YES,RDTLSTrustVerdictReject,@"explicit YES still requires a sole failure");
        fixtureProperties=@[@{@"error":@"CSSMERR_TP_CERT_EXPIRED"}];
        Expect(YES,RDTLSTrustVerdictReject,@"explicit YES cannot allow an expired certificate");
        systemTrusted=YES;
        Expect(NO,RDTLSTrustVerdictUseDefault,@"system trusted certificate follows default in strict mode");
        Expect(YES,RDTLSTrustVerdictUseDefault,@"system trusted certificate follows default with opt-in");
        checks++;
        BOOL nilRejected=RDTLSEvaluateServerTrustWithRevocationAllowed(NULL,@"good.example",YES,NULL)==RDTLSTrustVerdictReject;
        if(!nilRejected)failed++;
        printf("%s: absent trust rejected\n",nilRejected?"PASS":"FAIL");
        printf("TLS-REVOCATION-BOUNDARY checks=%lu failed=%lu REAL_OCSP_TEST=NO\n",(unsigned long)checks,(unsigned long)failed);
        return failed?1:0;
    }
}
