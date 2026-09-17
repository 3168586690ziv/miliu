#import "AdaptiveTransferScheduler.h"
@interface AdaptiveTransferScheduler () {
    NSInteger _window;
    NSInteger _maximum;
    NSUInteger _stableSamples;
    NSUInteger _lowRateSamples;
    double _lastRate;
    NSMutableDictionary<NSString *, NSValue *> *_streamRates;
}
@end
@implementation AdaptiveTransferScheduler
- (instancetype)initWithInitialWindow:(NSInteger)initial maximumWindow:(NSInteger)maximum {
    if ((self = [super init])) {
        _maximum = MAX(1, maximum);
        _window = MIN(MAX(1, initial), _maximum);
        _streamRates = [NSMutableDictionary dictionary];
    }
    return self;
}
- (NSInteger)window { return _window; }
- (NSInteger)recordThroughput:(double)rate error:(BOOL)error throttled:(BOOL)throttled {
    return [self recordThroughput:rate error:error throttled:throttled streamIdentifier:nil];
}

// BUG-044: raw task rates are stored separately, then the shared window uses the
// median healthy rate. A fast and a slow task therefore cannot make each callback
// look like a drastic aggregate change, and one task cannot halve the global window.
- (NSInteger)recordThroughput:(double)rate error:(BOOL)error
                    throttled:(BOOL)throttled streamIdentifier:(NSString *)identifier {
    if (identifier.length) {
        _streamRates[identifier] = @(MAX(0.0, rate));
    }
    NSMutableArray<NSNumber *> *rates = [NSMutableArray array];
    for (NSValue *value in _streamRates.allValues) {
        double item = [(NSNumber *)value doubleValue];
        if (item > 0) [rates addObject:@(item)];
    }
    [rates sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
    double sampledRate = rate;
    if (rates.count) {
        NSUInteger middle = rates.count / 2;
        sampledRate = (rates.count % 2)
            ? rates[middle].doubleValue
            : (rates[middle - 1].doubleValue + rates[middle].doubleValue) / 2.0;
    }

    if (error || throttled) {
        _window = MAX(1, (_window + 1) / 2);
        _stableSamples = 0;
        _lowRateSamples = 0;
        _lastRate = MAX(0.0, sampledRate);
        return _window;
    }

    // Three consecutive median samples below 1 MB/s shrink once, then require
    // fresh evidence. This preserves the old bounded response to genuine throttling.
    if (sampledRate > 0 && sampledRate < 1000000.0) {
        _lowRateSamples += 1;
        _stableSamples = 0;
        if (_lowRateSamples >= 3) {
            _window = MAX(1, (_window + 1) / 2);
            _lowRateSamples = 0;
        }
    } else {
        _lowRateSamples = 0;
    }

    if (sampledRate > 0 && (_lastRate <= 0 || sampledRate >= _lastRate * 0.85)) {
        _stableSamples += 1;
        if (_stableSamples >= 3 && _window < _maximum) {
            _window = MIN(_maximum, _window * 2);
            _stableSamples = 0;
        }
    } else if (sampledRate > 0 && _lastRate > 0 && sampledRate < _lastRate * 0.55) {
        _window = MAX(1, (_window + 1) / 2);
        _stableSamples = 0;
    }
    if (sampledRate > 0) _lastRate = sampledRate;
    return _window;
}

- (void)removeStreamIdentifier:(NSString *)identifier {
    if (identifier.length) [_streamRates removeObjectForKey:identifier];
}
@end
