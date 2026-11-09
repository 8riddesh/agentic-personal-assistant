import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/health_api.dart';

/// M0 skeleton screen: proves the APK can reach the backend (`GET /health`).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.config, required this.healthApi});

  final AppConfig config;
  final HealthApi healthApi;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<HealthStatus> _health;

  @override
  void initState() {
    super.initState();
    _health = widget.healthApi.check(); // also warms the sleeping Render instance
  }

  void _retry() {
    // Block body on purpose: an arrow would return the Future from the setState callback (assertion in Flutter).
    setState(() {
      _health = widget.healthApi.check();
    });
  }

  String _describe(Object error) {
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout =>
          "Server didn't answer in time (it may still be waking up).",
        DioExceptionType.connectionError => 'Cannot reach the server. Check your connection.',
        _ => 'Server error (${error.response?.statusCode ?? 'no response'}).',
      };
    }
    return 'Unexpected response from the server.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daily Assistant')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FutureBuilder<HealthStatus>(
            future: _health,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Contacting server… this can take up to a minute.'),
                  ],
                );
              }
              if (snapshot.hasError) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 48),
                    const SizedBox(height: 16),
                    Text(_describe(snapshot.error!), key: const Key('health-error'), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _retry, child: const Text('Retry')),
                  ],
                );
              }
              final health = snapshot.requireData;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(health.isOk ? Icons.cloud_done : Icons.cloud_queue, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    health.isOk ? 'Server is up' : 'Server is degraded',
                    key: const Key('health-status'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('database: ${health.db} · version: ${health.version}'),
                  const SizedBox(height: 16),
                  Text(widget.config.apiBaseUrl.host, style: Theme.of(context).textTheme.bodySmall),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
