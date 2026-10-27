#import "ExampleScenarios.h"
#import <WebKit/WebKit.h>

// Example app only: native scenarios + deep links: the URL scheme (`edgerumexample://<name>`), or a launch
// argument (`xcrun simctl launch booted <app id> -scenario <name>`), which skips the "Open in…?" prompt.
@implementation ExampleScenarios {
    BOOL _listening;
    NSString *_pending;
}

- (void)pluginInitialize {
    NSString *s = [NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain][@"scenario"];
    if (s) [self deliver:s];
}

- (void)handleOpenURL:(NSNotification *)notification {
    NSURL *url = notification.object;
    if ([url.scheme isEqualToString:@"edgerumexample"] && url.host) [self deliver:url.host];
}

- (void)listen:(CDVInvokedUrlCommand *)command {
    _listening = YES;
    CDVPluginResult *r = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:_pending ?: @""];
    _pending = nil;
    [self.commandDelegate sendPluginResult:r callbackId:command.callbackId];
}

- (void)slow:(CDVInvokedUrlCommand *)command {
    double ms = [command.arguments.firstObject doubleValue];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    });
}

- (void)hang:(CDVInvokedUrlCommand *)command {
    double ms = [command.arguments.firstObject doubleValue];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSThread sleepForTimeInterval:ms / 1000]; });
}

- (void)crash:(CDVInvokedUrlCommand *)command {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSException raise:NSInternalInconsistencyException format:@"Example native crash"];
    });
}

- (void)killRenderer:(CDVInvokedUrlCommand *)command {
    // Answered first: the call must not outlive the content process as a no_callback.
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    // ponytail: private WebKit API, fine in a test app; never ship this.
    WKWebView *web = (WKWebView *)self.webViewEngine.engineWebView;
    SEL kill = NSSelectorFromString(@"_killWebContentProcess");
    if ([web respondsToSelector:kill]) ((void (*)(id, SEL))[web methodForSelector:kill])(web, kill);
}

// Pushed by eval, not a keep-callback: an open call would be reported as `bridge.call` no_callback.
- (void)deliver:(NSString *)scenario {
    // Deep links are untrusted input to eval.
    if ([scenario rangeOfString:@"^[a-z-]+$" options:NSRegularExpressionSearch].location == NSNotFound) return;
    if (!_listening) {
        _pending = scenario;
        return;
    }
    [self.commandDelegate evalJs:[NSString stringWithFormat:@"window.runScenario('%@')", scenario]];
}

@end
