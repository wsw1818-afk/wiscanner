import 'package:flutter/material.dart';
import 'presentation/pages/home/home_page.dart';

class WiScanerApp extends StatelessWidget {
  const WiScanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WiScaner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
