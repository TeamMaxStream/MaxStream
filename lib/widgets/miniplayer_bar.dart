import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/miniplayer_service.dart';

class MiniplayerBar extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onClose;

  const MiniplayerBar({super.key, required this.onTap, required this.onClose});

  @override
  State<MiniplayerBar> createState() => _MiniplayerBarState();
}

class _MiniplayerBarState extends State<MiniplayerBar> {
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = MiniplayerService.instance;
    final controller = service.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth > 600;
    final miniWidth = isTablet ? 280.0 : 180.0;
    final miniHeight = isTablet ? 170.0 : 110.0;

    final value = controller.value;
    final position = value.position;
    final duration = value.duration;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final title = service.isMovie
        ? service.title
        : '${service.title} S${service.season}E${service.episode}';

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: miniWidth,
        height: miniHeight,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Actual video feed
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            ),
            // Gradient overlay for readability
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.6)],
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),
            ),
            // Title + progress
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isTablet ? 12 : 10,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Subtitles overlay
            if (service.activeSubtitleCues.isNotEmpty)
              Positioned(
                left: 4,
                right: 4,
                bottom: 36,
                child: Builder(
                  builder: (context) {
                    final cues = service.activeSubtitleCues.where(
                      (cue) => position >= cue.start && position <= cue.end,
                    );
                    if (cues.isEmpty) return const SizedBox.shrink();
                    return Text(
                      cues.map((c) => c.text).join('\n'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isTablet ? 10 : 8,
                        fontWeight: FontWeight.w500,
                        shadows: const [
                          Shadow(blurRadius: 4, color: Colors.black),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
              ),
            // Play/pause
            Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    if (value.isPlaying) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                    setState(() {});
                  },
                  icon: Icon(
                    value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
            // Close button
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: widget.onClose,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white70,
                    size: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
