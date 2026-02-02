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

class _RegisterUserState extends State<RegisterUser> {
  late CameraController _cameraController;
  late List<CameraDescription> _cameras;

  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isCapturing = false;

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
  static const int _requiredEmbeddings = 3; // Capture 3-5 for better accuracy

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
    _photoDetector.close();
    _interpreter.close();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
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
  }

  // ================= MODEL =================

  Future<void> _loadModel() async {
    _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
    _embeddingSize = _interpreter.getOutputTensor(0).shape[1];
    debugPrint('✅ Model loaded. Embedding size: $_embeddingSize');
  }

  // ================= CAPTURE FACE =================

  Future<void> _captureFaceEmbedding() async {
    if (_isCapturing || _capturedEmbeddings.length >= _requiredEmbeddings) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final file = await _cameraController.takePicture();
      final bytes = await File(file.path).readAsBytes();

      final embedding = await _generateFaceEmbedding(bytes);

      setState(() {
        _capturedEmbeddings.add(embedding);
      });

      // Show feedback
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Captured ${_capturedEmbeddings.length}/$_requiredEmbeddings faces',
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 1),
        ),
      );

      // Auto-proceed if we have enough embeddings
      if (_capturedEmbeddings.length >= _requiredEmbeddings) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Face data captured! Fill in details to register.'),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('❌ Capture error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        _isCapturing = false;
      });
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
      throw Exception('No face detected. Please try again.');
    }

    final face = faces.first;

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

    // 🔥 L2 Normalization (CRITICAL)
    final normalizedEmbedding = _l2Normalize(rawEmbedding);

    debugPrint('✅ Embedding generated and normalized');
    return normalizedEmbedding;
  }

  // 🔥 L2 Normalization
  List<double> _l2Normalize(List<double> embedding) {
    final norm = math.sqrt(
        embedding.fold(0.0, (sum, val) => sum + val * val)
    );

    if (norm == 0) return embedding;

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

  // ================= REGISTER USER =================

  Future<void> _registerUser() async {
    // Validation
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

    if (_capturedEmbeddings.length < _requiredEmbeddings) {
      _showError('Please capture at least $_requiredEmbeddings face images');
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      debugPrint('📤 Registering user...');
      debugPrint('📊 Sending ${_capturedEmbeddings.length} embeddings');

      final response = await _dio.post('/addUser', data: {
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone': _phoneController.text.trim(),
        'faceEmbedding': _capturedEmbeddings, // Array of arrays
      });

      debugPrint('📥 Response: ${response.data}');

      if (response.data['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Registration successful!'),
              backgroundColor: Colors.green,
            ),
          );

          // Navigate back or to another screen
          await Future.delayed(const Duration(seconds: 1));
          Navigator.pop(context);
        }
      } else {
        _showError(response.data['message'] ?? 'Registration failed');
      }
    } catch (e) {
      debugPrint('❌ Registration error: $e');
      _showError('Network error: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _resetCapture() {
    setState(() {
      _capturedEmbeddings.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register New User'),
        backgroundColor: Colors.blueAccent,
      ),
      body: _isInitialized
          ? SingleChildScrollView(
        child: Column(
          children: [
            // Camera Preview
            Container(
              height: 400,
              child: Stack(
                children: [
                  CameraPreview(_cameraController),

                  // Face guide overlay
                  Center(
                    child: Container(
                      width: 250,
                      height: 320,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(150),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.5),
                          width: 3,
                        ),
                      ),
                    ),
                  ),

                  // Capture indicator
                  if (_capturedEmbeddings.isNotEmpty)
                    Positioned(
                      top: 20,
                      right: 20,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_capturedEmbeddings.length}/$_requiredEmbeddings',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Instructions
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text(
                    _capturedEmbeddings.length < _requiredEmbeddings
                        ? 'Capture $_requiredEmbeddings different angles'
                        : 'Face data captured! Enter details below',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _capturedEmbeddings.length >= _requiredEmbeddings
                          ? Colors.green
                          : Colors.blue,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tip: Capture from slightly different angles for better accuracy',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            // Capture/Reset Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _capturedEmbeddings.length < _requiredEmbeddings && !_isCapturing
                          ? _captureFaceEmbedding
                          : null,
                      icon: _isCapturing
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                          : const Icon(Icons.camera_alt),
                      label: Text(_isCapturing ? 'Capturing...' : 'Capture Face'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                  if (_capturedEmbeddings.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      onPressed: _resetCapture,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Form Fields
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone (Optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.phone),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _capturedEmbeddings.length >= _requiredEmbeddings && !_isProcessing
                          ? _registerUser
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.all(16),
                      ),
                      child: _isProcessing
                          ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                          : const Text(
                        'Register',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}