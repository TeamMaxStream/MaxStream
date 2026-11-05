import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/auth_service.dart';
import 'profile_select_screen.dart';
import 'sign_up_screen.dart';
import 'forgot_password_screen.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen>
    with SingleTickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;
  String? _errorMessage;
  bool _showPassword = false;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _dismissKeyboard() => FocusScope.of(context).unfocus();

  Future<void> _signInWithEmail() async {
    _dismissKeyboard();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final user = await AuthService.signInWithEmailEnhanced(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );

      if (user != null && mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSelectScreen()),
        );
      } else if (mounted) {
        setState(() => _errorMessage = 'Sign-in failed. No user returned.');
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String errorMessage = 'An error occurred';
        switch (e.code) {
          case 'user-not-found':
            errorMessage = 'No user found with this email';
            break;
          case 'wrong-password':
            errorMessage = 'Incorrect password';
            break;
          case 'user-disabled':
            errorMessage = 'This account has been disabled';
            break;
          case 'too-many-requests':
            errorMessage = 'Too many failed attempts. Try again later';
            break;
          case 'network-request-failed':
            errorMessage = 'Network error. Check your connection';
            break;
          case 'invalid-email':
            errorMessage = 'Invalid email format';
            break;
          case 'invalid-credential':
            errorMessage = 'Invalid email or password';
            break;
          case 'invalid-api-key':
            errorMessage = 'Invalid Firebase API key. Check app configuration';
            break;
          case 'internal-error':
            errorMessage = 'Unexpected server error. Try again';
            break;
          default:
            errorMessage = 'Authentication failed (${e.code})';
        }
        setState(() => _errorMessage = errorMessage);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Sign-in failed: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      debugPrint('Attempting Google sign-in...');
      final user = await AuthService.signInWithGoogleEnhanced();
      debugPrint(
        'Google sign-in result: ${user != null ? 'Success' : 'Failed'}',
      );

      if (user != null && mounted) {
        debugPrint('Navigating to main screen...');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSelectScreen()),
        );
      } else if (mounted) {
        debugPrint('Google sign-in was cancelled or failed');
        setState(
          () => _errorMessage = 'Google sign-in was cancelled or failed',
        );
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('FirebaseAuthException during Google sign-in: ${e.code}');
      if (mounted) {
        String errorMessage = 'Google sign-in failed';
        switch (e.code) {
          case 'account-exists-with-different-credential':
            errorMessage = 'Account exists with different sign-in method';
            break;
          case 'invalid-credential':
            errorMessage = 'Invalid Google credentials';
            break;
          case 'operation-not-allowed':
            errorMessage =
                'Google sign-in not enabled. Please contact support.';
            break;
          case 'user-disabled':
            errorMessage = 'This account has been disabled';
            break;
          case 'user-not-found':
            errorMessage = 'No account found';
            break;
          case 'network-request-failed':
            errorMessage = 'Network error. Check your connection';
            break;
          default:
            errorMessage = e.message ?? 'Google authentication failed';
        }
        debugPrint('Google sign-in error: $errorMessage');
        setState(() => _errorMessage = errorMessage);
      }
    } catch (e) {
      debugPrint('General exception during Google sign-in: $e');
      if (mounted) {
        setState(() => _errorMessage = 'Google sign-in error: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(
            child: Image(
              image: AssetImage('assets/images/background.jpg'),
              fit: BoxFit.cover,
            ),
          ),
          SafeArea(
            child: Center(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.9,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          )
                        : SingleChildScrollView(
                            child: Form(
                              key: _formKey,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Welcome Back!',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _emailController,
                                    keyboardType: TextInputType.emailAddress,
                                    style: const TextStyle(color: Colors.white),
                                    autofillHints: const [
                                      AutofillHints.username,
                                    ],
                                    decoration: _inputDecoration(
                                      label: 'Email',
                                    ),
                                    validator: (value) {
                                      final email = value?.trim() ?? '';
                                      final valid = RegExp(
                                        r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                                      ).hasMatch(email);
                                      return valid
                                          ? null
                                          : 'Enter a valid email';
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _passwordController,
                                    obscureText: !_showPassword,
                                    style: const TextStyle(color: Colors.white),
                                    autofillHints: const [
                                      AutofillHints.password,
                                    ],
                                    decoration: _inputDecoration(
                                      label: 'Password',
                                      suffix: IconButton(
                                        icon: Icon(
                                          _showPassword
                                              ? Icons.visibility
                                              : Icons.visibility_off,
                                          color: Colors.white,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            _showPassword = !_showPassword;
                                          });
                                        },
                                      ),
                                    ),
                                    validator: (value) =>
                                        value == null || value.length < 6
                                        ? 'Enter 6+ characters'
                                        : null,
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const ForgotPasswordScreen(),
                                          ),
                                        );
                                      },
                                      child: const Text(
                                        'Forgot Password?',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  if (_errorMessage != null)
                                    Text(
                                      _errorMessage!,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  const SizedBox(height: 10),
                                  ElevatedButton(
                                    onPressed: _signInWithEmail,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.blueAccent,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 40,
                                        vertical: 14,
                                      ),
                                    ),
                                    child: const Text(
                                      'Sign In',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    onPressed: _signInWithGoogle,
                                    icon: const Icon(
                                      Icons.g_mobiledata,
                                      color: Colors.white,
                                    ),
                                    label: const Text(
                                      'Sign In with Google',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 30,
                                        vertical: 14,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pushReplacement(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const SignUpScreen(),
                                        ),
                                      );
                                    },
                                    child: const Text(
                                      "Don't have an account? Sign Up",
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({required String label, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white),
      suffixIcon: suffix,
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Colors.white),
        borderRadius: BorderRadius.circular(12),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Colors.blueAccent),
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}
