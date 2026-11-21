#import "DSHRHWebEndpoint.h"

static NSString *const DSHRHDefaultToken = @"dshios-fixed-token-8f3a2c";

NSURL *DSHRHBuildWebEndpoint(NSString *portText, NSString *tokenText) {
    NSString *port = [portText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *asciiDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    BOOL validPort = port.length > 0 && port.length <= 5 &&
        [port rangeOfCharacterFromSet:asciiDigits.invertedSet].location == NSNotFound;
    NSInteger number = validPort ? port.integerValue : 3080;
    if (number < 1 || number > 65535) number = 3080;

    NSString *token = tokenText.length ? tokenText : DSHRHDefaultToken;
    NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [token stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
    if (!encoded) encoded = DSHRHDefaultToken;
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"http";
    components.host = @"127.0.0.1";
    components.port = @(number);
    components.path = @"/";
    // Encode '+' as well: Node's query decoder treats a literal '+' as a space.
    components.percentEncodedQuery = [@"token=" stringByAppendingString:encoded];
    return components.URL ?: [NSURL URLWithString:
        @"http://127.0.0.1:3080/?token=dshios-fixed-token-8f3a2c"];
}

BOOL DSHRHIsLocalWebEndpoint(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return NO;
    if (!([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"])) return NO;
    if (components.user.length || components.password.length) return NO;
    if (components.port && (components.port.integerValue < 1 || components.port.integerValue > 65535)) return NO;
    return YES;
}
