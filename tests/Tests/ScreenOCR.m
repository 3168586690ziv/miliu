//
//  ScreenOCR.m — 屏幕/窗口截图文字识别（Vision），用于真实界面验收取证
//  用法：ScreenOCR <png 路径>
//  输出每行：x y w h <文本>（归一化坐标，原点左下）
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Vision/Vision.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { printf("usage: ScreenOCR <png>\n"); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (!image) { printf("OCR-FAIL 无法读取图片 %s\n", path.UTF8String); return 1; }
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (!cg) { printf("OCR-FAIL 无法解码 CGImage\n"); return 1; }
        if (argc >= 6) {   // 可选裁剪：x y w h（像素，原点左上）
            CGRect rect = CGRectMake(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]));
            CGImageRef cropped = CGImageCreateWithImageInRect(cg, rect);
            if (cropped) cg = cropped;
        }
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = NO;
        request.recognitionLanguages = @[@"zh-Hans", @"en-US", @"ja-JP"];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error]) {
            printf("OCR-FAIL %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("OCR-SIZE %zux%zu results=%lu\n", CGImageGetWidth(cg), CGImageGetHeight(cg),
               (unsigned long)request.results.count);
        for (VNRecognizedTextObservation *observation in request.results) {
            VNRecognizedText *text = [observation topCandidates:1].firstObject;
            if (!text.string.length) continue;
            CGRect box = observation.boundingBox;
            printf("OCR-BOX %.3f %.3f %.3f %.3f %s\n", box.origin.x, box.origin.y, box.size.width, box.size.height,
                   text.string.UTF8String);
        }
    }
    return 0;
}
