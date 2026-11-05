import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/device_code_service.dart';

const Color _accentRed = Color(0xFFE50914);
const Color _darkBackground = Color(0xFF0D0D0D);
const Color _cardDark = Color(0xFF161616);
const Color _cardDarkAlt = Color(0xFF1A1A1A);
const Color _buttonDark = Color(0xFF2A2A2A);

class TVPairingScreen extends StatefulWidget {
  const TVPairingScreen({super.key});

  @override
  State<TVPairingScreen> createState() => _TVPairingScreenState();
}

class _TVPairingScreenState extends State<TVPairingScreen> {
  String? _generatedCode;
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _generateTVCode() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _generatedCode = null;
    });

    try {
      final code = await DeviceCodeService.generateDeviceCode();
      if (mounted) {
        setState(() {
          _generatedCode = code;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = _formatErrorMessage(e.toString());
          _isLoading = false;
        });
      }
    }
  }

  String _formatErrorMessage(String error) {
    if (error.contains('permission_denied') ||
        error.contains('permission denied') ||
        error.contains('Could not create a pairing code')) {
      return 'Could not create a pairing code.\n\n'
          'Make sure you are signed in and try again.';
    } else if (error.contains('timed out') ||
        error.contains('Timeout') ||
        error.contains('timed out after')) {
      return 'Pairing code generation timed out. This usually happens when:\n'
          '• Your internet connection is slow\n'
          '• The server is experiencing issues\n\n'
          'Please try again. If the problem persists, check your internet '
          'connection.';
    } else if (error.contains('not authenticated') ||
        error.contains('User not')) {
      return 'You need to be logged in to generate a pairing code.\n'
          'Please log in first.';
    } else if (error.contains('Firebase')) {
      return 'Connection to MaxStream service failed.\n'
          'Please check your internet connection and try again.';
    } else {
      return 'Error: $error';
    }
  }

  void _copyToClipboard() {
    if (_generatedCode != null) {
      Clipboard.setData(ClipboardData(text: _generatedCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Code copied to clipboard'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _generateNew() {
    setState(() {
      _generatedCode = null;
      _errorMessage = null;
    });
    _generateTVCode();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: _darkBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: textColor,
        title: const Text(
          'TV Pairing',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        iconTheme: const IconThemeData(color: _accentRed),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderCard(context),
              const SizedBox(height: 32),
              _buildStepper(isDark),
              const SizedBox(height: 32),
              _buildCodeSection(isDark),
              const SizedBox(height: 32),
              if (_errorMessage != null) _buildErrorState(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.grey[400]! : Colors.grey[700]!;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? _cardDark : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _accentRed.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.tv, color: _accentRed, size: 36),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sign In on Your TV',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect your phone to your TV without typing your password',
                  style: TextStyle(
                    color: subTextColor,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepper(bool isDark) {
    final stepColor = isDark ? Colors.red[900]! : Colors.red[100]!;
    final stepBg = isDark ? Colors.red[800]! : Colors.red[50]!;

    return Column(
      children: [
        _stepIndicator(
          number: 1,
          title: 'Generate Code',
          statusLabel: 'Tap to generate a unique code for your TV',
          isCompleted: _generatedCode != null,
          stepColor: stepColor,
          stepBg: stepBg,
        ),
        const SizedBox(height: 8),
        _stepIndicator(
          number: 2,
          title: 'Go to MaxStream TV',
          statusLabel: 'Open MaxStream on your TV and navigate to sign in',
          isCompleted: true,
          stepColor: stepColor,
          stepBg: stepBg,
        ),
        const SizedBox(height: 8),
        _stepIndicator(
          number: 3,
          title: 'Enter Code',
          statusLabel: 'Enter the generated code on your TV',
          isCompleted: true,
          stepColor: stepColor,
          stepBg: stepBg,
        ),
      ],
    );
  }

  Widget _stepIndicator({
    required int number,
    required String title,
    required String statusLabel,
    required bool isCompleted,
    required Color stepColor,
    required Color stepBg,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.grey[400]! : Colors.grey[700]!;

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isCompleted ? stepColor : stepBg,
            shape: BoxShape.circle,
            boxShadow: isCompleted
                ? [
                    BoxShadow(
                      color: stepColor.withOpacity(0.4),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              '$number',
              style: TextStyle(
                color: isCompleted
                    ? Colors.white
                    : (isDark ? Colors.red[300]! : Colors.red[600]!),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isCompleted ? textColor : subTextColor,
                      fontSize: 14,
                      fontWeight: isCompleted
                          ? FontWeight.bold
                          : FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                  if (!isCompleted)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Text(
                        '(pending)',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                statusLabel,
                style: TextStyle(
                  color: isCompleted
                      ? _accentRed
                      : (isDark ? Colors.red[300]! : Colors.red[400]!),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCodeSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_generatedCode == null && _errorMessage == null)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _generateTVCode,
              icon: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.code, color: Colors.white),
              label: Text(
                _isLoading ? 'Generating...' : 'Generate TV Code',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accentRed,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 2,
              ),
            ),
          ),

        const SizedBox(height: 24),

        if (_generatedCode != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: isDark ? _cardDarkAlt : Colors.grey[50],
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _accentRed.withOpacity(0.3), width: 1),
              boxShadow: [
                BoxShadow(
                  color: _accentRed.withOpacity(0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                Text(
                  'Your TV Code',
                  style: TextStyle(
                    color: _accentRed.withOpacity(0.7),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _generatedCode!,
                  style: TextStyle(
                    color: _accentRed,
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    shadows: [
                      Shadow(
                        color: _accentRed.withOpacity(0.4),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Expires in 15 minutes',
                  style: TextStyle(
                    color: isDark ? Colors.grey[400]! : Colors.grey[600]!,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 24),

        if (_generatedCode != null) ...[
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _copyToClipboard,
                  icon: const Icon(Icons.copy, color: Colors.white),
                  label: const Text('Copy Code'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _buttonDark,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _generateNew,
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text('Generate New'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accentRed,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],

        if (_errorMessage != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.red.withOpacity(0.1)
                  : Colors.red.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
              border: const Border(
                left: BorderSide(color: Colors.red, width: 3),
              ),
            ),
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: Colors.red[300] ?? Colors.red,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _generateTVCode,
            icon: const Icon(Icons.refresh, color: Colors.white),
            label: const Text('Try Again'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accentRed,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.red.withOpacity(0.1)
                : Colors.red.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
            border: const Border(left: BorderSide(color: Colors.red, width: 3)),
          ),
          child: Text(
            _errorMessage!,
            style: TextStyle(
              color: Colors.red[300] ?? Colors.red,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _generateTVCode,
          icon: const Icon(Icons.refresh, color: Colors.white),
          label: const Text('Try Again'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _accentRed,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}
