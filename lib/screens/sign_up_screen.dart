import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/auth_service.dart';
import 'profile_select_screen.dart';
import 'sign_in_screen.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen>
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

  Future<void> _signUpWithEmail() async {
    _dismissKeyboard();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final result = await AuthService.signUpWithEmail(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );

      if (result != null && mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSelectScreen()),
        );
      } else if (mounted) {
        setState(() => _errorMessage = 'Sign-up failed. No user returned.');
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String errorMessage = 'An error occurred';
        switch (e.code) {
          case 'weak-password':
            errorMessage = 'Password is too weak (min 6 characters)';
            break;
          case 'email-already-in-use':
            errorMessage =
                'This email is already registered. Use Sign In instead.';
            break;
          case 'invalid-email':
            errorMessage = 'Invalid email format';
            break;
          case 'operation-not-allowed':
            errorMessage = 'Email/password accounts are not enabled';
            break;
          case 'network-request-failed':
            errorMessage = 'Network error. Check your connection';
            break;
          case 'too-many-requests':
            errorMessage = 'Too many attempts. Try again later';
            break;
          case 'invalid-api-key':
            errorMessage = 'Invalid Firebase API key. Check app configuration';
            break;
          case 'internal-error':
            errorMessage = 'Unexpected server error. Try again';
            break;
          default:
            errorMessage = 'Registration failed (${e.code})';
        }
        setState(() => _errorMessage = errorMessage);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Sign-up failed: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _signUpWithGoogle() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      print('Attempting Google sign-up...');
      final user = await AuthService.signInWithGoogleEnhanced();
      print('Google sign-up result: ${user != null ? 'Success' : 'Failed'}');

      if (user != null && mounted) {
        print('Navigating to main screen...');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSelectScreen()),
        );
      } else if (mounted) {
        print('Google sign-up was cancelled or failed');
        setState(
          () => _errorMessage = 'Google sign-up was cancelled or failed',
        );
      }
    } on FirebaseAuthException catch (e) {
      print('FirebaseAuthException during Google sign-up: ${e.code}');
      if (mounted) {
        String errorMessage = 'Google sign-up failed';
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
          case 'network-request-failed':
            errorMessage = 'Network error. Check your connection';
            break;
          default:
            errorMessage = e.message ?? 'Google authentication failed';
        }
        print('Google sign-up error: $errorMessage');
        setState(() => _errorMessage = errorMessage);
      }
    } catch (e) {
      print('General exception during Google sign-up: $e');
      if (mounted) {
        setState(() => _errorMessage = 'Google sign-up error: ${e.toString()}');
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
                                    'Create Account',
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
                                    autofillHints: const [AutofillHints.email],
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
                                      AutofillHints.newPassword,
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
                                    onPressed: _signUpWithEmail,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.blueAccent,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 40,
                                        vertical: 14,
                                      ),
                                    ),
                                    child: const Text(
                                      'Sign Up',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    onPressed: _signUpWithGoogle,
                                    icon: const Icon(
                                      Icons.g_mobiledata,
                                      color: Colors.white,
                                    ),
                                    label: const Text(
                                      'Sign Up with Google',
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
                                          builder: (_) => const SignInScreen(),
                                        ),
                                      );
                                    },
                                    child: const Text(
                                      "Already have an account? Sign In",
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
