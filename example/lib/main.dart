import 'package:flutter/material.dart';
import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'perf_harness.dart';

Future<void> main() async {
  // Keep the device awake while the harness is running so an auto-lock
  // doesn't interrupt a measurement mid-scenario. Binding has to be ready
  // before we touch the wakelock plugin's method channel.
  WidgetsFlutterBinding.ensureInitialized();
  await WakelockPlus.enable();

  await recorder.runApp(
    const RecorderDemoApp(),
    config: const SessionRecorderConfig.lightweight(
      maxSnapshotUploadBatchSize: 10,
      nativeSnapshotInterval: Duration(milliseconds: 500),
      nativeSnapshotMaxDimension: 720,
      snapshotUploadFlushInterval: Duration(seconds: 5),
      // Replace with your app's domain so the server can attribute the
      // session correctly.
      recordingDomain: 'your-app.example.com',
    ),
    // Replace with `HttpSessionRecorderTransport(endpoint: ..., apiKey: ...)`
    // pointing at your recorder backend to actually upload snapshots and
    // session batches. The noop transport keeps the example self-contained.
    transport: const NoopSessionRecorderTransport(),
    sessionProperties: <String, Object?>{
      'environment': 'example',
      'platformCapture': 'flutter_repaint_boundary',
    },
  );
}

class RecorderDemoApp extends StatelessWidget {
  const RecorderDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: recorder.navigatorObservers(),
      builder: recorder.appBuilder(),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session Recorder Perf Harness')),
      body: PerfHarness(
        scrollController: _scrollController,
        child: ListView.builder(
          controller: _scrollController,
          itemCount: 500,
          itemBuilder: (BuildContext context, int index) {
            return _ListRow(index: index);
          },
        ),
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final Color tint = Color.lerp(
          Colors.indigo.shade100,
          Colors.deepOrange.shade100,
          (index % 50) / 50.0,
        ) ??
        Colors.white;
    return Container(
      height: 88,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(10),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            backgroundColor: Colors.white,
            child: Text(
              '$index',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  'Item $index',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Scroll to generate frames for the harness to measure',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
