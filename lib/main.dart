import 'package:material_ui/material_ui.dart';

import 'features/diagnostics/day0_diagnostics_screen.dart';

void main() {
  runApp(const FujiStudioMobileApp());
}

class FujiStudioMobileApp extends StatelessWidget {
  const FujiStudioMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FujiStudio Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007A5E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const Day0DiagnosticsScreen(),
    );
  }
}
