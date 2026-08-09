// ⚠️ AppDelegate.h / objc/runtime.h import 는 제거했다. 쓰는 심볼이 0 개였고(옛 스위즐링 잔재),
//    cordova-ios 8 에서 AppDelegate.h 는 호환 shim 으로만 남아 9 에서 제거가 예고돼 있다.
#import "GooglePlus.h"

@implementation GooglePlus

- (void)pluginInitialize
{
    NSLog(@"GooglePlus pluginInitizalize");
    // ⚠️ CDVPluginHandleOpenURLWithAppSourceAndAnnotationNotification 은 구독하지 않는다.
    //    - cordova-ios 8 에서 deprecated 다(경고의 안내대로 부가 정보는 아래 알림의 userInfo 로 온다).
    //    - 더 중요한 건: 8 의 scene 라이프사이클에서는 CDVSceneDelegate 가 그 알림을 아예
    //      게시하지 않는다(CDVAppDelegate 만 게시). 즉 옛 구독은 scene 경로에서 한 번도 안 온다.
    //    CDVPluginHandleOpenURLNotification 은 모든 cordova-ios 버전이 object 에 NSURL 을 실어
    //    보낸다(≤7 은 object 만, 8 은 userInfo 에 sourceApplication/annotation 이 추가) —
    //    이 플러그인은 URL 만 필요하므로 이 알림 하나로 전 버전을 커버한다.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOpenURL:) name:CDVPluginHandleOpenURLNotification object:nil];
}

- (void)handleOpenURL:(NSNotification*)notification
{
    // ⚠️ 예전에는 여기서 아무것도 안 하고 sourceApplication 이 실려 오는
    //    ...WithAppSourceAndAnnotation 쪽에서만 처리했다. sourceApplication 이 필요하던 건
    //    GoogleSignIn 4.x 의 handleURL:sourceApplication:annotation: 시절 얘기고,
    //    지금 handleURL: 은 URL 하나만 받는다.
    //    handleURL: 은 자기 콜백이 아니면 NO 를 돌려주고 아무것도 하지 않으므로 호출해도 안전하다.
    //    (지금 로그인이 되는 건 SDK 가 ASWebAuthenticationSession 으로 콜백을 자체 처리하기
    //     때문이고, 이 경로는 외부 브라우저/커스텀 스킴 폴백을 위한 보험이다)
    NSURL* url = [notification.object isKindOfClass:[NSURL class]] ? notification.object : nil;
    if (url == nil) {
        return;
    }

    NSString* possibleReversedClientId = [url.absoluteString componentsSeparatedByString:@":"].firstObject;
    if ([possibleReversedClientId isEqualToString:self.getreversedClientId]) {
        [GIDSignIn.sharedInstance handleURL:url];
    }
}


/**
 * ── Android v10(GooglePlus.java) 과 같은 인증/인가 분리 + silent-first 구조 ──────────
 *   1. 인증 — signIn / restorePreviousSignIn. 신원만 얻는다.
 *      ⚠️ additionalScopes: 에는 항상 nil 을 넣는다. 스코프를 여기에 끼워 넣으면
 *         동의 화면이 "로그인 + 미체크 선택 항목" 통합 화면으로 돌아간다(granular consent).
 *   2. 인가 — finishLoginWithUser: 의 addScopes: 가 스코프 전용 동의 흐름을 맡는다.
 *
 * silent-first: 세션이 살아 있으면(currentUser / hasPreviousSignIn) 로그인 UI 없이
 * 토큰 갱신(refreshTokensIfNeeded)만으로 끝난다 → 앱의 401 재로그인 경로가 조용해진다.
 * 계정을 바꾸려면 로그아웃을 먼저 해야 한다(Android 와 같은 의도된 UX).
 *
 * ⚠️ Android v10.1.0 의 staleAccessToken(clearToken) 옵션은 iOS 에 대응 API 가 없어 무시된다.
 *    대신 refreshTokensIfNeeded 가 실패하면(외부 revoke 로 refresh token 이 죽은 경우 포함)
 *    대화형 로그인으로 떨어뜨려 같은 복구 경로를 제공한다.
 */
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

    GIDGoogleUser *currentUser = GIDSignIn.sharedInstance.currentUser;
    if (currentUser != nil) {
        [self refreshAndFinishWithUser:currentUser requestedScopes:scopes];
        return;
    }

    // 앱 재시작 후에는 currentUser 가 nil 이다 — 키체인의 이전 세션을 명시적으로 복원해야 한다
    // (disconnect 의 restorePreviousSignIn 과 같은 이유)
    if ([GIDSignIn.sharedInstance hasPreviousSignIn]) {
        [GIDSignIn.sharedInstance restorePreviousSignInWithCompletion:^(GIDGoogleUser * _Nullable user, NSError * _Nullable error) {
            if (user != nil && error == nil) {
                [self refreshAndFinishWithUser:user requestedScopes:scopes];
            } else {
                [self interactiveSignInWithScopes:scopes];
            }
        }];
        return;
    }

    [self interactiveSignInWithScopes:scopes];
}

/**
 * 조용한 경로: 만료(임박) 토큰을 갱신한 뒤 인가 검증으로 넘어간다.
 * ⚠️ 갱신 실패를 에러로 끝내지 않고 대화형 로그인으로 떨어뜨린다 — 외부(계정 설정/Drive)에서
 *    앱 권한을 해제하면 refresh token 이 서버에서 죽는데, 그걸 에러로 돌려주면 앱이
 *    "재로그인 → 같은 죽은 세션 → 또 에러" 루프에 갇힌다(Android 에서 실측된 시나리오의 iOS 판).
 */
- (void) refreshAndFinishWithUser:(GIDGoogleUser*)user requestedScopes:(NSArray*)scopes {
    [user refreshTokensIfNeededWithCompletion:^(GIDGoogleUser * _Nullable refreshedUser, NSError * _Nullable error) {
        if (refreshedUser == nil || error != nil) {
            [self interactiveSignInWithScopes:scopes];
            return;
        }
        [self finishLoginWithUser:refreshedUser requestedScopes:scopes];
    }];
}

/** 대화형 인증. ⚠️ additionalScopes: 는 항상 nil — 스코프는 인가 단계(addScopes:)의 몫이다. */
- (void) interactiveSignInWithScopes:(NSArray*)scopes {
    [GIDSignIn.sharedInstance signInWithPresentingViewController:self.viewController
                                                           hint:nil
                                               additionalScopes:nil
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
 * ── 2 단계: 인가 — Android 의 authorizeAccount + finishAuthorization 에 해당 ──────────
 * 인증(사인인)에는 스코프가 없으므로 스코프 승인은 전부 이 메서드가 맡는다.
 * 이미 승인된 스코프면(grantedScopes 에 있음) UI 없이 조용히 통과하고,
 * 아니면 addScopes: 가 **스코프 전용 동의 화면**을 띄운다 —
 * 로그인 화면에 딸린 미체크 체크박스가 아니라 "Drive 접근" 단독 화면이다.
 *
 * ⚠️ 요청 ≠ 승인. granular consent 때문에 동의 화면에서 일부만 승인해도 completion 은
 *    성공으로 들어올 수 있으므로 grantedScopes 를 다시 검증한다.
 *    검증 없이 토큰을 돌려주면 앱이 쓸모없는 토큰을 저장했다가 403 을 맞는다(Android 와 같은 규칙).
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

        // ⚠️ user 를 블록에서 직접 잡으면 -Warc-retain-cycles 경고가 난다
        //    (user 의 메서드에 넘기는 블록이 user 를 강참조). addScopes 성공 후에는
        //    sharedInstance.currentUser 가 갱신된 유저를 가리키므로 그걸 폴백으로 쓴다.
        GIDGoogleUser *updatedUser = signInResult.user ? : GIDSignIn.sharedInstance.currentUser;
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

/**
 * Android 는 Play Services 가용성을 검사하지만 iOS 는 검사할 대상이 없다 — 항상 가능.
 * (Android 의 callbackContext.success("true") 와 같은 형태로 문자열 "true" 를 돌려준다)
 * 예전에는 www/GooglePlus.js 가 노출하는데 네이티브 구현이 없어 호출하면 그냥 실패했다.
 */
- (void) isAvailable:(CDVInvokedUrlCommand*)command {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"true"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

/**
 * ⚠️ currentUser 만 보면 앱 재시작 후에는 항상 false 다(세션은 키체인에 있는데 복원 전이라).
 *    hasPreviousSignIn 을 함께 봐야 "로그인돼 있는가" 라는 질문의 답이 된다.
 */
- (void) isSignedIn:(CDVInvokedUrlCommand*)command {
    bool isSignedIn = [GIDSignIn.sharedInstance currentUser] != nil || [GIDSignIn.sharedInstance hasPreviousSignIn];
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
