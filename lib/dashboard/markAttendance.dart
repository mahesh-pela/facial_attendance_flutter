import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;
import 'package:face_attendance/manager/mydio.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:dio/dio.dart';

class MarkAttendance extends StatefulWidget {
  const MarkAttendance({super.key});

  @override
  State<MarkAttendance> createState() => _MarkAttendanceState();
}

class _MarkAttendanceState extends State<MarkAttendance>
    with TickerProviderStateMixin {
  late CameraController _cameraController;
  late List<CameraDescription> _cameras;
  late AnimationController _scanController;
  late AnimationController _successController;
  late FlutterTts flutterTts;

  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _attendanceMarked = false;
  bool _faceDetected = false;
  bool _dialogOpen = false;
  bool _isDetecting = false;

  bool _blinkDetected = false;
  bool _eyesWereOpen = false;
  double? _initialHeadPose;
  bool _headMovementDetected = false;
  bool _livenessPassed = false;

  int _faceDetectionCount = 0;
  int closedFrames = 0;
  static const int _requiredStableFrames = 3;

  final FaceDetector _streamDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
    ),
  );

  final FaceDetector _photoDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
    ),
  );

  late Interpreter _interpreter;
  late int _embeddingSize;

  String _verificationStatus = 'Position your face in the frame';
  Color _statusColor = const Color(0xFF60a5fa);

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'http://103.250.132.138:8886/api/v1',
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  bool _detectBlink(Face face) {
    final left = face.leftEyeOpenProbability;
    final right = face.rightEyeOpenProbability;

    if (left == null || right == null) return false;

    // SIMPLE DETECTION: Check if both eyes are closed
    bool eyesClosed =
        left < 0.4 && right < 0.4; // More strict threshold (0.4 instead of 0.5)

    if (eyesClosed && !_blinkDetected) {
      // Quick validation: check if eyes were open in recent frames
      if (_eyesWereOpen) {
        _blinkDetected = true;
        _eyesWereOpen = false;
        return true;
      }
    } else if (left > 0.7 && right > 0.7) {
      // Track when eyes are clearly open
      _eyesWereOpen = true;
    }

    return false;
  }

  bool _detectHeadMovement(Face face) {
    final pose = face.headEulerAngleY ?? 0;

    _initialHeadPose ??= pose;

    if ((pose - _initialHeadPose!).abs() > 12) {
      _headMovementDetected = true;
    }

    return _headMovementDetected;
  }

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
    _determinePosition();

    flutterTts = FlutterTts();
    _initializeTTS();

    _scanController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();

    _successController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
  }

  Future<void> _initializeTTS() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    // await flutterTts.setVoice({
    //   // "name": "female",
    //   "locale": "ne-NP",
    // });

    await flutterTts.setVolume(1);
    await flutterTts.setPitch(1.1);
  }

  Future<void> _playSound(String userName) async {
    try {
      final message =
          "Dear $userName Your attendance has been done";

      await flutterTts.speak(message);
    } catch (e) {
      debugPrint("TTS Error: $e");
    }
  }

  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }
    return await Geolocator.getCurrentPosition();
  }

  Future<void> _verifyWithBackend(List<double> embedding) async {
    try {
      Position position = await _determinePosition();
      final res = await(await MyDio().getDio()).post(
        '/users/face-attendance',
        data: {
          'faceEmbedding': embedding,
          'location': {
            'latitude': position.latitude,
            'longitude': position.longitude,
          }
        },
      );

      if (res.data['success'] == true) {
        _attendanceMarked = true;
        await _successController.forward();
        final userName = res.data['user']['name'] ?? 'User';
        final similarity = res.data['similarity']?.toStringAsFixed(3) ?? 'N/A';

        await _playSound(userName);
        _showSuccessDialog(userName, similarity);
      } else {
        final similarity = res.data['similarity']?.toStringAsFixed(3) ?? 'N/A';
        _resetAfterError('Face not recognized\n(Match: $similarity)');
      }
    } catch (e) {
      _resetAfterError('Network error. Please try again.');
    }
  }

  @override
  void dispose() {
    flutterTts.stop();
    _cameraController.dispose();
    _streamDetector.close();
    _photoDetector.close();
    _interpreter.close();
    _scanController.dispose();
    _successController.dispose();
    super.dispose();
  }

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

  Future<void> _loadModel() async {
    _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
    _embeddingSize = _interpreter.getOutputTensor(0).shape[1];
  }

  void _startFaceDetection() {
    if (!_isInitialized) return;

    int frameSkip = 0;
    _cameraController.startImageStream((image) async {
      if (_isProcessing || _attendanceMarked || _isDetecting) return;

      frameSkip++;
      if (frameSkip % 1 != 0) return;

      try {
        _isDetecting = true;
        final inputImage = _inputImageFromCameraImage(image);
        final faces = await _streamDetector.processImage(inputImage);

        if (faces.isNotEmpty) {
          final face = faces.first;

          // STEP 1: Blink Detection
          if (!_blinkDetected) {
            if (_detectBlink(face)) {
              setState(() {
                _verificationStatus = 'Blink detected ✓ Now turn head slightly';
                _statusColor = const Color(0xFF10b981);
              });
            } else {
              setState(() {
                _verificationStatus = 'Please blink once';
                _statusColor = const Color(0xFFf59e0b);
              });
              return;
            }
          }

          // STEP 2: Head Movement Detection
          if (!_headMovementDetected) {
            if (_detectHeadMovement(face)) {
              _livenessPassed = true;
              setState(() {
                _verificationStatus = 'Liveness confirmed ✓ Hold still';
              });
            } else {
              setState(() {
                _verificationStatus = 'Slowly turn your head left or right';
              });
              return;
            }
          }

          // STEP 3: Proceed normally
          if (_livenessPassed) {
            _faceDetectionCount++;

            setState(() {
              _faceDetected = true;
              _verificationStatus =
                  'Hold still... ($_faceDetectionCount/$_requiredStableFrames)';
              _statusColor = const Color(0xFF10b981);
            });

            if (_faceDetectionCount >= _requiredStableFrames) {
              _isProcessing = true;
              await _cameraController.stopImageStream();
              await _verifyFace();
            }
          }
        } else {
          _faceDetectionCount = 0;
          setState(() {
            _faceDetected = false;
            _verificationStatus = 'Position your face';
            _statusColor = const Color(0xFF60a5fa);
          });
        }
      } catch (e) {
        debugPrint("Face detection Error: $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  Future<void> _verifyFace() async {
    if (_attendanceMarked) return;

    setState(() {
      _verificationStatus = 'Capturing...';
      _statusColor = const Color(0xFFf59e0b);
    });

    try {
      final file = await _cameraController.takePicture();
      final bytes = await File(file.path).readAsBytes();

      setState(() {
        _verificationStatus = 'Extracting features...';
      });

      final embedding = await _generateFaceEmbedding(bytes);

      setState(() {
        _verificationStatus = 'Verifying identity...';
      });

      await _verifyWithBackend(embedding);
    } catch (e) {
      debugPrint('❌ Verification error: $e');
      _resetAfterError(e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<List<double>> _generateFaceEmbedding(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes))!;
    final temp = File(
      '${Directory.systemTemp.path}/face_${DateTime.now().millisecondsSinceEpoch}.jpg',
    )..writeAsBytesSync(imageBytes);

    final faces = await _photoDetector.processImage(
      InputImage.fromFilePath(temp.path),
    );

    try {
      await temp.delete();
    } catch (_) {}

    if (faces.isEmpty) {
      throw Exception('No face detected in captured image');
    }

    final face = faces.first;
    final padding = (face.boundingBox.width * 0.25).toInt();
    final x = (face.boundingBox.left - padding)
        .clamp(0, image.width - 1)
        .toInt();
    final y = (face.boundingBox.top - padding)
        .clamp(0, image.height - 1)
        .toInt();
    final w = (face.boundingBox.width + padding * 2)
        .clamp(1, image.width - x)
        .toInt();
    final h = (face.boundingBox.height + padding * 2)
        .clamp(1, image.height - y)
        .toInt();

    final cropped = img.copyCrop(image, x: x, y: y, width: w, height: h);
    final resized = img.copyResizeCropSquare(cropped, size: 112);

    final input = _imageToFloat32(resized);
    final output = List.filled(
      _embeddingSize,
      0.0,
    ).reshape([1, _embeddingSize]);
    _interpreter.run(input, output);

    final rawEmbedding = List<double>.from(output.reshape([_embeddingSize]));
    return _l2Normalize(rawEmbedding);
  }

  List<double> _l2Normalize(List<double> embedding) {
    final norm = math.sqrt(embedding.fold(0.0, (sum, val) => sum + val * val));
    if (norm == 0) return embedding;
    return embedding.map((val) => val / norm).toList();
  }

  Uint8List _imageToFloat32(img.Image image) {
    final buffer = Float32List(112 * 112 * 3);
    int i = 0;
    for (int y = 0; y < 112; y++) {
      for (int x = 0; x < 112; x++) {
        final p = image.getPixel(x, y);
        buffer[i++] = (p.r - 127.5) / 128;
        buffer[i++] = (p.g - 127.5) / 128;
        buffer[i++] = (p.b - 127.5) / 128;
      }
    }
    return buffer.buffer.asUint8List();
  }

  void _resetAfterError(String msg) {
    _faceDetectionCount = 0;
    _blinkDetected = false;
    _eyesWereOpen = false;
    _initialHeadPose = null;
    _headMovementDetected = false;
    _livenessPassed = false;

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
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF10b981), Color(0xFF059669)],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const Text(
                'Attendance Marked',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Welcome, $name!',
                style: const TextStyle(fontSize: 18, color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Match confidence: $similarity',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF10b981),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: const Text(
                  'Done',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    _dialogOpen = false;
  }

  Future<void> _showErrorDialog(String msg) {
    return showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFef4444).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Color(0xFFef4444),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Verification Failed',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                msg,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFef4444),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
      backgroundColor: const Color(0xFF0f172a),
      body: _isInitialized
          ? Stack(
              children: [
                // Full-screen camera preview with proper aspect ratio
                Positioned.fill(
                  child: ClipRRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _cameraController.value.previewSize?.height ?? 1,
                        height: _cameraController.value.previewSize?.width ?? 1,
                        child: CameraPreview(_cameraController),
                      ),
                    ),
                  ),
                ),

                // Gradient overlays
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.7),
                          Colors.transparent,
                          Colors.black.withOpacity(0.8),
                        ],
                        stops: const [0.0, 0.4, 1.0],
                      ),
                    ),
                  ),
                ),

                // Top bar
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(
                            Icons.arrow_back_ios,
                            color: Colors.white,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.15),
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.security,
                                color: Colors.white,
                                size: 16,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Secure',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Main content
                Column(
                  children: [
                    const Spacer(),

                    // Title
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Mark Attendance',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                    const SizedBox(height: 60),

                    // Face scanning area
                    Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Scanning animation
                          if (!_attendanceMarked)
                            AnimatedBuilder(
                              animation: _scanController,
                              builder: (context, child) {
                                return Container(
                                  width: 280,
                                  height: 350,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withOpacity(
                                        0.3 * (1 - _scanController.value),
                                      ),
                                      width: 2,
                                    ),
                                  ),
                                );
                              },
                            ),

                          // Face guide
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: 260,
                            height: 330,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _attendanceMarked
                                    ? const Color(0xFF10b981)
                                    : (_faceDetected
                                          ? const Color(0xFF10b981)
                                          : Colors.white),
                                width: 3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      (_attendanceMarked || _faceDetected
                                              ? const Color(0xFF10b981)
                                              : Colors.white)
                                          .withOpacity(0.5),
                                  blurRadius: 30,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                            child: _attendanceMarked
                                ? const Icon(
                                    Icons.check_circle,
                                    size: 100,
                                    color: Color(0xFF10b981),
                                  )
                                : (_faceDetected
                                      ? const Icon(
                                          Icons.face,
                                          size: 80,
                                          color: Color(0xFF10b981),
                                        )
                                      : null),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),
                    Container(
                      width: double.infinity,
                      child: Row(
                        children: [
                          ElevatedButton(onPressed: (){}, child: Text("Check in")),
                          ElevatedButton(onPressed: (){}, child: Text("Check Out")),
                        ],
                      ),
                    ),

                    // Status card
                    Container(
                      margin: const EdgeInsets.all(24),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_isProcessing)
                                Container(
                                  width: 24,
                                  height: 24,
                                  margin: const EdgeInsets.only(right: 12),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      _statusColor,
                                    ),
                                  ),
                                )
                              else
                                Icon(
                                  _attendanceMarked
                                      ? Icons.check_circle
                                      : (_faceDetected
                                            ? Icons.verified_user
                                            : Icons.face_outlined),
                                  color: _statusColor,
                                  size: 28,
                                ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _verificationStatus,
                                  style: TextStyle(
                                    color: _statusColor,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _attendanceMarked
                                ? 'You can go back now'
                                : (_isProcessing
                                      ? 'Please wait...'
                                      : 'Center your face in the circle'),
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),
                  ],
                ),
              ],
            )
          : Container(
              color: const Color(0xFF0f172a),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 24),
                    Text(
                      'Initializing camera...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
