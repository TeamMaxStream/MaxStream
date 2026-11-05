import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:async';

class ImageCropScreen extends StatefulWidget {
  final String imagePath;

  const ImageCropScreen({super.key, required this.imagePath});

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  late img.Image originalImage;
  late Size imageDisplaySize;
  Offset cropCenter = Offset.zero;
  double cropSize = 200;
  bool isLoading = true;
  String? errorMessage;
  ui.Image? displayImage;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final imageBytes = await File(widget.imagePath).readAsBytes();
      final image = img.decodeImage(imageBytes);

      if (image == null) {
        setState(() {
          errorMessage = 'Failed to load image';
          isLoading = false;
        });
        return;
      }

      // Convert to ui.Image for display
      final uiImage = await _convertImageForDisplay(image);

      setState(() {
        originalImage = image;
        displayImage = uiImage;
        isLoading = false;
        // Initialize crop center to center of image
        cropSize =
            (originalImage.width < originalImage.height
                ? originalImage.width
                : originalImage.height) *
            0.8;
        cropCenter = Offset(
          originalImage.width / 2.0,
          originalImage.height / 2.0,
        );
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Error loading image: $e';
        isLoading = false;
      });
    }
  }

  Future<ui.Image> _convertImageForDisplay(img.Image image) async {
    // Encode image to PNG/JPG bytes and decode back as ui.Image
    final encodedBytes = img.encodeJpg(image);
    final completer = Completer<ui.Image>();

    ui.decodeImageFromList(Uint8List.fromList(encodedBytes), (result) {
      completer.complete(result);
    });

    return completer.future;
  }

  Future<String?> _cropAndSave() async {
    try {
      // Calculate crop coordinates
      final left = (cropCenter.dx - cropSize / 2).toInt().clamp(
        0,
        originalImage.width,
      );
      final top = (cropCenter.dy - cropSize / 2).toInt().clamp(
        0,
        originalImage.height,
      );
      final size = cropSize.toInt();

      final croppedWidth = (left + size > originalImage.width)
          ? originalImage.width - left
          : size;
      final croppedHeight = (top + size > originalImage.height)
          ? originalImage.height - top
          : size;

      if (croppedWidth <= 0 || croppedHeight <= 0) {
        throw Exception('Invalid crop area');
      }

      // Crop the image
      final cropped = img.copyCrop(
        originalImage,
        x: left,
        y: top,
        width: croppedWidth,
        height: croppedHeight,
      );

      // Save cropped image
      final tempDir = Directory.systemTemp;
      final tempFile = File(
        '${tempDir.path}/profile_crop_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(img.encodeJpg(cropped, quality: 95));

      return tempFile.path;
    } catch (e) {
      debugPrint('Error cropping image: $e');
      return null;
    }
  }

  Future<void> _onDonePressed() async {
    final croppedPath = await _cropAndSave();
    if (!mounted) return;
    if (croppedPath != null) {
      Navigator.pop(context, croppedPath);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to crop image'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Crop Profile Picture',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          TextButton(
            onPressed: isLoading ? null : _onDonePressed,
            child: const Text(
              'Done',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.red))
          : errorMessage != null
          ? Center(
              child: Text(
                errorMessage!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            )
          : GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  cropCenter = Offset(
                    (cropCenter.dx + details.delta.dx).clamp(
                      0,
                      originalImage.width.toDouble(),
                    ),
                    (cropCenter.dy + details.delta.dy).clamp(
                      0,
                      originalImage.height.toDouble(),
                    ),
                  );
                });
              },
              child: Stack(
                children: [
                  // Display the image
                  Center(
                    child: CustomPaint(
                      painter: ImageCropPainter(
                        image: originalImage,
                        displayImage: displayImage,
                        cropCenter: cropCenter,
                        cropSize: cropSize,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                  // Crop overlay with instructions
                  Positioned(
                    bottom: 40,
                    left: 20,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Drag to position your face in the center',
                            style: TextStyle(color: Colors.white, fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'The red square shows what will be saved',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class ImageCropPainter extends CustomPainter {
  final img.Image image;
  final ui.Image? displayImage;
  final Offset cropCenter;
  final double cropSize;

  ImageCropPainter({
    required this.image,
    this.displayImage,
    required this.cropCenter,
    required this.cropSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the image scaled to fit the canvas
    final scaleX = size.width / image.width;
    final scaleY = size.height / image.height;
    final scale = (scaleX < scaleY) ? scaleX : scaleY;

    final scaledWidth = image.width * scale;
    final scaledHeight = image.height * scale;
    final offsetX = (size.width - scaledWidth) / 2;
    final offsetY = (size.height - scaledHeight) / 2;

    // Draw the image preview
    _drawImagePreview(canvas, size, offsetX, offsetY, scale);

    // Draw crop area (red square)
    final cropLeft = offsetX + (cropCenter.dx - cropSize / 2) * scale;
    final cropTop = offsetY + (cropCenter.dy - cropSize / 2) * scale;
    final cropWidth = cropSize * scale;

    // Draw darkened overlay outside crop area
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.black.withValues(alpha: 0.4),
    );

    // Clear the crop area
    canvas.drawRect(
      Rect.fromLTWH(cropLeft, cropTop, cropWidth, cropWidth),
      Paint()..blendMode = BlendMode.clear,
    );

    // Draw crop border (red)
    canvas.drawRect(
      Rect.fromLTWH(cropLeft, cropTop, cropWidth, cropWidth),
      Paint()
        ..color = Colors.red
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // Draw corner indicators
    final corners = [
      Offset(cropLeft, cropTop),
      Offset(cropLeft + cropWidth, cropTop),
      Offset(cropLeft, cropTop + cropWidth),
      Offset(cropLeft + cropWidth, cropTop + cropWidth),
    ];

    for (final corner in corners) {
      canvas.drawCircle(corner, 8, Paint()..color = Colors.red);
    }
  }

  void _drawImagePreview(
    Canvas canvas,
    Size size,
    double offsetX,
    double offsetY,
    double scale,
  ) {
    if (displayImage != null) {
      try {
        // Draw the actual image
        canvas.drawImageRect(
          displayImage!,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(
            offsetX,
            offsetY,
            image.width * scale,
            image.height * scale,
          ),
          Paint(),
        );
      } catch (e) {
        debugPrint('Error drawing image: $e');
        // Fallback: draw grey rectangle
        final paint = Paint()..color = Colors.grey[800]!;
        canvas.drawRect(
          Rect.fromLTWH(
            offsetX,
            offsetY,
            image.width * scale,
            image.height * scale,
          ),
          paint,
        );
      }
    } else {
      // Fallback: draw grey rectangle if image not loaded yet
      final paint = Paint()..color = Colors.grey[800]!;
      canvas.drawRect(
        Rect.fromLTWH(
          offsetX,
          offsetY,
          image.width * scale,
          image.height * scale,
        ),
        paint,
      );
    }

    // Draw grid lines for composition guide
    final gridPaint = Paint()
      ..color = Colors.grey[700]!
      ..strokeWidth = 0.5;

    // Vertical lines
    for (int i = 0; i <= 3; i++) {
      final x = offsetX + (image.width * scale / 3) * i;
      canvas.drawLine(
        Offset(x, offsetY),
        Offset(x, offsetY + image.height * scale),
        gridPaint,
      );
    }

    // Horizontal lines
    for (int i = 0; i <= 3; i++) {
      final y = offsetY + (image.height * scale / 3) * i;
      canvas.drawLine(
        Offset(offsetX, y),
        Offset(offsetX + image.width * scale, y),
        gridPaint,
      );
    }
  }

  @override
  bool shouldRepaint(ImageCropPainter oldDelegate) {
    return oldDelegate.cropCenter != cropCenter ||
        oldDelegate.cropSize != cropSize ||
        oldDelegate.displayImage != displayImage;
  }
}
