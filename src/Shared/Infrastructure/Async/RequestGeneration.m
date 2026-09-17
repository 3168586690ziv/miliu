//
//  RequestGeneration.m — 模块 08
//
#import "RequestGeneration.h"
#import <os/lock.h>

@interface RequestGeneration ()
@property (nonatomic, assign) NSUInteger counter;
@property (nonatomic, assign) os_unfair_lock lock;
@end

@implementation RequestGeneration
- (instancetype)init {
    self = [super init];
    if (self) _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (NSUInteger)nextGeneration {
    os_unfair_lock_lock(&_lock);
    NSUInteger generation = ++_counter;
    os_unfair_lock_unlock(&_lock);
    return generation;
}
- (BOOL)isCurrent:(NSUInteger)generation comparedTo:(NSUInteger)current {
    return generation == current;
}
@end
