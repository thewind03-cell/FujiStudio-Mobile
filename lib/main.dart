import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/di/app_providers.dart';
import 'core/ffi/native_worker.dart';
import 'core/theme/fuji_theme.dart';
import 'features/session_picker/album_picker_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final worker = await NativeWorker.spawn();
  runApp(
    ProviderScope(
      overrides: <Override>[
        nativeWorkerProvider.overrideWithValue(worker),
      ],
      child: const FujiStudioMobileApp(),
    ),
  );
}

class FujiStudioMobileApp extends StatelessWidget {
  const FujiStudioMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FujiStudio Mobile',
      debugShowCheckedModeBanner: false,
      theme: FujiTheme.dark(),
      home: const AlbumPickerScreen(),
    );
  }
}
