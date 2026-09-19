#import "RDStreamDownloadTask.h"
#import "RDStreamPlan.h"
#import "RDManifestParser.h"
#import "PerformancePolicy.h"
#import "RDLog.h"
static NSError *StreamError(NSString *text) { return [NSError errorWithDomain:@"RDStream" code:1 userInfo:@{NSLocalizedDescriptionKey:text}]; }
@interface RDStreamDownloadTask ()
@property id<RDDownloadBackend> backend;
@property NSURLRequest *request;
@property NSURL *output;
@property NSURL *root;
@property NSURL *muxer;
@property id<RDDownloadTask> transfer;
@property NSTask *process;
@property BOOL finished;
@property BOOL paused;
@property int64_t transferred;
@property NSUInteger sequence;
@property NSMutableArray<NSURL *> *inputs;
@property NSMutableSet *visited;
@property (copy) dispatch_block_t pending;
@property (copy) void (^progress)(int64_t,int64_t,int64_t);
@property (copy) void (^completion)(NSURL *,NSHTTPURLResponse *,NSError *);
@end
@implementation RDStreamDownloadTask
- (instancetype)initWithBackend:(id<RDDownloadBackend>)backend request:(NSURLRequest *)request output:(NSURL *)output muxer:(NSURL *)muxer progress:(void (^)(int64_t,int64_t,int64_t))progress completion:(void (^)(NSURL *,NSHTTPURLResponse *,NSError *))completion {
    if((self=[super init])){_backend=backend;_request=request;_output=output;_muxer=muxer;_progress=progress;_completion=completion;_inputs=[NSMutableArray array];_visited=[NSMutableSet set];_root=[output.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"stream-parts"];}
    return self;
}
- (void)start {
    NSError *error=nil;
    if(!self.muxer || ![[NSFileManager defaultManager]isExecutableFileAtPath:self.muxer.path]){[self finish:nil response:nil error:StreamError(@"离线视频合成组件缺失，请重新安装完整的觅流 App")];return;}
    if(![[NSFileManager defaultManager]createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:&error]){[self finish:nil response:nil error:error];return;}
    [self manifest:self.startURL ?: self.request.URL depth:0 completion:^{[self mux];}];
}
- (void)step:(dispatch_block_t)block { if(self.finished)return;if(self.paused)self.pending=block;else block(); }
- (void)finish:(NSURL *)url response:(NSHTTPURLResponse *)response error:(NSError *)error {
    if(self.finished)return;self.finished=YES;self.pending=nil;
    void (^done)(NSURL *,NSHTTPURLResponse *,NSError *)=self.completion;self.completion=nil;self.progress=nil;
    if(error){[self.transfer rd_cancel];if(self.process.running)[self.process terminate];}
    if(done)done(url,response,error);
}
- (void)rd_cancel { [self finish:nil response:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]]; }
- (void)rd_suspend { self.paused=YES;if([self.transfer respondsToSelector:@selector(rd_suspend)])[self.transfer rd_suspend];if(self.process.running)[self.process suspend]; }
- (void)rd_resume { self.paused=NO;if([self.transfer respondsToSelector:@selector(rd_resume)])[self.transfer rd_resume];if(self.process.running)[self.process resume];dispatch_block_t next=self.pending;self.pending=nil;if(next)next(); }
- (void)fetch:(NSURL *)url range:(NSString *)range limit:(int64_t)limit completion:(void (^)(NSURL *,NSHTTPURLResponse *))done {
    [self step:^{
        NSMutableURLRequest *r=[self.request mutableCopy];r.URL=url;
        [r setValue:range forHTTPHeaderField:@"Range"];[r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        [r setValue:nil forHTTPHeaderField:@"If-Range"];[r setValue:nil forHTTPHeaderField:@"If-Match"];
        NSURL *temp=[self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"fetch-%06lu.tmp",(unsigned long)self.sequence++]];
        int64_t before=self.transferred;
        void (^progress)(int64_t,int64_t,int64_t)=^(int64_t bytes,int64_t received,int64_t expected){
            if(self.finished)return;
            if(received>limit || before> [PerformancePolicy downloadMaxSingleFileBytes]-received){[self finish:nil response:nil error:StreamError(@"流媒体下载超过大小上限")];return;}
            if(self.progress)self.progress(bytes,before+received,-1);
        };
        void (^complete)(NSURL *,NSHTTPURLResponse *,NSError *)=^(NSURL *file,NSHTTPURLResponse *response,NSError *error){
            if(self.finished)return;self.transfer=nil;
            int64_t size=[[[NSFileManager defaultManager]attributesOfItemAtPath:file.path ?: @"" error:nil][NSFileSize] longLongValue];
            if(error || !file || response.statusCode<200 || response.statusCode>=300){[self finish:nil response:response error:error ?: StreamError([NSString stringWithFormat:@"清单或分片下载失败（HTTP %ld）",(long)response.statusCode])];return;}
            if(size<=0||size>limit || (response.expectedContentLength>0 && size!=response.expectedContentLength)){[self finish:nil response:response error:StreamError(@"媒体分片长度校验失败")];return;}
            if(range.length){
                NSString *wanted=[range substringFromIndex:6];NSArray *ends=[wanted componentsSeparatedByString:@"-"];
                NSString *prefix=[NSString stringWithFormat:@"bytes %@/",wanted];
                if(ends.count!=2||response.statusCode!=206||![[response valueForHTTPHeaderField:@"Content-Range"] hasPrefix:prefix]||size!=[ends[1] longLongValue]-[ends[0] longLongValue]+1){[self finish:nil response:response error:StreamError(@"服务器未返回指定的媒体字节范围")];return;}
            }
            self.transferred=before+size;if(self.progress)self.progress(size,self.transferred,-1);
            [self step:^{done(file,response);}];
        };
        if([self.backend respondsToSelector:@selector(rd_startRequest:writeToURL:progress:completion:)])self.transfer=[self.backend rd_startRequest:r writeToURL:temp progress:progress completion:complete];
        else self.transfer=[self.backend rd_startRequest:r writeToURL:temp completion:complete];
    }];
}
- (void)manifest:(NSURL *)url depth:(NSUInteger)depth completion:(dispatch_block_t)done {
    if(depth>5||[self.visited containsObject:url.absoluteString]){[self finish:nil response:nil error:StreamError(@"流媒体清单循环或嵌套层数过多")];return;}
    [self.visited addObject:url.absoluteString];
    [self fetch:url range:nil limit:2*1024*1024 completion:^(NSURL *file,NSHTTPURLResponse *response){
        NSString *text=[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];NSURL *base=response.URL ?: url;
        NSDictionary *parsed=[RDManifestParser parseManifest:text baseURL:base];
        if([parsed[@"kind"] isEqual:@"hls"]){
            if([parsed[@"isMaster"] boolValue]){
                NSArray *variants=[parsed[@"variants"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [@([b[@"bandwidth"] longLongValue]) compare:@([a[@"bandwidth"] longLongValue])];}];
                NSDictionary *best=variants.firstObject;
                // 界面选中了具体档位时固定该变体（清单内的变体 URL 与选中 URL
                // 来自同一解析链，按绝对地址精确匹配）；未命中回退带宽择优。
                if(self.pinnedVariantURL)for(NSDictionary *v in variants)
                    if([v[@"url"] isEqualToString:self.pinnedVariantURL.absoluteString]){best=v;break;}
                NSURL *video=[NSURL URLWithString:best[@"url"]];
                if(!video){[self finish:nil response:nil error:StreamError(@"主清单没有可下载的视频版本")];return;}
                NSDictionary *audio=nil;
                for(NSDictionary *candidate in parsed[@"audioTracks"])if([candidate[@"group-id"] isEqual:best[@"audio"]]&&[candidate[@"url"] length]){if(!audio || [candidate[@"default"] isEqual:@"YES"])audio=candidate;}
                [self manifest:video depth:depth+1 completion:^{if(audio)[self manifest:[NSURL URLWithString:audio[@"url"]] depth:depth+1 completion:done];else done();}];
            }else{
                NSError *error=nil;NSDictionary *plan=[RDStreamPlan HLSPlaylist:text baseURL:base error:&error];if(!plan){[self finish:nil response:nil error:error];return;}
                NSURL *folder=[self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"track-%lu",(unsigned long)self.inputs.count]];
                if(![[NSFileManager defaultManager]createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error]){[self finish:nil response:nil error:error];return;}
                NSURL *playlist=[folder URLByAppendingPathComponent:@"local.m3u8"];
                if(![plan[@"playlist"] writeToURL:playlist atomically:YES encoding:NSUTF8StringEncoding error:&error]){[self finish:nil response:nil error:error];return;}
                [self resources:plan[@"resources"] index:0 folder:folder appendTo:nil completion:^{[self.inputs addObject:playlist];done();}];
            }
        }else if([parsed[@"kind"] isEqual:@"dash"]){NSError *error=nil;NSArray *tracks=[RDStreamPlan DASHTracks:text baseURL:base error:&error];if(!tracks){[self finish:nil response:nil error:error];return;}[self dashTracks:tracks index:0 completion:done];}
        else [self finish:nil response:response error:StreamError(@"服务器没有返回有效的 HLS/DASH 清单")];
    }];
}
- (void)dashTracks:(NSArray *)tracks index:(NSUInteger)index completion:(dispatch_block_t)done {
    if(index==tracks.count){done();return;}
    NSURL *track=[self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"dash-%lu.mp4",(unsigned long)index]];
    if(![[NSFileManager defaultManager]createFileAtPath:track.path contents:nil attributes:nil]){[self finish:nil response:nil error:StreamError(@"无法创建音视频轨道文件")];return;}
    [self resources:tracks[index][@"resources"] index:0 folder:self.root appendTo:track completion:^{[self.inputs addObject:track];[self dashTracks:tracks index:index+1 completion:done];}];
}
- (void)resources:(NSArray *)resources index:(NSUInteger)index folder:(NSURL *)folder appendTo:(NSURL *)append completion:(dispatch_block_t)done {
    if(index==resources.count){done();return;}
    NSDictionary *resource=resources[index];
    [self fetch:[NSURL URLWithString:resource[@"url"]] range:resource[@"range"] limit:[resource[@"key"] boolValue]?16:[PerformancePolicy downloadMaxSingleFileBytes] completion:^(NSURL *file,NSHTTPURLResponse *response){
        if([resource[@"key"] boolValue] && [[[NSFileManager defaultManager]attributesOfItemAtPath:file.path error:nil][NSFileSize] longLongValue]!=16){[self finish:nil response:nil error:StreamError(@"AES-128 密钥长度无效")];return;}
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSError *error=nil;
            if(append){
                NSFileHandle *reader=[NSFileHandle fileHandleForReadingFromURL:file error:&error];NSFileHandle *writer=[NSFileHandle fileHandleForWritingToURL:append error:&error];
                @try{[writer seekToEndOfFile];while(!error){NSData *chunk=[reader readDataUpToLength:1024*1024 error:&error];if(!chunk.length)break;[writer writeData:chunk error:&error];}}@catch(NSException *exception){error=StreamError(@"写入媒体分片失败");}
                [reader closeFile];[writer closeFile];
            }else [[NSFileManager defaultManager]moveItemAtURL:file toURL:[folder URLByAppendingPathComponent:resource[@"local"]] error:&error];
            dispatch_async(dispatch_get_main_queue(),^{if(self.finished)return;if(error){[self finish:nil response:nil error:error];return;}[self step:^{[self resources:resources index:index+1 folder:folder appendTo:append completion:done];}];});
        });
    }];
}
- (void)mux {
    [self step:^{
        NSMutableArray *args=[NSMutableArray arrayWithArray:@[@"-hide_banner",@"-nostdin",@"-loglevel",@"error",@"-y"]];
        for(NSURL *input in self.inputs){[args addObjectsFromArray:@[@"-protocol_whitelist",@"file,crypto"]];if([input.pathExtension isEqual:@"m3u8"]){
            // ffmpeg 8.0 hls 解复用器三道扩展名检查全开白名单：本地分片落地名可能无
            // 常见多媒体扩展（resource-*.bin），旧参数 -allowed_extensions ALL 只过第一道
            //（2026-09-19 现场：angel-one-hls / test_001 分片齐但合流被拒，stderr 已入日志）。
            [args addObjectsFromArray:@[@"-allowed_extensions",@"ALL",@"-allowed_segment_extensions",@"ALL",@"-extension_picky",@"0"]];}
            [args addObjectsFromArray:@[@"-i",input.path]];}
        [args addObjectsFromArray:@[@"-map",@"0:v:0"]];
        [args addObjectsFromArray:self.inputs.count>1 ? @[@"-map",@"1:a:0"] : @[@"-map",@"0:a:0?"]];
        [args addObjectsFromArray:@[@"-c",@"copy",@"-movflags",@"+faststart",@"-f",@"mp4",self.output.path]];
        NSTask *process=[NSTask new];process.executableURL=self.muxer;process.arguments=args;
        process.standardInput=NSFileHandle.fileHandleWithNullDevice;process.standardOutput=NSFileHandle.fileHandleWithNullDevice;
        // ffmpeg 的 stderr 落临时文件：合成失败时把真实原因写进任务日志（此前被丢弃，
        // "无法合成"在日志里无从诊断 —— 2026-09-19 现场复现 test_001/angel-one-hls 两站）。
        NSString *errPath=[self.output.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:@"mux-ffmpeg-err.log"];
        [[NSFileManager defaultManager]removeItemAtPath:errPath error:nil];
        if(![[NSFileManager defaultManager]createFileAtPath:errPath contents:nil attributes:nil]){errPath=nil;}
        if(errPath){process.standardError=[NSFileHandle fileHandleForWritingAtPath:errPath];}
        else process.standardError=NSFileHandle.fileHandleWithNullDevice;
        self.process=process;__weak typeof(self) weak=self;
        process.terminationHandler=^(NSTask *p){dispatch_async(dispatch_get_main_queue(),^{
            typeof(self) self=weak;if(!self||self.finished)return;
            if(p.terminationStatus!=0){
                NSString *ffErr=errPath?[NSString stringWithContentsOfFile:errPath encoding:NSUTF8StringEncoding error:nil]:nil;
                NSString *detail=[NSString stringWithFormat:@"分片下载完成，但无法合成为可播放视频；请检查源站编码或重试"];
                if(ffErr.length)detail=[detail stringByAppendingFormat:@"（ffmpeg：%@）",ffErr.lastPathComponent];
                RDLogWrite(@"dl", @"合流失败 ffmpeg 输出：%@（完整输出在同目录 mux-ffmpeg-err.log）", ffErr?:@"（空）");
                [self finish:nil response:nil error:StreamError(detail)];return;}
            int64_t size=[[[NSFileManager defaultManager]attributesOfItemAtPath:self.output.path error:nil][NSFileSize] longLongValue];
            if(size<=0||![DownloadJob isLikelyVideoFileAtURL:self.output]){[self finish:nil response:nil error:StreamError(@"合成文件校验失败")];return;}
            NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"video/mp4",@"Content-Length":@(size).stringValue}];
            [self finish:self.output response:response error:nil];
        });};
        NSError *error=nil;if(![process launchAndReturnError:&error])[self finish:nil response:nil error:error];
    }];
}
@end
