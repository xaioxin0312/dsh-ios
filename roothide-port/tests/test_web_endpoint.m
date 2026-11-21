#import <Foundation/Foundation.h>
#include <stdlib.h>
#import "DSHRHWebEndpoint.h"

static void DSHRHRequire(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSArray *invalid = @[@"", @"0", @"65536", @"-1", @"3080x", @"3080/@example.com", @"999999999999999", @"１２３"];
        for (NSString *text in invalid) {
            NSURL *url = DSHRHBuildWebEndpoint(text, nil);
            DSHRHRequire(DSHRHIsLocalWebEndpoint(url), @"Invalid port must still produce a safe URL");
            DSHRHRequire(url.port.integerValue == 3080, @"Invalid port must use 3080");
        }
        NSURL *initial = DSHRHBuildWebEndpoint(nil, nil);
        DSHRHRequire(initial != nil && DSHRHIsLocalWebEndpoint(initial), @"Cold-start endpoint must never be nil");
        for (NSString *port in @[@"1", @"3080", @"65535", @"  3091\n"]) {
            NSURL *url = DSHRHBuildWebEndpoint(port, @"token");
            DSHRHRequire(url.port.integerValue == port.integerValue, @"Valid port must be retained");
        }
        NSString *token = @"a+b &?#/%中文";
        NSURL *encoded = DSHRHBuildWebEndpoint(@"3081", token);
        NSURLComponents *parts = [NSURLComponents componentsWithURL:encoded resolvingAgainstBaseURL:NO];
        DSHRHRequire([parts.queryItems.firstObject.value isEqualToString:token], @"Token must round-trip");
        DSHRHRequire([encoded.absoluteString containsString:@"%2B"], @"Plus must not turn into a space in Node's query parser");
        DSHRHRequire(!DSHRHIsLocalWebEndpoint(nil), @"A nil endpoint cannot be presented");
        for (NSString *text in @[@"file:///tmp/test", @"about:blank", @"http://example.com/", @"http://user@127.0.0.1:3080/"]) {
            DSHRHRequire(!DSHRHIsLocalWebEndpoint([NSURL URLWithString:text]), @"Fallback must only accept local HTTP(S)");
        }
        NSLog(@"PASS: cold-start endpoint, malformed ports, URL schemes and token encoding");
    }
    return 0;
}
