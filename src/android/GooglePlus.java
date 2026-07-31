package nl.xservices.plugins;

import android.accounts.Account;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.util.Log;

import androidx.activity.result.ActivityResult;
import androidx.activity.result.ActivityResultCallback;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.IntentSenderRequest;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.appcompat.app.AppCompatActivity;

import com.google.android.gms.auth.api.identity.AuthorizationRequest;
import com.google.android.gms.auth.api.identity.AuthorizationResult;
import com.google.android.gms.auth.api.identity.Identity;
import com.google.android.gms.auth.api.signin.GoogleSignIn;
import com.google.android.gms.auth.api.signin.GoogleSignInAccount;
import com.google.android.gms.auth.api.signin.GoogleSignInClient;
import com.google.android.gms.auth.api.signin.GoogleSignInOptions;
import com.google.android.gms.auth.api.signin.GoogleSignInStatusCodes;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.common.api.Scope;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaArgs;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaWebView;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

/**
 * Originally written by Eddy Verbruggen (http://github.com/EddyVerbruggen/cordova-plugin-googleplus)
 * Forked/Duplicated and Modified by PointSource, LLC, 2016.
 *
 * ── 인증(Authentication)과 인가(Authorization)의 분리 ─────────────────────────────
 * 예전 구현은 GoogleApiClient + Auth.GoogleSignInApi(전면 deprecated) 위에서
 * Drive 같은 API 스코프를 "로그인 옵션(GSO)" 에 끼워 넣었다. 그러면 구글의
 * granular consent 때문에 동의 화면에서 스코프가 **미체크 선택 항목**으로 붙어 나오고,
 * 사용자가 무시하고 넘어가면 403 이 난다.
 *
 * 지금 구조는 두 단계다:
 *   1. 인증  — GoogleSignInClient (Task 기반). 신원(email/idToken/프로필)만 얻는다.
 *              ⚠️ 여기에는 requestScopes 를 넣지 않는다. 그게 이 구조의 핵심이다.
 *   2. 인가  — Identity.getAuthorizationClient().authorize(). 스코프 승인 + accessToken.
 *              이미 승인된 스코프면 UI 없이 조용히 토큰이 나오고,
 *              아니면 **스코프 전용 동의 화면**(PendingIntent 해소)이 뜬다.
 *
 * 부수 효과로 예전의 AccountManager.getAuthToken + tokeninfo HTTP 왕복(토큰 검증)이
 * 통째로 사라졌다 — AuthorizationResult 가 accessToken 을 직접 준다.
 *
 * ⚠️ 결과에서 expires / expires_in 이 빠졌다. 그 값들은 tokeninfo 검증의 부산물이었는데
 *    AuthorizationClient 에는 만료 시각을 주는 API 가 없다. 유일한 소비자(util_backup.js)는
 *    accessToken / email 만 읽으므로 영향 없다. 대신 grantedScopes 가 추가됐다(iOS 와 대칭).
 *
 * 다음 단계(선택): 인증 쪽을 Credential Manager 로 옮기면 GoogleSignInClient 의존까지
 * 사라지지만, androidx.credentials + googleid 의존성이 새로 필요해 별도 작업으로 남긴다.
 */
public class GooglePlus extends CordovaPlugin {

    public static final String ACTION_IS_AVAILABLE = "isAvailable";
    public static final String ACTION_LOGIN = "login";
    public static final String ACTION_TRY_SILENT_LOGIN = "trySilentLogin";
    public static final String ACTION_LOGOUT = "logout";
    public static final String ACTION_DISCONNECT = "disconnect";
    public static final String ACTION_GET_SIGNING_CERTIFICATE_FINGERPRINT = "getSigningCertificateFingerprint";

    private final static String FIELD_ACCESS_TOKEN = "accessToken";
    private final static String FIELD_GRANTED_SCOPES = "grantedScopes";

    //String options/config object names passed in to login and trySilentLogin
    public static final String ARGUMENT_WEB_CLIENT_ID = "webClientId";
    public static final String ARGUMENT_SCOPES = "scopes";
    public static final String ARGUMENT_OFFLINE_KEY = "offline";
    public static final String ARGUMENT_HOSTED_DOMAIN = "hostedDomain";

    public static final String TAG = "GooglePlugin";

    private CallbackContext savedCallbackContext;

    private ActivityResultLauncher<Intent> signInActivityLauncher;
    private ActivityResultLauncher<IntentSenderRequest> authorizationLauncher;

    // 로그인 한 건이 인증(sign-in) → 인가(authorize) 두 단계를 오가는 동안 유지하는 상태.
    // 런처 콜백에는 인자를 실어 보낼 수 없어서 필드로 든다(동시 로그인은 어차피 불가능한 UI 흐름).
    private GoogleSignInAccount pendingAccount;
    private List<String> pendingScopeUris = new ArrayList<String>();

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        super.initialize(cordova, webView);

        AppCompatActivity cordovaActivity = cordova.getActivity();

        // ⚠️ registerForActivityResult 는 액티비티가 STARTED 되기 전에 불러야 한다.
        //    이 플러그인은 onload=true 라 initialize 가 onCreate 경로에서 돌므로 안전하다.
        this.signInActivityLauncher = cordovaActivity.registerForActivityResult(
                new ActivityResultContracts.StartActivityForResult(),
                new ActivityResultCallback<ActivityResult>() {
                    public void onActivityResult(ActivityResult result) {
                        handleSignInUiResult(result);
                    }
                });

        // 인가 동의 화면(AuthorizationResult 의 PendingIntent)용 런처
        this.authorizationLauncher = cordovaActivity.registerForActivityResult(
                new ActivityResultContracts.StartIntentSenderForResult(),
                new ActivityResultCallback<ActivityResult>() {
                    public void onActivityResult(ActivityResult result) {
                        handleAuthorizationUiResult(result);
                    }
                });
    }

    @Override
    public boolean execute(String action, CordovaArgs args, CallbackContext callbackContext) throws JSONException {
        if (ACTION_IS_AVAILABLE.equals(action)) {
            callbackContext.success("true");

        } else if (ACTION_LOGIN.equals(action)) {
            Log.i(TAG, "Trying to Log in!");
            login(args.optJSONObject(0), callbackContext);

        } else if (ACTION_TRY_SILENT_LOGIN.equals(action)) {
            Log.i(TAG, "Trying to do silent login!");
            trySilentLogin(args.optJSONObject(0), callbackContext);

        } else if (ACTION_LOGOUT.equals(action)) {
            Log.i(TAG, "Trying to logout!");
            signOut(callbackContext);

        } else if (ACTION_DISCONNECT.equals(action)) {
            Log.i(TAG, "Trying to disconnect the user");
            disconnect(callbackContext);

        } else if (ACTION_GET_SIGNING_CERTIFICATE_FINGERPRINT.equals(action)) {
            getSigningCertificateFingerprint(callbackContext);

        } else {
            Log.i(TAG, "This action doesn't exist");
            return false;
        }
        return true;
    }

    // ── 1 단계: 인증 ────────────────────────────────────────────────────────────

    /**
     * 인증용 GoogleSignInOptions.
     * ⚠️ 여기에 requestScopes 를 절대 넣지 말 것 — 스코프는 인가 단계(authorize)의 몫이다.
     *    로그인 옵션에 넣는 순간 동의 화면이 "로그인 + 미체크 선택 항목" 으로 돌아간다.
     */
    private GoogleSignInOptions buildSignInOptions(JSONObject clientOptions) {
        GoogleSignInOptions.Builder gso = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                .requestEmail()
                .requestProfile();

        if (clientOptions == null) {
            return gso.build();
        }

        String webClientId = clientOptions.optString(ARGUMENT_WEB_CLIENT_ID, null);
        if (webClientId != null && !webClientId.isEmpty()) {
            gso.requestIdToken(webClientId);
            if (clientOptions.optBoolean(ARGUMENT_OFFLINE_KEY, false)) {
                gso.requestServerAuthCode(webClientId, true);
            }
        }

        String hostedDomain = clientOptions.optString(ARGUMENT_HOSTED_DOMAIN, null);
        if (hostedDomain != null && !hostedDomain.isEmpty()) {
            gso.setHostedDomain(hostedDomain);
        }

        return gso.build();
    }

    /** options.scopes(공백 구분 문자열) → 스코프 URI 목록. 연속 공백으로 빈 항목이 섞이지 않게 거른다. */
    private List<String> parseScopeUris(JSONObject clientOptions) {
        List<String> uris = new ArrayList<String>();
        if (clientOptions == null) {
            return uris;
        }
        String scopes = clientOptions.optString(ARGUMENT_SCOPES, null);
        if (scopes == null || scopes.trim().isEmpty()) {
            return uris;
        }
        for (String s : scopes.trim().split("\\s+")) {
            if (!s.isEmpty()) {
                uris.add(s);
            }
        }
        return uris;
    }

    private void login(JSONObject clientOptions, CallbackContext callbackContext) {
        this.savedCallbackContext = callbackContext;
        this.pendingScopeUris = parseScopeUris(clientOptions);

        final GoogleSignInClient client = GoogleSignIn.getClient(cordova.getActivity(), buildSignInOptions(clientOptions));

        // 조용한 로그인을 먼저 시도한다.
        // 앱의 401 처리(토큰 만료 → 재로그인)가 이 경로를 타므로, 세션이 살아 있으면
        // 계정 선택 화면 없이 토큰만 조용히 재발급된다. 세션이 없으면(로그아웃/최초/revoke 직후)
        // 대화형 사인인 화면으로 넘어간다.
        // 계정을 바꾸고 싶으면 앱의 로그아웃(signOut)을 거치면 된다 — 그러면 silent 가 실패해 화면이 뜬다.
        client.silentSignIn()
                .addOnSuccessListener(account -> authorizeAccount(account))
                .addOnFailureListener(e -> signInActivityLauncher.launch(client.getSignInIntent()));
    }

    private void trySilentLogin(JSONObject clientOptions, CallbackContext callbackContext) {
        this.savedCallbackContext = callbackContext;
        this.pendingScopeUris = parseScopeUris(clientOptions);

        GoogleSignInClient client = GoogleSignIn.getClient(cordova.getActivity(), buildSignInOptions(clientOptions));

        client.silentSignIn()
                .addOnSuccessListener(account -> {
                    pendingAccount = account;

                    if (pendingScopeUris.isEmpty()) {
                        sendLoginResult(account, null, null);
                        return;
                    }

                    Identity.getAuthorizationClient(cordova.getActivity())
                            .authorize(buildAuthorizationRequest(account))
                            .addOnSuccessListener(authResult -> {
                                if (authResult.hasResolution()) {
                                    // "silent" 이므로 동의 UI 를 띄우지 않는다.
                                    // ⚠️ 그래도 에러가 아니라 성공(신원만, accessToken 없음)이다.
                                    //    이 액션의 두 소비처(googleDriveLogout / googleDriveDisconnect)가
                                    //    성공을 게이트로 logout/disconnect 를 부른다. 스코프를 거부한
                                    //    사용자를 여기서 막으면 revoke 에 도달하지 못해 403 복구
                                    //    루프가 되살아난다. 승인 여부는 grantedScopes 로 판단할 것.
                                    sendLoginResult(account, null, authResult.getGrantedScopes());
                                } else {
                                    finishAuthorization(authResult);
                                }
                            })
                            // 인가 조회가 실패해도(네트워크 등) 인증 자체는 유효하다 — 신원만 돌려준다
                            .addOnFailureListener(e -> sendLoginResult(account, null, null));
                })
                // 세션 없음 → SIGN_IN_REQUIRED(4) 등 상태 코드 그대로
                .addOnFailureListener(e -> sendError(callbackContext, e));
    }

    /** 대화형 사인인 화면의 결과 */
    private void handleSignInUiResult(ActivityResult result) {
        Log.i(TAG, "Sign-in activity finished");

        // ⚠️ 로그인 도중 프로세스가 죽었다 살아나면 런처가 결과를 재전달하는데,
        //    JS 콜백 컨텍스트는 웹뷰와 함께 사라졌다. 받을 사람이 없으므로 조용히 버린다.
        if (savedCallbackContext == null) {
            Log.w(TAG, "Sign-in result arrived without a pending callback (process was recreated?)");
            return;
        }

        Intent intent = result.getData();

        if (intent == null) {
            savedCallbackContext.error(GoogleSignInStatusCodes.SIGN_IN_CANCELLED);
            return;
        }

        try {
            GoogleSignInAccount account = GoogleSignIn.getSignedInAccountFromIntent(intent).getResult(ApiException.class);
            authorizeAccount(account);
        } catch (ApiException e) {
            // SIGN_IN_CANCELLED(12501) 등 상태 코드를 그대로 — 앱이 숫자 코드로 분기한다
            savedCallbackContext.error(e.getStatusCode());
        }
    }

    // ── 2 단계: 인가 ────────────────────────────────────────────────────────────

    private AuthorizationRequest buildAuthorizationRequest(GoogleSignInAccount account) {
        List<Scope> scopes = new ArrayList<Scope>();
        for (String uri : pendingScopeUris) {
            scopes.add(new Scope(uri));
        }

        AuthorizationRequest.Builder request = AuthorizationRequest.builder().setRequestedScopes(scopes);

        // 방금 로그인한 계정을 지정해 인가 UI 에서 계정을 또 고르지 않게 한다
        Account androidAccount = account.getAccount();
        if (androidAccount != null) {
            request.setAccount(androidAccount);
        }

        return request.build();
    }

    /** 인증이 끝난 계정에 대해 스코프 인가를 진행한다 */
    private void authorizeAccount(GoogleSignInAccount account) {
        this.pendingAccount = account;

        if (pendingScopeUris.isEmpty()) {
            // 스코프 없는 로그인 — 인가 단계가 필요 없다. 신원만 돌려준다(accessToken 없음).
            sendLoginResult(account, null, null);
            return;
        }

        Identity.getAuthorizationClient(cordova.getActivity())
                .authorize(buildAuthorizationRequest(account))
                .addOnSuccessListener(authResult -> {
                    if (authResult.hasResolution()) {
                        // 아직 승인되지 않은 스코프 — 스코프 전용 동의 화면을 띄운다.
                        // (로그인 화면에 딸린 미체크 체크박스가 아니라 "Drive 접근" 단독 화면이다)
                        PendingIntent pendingIntent = authResult.getPendingIntent();
                        authorizationLauncher.launch(
                                new IntentSenderRequest.Builder(pendingIntent.getIntentSender()).build());
                    } else {
                        // 이미 전부 승인됨 — UI 없이 토큰이 나온다 (401 재로그인이 조용한 이유)
                        finishAuthorization(authResult);
                    }
                })
                .addOnFailureListener(e -> sendError(savedCallbackContext, e));
    }

    /** 인가 동의 화면의 결과 */
    private void handleAuthorizationUiResult(ActivityResult result) {
        // ⚠️ handleSignInUiResult 와 같은 이유의 프로세스 재생성 방어
        if (savedCallbackContext == null) {
            Log.w(TAG, "Authorization result arrived without a pending callback (process was recreated?)");
            return;
        }

        if (result.getResultCode() != Activity.RESULT_OK || result.getData() == null) {
            // 동의 화면을 닫음/거부. 로그인 취소와 같은 코드(12501)를 돌려줘
            // 앱의 기존 취소 처리("You don't have permission")를 그대로 재사용한다.
            savedCallbackContext.error(GoogleSignInStatusCodes.SIGN_IN_CANCELLED);
            return;
        }

        try {
            AuthorizationResult authResult = Identity.getAuthorizationClient(cordova.getActivity())
                    .getAuthorizationResultFromIntent(result.getData());
            finishAuthorization(authResult);
        } catch (ApiException e) {
            savedCallbackContext.error(e.getStatusCode());
        }
    }

    /**
     * ⚠️ 요청 ≠ 승인. 여러 스코프면 부분 승인도 가능하므로 전부 승인됐는지 확인한다.
     *    검증 없이 토큰을 돌려주면 앱이 쓸모없는 토큰을 저장했다가 403 을 맞는다(iOS 와 같은 규칙).
     */
    private void finishAuthorization(AuthorizationResult authResult) {
        // 프로세스 재생성으로 인증 단계의 계정을 잃은 경우 — 결과를 조립할 수 없다
        if (pendingAccount == null) {
            savedCallbackContext.error("Sign-in session was lost, please log in again");
            return;
        }

        List<String> granted = authResult.getGrantedScopes();

        for (String requested : pendingScopeUris) {
            if (granted == null || !granted.contains(requested)) {
                savedCallbackContext.error("Required Google scopes were not granted");
                return;
            }
        }

        sendLoginResult(pendingAccount, authResult.getAccessToken(), granted);
    }

    // ── 결과/헬퍼 ──────────────────────────────────────────────────────────────

    /**
     * 필드 구성은 iOS(GooglePlus.m sendLoginSuccessWithUser:)와 맞춘다.
     * ⚠️ expires / expires_in 은 더 이상 없다(클래스 주석 참고).
     * ⚠️ JSONObject.put(key, null) 은 키를 제거한다 — null 필드는 JS 에서 undefined 가 된다(옛 동작과 동일).
     */
    private void sendLoginResult(GoogleSignInAccount account, String accessToken, List<String> grantedScopes) {
        try {
            JSONObject result = new JSONObject();
            result.put(FIELD_ACCESS_TOKEN, accessToken != null ? accessToken : JSONObject.NULL);
            if (grantedScopes != null) {
                result.put(FIELD_GRANTED_SCOPES, new JSONArray(grantedScopes));
            }
            result.put("email", account.getEmail());
            result.put("idToken", account.getIdToken());
            result.put("serverAuthCode", account.getServerAuthCode());
            result.put("userId", account.getId());
            result.put("displayName", account.getDisplayName());
            result.put("familyName", account.getFamilyName());
            result.put("givenName", account.getGivenName());
            result.put("imageUrl", account.getPhotoUrl());
            savedCallbackContext.success(result);
        } catch (JSONException e) {
            savedCallbackContext.error("Trouble obtaining result, error: " + e.getMessage());
        }
    }

    /** ApiException 이면 상태 코드(int)를, 아니면 메시지를 돌려준다 — 옛 에러 계약(숫자 코드) 유지 */
    private void sendError(CallbackContext callbackContext, Exception e) {
        if (e instanceof ApiException) {
            callbackContext.error(((ApiException) e).getStatusCode());
        } else {
            callbackContext.error(e != null && e.getMessage() != null ? e.getMessage() : "Unknown error");
        }
    }

    // ── 로그아웃 / 연결 해제 ────────────────────────────────────────────────────

    /**
     * ⚠️ 옛 구현의 "Please use login or trySilentLogin before ..." 사전 조건은 제거했다.
     *    GoogleApiClient 를 미리 만들어 둬야 했던 제약이었고, GoogleSignInClient 는
     *    그 자리에서 만들 수 있다. (앱의 trySilentLogin 선행 호출은 하위 호환용으로 무해하다)
     */
    private void signOut(CallbackContext callbackContext) {
        GoogleSignIn.getClient(cordova.getActivity(), buildSignInOptions(null))
                .signOut()
                .addOnCompleteListener(task -> {
                    if (task.isSuccessful()) {
                        callbackContext.success("Logged user out");
                    } else {
                        sendError(callbackContext, task.getException());
                    }
                });
    }

    /**
     * revokeAccess = 승인 기록 자체를 취소한다(로그아웃 포함).
     * ⚠️ signOut 과 절대 혼용하지 말 것 — 구글은 스코프 동의 거부를 기억하므로,
     *    revoke 만이 동의 화면을 처음부터 다시 띄운다. 403 복구 경로가 이것에 의존한다.
     */
    private void disconnect(CallbackContext callbackContext) {
        GoogleSignIn.getClient(cordova.getActivity(), buildSignInOptions(null))
                .revokeAccess()
                .addOnCompleteListener(task -> {
                    if (task.isSuccessful()) {
                        callbackContext.success("Disconnected user");
                    } else {
                        sendError(callbackContext, task.getException());
                    }
                });
    }

    private void getSigningCertificateFingerprint(CallbackContext callbackContext) {
        String packageName = webView.getContext().getPackageName();
        int flags = PackageManager.GET_SIGNATURES;
        PackageManager pm = webView.getContext().getPackageManager();
        try {
            PackageInfo packageInfo = pm.getPackageInfo(packageName, flags);
            Signature[] signatures = packageInfo.signatures;
            byte[] cert = signatures[0].toByteArray();

            String strResult = "";
            MessageDigest md;
            md = MessageDigest.getInstance("SHA1");
            md.update(cert);
            for (byte b : md.digest()) {
                String strAppend = Integer.toString(b & 0xff, 16);
                if (strAppend.length() == 1) {
                    strResult += "0";
                }
                strResult += strAppend;
                strResult += ":";
            }
            // strip the last ':'
            strResult = strResult.substring(0, strResult.length() - 1);
            strResult = strResult.toUpperCase();
            callbackContext.success(strResult);

        } catch (Exception e) {
            e.printStackTrace();
            callbackContext.error(e.getMessage());
        }
    }
}
