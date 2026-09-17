#import <Cocoa/Cocoa.h>

@interface MarketChartView : NSView
@property (nonatomic, copy) NSArray<NSDictionary *> *points;
@property (nonatomic, copy) NSString *emptyMessage;
@property (nonatomic, copy) NSString *valueSuffix;
@property (nonatomic, strong) NSTimeZone *displayTimeZone;
@property (nonatomic, copy) NSString *displayDateFormat;
/// Optional fixed time domain. When both values are present, points are mapped
/// by timestamp instead of being distributed evenly by array index.
@property (nonatomic, strong) NSNumber *timeAxisStart;
@property (nonatomic, strong) NSNumber *timeAxisEnd;
/// Rich presentation used by long-term account/asset charts. Defaults to NO so
/// existing market charts keep their current compact appearance.
@property (nonatomic) BOOL showsAreaFill;
@property (nonatomic) BOOL showsAxisLabels;
/// Uses the fixed 09:30-11:30 / 13:00-15:00 A-share session as the x axis.
/// Missing future minutes therefore remain empty instead of stretching the
/// received prefix across the full plot width.
@property (nonatomic) BOOL usesChinaTradingSessionAxis;
/// Explicit all-day change, normally current quote versus previous close.
/// When nil, legacy charts retain their first/last-point color behavior.
@property (nonatomic, strong) NSNumber *trendChangePercent;
- (NSDictionary *)tooltipDataForPoints:(NSArray<NSDictionary *> *)points atIndex:(NSInteger)idx;
- (NSInteger)pointIndexForMouseLocation:(NSPoint)location;
@end

@interface MarketNewsParser : NSObject <NSXMLParserDelegate>
@property (strong) NSMutableArray<NSString *> *titles;
@property (strong) NSMutableArray<NSString *> *links;
@end

NSArray<NSDictionary *> *MarketPointsFromNasdaqJSON(NSData *data);
NSArray<NSDictionary *> *MarketPointsFromFREDCSV(NSData *data);
NSArray<NSDictionary *> *MarketPointsFromYahooJSON(NSData *data);

/// 纯逻辑：将鼠标横坐标经 chart plot rect 映射到最近数据点索引。
/// count<2 或落在 plot 之外返回 NSNotFound。
NSInteger MarketNearestPointIndex(NSUInteger count, NSRect plot, NSPoint location);

/// 纯逻辑：返回索引对应的数据点（含 time 与 close）；越界返回 nil。
NSDictionary *MarketTooltipDataForPoints(NSArray<NSDictionary *> *points, NSInteger idx);

/// Maps an Asia/Shanghai timestamp onto the compressed 240-minute A-share
/// session. Returns NAN for times outside the two trading sessions.
double MarketChinaTradingProgressForTimestamp(NSTimeInterval timestamp);

/// Chooses the chart direction. An explicit daily change takes precedence
/// over the legacy first/last-point comparison.
BOOL MarketChartTrendIsUp(NSArray<NSDictionary *> *points, NSNumber *dailyChangePercent);
