import 'package:flutter/material.dart';
import 'dart:math' as math;

class CustomLoadingWidget extends StatefulWidget {
  final double size;
  final Color color;
  final String? text;
  final LoadingStyle style;

  const CustomLoadingWidget({
    super.key,
    this.size = 50.0,
    this.color = const Color(0xFFE50914),
    this.text,
    this.style = LoadingStyle.circular,
  });

  @override
  State<CustomLoadingWidget> createState() => _CustomLoadingWidgetState();
}

enum LoadingStyle { circular, dots, pulse, wave }

class _CustomLoadingWidgetState extends State<CustomLoadingWidget>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _pulseController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);

    _waveController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildLoadingIndicator(),
        if (widget.text != null) ...[
          const SizedBox(height: 16),
          Text(
            widget.text!,
            style: TextStyle(
              color: widget.color,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLoadingIndicator() {
    switch (widget.style) {
      case LoadingStyle.circular:
        return _buildCircularLoader();
      case LoadingStyle.dots:
        return _buildDotsLoader();
      case LoadingStyle.pulse:
        return _buildPulseLoader();
      case LoadingStyle.wave:
        return _buildWaveLoader();
    }
  }

  Widget _buildCircularLoader() {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: CircularLoadingPainter(
            progress: _controller.value,
            color: widget.color,
          ),
        );
      },
    );
  }

  Widget _buildDotsLoader() {
    return SizedBox(
      width: widget.size * 2,
      height: widget.size / 2,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final delay = index * 0.2;
              final progress = (_controller.value + delay) % 1.0;
              final scale = math.sin(progress * math.pi) * 0.5 + 0.5;

              return Transform.scale(
                scale: 0.5 + scale * 0.8,
                child: Container(
                  width: widget.size / 6,
                  height: widget.size / 6,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.3 + scale * 0.7),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }

  Widget _buildPulseLoader() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = 0.7 + _pulseController.value * 0.6;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.3),
              border: Border.all(color: widget.color, width: 2),
            ),
            child: Center(
              child: Container(
                width: widget.size / 3,
                height: widget.size / 3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWaveLoader() {
    return SizedBox(
      width: widget.size * 1.5,
      height: widget.size / 2,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(4, (index) {
          return AnimatedBuilder(
            animation: _waveController,
            builder: (context, child) {
              final delay = index * 0.1;
              final progress = (_waveController.value + delay) % 1.0;
              final height =
                  math.sin(progress * 2 * math.pi) * (widget.size / 4) +
                  (widget.size / 4);

              return Container(
                width: widget.size / 8,
                height: height,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(widget.size / 16),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

class CircularLoadingPainter extends CustomPainter {
  final double progress;
  final Color color;

  CircularLoadingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // Background circle
    final backgroundPaint = Paint()
      ..color = color.withValues(alpha: 0.1)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, backgroundPaint);

    // Progress arc
    final progressPaint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * progress;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      progressPaint,
    );

    // Gradient effect
    final gradientPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0.8),
          color,
          color.withValues(alpha: 0.3),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle + sweepAngle - 0.3,
      0.3,
      false,
      gradientPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Convenience widgets for common loading scenarios
class MovieLoadingWidget extends StatelessWidget {
  final String? text;

  const MovieLoadingWidget({super.key, this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: CustomLoadingWidget(
        size: 60,
        color: const Color(0xFFE50914),
        text: text ?? 'Loading...',
        style: LoadingStyle.circular,
      ),
    );
  }
}

class SearchLoadingWidget extends StatelessWidget {
  const SearchLoadingWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CustomLoadingWidget(
        size: 40,
        color: Color(0xFFE50914),
        style: LoadingStyle.dots,
      ),
    );
  }
}

class ButtonLoadingWidget extends StatelessWidget {
  final Color? color;

  const ButtonLoadingWidget({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return CustomLoadingWidget(
      size: 20,
      color: color ?? Colors.white,
      style: LoadingStyle.pulse,
    );
  }
}
