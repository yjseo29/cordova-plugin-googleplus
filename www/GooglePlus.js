function GooglePlus() {
}

GooglePlus.prototype.isAvailable = function (callback) {
  cordova.exec(callback, null, "GooglePlus", "isAvailable", []);
};

GooglePlus.prototype.login = function (options, successCallback, errorCallback) {
  cordova.exec(successCallback, errorCallback, "GooglePlus", "login", [options]);
};

/**
 * trySilentLogin 은 안드로이드 전용이다. iOS 네이티브에는 해당 액션 자체가 없다.
 *
 * ⚠️ 예전에는 device.platform 으로 분기했는데 두 가지 문제가 있었다.
 *    1. cordova-plugin-device 에 의존하는데 plugin.xml 에 dependency 선언이 없었다.
 *       그 플러그인이 없는 프로젝트에서는 ReferenceError 가 난다.
 *    2. device 전역은 deviceready 이후에만 정의된다. 그 전에 부르면 역시 ReferenceError.
 *    cordova.platformId 는 cordova.js 가 직접 제공하므로 둘 다 해당되지 않는다.
 */
GooglePlus.prototype.trySilentLogin = function (options, successCallback, errorCallback) {
  if (cordova.platformId === 'ios') {
    successCallback("For Android only");
  } else {
    cordova.exec(successCallback, errorCallback, "GooglePlus", "trySilentLogin", [options]);
  }
};

/**
 * isSignedIn 은 iOS 전용이다. 안드로이드 네이티브에는 해당 액션 자체가 없다
 * (trySilentLogin 이 그 역할을 겸한다). 안드로이드에서 부르면 명시적으로 에러를 준다 —
 * 액션 없는 exec 는 INVALID_ACTION 으로 조용히 실패해 원인을 찾기 어렵기 때문이다.
 */
GooglePlus.prototype.isSignedIn = function (successCallback, errorCallback) {
  if (cordova.platformId === 'android') {
    if (errorCallback) {
      errorCallback("For iOS only");
    }
  } else {
    cordova.exec(successCallback, errorCallback, "GooglePlus", "isSignedIn", []);
  }
};

GooglePlus.prototype.logout = function (successCallback, errorCallback) {
  cordova.exec(successCallback, errorCallback, "GooglePlus", "logout", []);
};

GooglePlus.prototype.disconnect = function (successCallback, errorCallback) {
  cordova.exec(successCallback, errorCallback, "GooglePlus", "disconnect", []);
};

GooglePlus.prototype.getSigningCertificateFingerprint = function (successCallback, errorCallback) {
  cordova.exec(successCallback, errorCallback, "GooglePlus", "getSigningCertificateFingerprint", []);
};

GooglePlus.install = function () {
  if (!window.plugins) {
    window.plugins = {};
  }

  window.plugins.googleplus = new GooglePlus();
  return window.plugins.googleplus;
};

cordova.addConstructor(GooglePlus.install);
