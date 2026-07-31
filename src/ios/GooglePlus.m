#import "AppDelegate.h"
#import "objc/runtime.h"
#import "GooglePlus.h"

@implementation GooglePlus

- (void)pluginInitialize
{
    NSLog(@"GooglePlus pluginInitizalize");
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOpenURL:) name:CDVPluginHandleOpenURLNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOpenURLWithAppSourceAndAnnotation:) name:CDVPluginHandleOpenURLWithAppSourceAndAnnotationNotification object:nil];
}

- (void)handleOpenURL:(NSNotification*)notification
{
    // no need to handle this handler, we dont have an sourceApplication here, which is required by GIDSignIn handleURL
}

- (void)handleOpenURLWithAppSourceAndAnnotation:(NSNotification*)notification
{
    NSMutableDictionary * options = [notification object];

    NSURL* url = options[@"url"];
    if (url == nil) {
        return;
    }

    NSString* possibleReversedClientId = [url.absoluteString componentsSeparatedByString:@":"].firstObject;

    // ⚠️ 예전에는 이 조건에 `&& self.isSigningIn` 이 붙어 있었는데, isSigningIn 을 YES 로
    //    만드는 곳이 GIDSignInDelegate 의 signIn:presentViewController: 하나뿐이었다.
    //    그 프로토콜은 GoogleSignIn 5.0 에서 삭제되어 호출되지 않으므로 isSigningIn 은 항상 NO 였고,
    //    결과적으로 handleURL: 이 단 한 번도 실행되지 않았다.
    //    (지금 로그인이 되는 건 최신 SDK 가 ASWebAuthenticationSession 으로 콜백을 자체 처리하기 때문)
    //    handleURL: 은 자기 콜백이 아니면 NO 를 돌려주고 아무것도 하지 않으므로 호출해도 안전하다.
    if ([possibleReversedClientId isEqualToString:self.getreversedClientId]) {
        [GIDSignIn.sharedInstance handleURL:url];
    }
}


- (void) login:(CDVInvokedUrlCommand*)command {
    _callbackId = command.callbackId;
    NSString *reversedClientId = [self getreversedClientId];

    if (reversedClientId == nil) {
        [self sendLoginErrorMessage:@"Could not find REVERSED_CLIENT_ID url scheme in app .plist"];
        return;
    }

    // ⚠️ 인자 방어. 예전에는 command.arguments[0] 을 그대로 읽어서, 인자 없이 호출하면
    //    NSRangeException, null 이 오면 NSNull 에 objectForKeyedSubscript: 를 보내 크래시였다.
    NSDictionary *options = nil;
    if (command.arguments.count > 0 && [command.arguments[0] isKindOfClass:[NSDictionary class]]) {
        options = command.arguments[0];
    }

    NSArray *scopes = [self scopesFromOptions:options];

    [GIDSignIn.sharedInstance signInWithPresentingViewController:self.viewController
                                                           hint:nil
                                               additionalScopes:(scopes.count > 0 ? scopes : nil)
                                                     completion:^(GIDSignInResult * _Nullable signInResult, NSError * _Nullable error) {
        if (error) {
            [self sendLoginErrorMessage:error.localizedDescription];
            return;
        }
        [self finishLoginWithUser:signInResult.user requestedScopes:scopes];
    }];
}

/**
 * options["scopes"] (공백으로 구분된 문자열) 를 배열로 바꾼다.
 * 연속 공백이 들어와도 빈 문자열이 스코프로 섞이지 않게 걸러낸다.
 */
- (NSArray*) scopesFromOptions:(NSDictionary*)options {
    NSString *scopesString = options[@"scopes"];
    if (![scopesString isKindOfClass:[NSString class]] || scopesString.length == 0) {
        return @[];
    }

    NSArray *raw = [scopesString componentsSeparatedByString:@" "];
    return [raw filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
}

/**
 * 요청한 스코프 중 아직 승인되지 않은 것들을 돌려준다.
 */
- (NSArray*) missingScopesIn:(NSArray*)requested granted:(NSArray*)granted {
    if (requested.count == 0) {
        return @[];
    }

    NSArray *grantedOrEmpty = granted ? : @[];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *scope in requested) {
        if (![grantedOrEmpty containsObject:scope]) {
            [missing addObject:scope];
        }
    }
    return missing;
}

/**
 * ⚠️ additionalScopes 는 "요청" 일 뿐 승인 보장이 아니다.
 *    구글의 granular consent 때문에 사용자가 스코프 체크박스를 해제한 채로 로그인해도
 *    completion 은 성공으로 들어오고, 그 상태의 accessToken 으로 API 를 부르면 403 이 난다.
 *    예전에는 이 검증이 없어서 쓸모없는 토큰을 그대로 앱에 돌려줬다.
 *
 *    부족하면 addScopes: 로 추가 동의 화면을 한 번 더 띄운다(증분 인가). 그래도 안 되면 에러다.
 */
- (void) finishLoginWithUser:(GIDGoogleUser*)user requestedScopes:(NSArray*)scopes {
    if (user == nil) {
        [self sendLoginErrorMessage:@"Sign-in returned no user"];
        return;
    }

    NSArray *missing = [self missingScopesIn:scopes granted:user.grantedScopes];
    if (missing.count == 0) {
        [self sendLoginSuccessWithUser:user];
        return;
    }

    [user addScopes:missing
presentingViewController:self.viewController
         completion:^(GIDSignInResult * _Nullable signInResult, NSError * _Nullable error) {
        if (error) {
            [self sendLoginErrorMessage:error.localizedDescription missingScopes:missing];
            return;
        }

        GIDGoogleUser *updatedUser = signInResult.user ? : user;
        NSArray *stillMissing = [self missingScopesIn:scopes granted:updatedUser.grantedScopes];
        if (stillMissing.count > 0) {
            [self sendLoginErrorMessage:@"Required Google scopes were not granted"
                          missingScopes:stillMissing];
            return;
        }

        [self sendLoginSuccessWithUser:updatedUser];
    }];
}

/**
 * 안드로이드(GooglePlus.java) 가 돌려주는 필드 구성에 맞춘다.
 * expires    = 만료 시각(epoch 초)
 * expires_in = 남은 초
 *
 * ⚠️ NSDictionary 리터럴에 nil 을 넣으면 NSInvalidArgumentException 으로 앱이 죽는다.
 *    예전에는 email / userId / idToken / accessToken 에 가드가 없었고, 특히 idToken 은
 *    클라이언트 구성에 따라 nil 이 될 수 있어 실제 크래시 위험이었다.
 */
- (void) sendLoginSuccessWithUser:(GIDGoogleUser*)user {
    NSURL *imageUrl = [user.profile imageURLWithDimension:120];
    NSDate *expiration = user.accessToken.expirationDate;

    NSDictionary *result = @{
        @"email"        : user.profile.email                ? : [NSNull null],
        @"userId"       : user.userID                       ? : [NSNull null],
        @"idToken"      : user.idToken.tokenString          ? : [NSNull null],
        @"accessToken"  : user.accessToken.tokenString      ? : [NSNull null],
        @"expires"      : expiration ? @((long long)[expiration timeIntervalSince1970]) : [NSNull null],
        @"expires_in"   : expiration ? @((long long)[expiration timeIntervalSinceNow])  : [NSNull null],
        @"grantedScopes": user.grantedScopes                ? : [NSNull null],
        @"displayName"  : user.profile.name                 ? : [NSNull null],
        @"givenName"    : user.profile.givenName            ? : [NSNull null],
        @"familyName"   : user.profile.familyName           ? : [NSNull null],
        @"imageUrl"     : imageUrl ? imageUrl.absoluteString : [NSNull null],
    };

    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void) sendLoginErrorMessage:(NSString*)message {
    [self sendLoginErrorMessage:message missingScopes:nil];
}

- (void) sendLoginErrorMessage:(NSString*)message missingScopes:(NSArray*)missingScopes {
    NSMutableDictionary *errorDetails = [@{
        @"status": @"error",
        @"message": message ? : @"Unknown error"
    } mutableCopy];

    if (missingScopes.count > 0) {
        errorDetails[@"missingScopes"] = missingScopes;
    }

    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[self toJSONString:errorDetails]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (NSString*) getreversedClientId {
    NSArray* URLTypes = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleURLTypes"];

    if (URLTypes != nil) {
        for (NSDictionary* dict in URLTypes) {
            NSString *urlName = dict[@"CFBundleURLName"];
            if ([urlName isEqualToString:@"REVERSED_CLIENT_ID"]) {
                NSArray* URLSchemes = dict[@"CFBundleURLSchemes"];
                if (URLSchemes != nil) {
                    return URLSchemes[0];
                }
            }
        }
    }
    return nil;
}

- (void) logout:(CDVInvokedUrlCommand*)command {
    [GIDSignIn.sharedInstance signOut];
    NSDictionary *details = @{@"status": @"success", @"message": @"Logged out"};
    CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[self toJSONString:details]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

/**
 * ⚠️ 앱을 재시작하면 GIDSignIn.sharedInstance.currentUser 가 nil 이다.
 *    GoogleSignIn 은 실행 시 세션을 자동 복원하지 않고 restorePreviousSignIn 을 명시적으로
 *    불러야 키체인에서 되살린다. 그 상태로 disconnect 를 부르면 취소할 대상이 없어
 *    아무것도 revoke 하지 않고 성공으로 끝나버린다.
 *
 *    이게 중요한 이유: 사용자가 동의 화면에서 스코프 체크를 해제하면 구글이 그 결정을 기억해서
 *    signOut -> login 을 반복해도 체크박스가 다시 뜨지 않는다. revoke 만이 그 기록을 지운다.
 *    복원에 실패해도 그대로 진행한다(원래 아무것도 못 하던 상태이므로 더 나빠지지 않는다).
 */
- (void) disconnect:(CDVInvokedUrlCommand*)command {
    if (GIDSignIn.sharedInstance.currentUser == nil && [GIDSignIn.sharedInstance hasPreviousSignIn]) {
        [GIDSignIn.sharedInstance restorePreviousSignInWithCompletion:^(GIDGoogleUser * _Nullable user, NSError * _Nullable error) {
            [self performDisconnect:command];
        }];
        return;
    }

    [self performDisconnect:command];
}

- (void) performDisconnect:(CDVInvokedUrlCommand*)command {
    [GIDSignIn.sharedInstance disconnectWithCompletion:^(NSError * _Nullable error) {
        if (error == nil) {
            NSDictionary *details = @{@"status": @"success", @"message": @"Disconnected"};
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[self toJSONString:details]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        } else {
            NSDictionary *details = @{@"status": @"error", @"message": [error localizedDescription]};
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[self toJSONString:details]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }
    }];
}

- (void) isSignedIn:(CDVInvokedUrlCommand*)command {
    bool isSignedIn = [GIDSignIn.sharedInstance currentUser] != nil;
    NSDictionary *details = @{@"status": @"success", @"message": (isSignedIn) ? @"true" : @"false"};
    CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[self toJSONString:details]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString*)toJSONString:(NSDictionary*)dictionaryOrArray {
    NSError *error;
         NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionaryOrArray
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
         if (! jsonData) {
            NSLog(@"%s: error: %@", __func__, error.localizedDescription);
            return @"{}";
         } else {
            return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
         }
}

@end
