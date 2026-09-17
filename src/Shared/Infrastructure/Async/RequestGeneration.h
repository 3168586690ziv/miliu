//
//  RequestGeneration.h — 模块 08
//
//  每次新请求递增代次；取消或旧代次回调不得传给 UI。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RequestGeneration : NSObject
- (NSUInteger)nextGeneration;
- (BOOL)isCurrent:(NSUInteger)generation comparedTo:(NSUInteger)current;
@end

NS_ASSUME_NONNULL_END
