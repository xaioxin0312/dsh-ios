#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSURL *DSHRHBuildWebEndpoint(NSString * _Nullable portText,
                                             NSString * _Nullable tokenText);
FOUNDATION_EXPORT BOOL DSHRHIsLocalWebEndpoint(NSURL * _Nullable url);

NS_ASSUME_NONNULL_END
