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

📌 **v10 분리 후 실측 — 근거의 경계를 섞지 말 것**:
- **문서로 확인된 사실 ①**: `drive.appdata` 는 구글 공식 분류로 **non-sensitive** 다
  (Drive API 문서의 스코프 표 — 앱 자신의 숨김 폴더만 접근).
- **문서로 확인된 사실 ②**: `hasResolution() == false` 의 의미는 "이전에 승인된 접근"
  이라는 것뿐이다(Android 인가 가이드). **"non-sensitive 면 동의 UI 를 건너뛴다" 는
  문서 어디에도 없다.**
- **실측(문서에 없는 동작)**: Drive 연결해제 + 앱데이터 삭제 후 재로그인 → 계정 선택만
  뜨고 hasResolution=false 로 즉시 토큰 발급, 백업 정상. 즉 revoke 뒤에도 동의 화면 없이
  재승인됐다. 과거 승인 이력 기반의 무UI 재부여로 보이지만 **문서화되지 않은 서버 정책**이다
  → "항상 안 뜬다" 를 가정하는 코드를 쓰지 말 것. hasResolution 양쪽 분기가 모두
  구현돼 있는 것이 진짜 보증이다.
- 한 번도 승인한 적 없는 새 계정에서 동의 화면이 뜨는지는 **미확인**.

예전 GSO 통합 흐름의 미체크 체크박스는 그 UI 가 추가 스코프를 일괄 선택 항목으로
나열하는 정책이었을 뿐이다. 분리가 곧 해법이었던 셈.

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

### v10.2.0 — iOS 를 Android v10 구조로 정렬 + GoogleSignIn 9.2.0 (§4 소화)

**맥에서 빌드 검증까지 끝났다** — 시뮬레이터 Debug, x86_64+arm64, 플러그인 경고 0 건.
7.1.0 상태의 053a797 도 먼저 단독으로 빌드 통과를 확인한 뒤 진행했다(회귀 원인 분리 목적).
**실기기 정상 경로 검증 완료(2026-08-10)** — 로그인, 백업/복구 왕복 정상.
남은 것은 복구 경로 시나리오(외부 revoke, 동의 거부 후 disconnect) — §4 참고.

- **GoogleSignIn `~> 9.2`** (plugin.xml 기본값). 예상대로 플러그인 코드 변경은 0 이었고
  pod 만 갈렸다: AppAuth 2.1.0 / GTMAppAuth 5.0.0 / AppCheckCore 11.3.1(신규) /
  GoogleUtilities 8.1.2(유지). daily-day 의 다른 pod 과 충돌 없이 한 번에 해석됐다
  (`--repo-update` 불필요했다).
- **`login` 재작성 — Android v10 과 같은 인증/인가 분리.**
  - 인증: `signIn...additionalScopes:nil` — 스코프를 끼워 넣지 않는다(신원만).
  - 인가: `finishLoginWithUser:` 의 `addScopes:` 가 전담. `grantedScopes` 검증은 그대로.
  - **silent-first**: `currentUser` → (`hasPreviousSignIn` 이면) `restorePreviousSignIn`
    → `refreshTokensIfNeeded` 순으로 조용히 시도하고, 세션이 없을 때만 로그인 UI 를 띄운다.
    앱의 401 재로그인 경로가 UI 없이 토큰 갱신만으로 끝난다. 계정 전환은 로그아웃 먼저(Android 와 동일 UX).
  - **`refreshTokensIfNeeded` 실패 시 대화형 로그인으로 폴백** — 외부 revoke 로 refresh token 이
    죽은 세션의 복구 경로다. Android v10.1.0 의 `staleAccessToken`(clearToken) 에 대응하는
    API 가 iOS 에는 없어서, **그 옵션은 iOS 에서 무시되고** 이 폴백이 같은 역할을 한다.
- **§4-C 일부 해소**: `isAvailable` iOS 구현 추가(항상 "true" — Android 와 같은 형태),
  `isSignedIn` 을 JS 에 노출(iOS 전용, Android 에서는 명시적 에러). `isSignedIn` 은
  재시작 후 `currentUser` 가 nil 이어도 맞게 답하도록 `hasPreviousSignIn` 을 함께 본다.
- **cordova-ios 8 대응 — URL 콜백 경로 정리.** deprecated 경고가 나던
  `CDVPluginHandleOpenURLWithAppSourceAndAnnotationNotification` 구독을 버리고
  `CDVPluginHandleOpenURLNotification` 하나만 구독한다. `AppDelegate.h`/`objc/runtime.h`
  import 도 제거(사용 심볼 0 개 — 옛 스위즐링 잔재. 전자는 8 에서 호환 shim, 9 에서 제거 예고).
  ⚠️ 단순 경고 수리가 아니었다 — **8 의 scene 라이프사이클에서는 `CDVSceneDelegate` 가 옛 알림을
  아예 게시하지 않는다**(`CDVAppDelegate` 만 게시). 즉 옛 구독은 scene 경로에서 handleURL 에
  한 번도 도달하지 못했다. 새 알림은 cordova-ios 전 버전이 object 에 NSURL 을 실어 보내므로
  (≤7 은 object 만, 8 은 userInfo 에 sourceApplication/annotation 추가) **7 이하와도 호환된다** —
  이 플러그인은 URL 만 쓴다. GIDSignIn 의 `handleURL:` 도 URL 하나만 받는다
  (sourceApplication 이 필요하던 건 GoogleSignIn 4.x 시절).
  **검증**: 8.1.1 헤더(daily-day 실제 플랫폼) + GoogleSignIn 9.2.0 조합과 7.1.1 헤더
  (npm 에서 받아 대조) 양쪽 모두 `clang -fsyntax-only -Wall` 진단 0 건.
  7.1.1 의 CDVAppDelegate.m:84 가 object=url 로 게시하는 것도 소스로 확인.
- 정리: `addScopes:` 완료 블록의 retain cycle 경고 해소(폴백을 `currentUser` 로),
  package.json 의 `q` 의존성 제거(삭제된 iOS 훅 prerequisites.js 의 잔재).

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
| GoogleSignIn 9.2.0 API / pod 해석 | ✅ Podfile.lock + 빌드로 확인 (v10.2.0) |
| `www/GooglePlus.js` 구문 | ✅ |
| **Xcode 빌드** | ✅ 시뮬레이터 Debug 통과 — 7.1.0(053a797 단독), 9.2.0(v10.2.0) 모두 (cordova-ios 7 시절 플랫폼) |
| cordova-ios 8 호환 | ✅ 8.1.1 헤더 fsyntax-only 진단 0 + daily-day 전체 앱 빌드(App 타깃) 실컴파일 + 실기기 로그인/백업 확인. 함께 고친 다른 플러그인: admob/consent(yjseo29/admob-plus 포크, alpha.6/alpha.1 릴리스됨), datetimepicker(yjseo29 포크 수정), file-transfer(최신 버전이 자체 해결), advanced-http(로컬 패치만 — 유일하게 남은 비영구 패치) |
| cordova-ios ≤7 하위 호환 | ✅ 7.1.1 헤더로 fsyntax-only 진단 0 + object=url 게시 소스 확인 |
| **실기기 동작 (정상 경로)** | ✅ 로그인 + 백업/복구 왕복 정상 (2026-08-10, cordova-ios 8 플랫폼). 로그인이 되므로 `handleURL:` 회귀 우려도 해소 |
| **실기기 동작 (복구 경로)** | ❌ **미검증** — 외부 revoke 폴백, 동의 거부 → disconnect 복구 → §4 |

`053a797` 은 Windows 에서 작성됐고, v10.2.0 작업에서 맥 빌드까지 확인했다.

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

## 4. iOS 작업 — 구현·빌드·정상 경로 실기기 검증 완료(v10.2.0)

§4 의 A(빌드)·B(9.2.0)·B-2(v10 구조)·C 일부(isAvailable/isSignedIn)는 **v10.2.0 에서 끝났다**(§2).
GoogleSignIn 9.x 마이그레이션은 예상대로 API 변경 0, pod 교체만으로 통과했다
(비교 근거는 plugin.xml 의 주석과 §2 v10.2.0 기록으로 옮겼다).
**실기기(2026-08-10)**: 로그인 + 백업/복구 왕복 정상 — 아래 1·6 은 해소, 남은 것은 복구 경로다.

### 실기기 검증 시나리오 (위험도 순)

1. ✅ **`handleURL:` 회귀** — 실기기 로그인 정상으로 해소(2026-08-10).
   만약 재발하면: SDK 자체 처리(ASWebAuthenticationSession)에만 맡겨 이전 동작으로 되돌리려면
   `handleOpenURL:` 안의 `if` 블록 전체를 주석 처리하면 된다.
   (v10.2.0 에서 구독이 `CDVPluginHandleOpenURLNotification` 하나로 바뀌었다 —
   cordova-ios 8 의 scene 경로에서는 옛 알림이 아예 안 오기 때문. §2)
2. ❌ **외부 revoke 복구 (B-2 ①)** — 계정 설정/Drive 에서 앱 권한을 외부에서 해제 → 재로그인 →
   죽은 세션에 갇히지 않고 `refreshTokensIfNeeded` 실패 → **대화형 로그인 폴백**이 도는지.
   Android 에서 실측된 v10.1.0 시나리오의 iOS 판이다. iOS 엔 clearToken 이 없어 이 폴백이 유일한 복구 경로다.
3. ❔ **silent-first (B-2 ②)** — 토큰 만료(약 1 시간) 후 재로그인이 **UI 없이** 조용히 되는지.
   (로그인·백업이 정상이므로 동작은 하지만, 만료 후 재로그인이 "조용했는지" 는 따로 관찰 안 됨)
4. ❔ **인가 전용 동의 흐름** — 한 번도 승인 안 한 계정으로 로그인 → 스코프 동의가 로그인 화면의
   체크박스가 아니라 **별도 화면**(`addScopes:`)으로 뜨는지. 거부하면 `missingScopes` 에러가 오는지.
   ⚠️ `drive.appdata` 는 non-sensitive 라 Android 처럼 무UI 자동 승인될 수도 있다(§1-2) — 그것도 정상이다.
5. ❌ **`disconnect` 복구** — 동의 거부 → 앱 **완전 종료 후 재실행** → 백업 시도 → 동의가
   **다시 뜨는지**. 이게 `restorePreviousSignIn` 을 disconnect 앞에 태운 목적이다.
6. ✅ 정상 백업/복구 왕복 — 실기기 확인(2026-08-10).

### C. 🟢 남은 비대칭/미구현 (급하지 않음)

- **`webClientId` / `offline` / `hostedDomain` 을 iOS 가 안 읽는다.** Android 만 처리한다.
  `serverAuthCode` 가 iOS 결과에 없는 이유이기도 하다. 앱이 안 쓰니 보류.
- **토큰 갱신 API 의 별도 노출은 없다.** 다만 v10.2.0 의 silent-first 가 내부에서
  `refreshTokensIfNeededWithCompletion:` 을 쓰므로, 앱이 401 후 `login` 을 다시 부르면
  사실상 무음 갱신으로 동작한다. 전용 refresh 액션이 필요해지면 그때 노출하면 된다
  (`expires` 필드는 그걸 위한 사전 작업).

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
# 앱 저장소(daily-day/cordova)에서 — remove 에도 변수가 필요하다(아래 ⚠️ 참고)
cordova plugin remove cordova-plugin-googleplus --variable CLIENT_ID=... --variable REVERSED_CLIENT_ID=...
cordova plugin add <이 플러그인 경로> --variable CLIENT_ID=... --variable REVERSED_CLIENT_ID=...
```

- `CLIENT_ID` / `REVERSED_CLIENT_ID` 값은 `daily-day/src/js/util_backup.js` 파일 상단 주석에 적혀 있다
- `REVERSED_CLIENT_ID` = Google Console > OAuth 2.0 클라이언트 ID > iOS > iOS URL 스키마
- ⚠️ 맥에서 `LANG` 미설정이면 `pod install` 이 인코딩 에러로 죽는다 →
  `LANG=en_US.UTF-8 cordova prepare ios`
- ⚠️ `plugin.xml`·네이티브·`www/` 를 고치면 **재설치해야 앱에 반영된다**
- ⚠️ **`plugin remove` 도 `--variable CLIENT_ID=... --variable REVERSED_CLIENT_ID=...` 를 요구한다.**
  plugin.xml 의 잘못이 아니다 — default 없는 `<preference>` 는 "설치 시 필수 변수" 라는 표준 선언이고,
  cordova 12 의 add 는 변수를 **package.json(`cordova.plugins`)에만** 저장하는데
  remove 는 저장된 변수를 **config.xml 의 `<plugin><variable>` 에서만** 읽는다
  (cordova-lib 의 쓰기/읽기 불일치 — `cordova/plugin/util.js mergeVariables` 는 `cfg.getPlugin` 만 본다.
  플랫폼 스코프 preference 라 최종적으로는 `plugman/variable-merge.js` 가 던진다).
  daily-day 의 config.xml 에 `<plugin>` 항목을 변수와 함께 넣어두면 변수 없는 remove 도 되지만,
  add 가 다시 써주지 않으므로 유지 관리 부담만 는다 — 그냥 §6 명령대로 변수를 붙이는 게 낫다.
  `default=""` 를 주는 "해결"은 금지 — 설치 시 강제가 사라져 빈 GIDClientID 로 조용히 설치된다.
- ⚠️ **cordova-ios 8 + 위젯 타깃 상태에서의 재설치 함정 (실제로 겪음).** cordova 의
  `addSourceFile` 은 타깃을 지정하지 않아, pbxproj **파일에서 먼저 나오는** 'Sources' phase 에
  소스가 들어간다. daily-day 의 iOS 플랫폼에는 위젯 익스텐션 타깃
  (DailyDayWidgetExtensionExtension)이 있고 그쪽 phase 가 App 보다 앞에 있어서,
  위젯 타깃이 존재하는 상태에서 플러그인을 재설치하면 `GooglePlus.m` 이 **위젯 타깃으로**
  들어가 `'Cordova/CDVPlugin.h' file not found` 로 빌드가 깨진다.
  (플랫폼을 처음 추가할 때는 위젯 타깃이 아직 없어서 — 위젯 타깃은 이후 훅/수동으로 생성 —
  플러그인들이 App 타깃에 정상 설치된다. 그래서 "재설치할 때만" 터진다.)
  증상이 나오면 `App.xcodeproj/project.pbxproj` 에서 `GooglePlus.m in Sources` build file 참조를
  위젯 타깃의 Sources phase 에서 App 타깃의 Sources phase 로 옮기면 된다.
  근본 원인은 daily-day 쪽 위젯 타깃 생성 순서/cordova-node-xcode 의 한계라 이 저장소 밖의 일이다.

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
| 로그인 창이 안 뜨거나 콜백이 안 옴 (iOS) | `handleURL:` 변경 회귀 의심 → §4 |
| (iOS) 로그인해도 계정 선택 화면이 안 뜬다 | 버그 아님 — v10.2.0 의 silent-first. 계정 전환은 로그아웃 먼저 → §2 |
| (iOS) `staleAccessToken` 옵션이 효과가 없다 | 대응 API 없음 — 무시된다. 대신 refresh 실패 시 대화형 폴백이 같은 복구를 한다 → §2 (v10.2.0) |
| (iOS) `CDVPluginHandleOpenURLWithAppSourceAndAnnotationNotification is deprecated` 경고 | v10.2.0 에서 해결 — `CDVPluginHandleOpenURLNotification` 단일 구독으로 교체. cordova-ios 8 scene 경로에서는 옛 알림이 아예 게시되지 않았다(경고보다 심각한 문제였다) → §2 |
| (iOS) 플러그인이 `AppDelegate.h` 를 import 해서 cordova-ios 9 대비 경고 | v10.2.0 에서 import 제거 — 쓰는 심볼이 없었다 → §2 |
| (Android) 로그인해도 계정 선택 화면이 안 뜬다 | 버그 아님 — v10 의 silent-first. 계정 전환은 로그아웃 먼저 → §2 |
| (Android) `trySilentLogin` 성공인데 `accessToken` 이 null | 버그 아님 — 스코프 미승인 상태의 신원-만 성공. `grantedScopes` 로 판단 → §2, §3 |
| (Android) 결과에 `expires` 가 없다 | v10 에서 제거됨(tokeninfo 검증 경로 삭제) → §3 |
| (Android) 외부에서 권한 해제 후 "invalid authentication credentials" 401 반복 | GMS 토큰 캐시가 revoke 를 모름 — `staleAccessToken` 으로 clearToken → §2 (v10.1.0) |
| (Android) revoke 후 재로그인인데 동의 화면 없이 그냥 된다 | 버그 아님 — `drive.appdata` 는 non-sensitive 라 인가 흐름이 무UI 자동 승인 → §1-2 |
| (Android) 앱 재설치/업데이트 후 옛 코드가 도는 듯 | `platforms/` 의 사본과 `plugins/` fetch 캐시가 갱신 안 됨 — 플러그인 remove/add 재설치 필요 → §6 |
| `plugin remove` 가 `Variable(s) missing: REVERSED_CLIENT_ID, CLIENT_ID` 로 실패 | plugin.xml 문제 아님 — cordova 12 가 변수를 package.json 에만 저장하고 remove 는 config.xml 만 읽는 불일치. remove 에도 `--variable` 을 붙일 것 → §6 |
| (iOS) 재설치 후 위젯 익스텐션 타깃에서 `'Cordova/CDVPlugin.h' file not found` | 위젯 타깃이 있는 상태의 재설치는 플러그인 소스가 위젯 타깃 Sources phase 로 들어간다 — pbxproj 에서 App 타깃으로 옮길 것 → §6 |
