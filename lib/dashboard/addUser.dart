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
  }

  Future<void> _loadModel() async {
    _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
    _embeddingSize = _interpreter.getOutputTensor(0).shape[1];
  }

  Future<void> _captureFaceEmbedding() async {
    if (_isCapturing || _capturedEmbeddings.length >= _requiredEmbeddings) {
      return;
    }

    setState(() => _isCapturing = true);
    await _captureController.forward();

    try {
      final file = await _cameraController.takePicture();
      final bytes = await File(file.path).readAsBytes();
      final embedding = await _generateFaceEmbedding(bytes);

      setState(() {
        _capturedEmbeddings.add(embedding);
      });

      // Show success animation
      await _captureController.reverse();

      if (_capturedEmbeddings.length >= _requiredEmbeddings) {
        await Future.delayed(const Duration(milliseconds: 500));
        setState(() => _showForm = true);
      }
    } catch (e) {
      _captureController.reverse();
      _showError(e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _isCapturing = false);
    }
  }

  Future<List<double>> _generateFaceEmbedding(List<int> imageBytes) async {
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
      throw Exception('No face detected. Please try again.');
    }

    final face = faces.first;
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

  Future<void> _registerUser() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Please enter your name');
      return;
    }
    if (_emailController.text.trim().isEmpty) {
      _showError('Please enter your email');
      return;
    }
    if (!_emailController.text.contains('@')) {
      _showError('Please enter a valid email');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final response = await _dio.post('/addUser', data: {
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone': _phoneController.text.trim(),
        'faceEmbedding': _capturedEmbeddings,
      });

      if (response.data['success'] == true) {
        if (mounted) {
          _showSuccessDialog();
        }
      } else {
        _showError(response.data['message'] ?? 'Registration failed');
      }
    } catch (e) {
      _showError('Network error. Please try again.');
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
      ),
    );
  }

  void _resetCapture() {
    setState(() {
      _capturedEmbeddings.clear();
      _showForm = false;
    });
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
                  if (_capturedEmbeddings.isNotEmpty)
                    IconButton(
                      onPressed: _resetCapture,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.2),
                      ),
                    ),
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

        // Bottom section
        Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                _capturedEmbeddings.isEmpty
                    ? 'Position your face in the circle'
                    : 'Capture ${_requiredEmbeddings - _capturedEmbeddings.length} more angle${_requiredEmbeddings - _capturedEmbeddings.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Try slightly different angles',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),

              // Capture button
              GestureDetector(
                onTap: _capturedEmbeddings.length < _requiredEmbeddings && !_isCapturing
                    ? _captureFaceEmbedding
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isCapturing
                        ? Colors.white.withOpacity(0.3)
                        : Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: _isCapturing
                      ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                      : const Icon(
                    Icons.camera_alt,
                    size: 36,
                    color: Color(0xFF0f172a),
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

              const SizedBox(height: 48),

              // Form fields
              _buildTextField(
                controller: _nameController,
                label: 'Full Name',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 20),
              _buildTextField(
                controller: _emailController,
                label: 'Email Address',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 20),
              _buildTextField(
                controller: _phoneController,
                label: 'Phone Number (Optional)',
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
              ),

              const SizedBox(height: 40),

              // Submit button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: !_isProcessing ? _registerUser : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10b981),
                    disabledBackgroundColor: const Color(0xFF10b981).withOpacity(0.5),
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
          fontSize: 16,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.white.withOpacity(0.6),
          ),
          prefixIcon: Icon(
            icon,
            color: Colors.white.withOpacity(0.6),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(20),
        ),
      ),
    );
  }
}