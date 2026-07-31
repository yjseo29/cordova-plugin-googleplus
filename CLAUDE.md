# CLAUDE.md — cordova-plugin-googleplus (yjseo29 fork)

Google 로그인 Cordova 플러그인. **실사용 목적은 하나 — daily-day(디데이) 앱의 Google Drive 백업/복구**다.
로그인 자체가 목적이 아니라 **Drive 접근 토큰을 얻는 수단**이라는 점이 이 포크의 모든 판단 기준이다.

> 증상으로 원인을 찾으려면 맨 아래 **[§7 함정 색인](#7-️-함정-색인-증상--원인)** 부터 보면 된다.

---

## 0. 계보와 소비자

**계보**: `EddyVerbruggen` → `Mr. D` → `Daniel Gabor(dgabor)` → **`yjseo29`(2024-10~)**

⚠️ **업스트림은 읽기 전용/방치 상태다.** PR 을 보낼 곳이 없으므로 이 포크가 사실상 본체다.
⚠️ 바로 위 dgabor 포크는 **firebase-x 사용자를 위해** 만들어졌다(커밋 `c2ca264 "for firebase-x"`).
   그래서 Firebase 를 전제로 한 코드가 섞여 있었고, 그중 iOS 훅은 제거했다(§2).

**유일한 소비자**: `daily-day/src/js/util_backup.js`

실제로 호출하는 API 는 **4 개뿐**이다. 나머지는 손대도 영향 없지만, 이 4 개는 백업/복구를 직접 깨뜨린다.

| API | 쓰임 |
|---|---|
| `login({scopes})` | Drive 토큰 획득 |
| `trySilentLogin({scopes})` | logout/disconnect 앞에 네이티브 클라이언트를 준비시키는 용도 |
| `logout()` | 설정 화면의 로그아웃 버튼 |
| `disconnect()` | **403(스코프 미승인) 복구 경로** — §3 참고 |

요청 스코프는 `https://www.googleapis.com/auth/drive.appdata` **하나뿐**이다.
`drive.file` 은 쓰이는 코드가 없어서 뺐다(동의 화면 항목만 늘린다).

---

## 1. ⚠️ 절대 규칙

### 1-1. `logout()` 과 `disconnect()` 를 섞어 쓰지 말 것

| | 네이티브 | 효과 |
|---|---|---|
| `logout()` | `signOut()` | 계정만 로그아웃. **승인 기록은 구글 서버에 남는다** |
| `disconnect()` | `revokeAccess()` (Android) / `disconnectWithCompletion:` (iOS) | 앱에 준 권한 자체를 취소 |

**구글은 스코프 동의 결정을 기억한다.** 사용자가 동의 화면에서 체크박스를 해제한 채 로그인하면,
그 뒤로는 `signOut → login` 을 반복해도 **계정 선택 화면만 뜨고 체크박스가 다시 나오지 않는다.**
→ 403 → 안내 → 재로그인 → 403 … **탈출 불가능한 무한 루프**가 된다.

`revokeAccess` 만이 그 기록을 지워 동의 화면을 처음부터 다시 띄운다.
`util_backup.js` 의 403 핸들러가 `googleDriveDisconnect` 를 쓰는 이유가 이것이다.
**설정 화면의 일반 로그아웃은 `logout()` 이 맞다** — 거기서 권한까지 취소하면 다음에 또 동의를 거쳐야 한다.

### 1-2. 동의 화면 체크박스를 미리 체크할 방법은 없다

구글의 **granular consent** 정책이다. 앱이 개입할 수 없다.
`AuthorizationClient` 로 바꿔도 화면이 "로그인에 딸린 선택 항목"에서 "Drive 접근 전용 화면"으로
바뀔 뿐, 체크는 사용자 몫이다. **이 전제를 뒤집는 해법을 찾지 말 것.**

할 수 있는 건 두 가지다: ①로그인 전에 설명 화면을 띄워 체크를 유도 ②거부 시 복구 경로 제공(§1-1).

📌 **v10 분리 후 실측**: `drive.appdata` 는 구글 공식 분류로 **non-sensitive** 스코프라
(Drive API 문서의 스코프 표 — 앱 자신의 숨김 폴더만 접근), 전용 인가 흐름에서는 구글이
**동의 UI 자체를 생략하고 자동 승인**하는 것이 관찰됐다(Drive 연결해제 + 앱데이터 삭제 후
재로그인 → 계정 선택만 뜨고 hasResolution=false 로 즉시 토큰 발급 → 백업 정상).
동의 화면을 띄울지는 구글 서버가 결정한다 — hasResolution 이 false 면 우리가 띄울 방법도,
띄울 이유도 없다. 예전 GSO 통합 흐름의 미체크 체크박스는 그 UI 가 추가 스코프를 일괄
선택 항목으로 나열하는 정책이었을 뿐이다. 분리가 곧 해법이었던 셈.

### 1-3. 스코프는 "요청" 이지 "승인" 이 아니다

`additionalScopes`(iOS) / `requestScopes`(Android) 는 요청일 뿐이다.
사용자가 거부해도 **로그인 자체는 성공으로 완료되고 토큰도 나온다.**
그 토큰으로 Drive 를 부르면 403 이다.

→ iOS 는 `grantedScopes` 로 검증한다(구현 완료). **Android 는 아직 검증하지 않는다**(§4-B).

### 1-4. Windows PowerShell 5.1 로 소스를 편집하지 말 것

UTF-8 을 ANSI 로 읽고 써서 **한글 주석이 깨진다.** 파일 수정은 Edit/Write 도구로.
(daily-day 저장소의 CLAUDE.md 와 같은 규칙)

---

## 2. 지금 상태 (2026-08 기준)

### v10.1.0 — 외부 revoke 복구 (`staleAccessToken` 옵션)

사용자가 **계정 설정/Drive 에서 앱 권한을 외부에서 해제**하면 서버 grant 는 사라지지만
GMS 로컬 캐시는 그걸 모른다(토큰이 만료 전이라 멀쩡해 보인다). 그 상태로 `authorize()` 는
죽은 토큰을 계속 돌려줘서 401 → 재로그인 → 같은 토큰 → 401 에 갇힌다.
(실기기에서 실제로 확인된 시나리오 — 에러 본문이 Drive API 의
"Request had invalid authentication credentials..." 그대로 표면화된다)

해법: 앱이 401 을 맞은 토큰을 `login({ staleAccessToken })` 으로 넘기면, 플러그인이
`AuthorizationClient.clearToken(ClearTokenRequest)` 으로 캐시에서 지운 **뒤** 진행한다
(네이티브에서 순차 실행 — 레이스 없음). 그러면 authorize 가 새로 민팅을 시도하고,
grant 가 없으면 hasResolution → 동의 화면 → 복구. 옛 구현의 `invalidateAuthToken` 재시도와
같은 의미론이다. 캐시에 없는 토큰이면 no-op 이라 언제 넘겨도 무해하다.

앱 쪽 연결(daily-day/util_backup.js): `googleDriveClear` 가 지우기 전 토큰을
`Keys.GOOGLE_DRIVE_STALE_TOKEN` 에 보관(메모리 전용) → 다음 `googleDriveLogin` 이 옵션으로 전달.

### v10.0.0 — Android 인증/인가 분리 (AuthorizationClient 전환)

`GooglePlus.java` 를 전면 재작성했다. 구조는 소스 상단 클래스 주석에 있다. 요점:

- **인증과 인가를 분리했다.** 사인인 GSO 에는 스코프를 넣지 않고(신원만),
  스코프+accessToken 은 `Identity.getAuthorizationClient().authorize()` 가 맡는다.
  스코프 동의가 필요하면 **전용 동의 화면**(PendingIntent 해소)이 뜬다 —
  로그인 화면에 딸린 미체크 체크박스가 아니라.
- **`login` 이 silent-first 다.** 세션이 살아 있으면 계정 선택 화면 없이 토큰만 재발급된다
  → 앱의 401 재로그인 경로가 조용해진다. 계정을 바꾸려면 로그아웃을 먼저 해야 한다(의도된 UX).
- **`trySilentLogin` 의 의미가 바뀌었다**: 인증(사인인)이 조용히 되면 **성공**이다.
  스코프가 미승인이면 accessToken 없이(신원 + `grantedScopes`) 성공으로 돌아온다.
  ⚠️ 이걸 에러로 바꾸지 말 것 — 소비처(googleDriveLogout/Disconnect)가 성공을 게이트로
  logout/disconnect 를 부르는데, 여기서 막으면 revoke 에 도달하지 못해 403 루프가 되살아난다.
- **`logout`/`disconnect` 의 사전 조건("Please use login ... before")이 사라졌다.**
  GoogleSignInClient 를 그 자리에서 만든다. 앱의 trySilentLogin 선행 호출은 무해한 하위 호환.
- **`GoogleApiClient` / `Auth.GoogleSignInApi` / `blockingConnect` / AsyncTask 전부 제거.**
  AccountManager.getAuthToken + tokeninfo HTTP 검증 경로도 통째로 사라졌다
  (AuthorizationResult 가 accessToken 을 직접 준다).
- **결과 계약 변화**: `grantedScopes` 추가(iOS 와 대칭), **`expires`/`expires_in` 제거**
  (tokeninfo 검증의 부산물이었는데 AuthorizationClient 엔 만료 API 가 없다.
  유일한 소비자는 accessToken/email 만 읽으므로 무해 — §3).
- **에러 계약 유지**: 상태 코드 int 그대로(12501=취소 등). 인가 동의 화면을 닫으면
  12501 을 돌려줘 앱의 기존 취소 처리("You don't have permission")를 재사용한다.
- 프로세스 재생성 방어: 런처 결과가 재전달될 때 `savedCallbackContext`/`pendingAccount` 가
  null 이면 NPE 대신 버린다.

**검증**: 실제 앱 프로젝트(gradle `:app:compileDebugJavaWithJavac`, play-services-auth 21.6.0
classpath)로 **javac 통과 확인**. 실기기 동작은 미검증 — §4-A 의 시나리오로 확인할 것.
남은 deprecation 노트: `GET_SIGNATURES`(지문 조회, 기존부터), `GoogleSignIn` 계열 자체의
deprecated 표시(다음 단계인 Credential Manager 권고 — §5).

### 커밋 `053a797` 에서 고친 것

**iOS**
- `grantedScopes` 검증 추가. 부족하면 `addScopes:` 로 추가 동의 요청(증분 인가), 그래도 없으면
  `missingScopes` 를 담아 에러
- **`handleURL:` 이 한 번도 호출되지 않던 문제** — 조건에 `isSigningIn` 이 물려 있었는데
  그 값을 `YES` 로 만드는 곳이 GoogleSignIn 5.0 에서 삭제된 `GIDSignInDelegate` 뿐이라 항상 `NO` 였다.
  지금 로그인이 되는 건 SDK 가 `ASWebAuthenticationSession` 으로 콜백을 자체 처리하기 때문이다
- **`disconnect` 가 아무것도 revoke 하지 않던 경로** — 앱 재시작 후 `currentUser` 가 nil 이면
  취소 대상이 없어 그냥 성공으로 끝났다. `restorePreviousSignIn` 을 먼저 태운다
- 크래시 2 건: `command.arguments[0]` 무방비 / `NSDictionary` 리터럴 nil 가드 누락(`idToken` 이 실제 위험)
- 결과에 `expires` / `expires_in` / `grantedScopes` 추가 — Android 와 필드 구성 일치
  (`expires` = 만료 epoch 초, `expires_in` = 남은 초)

**정리**
- `play-services-identity` 제거 (선언만 있고 import 0 개)
- `GET_ACCOUNTS` / `USE_CREDENTIALS` 제거 (AccountManager 시절 잔재. 전자는 위험 권한,
  후자는 API 23 에서 삭제된 권한)
- `AddressBook.framework` / `libz.dylib` 제거
- **`hooks/ios/` 전체 삭제** — `after_prepare.js` 는 프로젝트 루트의 `GoogleService-Info.plist`
  (Firebase 설정)를 요구해서, 그 파일이 없으면 `deferral.reject` 로 **prepare 자체를 실패시켰다.**
  `prerequisites.js` 는 그 훅이 쓰던 npm 패키지를 깔던 것이라 목적이 사라졌다.
  GIDClientID 는 `<preference name="CLIENT_ID">` + `<config-file parent="GIDClientID">` 가 대신한다
- `device.platform` → `cordova.platformId` (전자는 cordova-plugin-device 의존인데 dependency
  선언이 없었고, deviceready 이전에는 정의되지도 않는다)
- `engines` 현행화(`cordova-android >=10`) — 코드가 androidx `ActivityResultLauncher` 를 쓰는데
  선언은 `6.3.0` 이라 6.x 에 설치하면 컴파일에서 깨졌다

### ⚠️ 검증 상태

| 항목 | 상태 |
|---|---|
| `plugin.xml` 파싱 / 플랫폼별 해석 | ✅ cordova-common `PluginInfo` 로 확인 |
| ObjC 괄호 균형 / `.h`↔`.m` 선언 대조 | ✅ |
| GoogleSignIn 7.1.0 API 시그니처 | ✅ 실제 헤더로 대조 |
| `www/GooglePlus.js` 구문 | ✅ |
| **Xcode 빌드** | ❌ **미검증** |
| **실기기 동작** | ❌ **미검증** |

`053a797` 은 Windows 에서 작성됐다. **맥에서 빌드가 처음이다.**

---

## 3. 핵심 계약 — 결과 객체

`login` 성공 시 JS 가 받는 것은 **객체**다(문자열 아님). 두 플랫폼이 필드를 맞춰가는 중이다.

| 필드 | Android | iOS | 비고 |
|---|---|---|---|
| `accessToken` `email` `idToken` `userId` | ✅ | ✅ | |
| `displayName` `givenName` `familyName` `imageUrl` | ✅ | ✅ | |
| `grantedScopes` | ✅ | ✅ | v10.0.0 에서 Android 추가 |
| `expires` `expires_in` | ❌ | ✅ | **v10.0.0 에서 Android 제거** — AuthorizationClient 에 만료 API 가 없다. 소비자는 accessToken/email 만 읽어 무해 |
| `serverAuthCode` | ✅ | ❌ | iOS 는 `webClientId`/`offline` 옵션 자체를 안 읽는다 |

⚠️ Android `trySilentLogin` 은 스코프 미승인 시 `accessToken` 이 **null** 인 성공을 돌려준다(§2).
   승인 여부는 `grantedScopes` 로 판단할 것.

⚠️ **에러는 반대로 JSON "문자열" 이다.** `messageAsString:[self toJSONString:...]`.
`util_backup.js` 가 `error({message: msg})` 로 통째로 넘기고 있으므로 형식을 바꾸면 앱이 깨진다.

---

## 4. 맥에서 할 iOS 작업

### A. 🔴 1순위 — `053a797` 빌드 & 회귀 확인

**빌드부터 통과시킬 것.** 위험도 순으로 확인 항목이 정해져 있다.

1. **`handleURL:` 회귀** ← 이번 변경 중 가장 위험하다
   인증 콜백 경로를 건드렸다. 로그인이 아예 안 되면 여기부터 의심할 것.
   되돌리려면 조건에 `&& NO` 를 넣지 말고 `handleOpenURLWithAppSourceAndAnnotation:` 의
   `if` 블록 전체를 주석 처리하면 이전 동작과 같아진다.
2. **`addScopes:` 흐름** — 동의 화면에서 체크를 **일부러 해제**하고 로그인 → 추가 동의 화면이 뜨는지
3. **`disconnect` 복구** — 위에서 거부 → 앱 **완전 종료 후 재실행** → 백업 시도 →
   동의 화면 체크박스가 **다시 뜨는지**. 이게 `restorePreviousSignIn` 추가의 목적이다
4. 정상 백업/복구 왕복

### B. 🟡 2순위 — GoogleSignIn 7.1.0 → 9.x 마이그레이션

**좋은 소식: 코드 재작성은 거의 필요 없을 가능성이 높다.**
7.1.0 과 9.2.0 의 public 헤더를 대조한 결과, **플러그인이 쓰는 API 가 전부 그대로 있다**:

```
signInWithPresentingViewController:hint:additionalScopes:completion:
handleURL: / signOut / disconnectWithCompletion: / currentUser
hasPreviousSignIn / restorePreviousSignInWithCompletion:
addScopes:presentingViewController:completion: / grantedScopes
GIDToken.expirationDate / .tokenString / GIDGoogleUser.userID
GIDProfileData.imageURLWithDimension:
```

9.x 는 오버로드를 **추가**했을 뿐 위 시그니처를 지우지 않았다.

⚠️ **진짜 위험은 API 가 아니라 CocoaPods 의존성이다.**

| | 7.1.0 | 9.2.0 |
|---|---|---|
| `ios.deployment_target` | 10.0 | **12.0** |
| `AppAuth` | `>= 1.7.3, < 2.0` | **`~> 2.1`** (메이저) |
| `GTMAppAuth` | `>= 4.1.1, < 5.0` | **`~> 5.0`** (메이저) |
| `GTMSessionFetcher/Core` | `~> 3.3` | `~> 3.3` (동일) |
| `AppCheckCore` | — | **`~> 11.0`** (신규) |

- daily-day 의 `deployment-target` 은 **15.0** 이라 12.0 요구는 충족한다
- daily-day 플러그인 중 **AppAuth / GTMAppAuth 계열을 쓰는 건 이 플러그인뿐**이다(확인함).
  나머지 pod 은 `Google-Mobile-Ads-SDK`, `GoogleMobileAdsMediationFacebook`,
  `GoogleUserMessagingPlatform`, `GoogleUtilities` → **직접 충돌 가능성은 낮다**
- 막히면 `Podfile.lock` 을 지우고 `pod install --repo-update` 로 재해석해볼 것

작업 순서: `plugin.xml` 의 `GOOGLE_SIGN_IN_VERSION` 기본값을 `~> 9.2` 로 올리고
→ 플러그인 재설치 → `pod install` → 빌드 → §4-A 의 4 개 시나리오 재확인.

⚠️ `GOOGLE_UTILITIES_VERSION` 은 `~> 8.0` 그대로 둘 것. 9.2.0 도 `GoogleUtilities 8.x` 계열과 맞는다.

### C. 🟢 3순위 — 남은 비대칭/미구현

- **`isAvailable` 이 iOS 에 없다.** `www/GooglePlus.js` 는 노출하는데 `GooglePlus.m` 에 구현이 없다
  (Android 만 `ACTION_IS_AVAILABLE` 처리). 앱은 안 쓰지만 부르면 실패한다
- **`isSignedIn` 은 반대다.** `GooglePlus.m` 에 구현이 있는데 JS 에 노출이 없어 호출 불가
- **`webClientId` / `offline` / `hostedDomain` 을 iOS 가 안 읽는다.** Android 만 처리한다.
  `serverAuthCode` 가 iOS 결과에 없는 이유이기도 하다. 지금 쓰지 않으니 급하지 않다
- **토큰 갱신 API 가 없다.** `accessToken` 은 약 1 시간 만료인데 앱은 401 을 맞고 재로그인한다.
  `refreshTokensIfNeededWithCompletion:` 을 노출하면 무음 갱신이 가능하다.
  `expires` 를 결과에 넣어둔 건 이걸 위한 사전 작업이다

---

## 5. Android 쪽 남은 일 (참고 — 맥 작업 아님)

v10.0.0 에서 대부분 끝났다(§2). `GoogleApiClient`/`blockingConnect` 제거, `grantedScopes` 검증,
`AuthorizationClient` 분리 완료. 남은 것:

- **인증을 Credential Manager 로 옮기기** — `GoogleSignInClient` 도 구글이 deprecated 로 표시하고
  Credential Manager(`androidx.credentials` + `googleid`)를 권고한다. 다만 인가(AuthorizationClient)는
  그대로 유지되는 구조라, 옮길 때 바뀌는 건 1 단계(인증)뿐이다. 새 의존성 두 개가 필요해 별도 작업.
- `getSigningCertificateFingerprint` 가 `GET_SIGNATURES`(API 28 deprecated)를 쓴다.
  앱이 안 쓰는 액션이라 급하지 않다.
- **실기기 검증** — javac 만 통과한 상태다. 확인 시나리오:
  1. 로그인 → Drive 스코프 **전용 동의 화면**이 뜨는지 (로그인 화면 체크박스가 아니라)
  2. 동의 거부 → 12501 에러("You don't have permission") → 재시도 → 동의 화면이 다시 뜨는지
  3. 이미 승인된 계정으로 재로그인(토큰 만료 401 시나리오) → **화면 없이** 조용히 완료되는지
  4. 로그아웃 → 로그인 → 계정 선택 화면이 뜨는지 (계정 전환 경로)
  5. 백업/복구 왕복

---

## 6. 빌드 · 반영

```bash
# 앱 저장소(daily-day/cordova)에서
cordova plugin remove cordova-plugin-googleplus
cordova plugin add <이 플러그인 경로> --variable CLIENT_ID=... --variable REVERSED_CLIENT_ID=...
```

- `CLIENT_ID` / `REVERSED_CLIENT_ID` 값은 `daily-day/src/js/util_backup.js` 파일 상단 주석에 적혀 있다
- `REVERSED_CLIENT_ID` = Google Console > OAuth 2.0 클라이언트 ID > iOS > iOS URL 스키마
- ⚠️ 맥에서 `LANG` 미설정이면 `pod install` 이 인코딩 에러로 죽는다 →
  `LANG=en_US.UTF-8 cordova prepare ios`
- ⚠️ `plugin.xml`·네이티브·`www/` 를 고치면 **재설치해야 앱에 반영된다**

---

## 7. ⚠️ 함정 색인 (증상 → 원인)

| 증상 | 원인 / 참고 |
|---|---|
| 403 → 재로그인 → 다시 403 무한 루프 | `logout()`(signOut) 으로 복구 시도. `disconnect()`(revoke) 여야 한다 → §1-1 |
| 동의 화면 체크박스가 미체크로 뜬다 | 구글 granular consent. **해결 불가** → §1-2 |
| 앱 재시작 후 `disconnect` 해도 동의 화면이 안 돌아옴 | `currentUser` 가 nil → revoke 대상 없음. `restorePreviousSignIn` 필요 → §2 |
| 로그인은 성공했는데 Drive API 가 403 | 스코프 미승인. 요청 ≠ 승인 → §1-3 |
| `prepare` 가 `GoogleService-Info.plist not found` 로 실패 | Firebase 전용 훅. 제거됨 → §2 |
| iOS 로그인 후 앱이 죽음 | `NSDictionary` 리터럴 nil (특히 `idToken`) → §2 에서 수정됨 |
| 인자 없이 `login()` 호출 시 크래시 | `command.arguments[0]` 무방비 → §2 에서 수정됨 |
| cordova-android 6.x 에서 컴파일 실패 | 코드가 androidx `ActivityResultLauncher` 사용. `engines` 하한 10 → §2 |
| `trySilentLogin` 에서 `device is not defined` | 예전 `device.platform` 의존. `cordova.platformId` 로 교체됨 → §2 |
| 로그인 창이 안 뜨거나 콜백이 안 옴 (iOS) | `handleURL:` 변경 회귀 의심 → §4-A |
| (Android) 로그인해도 계정 선택 화면이 안 뜬다 | 버그 아님 — v10 의 silent-first. 계정 전환은 로그아웃 먼저 → §2 |
| (Android) `trySilentLogin` 성공인데 `accessToken` 이 null | 버그 아님 — 스코프 미승인 상태의 신원-만 성공. `grantedScopes` 로 판단 → §2, §3 |
| (Android) 결과에 `expires` 가 없다 | v10 에서 제거됨(tokeninfo 검증 경로 삭제) → §3 |
| (Android) 외부에서 권한 해제 후 "invalid authentication credentials" 401 반복 | GMS 토큰 캐시가 revoke 를 모름 — `staleAccessToken` 으로 clearToken → §2 (v10.1.0) |
| (Android) revoke 후 재로그인인데 동의 화면 없이 그냥 된다 | 버그 아님 — `drive.appdata` 는 non-sensitive 라 인가 흐름이 무UI 자동 승인 → §1-2 |
| (Android) 앱 재설치/업데이트 후 옛 코드가 도는 듯 | `platforms/` 의 사본과 `plugins/` fetch 캐시가 갱신 안 됨 — 플러그인 remove/add 재설치 필요 → §6 |
