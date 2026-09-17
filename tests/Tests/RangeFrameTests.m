#import <Cocoa/Cocoa.h>
#import "RDRangeAsset.h"
int main(int argc,char **argv) { @autoreleasepool {
 NSData *data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
 __block BOOL done=NO,ok=NO; __block NSUInteger bytes=0;
 RDRangeAsset *loader=[[RDRangeAsset alloc] initWithLength:data.length etag:@"\"v1\"" request:^(NSDictionary *headers,NSUInteger budget,void (^completion)(RDMetadataResponse *)) {
 unsigned long long lo=0,hi=0; sscanf([headers[@"Range"] UTF8String],"bytes=%llu-%llu",&lo,&hi);
 RDMetadataResponse *r=[RDMetadataResponse new]; r.data=[data subdataWithRange:NSMakeRange(lo,hi-lo+1)]; bytes+=r.data.length;
 r.response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://fixture.invalid/a.mp4"] statusCode:206 HTTPVersion:@"HTTP/1.1" headerFields:@{@"ETag":@"\"v1\"",@"Content-Range":[NSString stringWithFormat:@"bytes %llu-%llu/%lu",lo,hi,data.length]}];
 dispatch_async(dispatch_get_main_queue(),^{completion(r);});
 }];
 AVAssetImageGenerator *g=[AVAssetImageGenerator assetImageGeneratorWithAsset:loader.asset];
 [g generateCGImageAsynchronouslyForTime:CMTimeMakeWithSeconds(.1,600) completionHandler:^(CGImageRef image,CMTime t,NSError *e){dispatch_async(dispatch_get_main_queue(),^{ok=image!=NULL;done=YES;NSLog(@"frame=%d bytes=%lu error=%@",ok,bytes,e);});}];
 NSDate *end=[NSDate dateWithTimeIntervalSinceNow:15]; while(!done&&end.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 [loader cancel]; return ok?0:1;
 }}
