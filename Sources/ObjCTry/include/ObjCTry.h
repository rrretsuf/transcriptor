#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the reason of any Objective-C exception it raised.
/// Swift cannot catch these; one that escapes a Swift task corrupts the runtime.
NSString *_Nullable ObjCTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
