import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;
import 'package:face_attendance/manager/mydio.dart';
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

class _RegisterUserState extends State<RegisterUser>
    with TickerProviderStateMixin {
  late CameraController _cameraController;
  late List<CameraDescription> _cameras;
  late AnimationController _pulseController;
  late AnimationController _captureController;
  late AnimationController _arrowAnimationController; // NEW: For arrow movement
  Timer? _faceDetectionTimer;
  bool _faceDetectedInPosition = false;
  bool _isDetectionInProgress = false;

  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isCapturing = false;
  bool _showForm = false;

  bool _showLeftArrow = false;
  bool _showRightArrow = false;
  bool _showUpArrow = false;
  bool _showDownArrow = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  final FaceDetector _photoDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
    ),
  );

  late Interpreter _interpreter;
  late int _embeddingSize;
  bool isFetchingUsersData = false;

  List<List<double>> _capturedEmbeddings = [];
  static const int _requiredEmbeddings = 3;

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'http://103.250.132.138:8886/api/v1',
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

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
  static const double _circleRadiusPercent = 0.35;

  // Frame processing optimization
  int _frameCounter = 0;
  static const int _processEveryNthFrame = 2;

  // Quality thresholds
  static const double _minFaceSize = 0.15;
  static const double _maxFaceSize = 0.6;
  static const double _minFaceHeightRatio = 0.2;
  static const double _minEyeOpenProbability = 0.5;

  // Real-time feedback
  String _feedbackMessage = '';
  Color _feedbackColor = Colors.white;
  bool _showFeedback = false;
  List<dynamic> usersList = [];
  String? selectedUser;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
    getUsers();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);

    _captureController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // NEW: Arrow animation controller
    _arrowAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
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
    _arrowAnimationController.dispose(); // NEW
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
      _frameCounter = 0;
      _showLeftArrow = false;
      _showRightArrow = false;
      _showUpArrow = false;
      _showDownArrow = false;
    });

    _startContinuousFaceDetection();
  }

  //method for arrow indicators
  void _updateArrowIndicators(
    Face face,
    double imageWidth,
    double imageHeight,
  ) {
    final circleCenterX = imageWidth * _circleCenterX;
    final circleCenterY = imageHeight * _circleCenterY;
    final circleRadius = imageWidth * _circleRadiusPercent;

    final faceRect = face.boundingBox;
    final faceCenterX = faceRect.left + faceRect.width / 2;
    final faceCenterY = faceRect.top + faceRect.height / 2;

    if (!mounted) return;

    setState(() {
      // For center pose (index 0), show arrows to center the face
      if (_currentCaptureIndex == 0) {
        // Horizontal positioning
        if (faceCenterX < circleCenterX - circleRadius * 0.1) {
          _showRightArrow = true;
          _showLeftArrow = false;
        } else if (faceCenterX > circleCenterX + circleRadius * 0.1) {
          _showRightArrow = false;
          _showLeftArrow = true;
        } else {
          _showRightArrow = false;
          _showLeftArrow = false;
        }

        // Vertical positioning
        if (faceCenterY < circleCenterY - circleRadius * 0.1) {
          _showDownArrow = true;
          _showUpArrow = false;
        } else if (faceCenterY > circleCenterY + circleRadius * 0.1) {
          _showDownArrow = false;
          _showUpArrow = true;
        } else {
          _showDownArrow = false;
          _showUpArrow = false;
        }
      }
      // For right turn (index 1), show left arrow to guide turn
      else if (_currentCaptureIndex == 1) {
        _showLeftArrow = true;
        _showRightArrow = false;
        _showUpArrow = false;
        _showDownArrow = false;
      }
      // For left turn (index 2), show right arrow to guide turn
      else if (_currentCaptureIndex == 2) {
        _showRightArrow = true;
        _showLeftArrow = false;
        _showUpArrow = false;
        _showDownArrow = false;
      }
    });
  }

  void _startContinuousFaceDetection() {
    _faceDetectionTimer?.cancel();

    _faceDetectionTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (!_isAutoCaptureActive ||
          _isCapturing ||
          _currentCaptureIndex >= _requiredEmbeddings) {
        timer.cancel();
        return;
      }

      if (_isDetectionInProgress) {
        return;
      }

      // Frame skipping for performance
      _frameCounter++;
      if (_frameCounter % _processEveryNthFrame != 0) {
        return;
      }

      try {
        _isDetectionInProgress = true;

        final image = await _cameraController.takePicture();
        final bytes = await File(image.path).readAsBytes();
        final result = await _quickFaceValidation(bytes);

        if (result['isValid'] == true) {
          timer.cancel();
          _isDetectionInProgress = false;
          await _attemptAutoCapture();

          if (_isAutoCaptureActive &&
              _currentCaptureIndex < _requiredEmbeddings) {
            Future.delayed(const Duration(milliseconds: 500), () {
              _startContinuousFaceDetection();
            });
          }
        } else {
          // Update real-time feedback
          _updateFeedback(
            result['message'] ?? '',
            result['isWarning'] ?? false,
          );
          _isDetectionInProgress = false;
        }
      } catch (e) {
        _isDetectionInProgress = false;
      }
    });
  }

  void _updateFeedback(String message, bool isWarning) {
    if (mounted) {
      setState(() {
        _feedbackMessage = message;
        _feedbackColor = isWarning ? Colors.orange : Colors.red;
        _showFeedback = message.isNotEmpty;
      });
    }
  }

  Future<Map<String, dynamic>> _quickFaceValidation(
    List<int> imageBytes,
  ) async {
    try {
      final image = img.decodeImage(Uint8List.fromList(imageBytes))!;
      final temp = File(
        '${Directory.systemTemp.path}/face_check_${DateTime.now().millisecondsSinceEpoch}.jpg',
      )..writeAsBytesSync(imageBytes);

      final faces = await _photoDetector.processImage(
        InputImage.fromFilePath(temp.path),
      );

      try {
        await temp.delete();
      } catch (_) {}

      if (faces.isEmpty) {
        // Hide arrows when no face detected
        if (mounted) {
          setState(() {
            _showLeftArrow = false;
            _showRightArrow = false;
            _showUpArrow = false;
            _showDownArrow = false;
          });
        }
        return {
          'isValid': false,
          'message': 'No face detected',
          'isWarning': false,
        };
      }

      final face = faces.first;
      _updateArrowIndicators(
        face,
        image.width.toDouble(),
        image.height.toDouble(),
      );

      // FACE SIZE CHECK
      final faceWidthRatio = face.boundingBox.width / image.width;
      final faceHeightRatio = face.boundingBox.height / image.height;
      if (faceWidthRatio < _minFaceSize || faceWidthRatio > _maxFaceSize) {
        return {
          'isValid': false,
          'message': 'Adjust distance from camera',
          'isWarning': true,
        };
      }
      if (faceHeightRatio < _minFaceHeightRatio) {
        return {
          'isValid': false,
          'message': 'Move closer - show your full face',
          'isWarning': true,
        };
      }

      // LANDMARK CHECK (Center Pose)
      if (_currentCaptureIndex == 0) {
        final requiredLandmarks = [
          FaceLandmarkType.leftEye,
          FaceLandmarkType.rightEye,
          FaceLandmarkType.noseBase,
          FaceLandmarkType.leftMouth,
          FaceLandmarkType.rightMouth,
          FaceLandmarkType.bottomMouth,
          FaceLandmarkType.leftCheek,
          FaceLandmarkType.rightCheek,
        ];

        final landmarks = face.landmarks;
        if (requiredLandmarks.any((lm) => landmarks[lm] == null)) {
          return {
            'isValid': false,
            'message': 'Show full face - eyes, nose, mouth',
            'isWarning': true,
          };
        }

        // Ensure all critical landmarks are inside the circle
        final circleCenterX = image.width * _circleCenterX;
        final circleCenterY = image.height * _circleCenterY;
        final circleRadius = image.width * _circleRadiusPercent;

        for (var lm in requiredLandmarks) {
          final l = landmarks[lm]!;
          final dx = l.position.x - circleCenterX;
          final dy = l.position.y - circleCenterY;
          final distance = math.sqrt(dx * dx + dy * dy);
          if (distance > circleRadius * 0.8) {
            return {
              'isValid': false,
              'message': 'Position face fully inside the circle',
              'isWarning': true,
            };
          }
        }
      }

      // NEW: Check if entire face bounding box is within circle
      if (!_isFullFaceInsideCircle(
        face,
        image.width.toDouble(),
        image.height.toDouble(),
      )) {
        return {
          'isValid': false,
          'message': 'Center your face better in the circle',
          'isWarning': true,
        };
      }

      // NEW: Verify face proportions are correct (not stretched/cropped)
      final faceAspectRatio = face.boundingBox.width / face.boundingBox.height;
      if (faceAspectRatio < 0.7 || faceAspectRatio > 1.3) {
        return {
          'isValid': false,
          'message': 'Face appears distorted. Look straight',
          'isWarning': true,
        };
      }

      // HEAD POSE
      if (!_isCorrectHeadPose(face)) {
        return {
          'isValid': false,
          'message': _captureInstructions[_currentCaptureIndex],
          'isWarning': true,
        };
      }

      // EYES OPEN
      if ((face.leftEyeOpenProbability ?? 1.0) < _minEyeOpenProbability ||
          (face.rightEyeOpenProbability ?? 1.0) < _minEyeOpenProbability) {
        return {
          'isValid': false,
          'message': 'Keep your eyes open',
          'isWarning': true,
        };
      }

      // IMAGE SHARPNESS
      final isSharp = await _checkImageSharpness(image);
      if (!isSharp)
        return {
          'isValid': false,
          'message': 'Hold steady - image too blurry',
          'isWarning': true,
        };

      return {'isValid': true, 'message': 'Good position!', 'isWarning': false};
    } catch (e) {
      return {
        'isValid': false,
        'message': 'Error validating face',
        'isWarning': false,
      };
    }
  }

  Future<bool> _checkImageSharpness(img.Image image) async {
    try {
      final centerX = image.width ~/ 2;
      final centerY = image.height ~/ 2;
      final sampleSize = 100;

      List<int> grayValues = [];
      for (
        int y = centerY - sampleSize;
        y < centerY + sampleSize && y < image.height;
        y++
      ) {
        for (
          int x = centerX - sampleSize;
          x < centerX + sampleSize && x < image.width;
          x++
        ) {
          if (y >= 0 && x >= 0) {
            final pixel = image.getPixel(x, y);
            final gray = (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b)
                .toInt();
            grayValues.add(gray);
          }
        }
      }

      if (grayValues.isEmpty) return true;

      final mean = grayValues.reduce((a, b) => a + b) / grayValues.length;
      final variance =
          grayValues.map((v) => math.pow(v - mean, 2)).reduce((a, b) => a + b) /
          grayValues.length;

      return variance > 100;
    } catch (e) {
      return true;
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

      //strict pre-check before capture
      final validation = await _quickFaceValidation(bytes);
      if (validation["isValid"] != true) {
        _updateFeedback(
          validation['message'] ?? 'Adjust your face position',
          validation['isWarning'] ?? true,
        );
        _instructionViolationCount++;
        if (_instructionViolationCount >= _maxViolations) {
          _faceDetectionTimer?.cancel();
          _handleMaxViolations();
        }
        return;
      }

      final result = await _validateAndGenerateEmbedding(bytes);

      if (result['success'] == true) {
        await _captureController.forward();

        setState(() {
          _capturedEmbeddings.add(result['embedding']);
          _currentCaptureIndex++;
          _instructionViolationCount = 0;
          _showFeedback = false;
        });

        await _captureController.reverse();

        if (_capturedEmbeddings.length >= _requiredEmbeddings) {
          setState(() => _isAutoCaptureActive = false);
          _faceDetectionTimer?.cancel();
          await Future.delayed(const Duration(milliseconds: 500));
          setState(() => _showForm = true);
        }
      } else {
        _instructionViolationCount++;
        _showError(result['message'] ?? 'Please follow the instruction');

        if (_instructionViolationCount >= _maxViolations) {
          _faceDetectionTimer?.cancel();
          _handleMaxViolations();
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

  Future<Map<String, dynamic>> _validateAndGenerateEmbedding(
    List<int> imageBytes,
  ) async {
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
      return {
        'success': false,
        'message': 'No face detected. Please position your face in the circle.',
      };
    }

    final face = faces.first;

    // Validate face size
    final faceWidth = face.boundingBox.width;
    final faceSizeRatio = faceWidth / image.width.toDouble();

    if (faceSizeRatio < _minFaceSize || faceSizeRatio > _maxFaceSize) {
      return {
        'success': false,
        'message': 'Face size incorrect. Please adjust distance.',
      };
    }

    // NEW: Validate full face is visible
    final faceHeight = face.boundingBox.height;
    final faceHeightRatio = faceHeight / image.height.toDouble();

    if (faceHeightRatio < _minFaceHeightRatio) {
      return {
        'success': false,
        'message': 'Show your full face in the circle.',
      };
    }

    // NEW: Check if entire face bounding box is within circle
    if (!_isFullFaceInsideCircle(
      face,
      image.width.toDouble(),
      image.height.toDouble(),
    )) {
      return {
        'success': false,
        'message': 'Position entire face inside the circle',
      };
    }

    // NEW: Verify face proportions are correct (not stretched/cropped)
    final faceAspectRatio = face.boundingBox.width / face.boundingBox.height;
    if (faceAspectRatio < 0.7 || faceAspectRatio > 1.3) {
      return {
        'success': false,
        'message': 'Face appears distorted. Look straight',
      };
    }

    // NEW: Check that face covers reasonable area of circle
    final circleCenterX = image.width * _circleCenterX;
    final circleCenterY = image.height * _circleCenterY;
    final circleRadius = image.width * _circleRadiusPercent;
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final circleArea = math.pi * circleRadius * circleRadius;
    final coverageRatio = faceArea / circleArea;

    if (coverageRatio < 0.15) {
      return {
        'success': false,
        'message': 'Face too small. Move closer to fill the circle.',
      };
    }

    // NEW: Validate all landmarks for center pose
    if (_currentCaptureIndex == 0) {
      final landmarks = face.landmarks;
      final List<FaceLandmarkType> requiredLandmarks = [
        FaceLandmarkType.leftEye,
        FaceLandmarkType.rightEye,
        FaceLandmarkType.noseBase,
        FaceLandmarkType.leftMouth,
        FaceLandmarkType.rightMouth,
        FaceLandmarkType.bottomMouth,
        FaceLandmarkType.leftCheek,
        FaceLandmarkType.rightCheek,
      ];

      int validLandmarks = 0;
      for (var landmarkType in requiredLandmarks) {
        final landmark = landmarks[landmarkType];
        if (landmark != null) {
          final landmarkDist = math.sqrt(
            math.pow(landmark.position.x - circleCenterX, 2) +
                math.pow(landmark.position.y - circleCenterY, 2),
          );

          // Landmark must be well within circle (80% of radius)
          if (landmarkDist <= circleRadius * 0.8) {
            validLandmarks++;
          }
        }
      }

      // REQUIRE ALL 8 landmarks to be present and properly positioned
      if (validLandmarks < 8) {
        return {
          'success': false,
          'message':
              'Full face not detected. Show complete face inside circle.',
        };
      }
    }

    // Validate if face landmarks are within the circle boundary
    if (!_areLandmarksInCircle(
      face,
      image.width.toDouble(),
      image.height.toDouble(),
    )) {
      return {
        'success': false,
        'message':
            'Face is outside the circle. Please position yourself correctly.',
      };
    }

    // Validate head pose
    if (!_isCorrectHeadPose(face)) {
      String instruction = _captureInstructions[_currentCaptureIndex];
      return {
        'success': false,
        'message': 'Please follow the instruction: $instruction',
      };
    }

    // Validate eyes are open
    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      if (face.leftEyeOpenProbability! < _minEyeOpenProbability ||
          face.rightEyeOpenProbability! < _minEyeOpenProbability) {
        return {'success': false, 'message': 'Please keep your eyes open.'};
      }
    }

    // Check image sharpness
    final isSharp = await _checkImageSharpness(image);
    if (!isSharp) {
      return {
        'success': false,
        'message': 'Image too blurry. Please hold steady.',
      };
    }

    // Perform landmark-based face alignment
    final alignedImage = await _alignFaceWithLandmarks(image, face);
    if (alignedImage == null) {
      return {
        'success': false,
        'message': 'Could not align face properly. Please try again.',
      };
    }

    // Generate embedding from aligned face
    final padding = (face.boundingBox.width * 0.25).toInt();
    final x = (face.boundingBox.left - padding)
        .clamp(0, alignedImage.width - 1)
        .toInt();
    final y = (face.boundingBox.top - padding)
        .clamp(0, alignedImage.height - 1)
        .toInt();
    final w = (face.boundingBox.width + padding * 2)
        .clamp(1, alignedImage.width - x)
        .toInt();
    final h = (face.boundingBox.height + padding * 2)
        .clamp(1, alignedImage.height - y)
        .toInt();

    final cropped = img.copyCrop(alignedImage, x: x, y: y, width: w, height: h);
    final resized = img.copyResizeCropSquare(cropped, size: 112);

    final input = _imageToFloat32(resized);
    final output = List.filled(
      _embeddingSize,
      0.0,
    ).reshape([1, _embeddingSize]);
    _interpreter.run(input, output);

    final rawEmbedding = List<double>.from(output.reshape([_embeddingSize]));
    final normalizedEmbedding = _l2Normalize(rawEmbedding);

    return {'success': true, 'embedding': normalizedEmbedding};
  }

  Future<img.Image?> _alignFaceWithLandmarks(img.Image image, Face face) async {
    try {
      final landmarks = face.landmarks;

      final leftEye = landmarks[FaceLandmarkType.leftEye];
      final rightEye = landmarks[FaceLandmarkType.rightEye];

      if (leftEye == null || rightEye == null) {
        return image;
      }

      final dx = rightEye.position.x - leftEye.position.x;
      final dy = rightEye.position.y - leftEye.position.y;
      final angle = math.atan2(dy, dx);

      if (angle.abs() > 0.087) {
        final angleDegrees = angle * 180 / math.pi;
        final rotated = img.copyRotate(image, angle: -angleDegrees);
        return rotated;
      }

      return image;
    } catch (e) {
      return image;
    }
  }

  bool _areLandmarksInCircle(Face face, double imageWidth, double imageHeight) {
    final circleCenterX = imageWidth * _circleCenterX;
    final circleCenterY = imageHeight * _circleCenterY;
    final circleRadius = imageWidth * _circleRadiusPercent;

    // For center pose (index 0), be strict
    if (_currentCaptureIndex == 0) {
      // FIRST: Check if face is reasonably inside circle
      if (!_isFullFaceInsideCircle(face, imageWidth, imageHeight)) {
        return false;
      }

      // SECOND: Check critical landmarks for center pose
      final landmarks = face.landmarks;
      final List<FaceLandmarkType> requiredLandmarks = [
        FaceLandmarkType.leftEye,
        FaceLandmarkType.rightEye,
        FaceLandmarkType.noseBase,
        FaceLandmarkType.leftMouth,
        FaceLandmarkType.rightMouth,
      ];

      int landmarksInside = 0;
      for (var landmarkType in requiredLandmarks) {
        final landmark = landmarks[landmarkType];
        if (landmark != null) {
          final dx = landmark.position.x - circleCenterX;
          final dy = landmark.position.y - circleCenterY;
          final distance = math.sqrt(dx * dx + dy * dy);

          if (distance <= circleRadius * 0.9) {
            landmarksInside++;
          }
        }
      }

      // At least 4 out of 5 critical landmarks must be inside for center pose
      return landmarksInside >= 4;
    }
    // For angled poses (index 1 and 2), be more lenient
    else {
      // Check only nose and at least one eye are in circle
      final landmarks = face.landmarks;

      // Check nose base
      final nose = landmarks[FaceLandmarkType.noseBase];
      if (nose != null) {
        final dx = nose.position.x - circleCenterX;
        final dy = nose.position.y - circleCenterY;
        final noseDistance = math.sqrt(dx * dx + dy * dy);

        // Nose should be well inside circle for angled poses
        if (noseDistance > circleRadius * 0.8) {
          return false;
        }
      } else {
        return false;
      }

      // Check at least one eye is visible and inside circle
      final leftEye = landmarks[FaceLandmarkType.leftEye];
      final rightEye = landmarks[FaceLandmarkType.rightEye];

      bool leftEyeInside = false;
      bool rightEyeInside = false;

      if (leftEye != null) {
        final dx = leftEye.position.x - circleCenterX;
        final dy = leftEye.position.y - circleCenterY;
        final distance = math.sqrt(dx * dx + dy * dy);
        leftEyeInside = distance <= circleRadius * 1.2;
      }

      if (rightEye != null) {
        final dx = rightEye.position.x - circleCenterX;
        final dy = rightEye.position.y - circleCenterY;
        final distance = math.sqrt(dx * dx + dy * dy);
        rightEyeInside = distance <= circleRadius * 1.2;
      }

      // For angled poses, at least one eye should be visible
      return leftEyeInside || rightEyeInside;
    }
  }

  bool _isFullFaceInsideCircle(
    Face face,
    double imageWidth,
    double imageHeight,
  ) {
    final circleCenterX = imageWidth * _circleCenterX;
    final circleCenterY = imageHeight * _circleCenterY;
    final circleRadius = imageWidth * _circleRadiusPercent;

    final faceRect = face.boundingBox;

    // Calculate face center
    final faceCenterX = faceRect.left + faceRect.width / 2;
    final faceCenterY = faceRect.top + faceRect.height / 2;

    // Calculate distance from face center to circle center
    final centerDistance = math.sqrt(
      math.pow(faceCenterX - circleCenterX, 2) +
          math.pow(faceCenterY - circleCenterY, 2),
    );

    // Face center should be within 40% of circle radius from center
    if (centerDistance > circleRadius * 0.4) {
      return false;
    }

    // Check if majority of face area is inside circle
    final List<Offset> faceEdgeCenters = [
      Offset(faceRect.left + faceRect.width / 2, faceRect.top),
      Offset(faceRect.left + faceRect.width / 2, faceRect.bottom),
      Offset(faceRect.left, faceRect.top + faceRect.height / 2),
      Offset(faceRect.right, faceRect.top + faceRect.height / 2),
    ];

    int edgesInside = 0;
    for (var edge in faceEdgeCenters) {
      final dx = edge.dx - circleCenterX;
      final dy = edge.dy - circleCenterY;
      final distance = math.sqrt(dx * dx + dy * dy);

      if (distance <= circleRadius * 1.1) {
        edgesInside++;
      }
    }

    // At least 3 out of 4 edge centers should be inside circle
    return edgesInside >= 3;
  }

  bool _isCorrectHeadPose(Face face) {
    final headEulerAngleY = face.headEulerAngleY ?? 0;
    final headEulerAngleX = face.headEulerAngleX ?? 0;
    final headEulerAngleZ = face.headEulerAngleZ ?? 0;

    if (headEulerAngleX.abs() > 30 || headEulerAngleZ.abs() > 25) {
      return false;
    }

    if (_currentCaptureIndex == 0) {
      return headEulerAngleY.abs() < 20;
    } else if (_currentCaptureIndex == 1) {
      return headEulerAngleY < -5 && headEulerAngleY > -45;
    } else {
      return headEulerAngleY > 5 && headEulerAngleY < 45;
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
    setState(() => _isProcessing = true);

    try {
      for (var embedding in _capturedEmbeddings) {
        if (embedding.any((val) => val.isNaN || val.isInfinite)) {
          throw Exception('Invalid embedding data detected');
        }
      }

      final response = await(await MyDio().getDio()).post(
        '/users/face-registartion',
        data: {'user_id': selectedUser, 'faceEmbedding': _capturedEmbeddings},
      );

      _showSuccessDialog();
    } on DioException catch (e) {
      String errorMessage = 'Registration failed. Please try again.';

      if (e.response?.data != null && e.response?.data['message'] != null) {
        errorMessage = e.response!.data['message'];
      } else if (e.type == DioExceptionType.connectionTimeout) {
        errorMessage = 'Connection timeout. Please check your internet.';
      }

      _showError(errorMessage);
      debugPrint("Error registering user: ${e}");
    } catch (e) {
      _showError('Unexpected error: ${e.toString()}');
      debugPrint("Unexpected error: $e");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> getUsers() async {
    setState(() {
      isFetchingUsersData = true;
    });
    try {
      var response = await (await MyDio().getDio()).get(
        "/settings/users?noLimit=true",
      );
      usersList = response.data["data"] ?? [];
      debugPrint("success getting users data $usersList");
      setState(() {});
    } catch (e) {
      debugPrint("error getting user data $e");
    } finally {
      setState(() {
        isFetchingUsersData = false;
      });
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: const Text(
                  'Continue',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _resetCapture() {
    setState(() {
      _capturedEmbeddings.clear();
      _showForm = false;
      _currentCaptureIndex = 0;
      _instructionViolationCount = 0;
      _frameCounter = 0;
      _showFeedback = false;
      _showLeftArrow = false;
      _showRightArrow = false;
      _showUpArrow = false;
      _showDownArrow = false;
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

                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(
                            Icons.arrow_back_ios,
                            color: Colors.white,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.2),
                          ),
                        ),
                        const Spacer(),
                        if (_capturedEmbeddings.isNotEmpty &&
                            !_isAutoCaptureActive &&
                            !_showForm)
                          IconButton(
                            onPressed: _resetCapture,
                            icon: const Icon(
                              Icons.refresh,
                              color: Colors.white,
                            ),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                if (_showFeedback && !_showForm)
                  Positioned(
                    top: 100,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _feedbackColor.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _feedbackColor == Colors.red
                                  ? Icons.warning_amber_rounded
                                  : Icons.info_outline,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _feedbackMessage,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (!_showForm) _buildCameraUI() else _buildFormUI(),
              ],
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }

  Widget _buildCameraUI() {
    return Column(
      children: [
        const SizedBox(height: 40),

        // Main content area with arrows
        Expanded(
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 280 + (_pulseController.value * 20),
                              height: 350 + (_pulseController.value * 20),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.red.withOpacity(
                                    0.3 - (_pulseController.value * 0.2),
                                  ),
                                  width: 2,
                                ),
                              ),
                            ),
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
                                          ? Colors.red
                                          : const Color(0xFF10b981),
                                      width: 4,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color:
                                            (_capturedEmbeddings.isEmpty
                                                    ? Colors.red
                                                    : const Color(0xFF10b981))
                                                .withOpacity(0.5),
                                        blurRadius:
                                            20 +
                                            (_captureController.value * 20),
                                        spreadRadius:
                                            5 + (_captureController.value * 10),
                                      ),
                                    ],
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.2),
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 40),

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

              // NEW: Custom animated arrow indicators
              _buildArrowIndicators(),
            ],
          ),
        ),

        // Bottom controls section
        Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (_isAutoCaptureActive &&
                  _currentCaptureIndex < _requiredEmbeddings)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
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
                    : 'Position your ENTIRE face inside the circle',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _currentCaptureIndex == 0
                    ? 'Center your face in the circle'
                    : _currentCaptureIndex == 1
                    ? 'Follow the arrows to turn RIGHT'
                    : 'Follow the arrows to turn LEFT',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),

              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isCapturing
                      ? const Color(0xFF10b981).withOpacity(0.3)
                      : Colors.white.withOpacity(0.3),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Center(
                  child: _isCapturing
                      ? const CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        )
                      : Icon(
                          Icons.camera_alt,
                          size: 28,
                          color: Colors.white.withOpacity(0.8),
                        ),
                ),
              ),
              const SizedBox(height: 20),
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
          colors: [Colors.black.withOpacity(0.8), const Color(0xFF0f172a)],
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

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

              const SizedBox(height: 32),
              Text(
                "Select User",
                style: TextStyle(fontFamily: "Fredoka", color: Colors.white, fontSize: 16),
              ),
              SizedBox(height: 8,),
              DropdownButtonFormField(
                isExpanded: true,
                menuMaxHeight: 300,
                style: TextStyle(color: Colors.white, fontFamily: "Fredoka"),
                // 👈 selected text color
                validator: (value){
                  if(value == null){
                    return "Please select atleast one user";
                  }
                  return null;
                },
                dropdownColor: Colors.black87,
                // optional (menu background for dark theme)
                decoration: InputDecoration(
                  hintText: "Select User",
                  hintStyle: TextStyle(
                    color: Colors.white70,
                    fontFamily: "Fredoka",
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Colors.white),
                  ),
                ),
                value: selectedUser,
                items: usersList.map((users) {
                  return DropdownMenuItem(
                    value: users["_id"],
                    child: Text(
                      users["name"],
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: "Fredoka",
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    selectedUser = value.toString();
                    debugPrint("Selected user $selectedUser");
                  });
                },
              ),

              SizedBox(height: 15),
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
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
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
        border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            fontSize: 14,
            color: Colors.white.withOpacity(0.6),
          ),
          prefixIcon: Icon(icon, color: Colors.white.withOpacity(0.6)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(16),
        ),
      ),
    );
  }

  // NEW: Custom animated arrow indicators for turning left/right
  Widget _buildArrowIndicators() {
    // Only show arrows for step 2 (turn right) and step 3 (turn left)
    if (_currentCaptureIndex == 0) {
      return const SizedBox.shrink();
    }

    // Determine which direction to show arrows
    final bool showRightDirectionArrows =
        _currentCaptureIndex == 1; // Turn RIGHT
    final bool showLeftDirectionArrows = _currentCaptureIndex == 2; // Turn LEFT

    return AnimatedBuilder(
      animation: _arrowAnimationController,
      builder: (context, child) {
        final screenHeight = MediaQuery.of(context).size.height;
        final offsetValue =
            _arrowAnimationController.value * 30; // Movement range

        return Stack(
          children: [
            // LEFT SIDE ARROWS
            if (showRightDirectionArrows) ...[
              // Left side - pointing RIGHT (3 arrows)
              _buildMovingArrow(
                left: 20 + offsetValue,
                top: screenHeight * 0.30,
                isPointingRight: true,
              ),
              _buildMovingArrow(
                left: 20 + offsetValue,
                top: screenHeight * 0.40,
                isPointingRight: true,
              ),
              _buildMovingArrow(
                left: 20 + offsetValue,
                top: screenHeight * 0.50,
                isPointingRight: true,
              ),
            ],
            if (showLeftDirectionArrows) ...[
              // Left side - pointing LEFT (3 arrows)
              _buildMovingArrow(
                left: 50 - offsetValue,
                top: screenHeight * 0.30,
                isPointingRight: false,
              ),
              _buildMovingArrow(
                left: 50 - offsetValue,
                top: screenHeight * 0.40,
                isPointingRight: false,
              ),
              _buildMovingArrow(
                left: 50 - offsetValue,
                top: screenHeight * 0.50,
                isPointingRight: false,
              ),
            ],

            // RIGHT SIDE ARROWS
            if (showRightDirectionArrows) ...[
              // Right side - pointing RIGHT (3 arrows)
              _buildMovingArrow(
                right: 50 - offsetValue,
                top: screenHeight * 0.30,
                isPointingRight: true,
              ),
              _buildMovingArrow(
                right: 50 - offsetValue,
                top: screenHeight * 0.40,
                isPointingRight: true,
              ),
              _buildMovingArrow(
                right: 50 - offsetValue,
                top: screenHeight * 0.50,
                isPointingRight: true,
              ),
            ],
            if (showLeftDirectionArrows) ...[
              // Right side - pointing LEFT (3 arrows)
              _buildMovingArrow(
                right: 20 + offsetValue,
                top: screenHeight * 0.30,
                isPointingRight: false,
              ),
              _buildMovingArrow(
                right: 20 + offsetValue,
                top: screenHeight * 0.40,
                isPointingRight: false,
              ),
              _buildMovingArrow(
                right: 20 + offsetValue,
                top: screenHeight * 0.50,
                isPointingRight: false,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMovingArrow({
    double? left,
    double? right,
    required double top,
    required bool isPointingRight,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      child: CustomPaint(
        size: const Size(30, 22),
        painter: _ArrowPainter(
          isPointingRight: isPointingRight,
          color: const Color(0xFF10b981),
        ),
      ),
    );
  }
}

// Custom Painter for directional arrows
class _ArrowPainter extends CustomPainter {
  final bool isPointingRight;
  final Color color;

  _ArrowPainter({required this.isPointingRight, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.7)
      ..style = PaintingStyle.fill
      ..strokeWidth = 3;

    final path = Path();

    if (isPointingRight) {
      // Right-pointing arrow: ▶
      path.moveTo(0, 0);
      path.lineTo(size.width, size.height / 2);
      path.lineTo(0, size.height);
      path.lineTo(size.width * 0.2, size.height / 2);
      path.close();
    } else {
      // Left-pointing arrow: ◀
      path.moveTo(size.width, 0);
      path.lineTo(0, size.height / 2);
      path.lineTo(size.width, size.height);
      path.lineTo(size.width * 0.8, size.height / 2);
      path.close();
    }

    // Draw shadow/glow effect
    canvas.drawShadow(path, color, 8.0, true);

    // Draw the arrow
    canvas.drawPath(path, paint);

    // Add border for better visibility
    final borderPaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) {
    return oldDelegate.isPointingRight != isPointingRight ||
        oldDelegate.color != color;
  }
}
