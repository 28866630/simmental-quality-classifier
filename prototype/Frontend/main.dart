// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html show FileUploadInputElement, FileReader, document; // web picker

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// ===== Abstractions (so tests can inject fakes) =====

abstract class ImageSource {
  Future<List<Uint8List>> pickImages({int maxCount = 10});
}

abstract class PredictApi {
  Future<PredictionResult> predict(Uint8List bytes);
}

class PredictionResult {
  final String prediction; // "Good", "Bad", or "No cow detected"
  final double? score;     // 0..1 for Good/Bad, null for no-cow
  PredictionResult(this.prediction, this.score);
}

/// ===== Real web implementations =====

class HtmlFilePickerSource implements ImageSource {
  @override
  Future<List<Uint8List>> pickImages({int maxCount = 10}) async {
    final input = html.FileUploadInputElement()
      ..accept = 'image/*'
      ..multiple = true;

    // Hide it off-screen so it doesn't intercept taps
    input.style
      ..position = 'fixed'
      ..top = '-10000px'
      ..left = '-10000px'
      ..opacity = '0';
    html.document.body?.append(input);

    input.click();

    final out = <Uint8List>[];
    try {
      await input.onChange.first;
      final files = input.files ?? [];
      final limit = files.length > maxCount ? maxCount : files.length;

      for (var i = 0; i < limit; i++) {
        final f = files[i];
        if (!f.type.startsWith('image/') || f.size > 5 * 1024 * 1024) {
          continue;
        }
        final reader = html.FileReader();
        final completer = Completer<Uint8List>();
        reader.readAsArrayBuffer(f);
        reader.onLoadEnd.listen((_) {
          try {
            completer.complete(reader.result as Uint8List);
          } catch (e) {
            completer.completeError(e);
          }
        });
        reader.onError.listen((_) => completer.completeError('read error'));
        out.add(await completer.future);
      }
    } finally {
      input.remove();
    }
    return out;
  }
}

class HttpPredictApi implements PredictApi {
  final Uri endpoint;
  final http.Client _client;
  HttpPredictApi(this.endpoint, {http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<PredictionResult> predict(Uint8List bytes) async {
    final req = http.MultipartRequest('POST', endpoint)
      ..files.add(http.MultipartFile.fromBytes('image', bytes,
          filename: 'image.jpg'));
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final label = data['prediction'] as String? ?? 'No cow detected';
      final score = (data['score'] as num?)?.toDouble();
      return PredictionResult(label, score);
    } else {
      // Treat any non-200 as "no cow" for UI purposes
      return PredictionResult('No cow detected', null);
    }
  }
}

/// ===== App root with DI =====

void main() {
  // Default: real web picker + your backend endpoint
  runApp(CowClassifierApp(
    imageSource: HtmlFilePickerSource(),
    api: HttpPredictApi(Uri.parse('http://192.168.2.131:5050/predict')),
  ));
}

class CowClassifierApp extends StatelessWidget {
  final ImageSource imageSource;
  final PredictApi api;
  const CowClassifierApp({
    super.key,
    required this.imageSource,
    required this.api,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cow Classifier',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.brown,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: ClassifierScreen(imageSource: imageSource, api: api),
    );
  }
}

enum GroupMode { multipleCows, singleCow }

class ClassifierScreen extends StatefulWidget {
  final ImageSource imageSource;
  final PredictApi api;
  const ClassifierScreen({
    super.key,
    required this.imageSource,
    required this.api,
  });

  @override
  State<ClassifierScreen> createState() => _ClassifierScreenState();
}

class _ClassifierScreenState extends State<ClassifierScreen> {
  static const int _maxImages = 10;

  // Keys (helpful for tests)
  final _gridKey = const ValueKey('grid');
  final _clearAllKey = const ValueKey('btn-clear-all');

  List<Uint8List> _imageBytesList = [];
  List<String?> _predictions = [];
  List<double?> _scores = [];
  GroupMode _mode = GroupMode.multipleCows;

  // ===== Test-only hook to seed images (no effect in release) =====
  @visibleForTesting
  void debugSetImages(List<Uint8List> imgs) {
    assert(() {
      setState(() {
        _imageBytesList = List<Uint8List>.from(imgs);
        _predictions =
            List<String?>.filled(_imageBytesList.length, null, growable: true);
        _scores =
            List<double?>.filled(_imageBytesList.length, null, growable: true);
      });
      return true;
    }());
  }

  // ===== Delete helpers =====
  void _removeImageAt(int index) {
    if (index < 0 || index >= _imageBytesList.length) return;
    setState(() {
      _imageBytesList.removeAt(index);
      if (index < _predictions.length) _predictions.removeAt(index);
      if (index < _scores.length) _scores.removeAt(index);
    });
  }

  void _clearAllImages() {
    setState(() {
      _imageBytesList.clear();
      _predictions.clear();
      _scores.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cleared all images')),
    );
  }

  // ===== Pick images via injected source =====
  Future<void> _pickImages() async {
    final imgs = await widget.imageSource.pickImages(maxCount: _maxImages);
    if (imgs.isEmpty) return;
    setState(() {
      _imageBytesList = imgs;
      _predictions =
          List<String?>.filled(_imageBytesList.length, null, growable: true);
      _scores =
          List<double?>.filled(_imageBytesList.length, null, growable: true);
    });
  }

  // ===== Predict =====
  Future<void> _sendImagesToServer() async {
    if (_imageBytesList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one image.')),
      );
      return;
    }

    setState(() {
      _predictions =
          List<String?>.filled(_imageBytesList.length, null, growable: true);
      _scores =
          List<double?>.filled(_imageBytesList.length, null, growable: true);
    });

    bool anyNoCowDetected = false;

    for (int i = 0; i < _imageBytesList.length; i++) {
      try {
        final r = await widget.api.predict(_imageBytesList[i]);
        setState(() {
          _predictions[i] = r.prediction;
          _scores[i] = r.score;
        });
        if (r.prediction == 'No cow detected') anyNoCowDetected = true;
      } catch (_) {
        setState(() {
          _predictions[i] = 'No cow detected';
          _scores[i] = null;
        });
        anyNoCowDetected = true;
      }
    }

    if (anyNoCowDetected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('In one or more images, no cow was detected.')),
      );
    }
  }

  // ===== Confidence & overall =====
  double? _confidenceForLabel(String? label, double? score) {
    if (label == null || score == null || label == 'No cow detected') {
      return null;
    }
    return label == 'Good' ? score : (1.0 - score);
  }

  double? _averageScore() {
    final vals = _scores.whereType<double>().toList();
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  String? _overallLabel(double avgScore) => avgScore >= 0.5 ? 'Good' : 'Bad';

  Widget _buildOverallResult() {
    if (_mode != GroupMode.singleCow || _imageBytesList.isEmpty) {
      return const SizedBox.shrink();
    }
    final avg = _averageScore();

    final allProcessedButNoValid = _imageBytesList.isNotEmpty &&
        _scores.whereType<double>().isEmpty &&
        _predictions.any((p) => p != null);

    if (allProcessedButNoValid) {
      return _infoCard(
          'No overall prediction — no cow was detected in the selected images.');
    }
    if (avg == null) {
      return _progressCard('Computing overall prediction…');
    }

    final label = _overallLabel(avg)!;
    final confidence = (label == 'Good' ? avg : 1 - avg) * 100.0;
    final color = label == 'Good' ? Colors.green[800] : Colors.red[700];

    return Card(
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Overall Prediction (Single Cow)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('$label — ${confidence.toStringAsFixed(1)}% confidence',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _infoCard(String msg) => Card(
        elevation: 2,
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(msg, textAlign: TextAlign.center)),
      );

  Widget _progressCard(String msg) => Card(
        elevation: 2,
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 12),
            Expanded(child: Text(msg)),
          ]),
        ),
      );

  Widget _modeSelector() {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: RadioListTile<GroupMode>(
                key: const ValueKey('radio-multi'),
                title: const Text('Multiple Cows'),
                dense: true,
                value: GroupMode.multipleCows,
                groupValue: _mode,
                onChanged: (val) {
                  if (val != null) setState(() => _mode = val);
                },
              ),
            ),
            Expanded(
              child: RadioListTile<GroupMode>(
                key: const ValueKey('radio-single'),
                title: const Text('Single Cow'),
                dense: true,
                value: GroupMode.singleCow,
                groupValue: _mode,
                onChanged: (val) {
                  if (val != null) setState(() => _mode = val);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 480;

    return Scaffold(
      appBar: AppBar(
        title: const Text('🐄 Cow Classifier'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: [
                // 👇 Added radio buttons here
                _modeSelector(),

                _buildOverallResult(),

                if (_imageBytesList.isNotEmpty)
                  GridView.builder(
                    key: _gridKey,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _imageBytesList.length,
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: isNarrow ? 2 : 3,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.75,
                    ),
                    itemBuilder: (context, index) {
                      final pred = index < _predictions.length
                          ? _predictions[index]
                          : null;
                      final score = index < _scores.length
                          ? _scores[index]
                          : null;
                      final conf = _confidenceForLabel(pred, score);
                      final tileKey = ValueKey(
                          'img-${_imageBytesList[index].length}-$index');

                      return Dismissible(
                        key: tileKey,
                        direction: DismissDirection.endToStart,
                        background:
                            _dismissBg(Alignment.centerRight),
                        onDismissed: (_) => _removeImageAt(index),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: Colors.brown, width: 2),
                                borderRadius:
                                    BorderRadius.circular(12),
                              ),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Center(
                                      child: ClipRRect(
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                top: Radius.circular(12)),
                                        child: Image.memory(
                                          _imageBytesList[index],
                                          fit: BoxFit.contain,
                                          alignment:
                                              Alignment.center,
                                          gaplessPlayback: true,
                                          // prevent codec crashes on bad bytes
                                          errorBuilder: (_, __, ___) =>
                                              const Center(
                                            child: Icon(
                                                Icons.broken_image,
                                                size: 32),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_mode ==
                                          GroupMode.multipleCows &&
                                      pred != null)
                                    Padding(
                                      padding:
                                          const EdgeInsets.all(8.0),
                                      child: pred == 'No cow detected'
                                          ? const Text(
                                              'No cow detected',
                                              textAlign:
                                                  TextAlign.center,
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight:
                                                      FontWeight
                                                          .bold),
                                            )
                                          : Text(
                                              'Prediction: $pred\nConfidence: ${(conf! * 100).toStringAsFixed(1)}%',
                                              textAlign:
                                                  TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: pred == 'Good'
                                                    ? Colors.green
                                                    : Colors.red,
                                                fontWeight:
                                                    FontWeight.bold,
                                              ),
                                            ),
                                    ),
                                ],
                              ),
                            ),
                            Positioned(
                              right: 4,
                              top: 4,
                              child: GestureDetector(
                                key: ValueKey('tile-close-$index'),
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _removeImageAt(index),
                                child: Container(
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black54,
                                  ),
                                  padding: const EdgeInsets.all(6),
                                  child: const Icon(Icons.close,
                                      size: 18, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                const SizedBox(height: 16),

                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 480;
                    return Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment:
                          WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width:
                              narrow ? double.infinity : null,
                          child: ElevatedButton.icon(
                            key: const ValueKey('btn-pick'),
                            onPressed: _pickImages,
                            icon: const Icon(Icons.photo_library),
                            label: const Text(
                                'Pick up to 10 Images'),
                          ),
                        ),
                        SizedBox(
                          width:
                              narrow ? double.infinity : null,
                          child: ElevatedButton(
                            key: const ValueKey('btn-predict'),
                            onPressed: _sendImagesToServer,
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green),
                            child: const Text('Predict All'),
                          ),
                        ),
                        if (_imageBytesList.isNotEmpty)
                          SizedBox(
                            width: narrow
                                ? double.infinity
                                : null,
                            child: TextButton.icon(
                              key: _clearAllKey,
                              onPressed: _clearAllImages,
                              icon: const Icon(Icons.delete_sweep),
                              label: const Text('Clear all'),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dismissBg(AlignmentGeometry align) => Container(
        alignment: align,
        padding:
            const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      );
}
