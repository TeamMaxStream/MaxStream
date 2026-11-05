import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: "AIzaSyAl1ehmMvnoJ8PMeFymmq30IhGLS5_guPQ",
    authDomain: "maxstream-8effc.firebaseapp.com",
    projectId: "maxstream-8effc",
    storageBucket: "maxstream-8effc.appspot.com",
    messagingSenderId: "799710852137",
    appId: "1:799710852137:web:19068a6c609e22a3649838",
    measurementId: "G-XR7XE1T7RE",
    databaseURL: "https://maxstream-8effc-default-rtdb.firebaseio.com",
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: "AIzaSyAiNjTADd8kA3qi3Dgnvlyo1Vf347QnsYk",
    projectId: "maxstream-8effc",
    storageBucket: "maxstream-8effc.firebasestorage.app",
    messagingSenderId: "799710852137",
    appId: "1:799710852137:android:5b9af68b833c3811649838",
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: "AIzaSyAl1ehmMvnoJ8PMeFymmq30IhGLS5_guPQ",
    projectId: "maxstream-8effc",
    storageBucket: "maxstream-8effc.appspot.com", // ✅ FIXED
    messagingSenderId: "799710852137",
    appId:
        "1:799710852137:ios:e22a364983819068a6c609", // ✅ Use correct iOS appId if available
    iosBundleId:
        'com.example.maxstream', // ✅ Update this if you have a real iOS bundle ID
  );

  static const FirebaseOptions macos = ios;
}
