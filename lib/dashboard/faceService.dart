import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceService {
  late Interpreter _interpreter;

  static const int inputSize = 112;
  static const int embeddingSize = 192;

  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
  }

  List<double> getEmbedding(img.Image image) {
    final resized =
    img.copyResize(image, width: inputSize, height: inputSize);

    final input = Float32List(inputSize * inputSize * 3);
    int i = 0;

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final p = resized.getPixel(x, y);
        input[i++] = (p.r - 128) / 128;
        input[i++] = (p.g - 128) / 128;
        input[i++] = (p.b - 128) / 128;
      }
    }

    final output =
    List.filled(embeddingSize, 0.0).reshape([1, embeddingSize]);

    _interpreter.run(input.reshape([1, inputSize, inputSize, 3]), output);

    return List<double>.from(output[0]);
  }
}
