import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:glassmorphism/glassmorphism.dart';

import '../services/auth_service.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _emailController = TextEditingController();
  String? _message;
  bool _isError = false;
  bool _loading = false;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _sendResetEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _isError = true;
        _message = "Please enter a valid email address";
      });
      return;
    }

    setState(() {
      _loading = true;
      _message = null;
    });

    try {
      await AuthService.resetPassword(email);

      if (mounted) {
        setState(() {
          _isError = false;
          _message = "Password reset email sent!";
        });
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String errorMessage = "An error occurred";
        switch (e.code) {
          case 'user-not-found':
            errorMessage = 'No account found with this email';
            break;
          case 'invalid-email':
            errorMessage = 'Invalid email format';
            break;
          case 'network-request-failed':
            errorMessage = 'Network error. Check your connection';
            break;
          case 'too-many-requests':
            errorMessage = 'Too many requests. Please try again later';
            break;
          default:
            errorMessage = e.message ?? "An error occurred";
        }
        setState(() {
          _isError = true;
          _message = errorMessage;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isError = true;
          _message = "Failed to send reset email: ${e.toString()}";
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: Center(
          child: GlassmorphicContainer(
            width: MediaQuery.of(context).size.width * 0.9,
            height: 400,
            borderRadius: 20,
            blur: 20,
            alignment: Alignment.center,
            border: 2,
            linearGradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.1),
                Colors.white.withValues(alpha: 0.05),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderGradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.4),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.red),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Reset Password',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _emailController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Email',
                            labelStyle: const TextStyle(color: Colors.white),
                            filled: true,
                            fillColor: Colors.white12,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 15),
                        if (_message != null)
                          Text(
                            _message!,
                            style: TextStyle(
                              color: _isError ? Colors.red : Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        const SizedBox(height: 15),
                        ElevatedButton(
                          onPressed: _sendResetEmail,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                          ),
                          child: const Text(
                            "Send Reset Link",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            "Back to Sign In",
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
