#import "MarketModule.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSColor *MC(double r,double g,double b,double a){return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];}

NSArray<NSDictionary *> *MarketPointsFromNasdaqJSON(NSData *data) {
    NSMutableArray *points=[NSMutableArray array]; NSError *jsonError=nil;
    id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]:nil;
    if(![parsed isKindOfClass:NSDictionary.class])return points;
    NSDictionary *json=(NSDictionary *)parsed;
    id dataNode=json[@"data"];
    id table=[dataNode isKindOfClass:NSDictionary.class]?dataNode[@"tradesTable"]:nil;
    id rowNode=[table isKindOfClass:NSDictionary.class]?table[@"rows"]:nil;
    NSArray *rows=[rowNode isKindOfClass:NSArray.class]?rowNode:@[];
    NSDateFormatter *f=[NSDateFormatter new]; f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat=@"MM/dd/yyyy";
    for(id item in rows){if(![item isKindOfClass:NSDictionary.class])continue;NSDictionary *row=item;id closeNode=row[@"close"];id dateNode=row[@"date"];if(![closeNode isKindOfClass:NSString.class]||![dateNode isKindOfClass:NSString.class])continue;NSString *v=[closeNode stringByReplacingOccurrencesOfString:@"," withString:@""];NSDate *d=[f dateFromString:dateNode];double close=v.doubleValue;if(d&&isfinite(close)&&close>0)[points addObject:@{@"time":@([d timeIntervalSince1970]),@"close":@(close)}];}
    [points sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"time"] compare:b[@"time"]];}]; return points;
}

NSArray<NSDictionary *> *MarketPointsFromFREDCSV(NSData *data) {
    NSMutableArray *points=[NSMutableArray array]; NSString *csv=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
    NSDateFormatter *f=[NSDateFormatter new];f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];f.dateFormat=@"yyyy-MM-dd";
    for(NSString *line in [csv componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){NSArray *p=[line componentsSeparatedByString:@","];if(p.count<2||[p[0] isEqualToString:@"observation_date"]||[p[1] isEqualToString:@"."])continue;NSDate *d=[f dateFromString:p[0]];if(d&&[p[1] doubleValue]>0)[points addObject:@{@"time":@([d timeIntervalSince1970]),@"close":@([p[1] doubleValue])}];} return points;
}

NSArray<NSDictionary *> *MarketPointsFromYahooJSON(NSData *data) {
    NSMutableArray *points=[NSMutableArray array]; NSError *jsonError=nil;
    id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]:nil;
    if(![parsed isKindOfClass:NSDictionary.class])return points;
    id chart=((NSDictionary *)parsed)[@"chart"];
    id resultNode=[chart isKindOfClass:NSDictionary.class]?chart[@"result"]:nil;
    id firstResult=[resultNode isKindOfClass:NSArray.class]?[(NSArray *)resultNode firstObject]:nil;
    NSDictionary *result=[firstResult isKindOfClass:NSDictionary.class]?firstResult:@{};
    NSArray *timestamps=[result[@"timestamp"] isKindOfClass:NSArray.class]?result[@"timestamp"]:@[];
    id indicators=result[@"indicators"];
    id quoteNode=[indicators isKindOfClass:NSDictionary.class]?indicators[@"quote"]:nil;
    id firstQuote=[quoteNode isKindOfClass:NSArray.class]?[(NSArray *)quoteNode firstObject]:nil;
    NSArray *closes=[firstQuote isKindOfClass:NSDictionary.class]&&[firstQuote[@"close"] isKindOfClass:NSArray.class]?firstQuote[@"close"]:@[];
    if(![closes isKindOfClass:NSArray.class]) return points;
    NSUInteger count=MIN(timestamps.count,closes.count);
    for(NSUInteger i=0;i<count;i++){NSNumber *time=[timestamps[i] isKindOfClass:NSNumber.class]?timestamps[i]:nil;NSNumber *close=[closes[i] isKindOfClass:NSNumber.class]?closes[i]:nil;if(time&&close&&isfinite(time.doubleValue)&&isfinite(close.doubleValue)&&close.doubleValue>0)[points addObject:@{@"time":time,@"close":close}];}
    [points sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"time"] compare:b[@"time"]];}];
    return points;
}

@interface MarketChartView ()
@property (strong) NSTrackingArea *hoverTrackingArea;
@property NSInteger hoveredIndex;
@end

@implementation MarketChartView
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if(self){
        self.wantsLayer=YES; self.layer.cornerRadius=14;
        self.layer.backgroundColor=MC(.035,.038,.046,.96).CGColor;
        self.layer.borderWidth=1; self.layer.borderColor=MC(.34,.40,.48,.88).CGColor;
        self.points=@[]; self.emptyMessage=@"正在读取指数数据…"; self.valueSuffix=@"";
        self.displayTimeZone=[NSTimeZone timeZoneWithName:@"America/New_York"];
        self.displayDateFormat=@"M月d日 HH:mm";
        _hoveredIndex=NSNotFound;
    }
    return self;
}
- (void)setPoints:(NSArray<NSDictionary *> *)points {
    NSMutableArray<NSDictionary *> *valid=[NSMutableArray array];
    for(id item in points){
        if(![item isKindOfClass:NSDictionary.class])continue;
        id time=item[@"time"],close=item[@"close"];
        if(![time isKindOfClass:NSNumber.class]||![close isKindOfClass:NSNumber.class])continue;
        if(!isfinite([time doubleValue])||!isfinite([close doubleValue]))continue;
        [valid addObject:item];
    }
    _points=[valid copy]; _hoveredIndex=NSNotFound; self.needsDisplay=YES;
}
- (void)setTrendChangePercent:(NSNumber *)trendChangePercent {
    _trendChangePercent=trendChangePercent;
    self.needsDisplay=YES;
}
- (void)updateTrackingAreas {
    if(self.hoverTrackingArea)[self removeTrackingArea:self.hoverTrackingArea];
    self.hoverTrackingArea=[[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways) owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea]; [super updateTrackingAreas];
}
- (void)resetCursorRects { [super resetCursorRects]; [self addCursorRect:NSInsetRect(self.bounds,20,18) cursor:NSCursor.crosshairCursor]; }
NSInteger MarketNearestPointIndex(NSUInteger count, NSRect plot, NSPoint location) {
    if (count < 2) return NSNotFound;
    // 允许右边界命中（NSPointInRect 对 maxX 为开区间）
    BOOL inX = (location.x >= NSMinX(plot) && location.x <= NSMaxX(plot));
    BOOL inY = (location.y >= NSMinY(plot) && location.y <= NSMaxY(plot));
    if (!(inX && inY)) return NSNotFound;
    CGFloat progress = (location.x - NSMinX(plot)) / plot.size.width;
    return MAX(0, MIN((NSInteger)count - 1, (NSInteger)llround(progress * (count - 1))));
}

NSDictionary *MarketTooltipDataForPoints(NSArray<NSDictionary *> *points, NSInteger idx) {
    if (!points || points.count == 0 || idx < 0 || idx >= (NSInteger)points.count) return nil;
    return points[idx];
}

double MarketChinaTradingProgressForTimestamp(NSTimeInterval timestamp) {
    if(!isfinite(timestamp))return NAN;
    static NSCalendar *calendar=nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        calendar=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    });
    NSDateComponents *parts=[calendar components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
    NSInteger minute=parts.hour*60+parts.minute;
    NSInteger offset=NSNotFound;
    if(minute>=9*60+30&&minute<=11*60+30)offset=minute-(9*60+30);
    else if(minute>=13*60&&minute<=15*60)offset=120+minute-13*60;
    return offset==NSNotFound?NAN:(double)offset/240.0;
}

BOOL MarketChartTrendIsUp(NSArray<NSDictionary *> *points, NSNumber *dailyChangePercent) {
    if(dailyChangePercent)return dailyChangePercent.doubleValue>=0;
    if(points.count<2)return YES;
    return [points.lastObject[@"close"] doubleValue]>=[points.firstObject[@"close"] doubleValue];
}

- (CGFloat)xForPoint:(NSDictionary *)point inPlot:(NSRect)plot {
    if(self.timeAxisStart&&self.timeAxisEnd&&self.timeAxisEnd.doubleValue>self.timeAxisStart.doubleValue){
        double progress=([point[@"time"] doubleValue]-self.timeAxisStart.doubleValue)/(self.timeAxisEnd.doubleValue-self.timeAxisStart.doubleValue);
        return NSMinX(plot)+plot.size.width*MIN(1.0,MAX(0.0,progress));
    }
    if(!self.usesChinaTradingSessionAxis)return NAN;
    double progress=MarketChinaTradingProgressForTimestamp([point[@"time"] doubleValue]);
    return isfinite(progress)?NSMinX(plot)+plot.size.width*progress:NAN;
}

- (NSInteger)pointIndexForMouseLocation:(NSPoint)location {
    NSRect plot = NSInsetRect(self.bounds, self.showsAxisLabels?54:20, self.showsAxisLabels?28:18);
    if(self.usesChinaTradingSessionAxis||self.timeAxisStart){
        BOOL inside=location.x>=NSMinX(plot)&&location.x<=NSMaxX(plot)&&location.y>=NSMinY(plot)&&location.y<=NSMaxY(plot);
        if(!inside||self.points.count<2)return NSNotFound;
        CGFloat lastX=[self xForPoint:self.points.lastObject inPlot:plot];
        if(!isfinite(lastX)||location.x>lastX+MAX(4.0,plot.size.width/240.0))return NSNotFound;
        NSInteger nearest=NSNotFound;CGFloat distance=CGFLOAT_MAX;
        for(NSInteger i=0;i<(NSInteger)self.points.count;i++){
            CGFloat x=[self xForPoint:self.points[i] inPlot:plot];if(!isfinite(x))continue;
            CGFloat candidate=fabs(location.x-x);if(candidate<distance){distance=candidate;nearest=i;}
        }
        return nearest;
    }
    return MarketNearestPointIndex(self.points.count, plot, location);
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = [self pointIndexForMouseLocation:point];
    if (index != self.hoveredIndex) { self.hoveredIndex = index; self.needsDisplay = YES; }
}
- (void)mouseExited:(NSEvent *)event { if(self.hoveredIndex!=NSNotFound){self.hoveredIndex=NSNotFound;self.needsDisplay=YES;} }
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty]; NSRect plot=NSInsetRect(self.bounds,self.showsAxisLabels?54:20,self.showsAxisLabels?28:18);
    if(self.points.count<2){
        NSString *message=self.emptyMessage.length?self.emptyMessage:@"暂无趋势数据";
        NSSize size=[message sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13]}];
        [message drawAtPoint:NSMakePoint(NSMidX(self.bounds)-size.width/2,NSMidY(self.bounds)-8) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:MC(.58,.65,.73,1)}]; return;
    }
    double low=DBL_MAX,high=-DBL_MAX;
    for(NSDictionary *item in self.points){double value=[item[@"close"] doubleValue];low=MIN(low,value);high=MAX(high,value);}
    double magnitude=MAX(MAX(fabs(high),fabs(low)),1.0);
    double pad=MAX((high-low)*.16,magnitude*.004);
    low-=pad; high+=pad;
    NSBezierPath *grid=[NSBezierPath bezierPath]; [MC(.24,.30,.38,.62) setStroke];
    for(int i=0;i<4;i++){CGFloat y=NSMinY(plot)+plot.size.height*i/3.;[grid moveToPoint:NSMakePoint(NSMinX(plot),y)];[grid lineToPoint:NSMakePoint(NSMaxX(plot),y)];}
    [grid stroke];
    NSBezierPath *line=[NSBezierPath bezierPath]; line.lineWidth=2.4;line.lineJoinStyle=NSLineJoinStyleRound;line.lineCapStyle=NSLineCapStyleRound;BOOL moved=NO;
    for(NSInteger i=0;i<self.points.count;i++){
        double value=[self.points[i][@"close"] doubleValue]; CGFloat x=(self.usesChinaTradingSessionAxis||self.timeAxisStart)?[self xForPoint:self.points[i] inPlot:plot]:NSMinX(plot)+plot.size.width*i/(self.points.count-1), y=NSMinY(plot)+plot.size.height*(value-low)/(high-low);
        if(!isfinite(x))continue;if(moved)[line lineToPoint:NSMakePoint(x,y)];else{[line moveToPoint:NSMakePoint(x,y)];moved=YES;}
    }
    NSColor *trendColor=MarketChartTrendIsUp(self.points,self.trendChangePercent)?MC(1,.46,.56,1):MC(.47,.82,.62,1);
    if(self.showsAreaFill&&moved){
        NSBezierPath *area=[line copy];
        CGFloat lastX=(self.usesChinaTradingSessionAxis||self.timeAxisStart)?[self xForPoint:self.points.lastObject inPlot:plot]:NSMaxX(plot);
        CGFloat firstX=(self.usesChinaTradingSessionAxis||self.timeAxisStart)?[self xForPoint:self.points.firstObject inPlot:plot]:NSMinX(plot);
        [area lineToPoint:NSMakePoint(lastX,NSMinY(plot))];[area lineToPoint:NSMakePoint(firstX,NSMinY(plot))];[area closePath];
        [NSGraphicsContext saveGraphicsState];[area addClip];
        NSGradient *fade=[[NSGradient alloc] initWithStartingColor:[trendColor colorWithAlphaComponent:.28] endingColor:[trendColor colorWithAlphaComponent:.015]];
        [fade drawFromPoint:NSMakePoint(0,NSMaxY(plot)) toPoint:NSMakePoint(0,NSMinY(plot)) options:0];[NSGraphicsContext restoreGraphicsState];
    }
    [trendColor setStroke]; [line stroke];
    if(self.showsAxisLabels){
        NSDictionary *attrs=@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],NSForegroundColorAttributeName:MC(.55,.62,.70,1)};
        for(int i=0;i<4;i++){double v=low+(high-low)*i/3.0;NSString *s=[NSString stringWithFormat:@"%.0f",v];[s drawAtPoint:NSMakePoint(8,NSMinY(plot)+plot.size.height*i/3.0-5) withAttributes:attrs];}
        NSDateFormatter *axis=[NSDateFormatter new];axis.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];axis.timeZone=self.displayTimeZone?:NSTimeZone.localTimeZone;axis.dateFormat=@"M/d";
        NSString *left=[axis stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.timeAxisStart?[self.timeAxisStart doubleValue]:[self.points.firstObject[@"time"] doubleValue]]];
        NSString *right=[axis stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.timeAxisEnd?[self.timeAxisEnd doubleValue]:[self.points.lastObject[@"time"] doubleValue]]];
        [left drawAtPoint:NSMakePoint(NSMinX(plot),5) withAttributes:attrs];NSSize rs=[right sizeWithAttributes:attrs];[right drawAtPoint:NSMakePoint(NSMaxX(plot)-rs.width,5) withAttributes:attrs];
    }
    if(self.hoveredIndex==NSNotFound)return;
    NSDictionary *item=[self tooltipDataForPoints:self.points atIndex:self.hoveredIndex]; if(!item)return; double value=[item[@"close"] doubleValue];
    CGFloat x=(self.usesChinaTradingSessionAxis||self.timeAxisStart)?[self xForPoint:item inPlot:plot]:NSMinX(plot)+plot.size.width*self.hoveredIndex/(self.points.count-1), y=NSMinY(plot)+plot.size.height*(value-low)/(high-low);
    NSBezierPath *crosshair=[NSBezierPath bezierPath]; crosshair.lineWidth=1;
    [crosshair moveToPoint:NSMakePoint(x,NSMinY(plot))];[crosshair lineToPoint:NSMakePoint(x,NSMaxY(plot))];[crosshair moveToPoint:NSMakePoint(NSMinX(plot),y)];[crosshair lineToPoint:NSMakePoint(NSMaxX(plot),y)];
    [MC(.78,.84,.91,.52) setStroke]; [crosshair stroke];
    [trendColor setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-4,y-4,8,8)] fill];
    NSDateFormatter *formatter=[NSDateFormatter new]; formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"]; formatter.timeZone=self.displayTimeZone?:[NSTimeZone localTimeZone]; formatter.dateFormat=self.displayDateFormat.length?self.displayDateFormat:@"M月d日";
    NSString *pointLabel=[item[@"label"] isKindOfClass:NSString.class]?item[@"label"]:[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"time"] doubleValue]]];
    NSString *label=[NSString stringWithFormat:@"%.2f%@\n%@",value,self.valueSuffix?:@"",pointLabel];
    CGFloat tooltipWidth=[item[@"label"] isKindOfClass:NSString.class]?MIN(280,MAX(158,[label sizeWithAttributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium]}].width+18)):158;
    NSRect tooltip=NSMakeRect(MIN(NSMaxX(plot)-tooltipWidth,MAX(NSMinX(plot),x+10)),MIN(NSMaxY(plot)-44,MAX(NSMinY(plot),y+10)),tooltipWidth,44);
    NSBezierPath *bubble=[NSBezierPath bezierPathWithRoundedRect:tooltip xRadius:7 yRadius:7]; [MC(.08,.10,.13,.96) setFill];[bubble fill]; [MC(.55,.63,.72,.8) setStroke];[bubble stroke];
    [label drawInRect:NSInsetRect(tooltip,8,5) withAttributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor}];
}
- (NSDictionary *)tooltipDataForPoints:(NSArray<NSDictionary *> *)points atIndex:(NSInteger)idx {
    return MarketTooltipDataForPoints(points, idx);
}
@end

@interface MarketNewsParser ()
@property(strong)NSMutableString *buffer;@property BOOL insideItem;@property BOOL insideTitle;@property BOOL insideLink;
@end
@implementation MarketNewsParser
- (instancetype)init{self=[super init];if(self){_titles=[NSMutableArray array];_links=[NSMutableArray array];_buffer=[NSMutableString string];}return self;}
- (void)parser:(NSXMLParser*)p didStartElement:(NSString*)e namespaceURI:(NSString*)u qualifiedName:(NSString*)q attributes:(NSDictionary*)a{if([e isEqualToString:@"item"])self.insideItem=YES;if(self.insideItem&&([e isEqualToString:@"title"]||[e isEqualToString:@"link"])){self.insideTitle=[e isEqualToString:@"title"];self.insideLink=[e isEqualToString:@"link"];[self.buffer setString:@""];}}
- (void)parser:(NSXMLParser*)p foundCharacters:(NSString*)s{if(self.insideTitle||self.insideLink)[self.buffer appendString:s];}
- (void)parser:(NSXMLParser*)p didEndElement:(NSString*)e namespaceURI:(NSString*)u qualifiedName:(NSString*)q{if(self.insideTitle&&[e isEqualToString:@"title"]){if(self.buffer.length)[self.titles addObject:self.buffer.copy];self.insideTitle=NO;}if(self.insideLink&&[e isEqualToString:@"link"]){if(self.buffer.length)[self.links addObject:self.buffer.copy];self.insideLink=NO;}if([e isEqualToString:@"item"])self.insideItem=NO;}
@end
