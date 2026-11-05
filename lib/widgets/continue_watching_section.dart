import 'package:flutter/material.dart';
import 'video_player_screen.dart';

class ContinueWatchingSection extends StatefulWidget {
  final List<Map<String, dynamic>> continueWatching;
  final Future<void> Function()? onChanged;

  const ContinueWatchingSection({
    super.key,
    required this.continueWatching,
    this.onChanged,
  });

  @override
  State<ContinueWatchingSection> createState() =>
      _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState extends State<ContinueWatchingSection> {
  @override
  Widget build(BuildContext context) {
    if (widget.continueWatching.isEmpty) return const SizedBox();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Continue Watching',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 280,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: widget.continueWatching.length,
            itemBuilder: (context, index) {
              final item = widget.continueWatching[index];
              return _buildContinueWatchingCard(context, item);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildContinueWatchingCard(
    BuildContext context,
    Map<String, dynamic> item,
  ) {
    final progress = (item['position'] ?? 0) / (item['duration'] ?? 1);
    final progressPercent = (progress * 100).round();
    final isMovie = item['isMovie'] == true;
    final typeLabel = isMovie ? 'MOVIE' : 'TV';
    final title = item['title'] ?? 'Unknown Title';

    return GestureDetector(
      onTap: () {
        _playContent(context, item);
      },
      child: Container(
        width: 135,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  SizedBox(
                    width: 135,
                    height: 200,
                    child:
                        item['posterUrl'] != null &&
                            item['posterUrl'].toString().isNotEmpty
                        ? Image.network(
                            item['posterUrl'].toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: Colors.grey[850],
                              child: const Icon(
                                Icons.movie,
                                color: Colors.grey,
                                size: 40,
                              ),
                            ),
                          )
                        : Container(
                            color: Colors.grey[850],
                            child: const Icon(
                              Icons.movie,
                              color: Colors.grey,
                              size: 40,
                            ),
                          ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        typeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 60,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.8),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Center(
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 32,
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[800],
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.red,
                      ),
                      minHeight: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$progressPercent%',
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playContent(
    BuildContext context,
    Map<String, dynamic> item,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => buildVideoPlayerScreen(
          title: item['title'],
          tmdbId: item['tmdbId'],
          isMovie: item['isMovie'],
          season: item['season'] ?? 1,
          episode: item['episode'] ?? 1,
        ),
      ),
    );
    await widget.onChanged?.call();
  }
}
