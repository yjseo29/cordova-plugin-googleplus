#import <Cordova/CDVPlugin.h>
#import <GoogleSignIn/GoogleSignIn.h>

@interface GooglePlus : CDVPlugin

@property (nonatomic, copy) NSString* callbackId;

// ⚠️ isSigningIn 프로퍼티는 제거했다.
//    YES 로 만드는 곳이 GIDSignInDelegate 의 signIn:presentViewController: 뿐이었는데,
//    그 프로토콜은 GoogleSignIn 5.0 에서 삭제되어 호출되지 않는다. 즉 항상 NO 인 값으로
//    handleURL: 호출을 막고 있었다(GooglePlus.m 의 handleOpenURLWithAppSourceAndAnnotation: 참고).

- (void) login:(CDVInvokedUrlCommand*)command;
- (void) logout:(CDVInvokedUrlCommand*)command;
- (void) disconnect:(CDVInvokedUrlCommand*)command;
- (void) isAvailable:(CDVInvokedUrlCommand*)command;
- (void) isSignedIn:(CDVInvokedUrlCommand*)command;

@end
