import 'package:flutter/material.dart';

/// Tabs whose features ship in later milestones (Chat M5, Reports M4).
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(message, key: const Key('placeholder-message'), textAlign: TextAlign.center),
          ),
        ),
      );
}
