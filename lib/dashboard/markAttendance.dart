import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:dio/dio.dart';

class MarkAttendance extends StatefulWidget {
  const MarkAttendance({super.key});

  @override
  State<MarkAttendance> createState() => _MarkAttendanceState();
}

class _MarkAttendanceState extends State<MarkAttendance> {
  late CameraController _cameraController;
  late List<CameraDescription> _cameras;

  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _attendanceMarked = false;
  bool _faceDetected = false;
  bool _dialogOpen = false;
  bool _isDetecting = false;

  int _faceDetectionCount = 0;
  static const int _requiredStableFrames = 3;

  /// FAST detector for streaming
  final FaceDetector _streamDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: false,
      enableContours: false,
    ),
  );

  /// ACCURATE detector for captured image
  final FaceDetector _photoDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
    ),
  );

  late Interpreter _interpreter;
  late int _embeddingSize;

  String _verificationStatus = 'Position your face in the frame';
  Color _statusColor = Colors.blue;

  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://103.250.132.138:8886/api/v1',
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _streamDetector.close();
    _photoDetector.close();
    _interpreter.close();
    super.dispose();
  }

  // ================= CAMERA =================

  Future<void> _initializeCamera() async {
    _cameras = await availableCameras();
    _cameraController = CameraController(
      _cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      ),
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _cameraController.initialize();

    setState(() => _isInitialized = true);
    _startFaceDetection();
  }

  // ================= MODEL =================

  Future<void> _loadModel() async {
    _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
    _embeddingSize = _interpreter.getOutputTensor(0).shape[1];
    debugPrint('✅ Model loaded. Embedding size: $_embeddingSize');
  }

  // ================= STREAMING FACE CHECK =================

  void _startFaceDetection() {
    if (!_isInitialized) return;

    int frameSkip = 0;

    _cameraController.startImageStream((image) async {
      if (_isProcessing || _attendanceMarked) return;

      frameSkip++;
      if (frameSkip % 10 != 0) return; // Process every 10th frame

      try {
        final inputImage = _inputImageFromCameraImage(image);

        if (_isDetecting) return;
        _isDetecting = true;

        final faces = await _streamDetector.processImage(inputImage);

        _isDetecting = false;

        if (faces.isNotEmpty) {
          _faceDetectionCount++;

          setState(() {
            _faceDetected = true;
            _verificationStatus = 'Hold still... ($_faceDetectionCount/$_requiredStableFrames)';
            _statusColor = Colors.green;
          });

          if (_faceDetectionCount >= _requiredStableFrames) {
            _isProcessing = true;
            await _cameraController.stopImageStream();
            await _verifyFace();
          }
        } else {
          _faceDetectionCount = 0;
          setState(() {
            _faceDetected = false;
            _verificationStatus = 'Position your face';
            _statusColor = Colors.blue;
          });
        }
      } catch (e) {
        _isDetecting = false;
        debugPrint("Face detection Error: $e");
      }
    });
  }

  // ================= VERIFY FACE =================

  Future<void> _verifyFace() async {
    if (_attendanceMarked) return;

    setState(() {
      _verificationStatus = 'Capturing...';
      _statusColor = Colors.yellow;
    });

    try {
      final file = await _cameraController.takePicture();
      final bytes = await File(file.path).readAsBytes();

      setState(() {
        _verificationStatus = 'Extracting face features...';
      });

      final embedding = await _generateFaceEmbedding(bytes);

      // 🔥 DEBUG: Print embedding stats
      debugPrint('📊 Embedding generated: ${embedding.length} dimensions');
      debugPrint('📊 Sample values: ${embedding.take(5).toList()}');
      debugPrint('📊 Min: ${embedding.reduce(math.min)}, Max: ${embedding.reduce(math.max)}');

      setState(() {
        _verificationStatus = 'Verifying identity...';
      });

      await _verifyWithBackend(embedding);
    } catch (e) {
      debugPrint('❌ Verification error: $e');
      _resetAfterError(e.toString());
    }
  }

  // ================= EMBEDDING =================

  Future<List<double>> _generateFaceEmbedding(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes))!;

    // Save temp file for ML Kit
    final temp = File('${Directory.systemTemp.path}/face_${DateTime.now().millisecondsSinceEpoch}.jpg')
      ..writeAsBytesSync(imageBytes);

    final faces = await _photoDetector.processImage(
      InputImage.fromFilePath(temp.path),
    );

    // Clean up temp file
    try {
      await temp.delete();
    } catch (_) {}

    if (faces.isEmpty) {
      throw Exception('No face detected in captured image');
    }

    final face = faces.first;
    debugPrint('✅ Face detected. Confidence: ${face.headEulerAngleY}');

    // Crop face with padding
    final padding = (face.boundingBox.width * 0.25).toInt();
    final x = (face.boundingBox.left - padding).clamp(0, image.width - 1).toInt();
    final y = (face.boundingBox.top - padding).clamp(0, image.height - 1).toInt();
    final w = (face.boundingBox.width + padding * 2)
        .clamp(1, image.width - x)
        .toInt();
    final h = (face.boundingBox.height + padding * 2)
        .clamp(1, image.height - y)
        .toInt();

    final cropped = img.copyCrop(image, x: x, y: y, width: w, height: h);
    final resized = img.copyResizeCropSquare(cropped, size: 112);

    // Convert to model input
    final input = _imageToFloat32(resized);
    final output = List.filled(_embeddingSize, 0.0).reshape([1, _embeddingSize]);

    _interpreter.run(input, output);

    // Extract and normalize embedding
    final rawEmbedding = List<double>.from(output.reshape([_embeddingSize]));

    // 🔥 L2 Normalization (CRITICAL for cosine similarity)
    final normalizedEmbedding = _l2Normalize(rawEmbedding);

    return normalizedEmbedding;
  }

  // 🔥 L2 Normalization - Makes cosine similarity work properly
  List<double> _l2Normalize(List<double> embedding) {
    final norm = math.sqrt(
        embedding.fold(0.0, (sum, val) => sum + val * val)
    );

    if (norm == 0) return embedding; // Avoid division by zero

    return embedding.map((val) => val / norm).toList();
  }

  Uint8List _imageToFloat32(img.Image image) {
    final buffer = Float32List(112 * 112 * 3);
    int i = 0;

    for (int y = 0; y < 112; y++) {
      for (int x = 0; x < 112; x++) {
        final p = image.getPixel(x, y);
        // Normalize to [-1, 1] range
        buffer[i++] = (p.r - 127.5) / 128;
        buffer[i++] = (p.g - 127.5) / 128;
        buffer[i++] = (p.b - 127.5) / 128;
      }
    }

    return buffer.buffer.asUint8List();
  }

  // ================= BACKEND =================

  Future<void> _verifyWithBackend(List<double> embedding) async {
    try {
      debugPrint('📤 Sending embedding to backend...');

      final res = await _dio.post('/verifyUser', data: {
        'faceEmbedding': embedding,
      });

      debugPrint('📥 Backend response: ${res.data}');

      if (res.data['success'] == true) {
        _attendanceMarked = true;
        final userName = res.data['user']['name'] ?? 'User';
        final similarity = res.data['similarity']?.toStringAsFixed(3) ?? 'N/A';
        _showSuccessDialog(userName, similarity);
      } else {
        final similarity = res.data['similarity']?.toStringAsFixed(3) ?? 'N/A';
        _resetAfterError('Face not recognized\n(Similarity: $similarity)');
      }
    } catch (e) {
      debugPrint('❌ Backend error: $e');
      _resetAfterError('Network error: ${e.toString()}');
    }
  }

  void _resetAfterError(String msg) {
    if (_dialogOpen) return;
    _dialogOpen = true;
    _showErrorDialog(msg).then((_) {
      _dialogOpen = false;
      _isProcessing = false;
      _faceDetectionCount = 0;
      if (!_attendanceMarked && mounted) {
        _startFaceDetection();
      }
    });
  }

  Future<void> _showSuccessDialog(String name, String similarity) async {
    if (_dialogOpen) return;
    _dialogOpen = true;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 30),
            SizedBox(width: 10),
            Text('Success'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Welcome, $name!',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Attendance marked successfully'),
            const SizedBox(height: 8),
            Text(
              'Match confidence: $similarity',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    _dialogOpen = false;
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _showErrorDialog(String msg) {
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 30),
            SizedBox(width: 10),
            Text('Verification Failed'),
          ],
        ),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ================= IMAGE CONVERSION =================

  InputImage _inputImageFromCameraImage(CameraImage image) {
    final rotation = InputImageRotationValue.fromRawValue(
      _cameraController.description.sensorOrientation,
    )!;

    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mark Attendance'),
        centerTitle: true,
        backgroundColor: Colors.blueAccent,
      ),
      body: Stack(
        children: [
          // Camera Preview
          if (_isInitialized)
            Positioned.fill(
              child: CameraPreview(_cameraController),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // Overlay for face guide
          Center(
            child: Container(
              width: 250,
              height: 320,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(150),
                border: Border.all(
                  color: _faceDetected
                      ? Colors.green
                      : Colors.white.withOpacity(0.3),
                  width: 3,
                ),
              ),
              child: _faceDetected
                  ? const Center(
                child: Icon(
                  Icons.face,
                  size: 80,
                  color: Colors.green,
                ),
              )
                  : null,
            ),
          ),

          // Status overlay
          Positioned(
            bottom: 100,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isProcessing)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      else
                        Icon(
                          _attendanceMarked
                              ? Icons.check_circle
                              : (_faceDetected ? Icons.verified : Icons.face),
                          color: _statusColor,
                          size: 24,
                        ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _verificationStatus,
                          style: TextStyle(
                            color: _statusColor,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _attendanceMarked
                        ? 'You can go back now'
                        : (_isProcessing
                        ? 'Please wait...'
                        : 'Center your face in the circle'),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}