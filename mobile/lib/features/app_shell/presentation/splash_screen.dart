import 'package:flutter/material.dart';

/// Spinner while the stored token is being read (`AuthUnknown`).
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}
