import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Day-0 smoke: displays 0.1.0-day0 and passes FFI isolate test', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FujiStudioMobileApp());

    // Wait for async NativeWorker initialization and fs_core_version() result.
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('0.1.0-day0').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.text('0.1.0-day0'), findsOneWidget);

    final runButton = find.byKey(const Key('run_ffi_smoke_button'));
    expect(runButton, findsOneWidget);
    await tester.tap(runButton);

    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final statusFinder = find.descendant(
        of: find.byKey(const Key('ffi_smoke_status')),
        matching: find.text('PASS'),
      );
      if (statusFinder.evaluate().isNotEmpty) {
        break;
      }
    }

    expect(
      find.descendant(
        of: find.byKey(const Key('ffi_smoke_status')),
        matching: find.text('PASS'),
      ),
      findsOneWidget,
    );
  });
}
