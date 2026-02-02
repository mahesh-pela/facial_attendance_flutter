import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:dio/dio.dart';

class RegisterUser extends StatefulWidget {
  const RegisterUser({super.key});

  @override
  State<RegisterUser> createState() => _RegisterUserState();
}

class _RegisterUserState extends State<RegisterUser> with TickerProviderStateMixin {
  late CameraController _cameraController;
  late List<CameraDescription> _cameras;
  late AnimationController _pulseController;
  late AnimationController _captureController;
  Timer? _faceDetectionTimer;
  bool _faceDetectedInPosition = false;
  bool _isDetectionInProgress = false;

  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isCapturing = false;
  bool _showForm = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  final FaceDetector _photoDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
    ),
  );

  late Interpreter _interpreter;
  late int _embeddingSize;

  List<List<double>> _capturedEmbeddings = [];
  static const int _requiredEmbeddings = 3;

  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://103.250.132.138:8886/api/v1',
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  // Auto-capture variables
  int _currentCaptureIndex = 0;
  final List<String> _captureInstructions = [
    'Look straight at the camera',
    'Turn your face slightly RIGHT',
    'Turn your face slightly LEFT',
  ];
  bool _isAutoCaptureActive = false;
  int _instructionViolationCount = 0;
  static const int _maxViolations = 5;

  // Circle boundaries for landmark validation (in percentage of screen)
  static const double _circleCenterX = 0.5;
  static const double _circleCenterY = 0.4;
  static const double _circleRadiusPercent = 0.35; // 35% of width

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();

    // Animation for pulsing ring
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);

    // Animation for capture feedback
    _captureController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _faceDetectionTimer?.cancel();
    _cameraController.dispose();
    _photoDetector.close();
    _interpreter.close();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _pulseController.dispose();
    _captureController.dispose();
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

    // Start auto-capture sequence
    _startAutoCaptureSequence();
  }

  Future<void> _loadModel() async {
    _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
    _embeddingSize = _interpreter.getOutputTensor(0).shape[1];
  }

  void _startAutoCaptureSequence() {
    setState(() {
      _isAutoCaptureActive = true;
      _currentCaptureIndex = 0;
      _instructionViolationCount = 0;
      _faceDetectedInPosition = false;
    });

    // start continuous face detection
    _startContinuousFaceDetection();
  }

  void _startContinuousFaceDetection() {
    _faceDetectionTimer?.cancel();

    _faceDetectionTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) async {
      if (!_isAutoCaptureActive || _isCapturing || _currentCaptureIndex >= _requiredEmbeddings) {
        timer.cancel();
        return;
      }

      // Skip if previous detection is still in progress
      if (_isDetectionInProgress) {
        return;
      }

      // Quick face check without taking picture
      try {
        _isDetectionInProgress = true;

        final image = await _cameraController.takePicture();
        final bytes = await File(image.path).readAsBytes();
        final result = await _quickFaceValidation(bytes);

        if (result) {
          // Face detected in correct position - attempt capture
          timer.cancel();
          _isDetectionInProgress = false;
          await _attemptAutoCapture();

          // Restart detection after capture attempt
          if (_isAutoCaptureActive && _currentCaptureIndex < _requiredEmbeddings) {
            Future.delayed(const Duration(milliseconds: 700), () {
              _startContinuousFaceDetection();
            });
          }
        }
        else{
          _isDetectionInProgress = false;
        }
      } catch (e) {
        // Continue checking
        _isDetectionInProgress = false;
      }
    });
  }

  Future<bool> _quickFaceValidation(List<int> imageBytes) async {
    try {
      final image = img.decodeImage(Uint8List.fromList(imageBytes))!;
      final temp = File('${Directory.systemTemp.path}/face_check_${DateTime.now().millisecondsSinceEpoch}.jpg')
        ..writeAsBytesSync(imageBytes);

      final faces = await _photoDetector.processImage(
        InputImage.fromFilePath(temp.path),
      );

      try {
        await temp.delete();
      } catch (_) {}

      if (faces.isEmpty) return false;

      final face = faces.first;

      // Quick validation - check if face is in position
      final inCircle = _areLandmarksInCircle(face, image.width.toDouble(), image.height.toDouble());
      final correctPose = _isCorrectHeadPose(face);

      return inCircle && correctPose;
    } catch (e) {
      return false;
    }
  }

  Future<void> _attemptAutoCapture() async {
    if (!_isAutoCaptureActive || _currentCaptureIndex >= _requiredEmbeddings) {
      return;
    }

    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      final file = await _cameraController.takePicture();
      final bytes = await File(file.path).readAsBytes();

      // Validate and generate embedding
      final result = await _validateAndGenerateEmbedding(bytes);

      if (result['success'] == true) {
        // Success - capture animation
        await _captureController.forward();

        setState(() {
          _capturedEmbeddings.add(result['embedding']);
          _currentCaptureIndex++;
          _instructionViolationCount = 0;
        });

        await _captureController.reverse();

        if (_capturedEmbeddings.length >= _requiredEmbeddings) {
          setState(() => _isAutoCaptureActive = false);
          _faceDetectionTimer?.cancel();
          await Future.delayed(const Duration(milliseconds: 500));
          setState(() => _showForm = true);
        }
      } else {
        // Validation failed
        _instructionViolationCount++;

        if (_instructionViolationCount >= _maxViolations) {
          _faceDetectionTimer?.cancel();
          _handleMaxViolations();
        } else {
          _showError(result['message'] ?? 'Please follow the instruction');
        }
      }
    } catch (e) {
      _instructionViolationCount++;

      if (_instructionViolationCount >= _maxViolations) {
        _faceDetectionTimer?.cancel();
        _handleMaxViolations();
      } else {
        _showError(e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      setState(() => _isCapturing = false);
    }
  }
  void _handleMaxViolations() {
    setState(() => _isAutoCaptureActive = false);
    _showError('Please follow the instructions carefully');

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pop(context);
      }
    });
  }

  Future<Map<String, dynamic>> _validateAndGenerateEmbedding(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes))!;
    final temp = File('${Directory.systemTemp.path}/face_${DateTime.now().millisecondsSinceEpoch}.jpg')
      ..writeAsBytesSync(imageBytes);

    final faces = await _photoDetector.processImage(
      InputImage.fromFilePath(temp.path),
    );

    try {
      await temp.delete();
    } catch (_) {}

    if (faces.isEmpty) {
      return {
        'success': false,
        'message': 'No face detected. Please position your face in the circle.',
      };
    }

    final face = faces.first;

    // // Validate if face landmarks are within the circle boundary
    if (!_areLandmarksInCircle(face, image.width.toDouble(), image.height.toDouble())) {
      return {
        'success': false,
        'message': 'Face is outside the circle. Please position yourself correctly.',
      };
    }

    //vlidating head pose
    if (!_isCorrectHeadPose(face)) {
      String instruction = _captureInstructions[_currentCaptureIndex];
      return {
        'success': false,
        'message': 'Please follow the instruction: $instruction',
      };
    }

    // Generate embedding
    final padding = (face.boundingBox.width * 0.25).toInt();
    final x = (face.boundingBox.left - padding).clamp(0, image.width - 1).toInt();
    final y = (face.boundingBox.top - padding).clamp(0, image.height - 1).toInt();
    final w = (face.boundingBox.width + padding * 2).clamp(1, image.width - x).toInt();
    final h = (face.boundingBox.height + padding * 2).clamp(1, image.height - y).toInt();

    final cropped = img.copyCrop(image, x: x, y: y, width: w, height: h);
    final resized = img.copyResizeCropSquare(cropped, size: 112);

    final input = _imageToFloat32(resized);
    final output = List.filled(_embeddingSize, 0.0).reshape([1, _embeddingSize]);
    _interpreter.run(input, output);

    final rawEmbedding = List<double>.from(output.reshape([_embeddingSize]));
    final normalizedEmbedding = _l2Normalize(rawEmbedding);

    return {
      'success': true,
      'embedding': normalizedEmbedding,
    };
  }

  bool _areLandmarksInCircle(Face face, double imageWidth, double imageHeight) {
    // Calculate circle center and radius in pixel coordinates
    final circleCenterX = imageWidth * _circleCenterX;
    final circleCenterY = imageHeight * _circleCenterY;
    final circleRadius = imageWidth * _circleRadiusPercent;

    // Check if face bounding box center is within circle
    final faceCenterX = face.boundingBox.left + face.boundingBox.width / 2;
    final faceCenterY = face.boundingBox.top + face.boundingBox.height / 2;

    final distance = math.sqrt(
        math.pow(faceCenterX - circleCenterX, 2) +
            math.pow(faceCenterY - circleCenterY, 2)
    );

    // For center pose (first capture), be more strict
    if (_currentCaptureIndex == 0) {
      // Check if face center is within circle with moderate tolerance
      if (distance > circleRadius * 1.1) {
        return false;
      }

      // For center pose, verify key landmarks are also within circle
      final landmarks = face.landmarks;
      if (landmarks.isNotEmpty) {
        final List<FaceLandmark?> criticalLandmarks = [
          landmarks[FaceLandmarkType.leftEye],
          landmarks[FaceLandmarkType.rightEye],
          landmarks[FaceLandmarkType.noseBase],
        ];

        int landmarksInCircle = 0;
        for (var landmark in criticalLandmarks) {
          if (landmark != null) {
            final landmarkDist = math.sqrt(
                math.pow(landmark.position.x - circleCenterX, 2) +
                    math.pow(landmark.position.y - circleCenterY, 2)
            );

            if (landmarkDist <= circleRadius) {
              landmarksInCircle++;
            }
          }
        }

        // At least 2 out of 3 landmarks should be in circle for center pose
        if (landmarksInCircle < 2) {
          return false;
        }
      }
    } else {
      // For angled poses (left/right), be more lenient
      // Only check that majority of face bounding box is within circle
      // This allows some landmarks to go outside when face is turned
      if (distance > circleRadius * 1.8) {
        return false;
      }

      // Check that at least the nose base (center of face) is in circle
      final landmarks = face.landmarks;
      if (landmarks.isNotEmpty) {
        final noseBase = landmarks[FaceLandmarkType.noseBase];
        if (noseBase != null) {
          final noseDist = math.sqrt(
              math.pow(noseBase.position.x - circleCenterX, 2) +
                  math.pow(noseBase.position.y - circleCenterY, 2)
          );

          // Nose should be within circle (with good tolerance for angled poses)
          if (noseDist > circleRadius * 1.2) {
            return false;
          }
        }
      }
    }

    return true;
  }

  bool _isCorrectHeadPose(Face face) {
    // Get head rotation angles
    final headEulerAngleY = face.headEulerAngleY ?? 0;  // Left/Right rotation

    if (_currentCaptureIndex == 0) {
      // Center pose: face should be looking straight (±20 degrees - more lenient)
      return headEulerAngleY.abs() < 20;
    } else if (_currentCaptureIndex == 1) {
      // Left pose: face should be turned left (negative angle, -5 to -40 degrees - more lenient)
      return headEulerAngleY < -5 && headEulerAngleY > -40;
    } else {
      // Right pose: face should be turned right (positive angle, 5 to 40 degrees - more lenient)
      return headEulerAngleY > 5 && headEulerAngleY < 40;
    }
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

  Future<void> _registerUser() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Please enter your name');
      return;
    }


    setState(() => _isProcessing = true);

    try {
      final response = await _dio.post('/addUser', data: {
        'name': _nameController.text.trim(),
        'email': "ds@gmail.com",
        'phone': "5797532255",
        'faceEmbedding': _capturedEmbeddings,
      });

      if (response.data['success'] == true) {
        if (mounted) {
          _showSuccessDialog();
        }
      } else {
        _showError(response.data['message'] ?? 'Registration failed');
      }
    }on DioException catch (e) {
      _showError('Error: ${e.response?.data["message"]}');
      debugPrint("error registering user ${e.response?.data}");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF667eea), Color(0xFF764ba2)],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Registration Successful!',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Welcome, ${_nameController.text}',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white.withOpacity(0.9),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF667eea),
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: const Text(
                  'Continue',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: const Color(0xFFef4444),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _resetCapture() {
    setState(() {
      _capturedEmbeddings.clear();
      _showForm = false;
      _currentCaptureIndex = 0;
      _instructionViolationCount = 0;
    });
    _startAutoCaptureSequence();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0f172a),
      body: _isInitialized
          ? Stack(
        children: [
          // Full-screen camera preview
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

          // Gradient overlay for better readability
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.6),
                    Colors.transparent,
                    Colors.black.withOpacity(0.8),
                  ],
                  stops: const [0.0, 0.3, 1.0],
                ),
              ),
            ),
          ),

          // Top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.2),
                    ),
                  ),
                  const Spacer(),
                  // if (_capturedEmbeddings.isNotEmpty && !_isAutoCaptureActive)
                  //   IconButton(
                  //     onPressed: _resetCapture,
                  //     icon: const Icon(Icons.refresh, color: Colors.white),
                  //     style: IconButton.styleFrom(
                  //       backgroundColor: Colors.white.withOpacity(0.2),
                  //     ),
                  //   ),
                ],
              ),
            ),
          ),

          // Content
          if (!_showForm) _buildCameraUI() else _buildFormUI(),
        ],
      )
          : const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildCameraUI() {
    return Column(
      children: [
        const Spacer(),

        // Face capture area
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated face guide
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer pulsing ring
                      Container(
                        width: 280 + (_pulseController.value * 20),
                        height: 350 + (_pulseController.value * 20),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.3 - (_pulseController.value * 0.2)),
                            width: 2,
                          ),
                        ),
                      ),
                      // Inner guide
                      AnimatedBuilder(
                        animation: _captureController,
                        builder: (context, child) {
                          return Container(
                            width: 260,
                            height: 330,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _capturedEmbeddings.isEmpty
                                    ? Colors.white
                                    : const Color(0xFF10b981),
                                width: 3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (_capturedEmbeddings.isEmpty
                                      ? Colors.white
                                      : const Color(0xFF10b981))
                                      .withOpacity(0.5),
                                  blurRadius: 20 + (_captureController.value * 20),
                                  spreadRadius: 5 + (_captureController.value * 10),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 40),

              // Progress indicators
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _requiredEmbeddings,
                      (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: index < _capturedEmbeddings.length ? 40 : 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: index < _capturedEmbeddings.length
                          ? const Color(0xFF10b981)
                          : Colors.white.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const Spacer(),

        // Bottom section with auto-capture instructions
        Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // Current instruction
              if (_isAutoCaptureActive && _currentCaptureIndex < _requiredEmbeddings)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10b981).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF10b981),
                      width: 2,
                    ),
                  ),
                  child: Text(
                    _captureInstructions[_currentCaptureIndex],
                    style: const TextStyle(
                      color: Color(0xFF10b981),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

              const SizedBox(height: 16),

              Text(
                _isCapturing
                    ? 'Capturing...'
                    : 'Position your face inside the circle',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Auto-capture in progress',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),

              // Auto-capture indicator
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isCapturing
                      ? const Color(0xFF10b981).withOpacity(0.3)
                      : Colors.white.withOpacity(0.3),
                  border: Border.all(
                    color: Colors.white,
                    width: 3,
                  ),
                ),
                child: Center(
                  child: _isCapturing
                      ? const CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  )
                      : Icon(
                    Icons.camera_alt,
                    size: 36,
                    color: Colors.white.withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFormUI() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.8),
            const Color(0xFF0f172a),
          ],
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

              // Success indicator
              Center(
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10b981).withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_circle,
                        size: 48,
                        color: Color(0xFF10b981),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Face Captured',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Complete your registration',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 25),

              // Form fields
              _buildTextField(
                controller: _nameController,
                label: 'Full Name',
                icon: Icons.person_outline,
              ),

              const SizedBox(height: 20),

              // Submit button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: !_isProcessing ? _registerUser : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    disabledBackgroundColor: Colors.blue.withOpacity(0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _isProcessing
                      ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                      : const Text(
                    'Complete Registration',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            fontSize: 14,
            color: Colors.white.withOpacity(0.6),
          ),
          prefixIcon: Icon(
            icon,
            color: Colors.white.withOpacity(0.6),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(8),
        ),
      ),
    );
  }
}