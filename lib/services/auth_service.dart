import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'legacy_credential_cleanup.dart';
import 'password_manager_service.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Web OAuth client ID (client_type 3 in google-services.json). Required so
  // google_sign_in returns an idToken that Firebase Auth can verify; without
  // it `googleUser.authentication` may return a null idToken on Android.
  static const String _googleServerClientId =
      '799710852137-csceotikflpa96b2b8j6pdbjqimbngt7.apps.googleusercontent.com';

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: _googleServerClientId,
  );

  static Future<User?> signUpWithEmail(String email, String password) async {
    try {
      final result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Save password to Google Password Manager after successful signup
      if (result.user != null) {
        final passwordManager = PasswordManagerService();
        await passwordManager.savePasswordCredential(
          email: email,
          password: password,
          displayName: result.user!.displayName ?? 'MaxStream Account',
        );
      }

      return result.user;
    } on FirebaseAuthException catch (e) {
      print('Email sign-up error: code=${e.code} message=${e.message}');
      rethrow;
    } catch (e) {
      print('Email sign-up error: $e');
      rethrow;
    }
  }

  static Future<User?> signInWithEmail(String email, String password) async {
    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Save password to Google Password Manager after successful signin
      // (in case it wasn't saved before)
      if (result.user != null) {
        final passwordManager = PasswordManagerService();
        await passwordManager.savePasswordCredential(
          email: email,
          password: password,
          displayName: result.user!.displayName ?? 'MaxStream Account',
        );
      }

      return result.user;
    } catch (e) {
      print('Email sign-in error: $e');
      rethrow;
    }
  }

  static Future<User?> signInWithGoogle() async {
    try {
      // Sign out from any previous Google Sign-In to ensure clean state
      await _googleSignIn.signOut();

      // Attempt to sign in with Google
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      // If user cancels the sign-in flow
      if (googleUser == null) {
        print('Google sign-in was cancelled by the user');
        throw Exception('Google sign-in was cancelled by the user');
      }

      // Get the authentication details
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Verify we have at least one usable token. Firebase can exchange either
      // the idToken or the accessToken.
      if (googleAuth.accessToken == null && googleAuth.idToken == null) {
        print('Failed to retrieve Google authentication tokens');
        throw Exception(
          'Failed to retrieve Google authentication token. Please try again '
          'later. If this persists, make sure the app\'s SHA-1 signing '
          'fingerprint is registered under Google Sign-In in the Firebase '
          'console, then rebuild the app.',
        );
      }

      // Create the credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Sign in to Firebase with the Google credential
      final result = await _auth.signInWithCredential(credential);
      print('Successfully signed in with Google: ${result.user?.displayName}');
      return result.user;
    } on FirebaseAuthException catch (e) {
      print(
        'Firebase Auth Exception during Google sign-in: ${e.code} - ${e.message}',
      );
      // Re-throw FirebaseAuthException with more context
      rethrow;
    } catch (e) {
      print('General exception during Google sign-in: $e');
      // Handle any other exceptions
      throw Exception('Google sign-in error: ${e.toString()}');
    }
  }

  static Future<void> signOut() async {
    try {
      await _auth.signOut();
      await _googleSignIn.signOut();
      await LegacyCredentialCleanup.clearStoredPasswords();
      print('Successfully signed out');
    } catch (e) {
      print('Error during sign out: $e');
      rethrow;
    }
  }

  static User? get currentUser => _auth.currentUser;

  static Stream<User?> get authStateChanges => _auth.authStateChanges();

  static Future<User?> checkCurrentUser() async {
    try {
      // Wait for Firebase Auth to fully initialize and restore any persisted session
      await Future.delayed(const Duration(milliseconds: 500));

      // Get current user
      final user = _auth.currentUser;
      if (user != null) {
        try {
          // Force refresh the current user token to ensure it's still valid
          await user.reload();
          // Get the refreshed user after reload
          final refreshedUser = _auth.currentUser;
          if (refreshedUser != null) {
            // Verify the token is still valid by getting it
            await refreshedUser.getIdToken(true); // Force refresh token
            print('User session is valid: ${refreshedUser.email}');
            return refreshedUser;
          }
        } catch (tokenError) {
          print('Token validation failed: $tokenError');
          // Token is invalid, sign out the user
          await signOut();
          return null;
        }
      } else {
        print('No current user found');
      }

      return null;
    } catch (e) {
      print('Auth check failed: $e');
      // If any error occurs, ensure user is signed out
      try {
        await signOut();
      } catch (signOutError) {
        print('Sign out error: $signOutError');
      }
      return null;
    }
  }

  /// Enhanced sign-in with better error handling
  static Future<User?> signInWithEmailEnhanced(
    String email,
    String password,
  ) async {
    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Save password to Google Password Manager after successful signin
      if (result.user != null) {
        final passwordManager = PasswordManagerService();
        await passwordManager.savePasswordCredential(
          email: email,
          password: password,
          displayName: result.user!.displayName ?? 'MaxStream Account',
        );
      }

      return result.user;
    } catch (e) {
      print('Enhanced email sign-in error: $e');
      rethrow;
    }
  }

  /// Enhanced Google sign-in with better error handling
  static Future<User?> signInWithGoogleEnhanced() async {
    return signInWithGoogle(); // Reuse the main implementation
  }

  /// Reset password for email authentication
  static Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      print('Password reset email sent to: $email');
    } catch (e) {
      print('Password reset error: $e');
      rethrow;
    }
  }

  /// Sign in with custom token from backend (future implementation)
  /// Called after backend issues a custom token via Cloud Function
  static Future<User?> signInWithCustomToken(String customToken) async {
    try {
      final result = await _auth.signInWithCustomToken(customToken);
      print('Signed in with custom token: ${result.user?.email}');
      return result.user;
    } catch (e) {
      print('Custom token sign-in error: $e');
      rethrow;
    }
  }
}
