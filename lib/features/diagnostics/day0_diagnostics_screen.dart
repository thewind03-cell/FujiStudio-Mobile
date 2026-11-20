import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ffi/native_worker.dart';
import '../../core/schema/session_document.dart';

/// Minimalist Day-0 diagnostics screen verifying:
/// 1. Native C++20 core version via `fs_core_version()`.
/// 2. Long-lived Isolate FFI round-trip (`fs_invert_rgba_smoke` on 64x64 RGBA).
/// 3. Desktop v2.4.2 schema round-trip with Unknown-Field Preservation.
class Day0DiagnosticsScreen extends StatefulWidget {
  const Day0DiagnosticsScreen({super.key});

  @override
  State<Day0DiagnosticsScreen> createState() => _Day0DiagnosticsScreenState();
}

class _Day0DiagnosticsScreenState extends State<Day0DiagnosticsScreen> {
  static const int _smokeWidth = 64;
  static const int _smokeHeight = 64;

  NativeWorker? _worker;
  String _coreVersion = 'Loading...';
  String? _workerError;

  bool _runningFfiSmoke = false;
  String _ffiSmokeStatus = 'IDLE';
  String _ffiSmokeDetail = 'Press button to run 64x64 RGBA inversion in Isolate';

  String _schemaStatus = 'CHECKING';
  String _schemaDetail = 'Validating Desktop v2.4.2 fixture round-trip...';

  @override
  void initState() {
    super.initState();
    _initDiagnostics();
  }

  @override
  void dispose() {
    _worker?.dispose();
    super.dispose();
  }

  Future<void> _initDiagnostics() async {
    await Future.wait<void>(<Future<void>>[
      _initNativeCore(),
      _verifySchemaRoundTrip(),
    ]);
  }

  Future<void> _initNativeCore() async {
    try {
      final worker = await NativeWorker.spawn();
      final version = await worker.coreVersion();
      if (!mounted) {
        await worker.dispose();
        return;
      }
      setState(() {
        _worker = worker;
        _coreVersion = version;
        _workerError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _coreVersion = 'ERROR';
        _workerError = error.toString();
      });
    }
  }

  Future<void> _verifySchemaRoundTrip() async {
    try {
      final rawText = await rootBundle.loadString(
        'schemas/fixtures/desktop_v2_4_2_sample.json',
      );
      final decoded = jsonDecode(rawText) as Map<String, Object?>;
      final doc = SessionDocument.fromJson(decoded);

      final firstItem = doc.items.first;
      final mutated = doc.copyWith(
        items: <dynamic>[
          firstItem.copyWith(
            editRecipe: firstItem.editRecipe.copyWith(
              dnaRescue: firstItem.editRecipe.dnaRescue.copyWith(
                shadowLift: 42.0,
              ),
            ),
          ),
          ...doc.items.skip(1),
        ].cast(),
      );

      final serialized = mutated.toJson();
      final reparsed = SessionDocument.fromJson(serialized);

      final hasRootUnknown = serialized.containsKey('desktop_lut_cache') &&
          serialized.containsKey('xmp_sidecar_hash');
      final itemJson =
          (serialized['items'] as List<Object?>).first as Map<String, Object?>;
      final hasItemUnknown = itemJson.containsKey('histogram_bins');
      final recipeJson = itemJson['edit_recipe'] as Map<String, Object?>;
      final hasRecipeUnknown =
          recipeJson.containsKey('desktop_reinhard_lab_ref_id');
      final updatedLift = reparsed.items.first.editRecipe.dnaRescue.shadowLift;

      final passed = hasRootUnknown &&
          hasItemUnknown &&
          hasRecipeUnknown &&
          updatedLift == 42.0;

      if (!mounted) return;
      setState(() {
        _schemaStatus = passed ? 'PASS' : 'FAIL';
        _schemaDetail = passed
            ? 'v${reparsed.schemaVersion} round-trip OK '
                '(${reparsed.unknownFields.length} root unknown fields preserved)'
            : 'Unknown field preservation mismatch';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _schemaStatus = 'FAIL';
        _schemaDetail = error.toString();
      });
    }
  }

  Future<void> _runFfiSmokeTest() async {
    final worker = _worker;
    if (worker == null || _runningFfiSmoke) return;

    setState(() {
      _runningFfiSmoke = true;
      _ffiSmokeStatus = 'RUNNING';
      _ffiSmokeDetail = 'Running fs_invert_rgba_smoke (64x64) in Isolate...';
    });

    try {
      const byteLen = _smokeWidth * _smokeHeight * 4;
      final input = Uint8List(byteLen);
      for (var i = 0; i < byteLen; i += 4) {
        final px = i ~/ 4;
        input[i + 0] = px & 0xFF;
        input[i + 1] = (px * 3) & 0xFF;
        input[i + 2] = (px * 7) & 0xFF;
        input[i + 3] = 220;
      }

      final result = await worker.invertRgbaSmoke(
        inputRgba: input,
        width: _smokeWidth,
        height: _smokeHeight,
      );

      var verified = result.isOk &&
          result.rgbaBytes != null &&
          result.rgbaBytes!.length == byteLen;
      if (verified) {
        final out = result.rgbaBytes!;
        for (var i = 0; i < byteLen; i += 4) {
          if (out[i + 0] != 255 - input[i + 0] ||
              out[i + 1] != 255 - input[i + 1] ||
              out[i + 2] != 255 - input[i + 2] ||
              out[i + 3] != input[i + 3]) {
            verified = false;
            break;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _runningFfiSmoke = false;
        _ffiSmokeStatus = verified ? 'PASS' : 'FAIL';
        _ffiSmokeDetail = verified
            ? '64x64 RGBA inverted & verified in '
                '${result.elapsedMilliseconds.toStringAsFixed(2)} ms'
            : 'Verification failed (statusCode=${result.statusCode})';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _runningFfiSmoke = false;
        _ffiSmokeStatus = 'FAIL';
        _ffiSmokeDetail = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('FujiStudio Mobile — Day-0 Diagnostics'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _DiagnosticCard(
            title: '1. C++20 Core Version (fs_core_version)',
            status: _workerError == null && _coreVersion == '0.1.0-day0'
                ? 'PASS'
                : (_coreVersion == 'Loading...' ? 'LOADING' : 'FAIL'),
            valueKey: const Key('core_version_text'),
            valueText: _coreVersion,
            detailText: _workerError ?? 'Loaded via dart:ffi in NativeWorker',
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '2. FFI Isolate Smoke (fs_invert_rgba_smoke)',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      _StatusChip(
                        key: const Key('ffi_smoke_status'),
                        label: _ffiSmokeStatus,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_ffiSmokeDetail, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('run_ffi_smoke_button'),
                    onPressed: (_worker != null && !_runningFfiSmoke)
                        ? _runFfiSmokeTest
                        : null,
                    child: Text(
                      _runningFfiSmoke
                          ? 'Running...'
                          : 'Run 64x64 RGBA FFI Smoke Test',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _DiagnosticCard(
            title: '3. Schema Contract Round-Trip (v2.4.2)',
            status: _schemaStatus,
            valueKey: const Key('schema_roundtrip_status'),
            valueText: _schemaStatus,
            detailText: _schemaDetail,
          ),
        ],
      ),
    );
  }
}

class _DiagnosticCard extends StatelessWidget {
  const _DiagnosticCard({
    required this.title,
    required this.status,
    required this.valueKey,
    required this.valueText,
    required this.detailText,
  });

  final String title;
  final String status;
  final Key valueKey;
  final String valueText;
  final String detailText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                _StatusChip(label: status),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              valueText,
              key: valueKey,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            Text(detailText, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color foreground;
    switch (label) {
      case 'PASS':
        background = Colors.green.shade800;
        foreground = Colors.white;
      case 'FAIL':
        background = Colors.red.shade800;
        foreground = Colors.white;
      default:
        background = Colors.blueGrey.shade700;
        foreground = Colors.white;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}
