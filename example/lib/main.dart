import 'package:flutter/material.dart';
import 'package:flutter_session_recorder/flutter_session_recorder.dart';

Future<void> main() async {
  await recorder.runApp(
    const RecorderDemoApp(),
    config: const SessionRecorderConfig.lightweight(
      maxSnapshotUploadBatchSize: 10,
      nativeSnapshotInterval: Duration(milliseconds: 500),
      nativeSnapshotMaxDimension: 720,
      snapshotUploadFlushInterval: Duration(seconds: 5),
    ),
    transport: const DebugPrintSessionRecorderTransport(),
    sessionProperties: <String, Object?>{
      'environment': 'example',
      'platformCapture': 'native_snapshots_plus_structured_events',
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session Recorder Demo')),
      body: ListView.builder(
        itemCount: 30,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ElevatedButton(
                    onPressed: () {
                      recorder.recordEvent(
                        'purchase_button_tapped',
                        properties: <String, Object?>{'cta': 'hero'},
                      );
                      recorder.log(
                        'Hero CTA tapped',
                        logger: 'demo',
                      );
                    },
                    child: const Text('Track custom event'),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      recorder.setUser(
                        'demo-user',
                        userProperties: <String, Object?>{'plan': 'pro'},
                      );
                    },
                    child: const Text('Set current user'),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      recorder.setUserProperties(
                        <String, Object?>{'plan': 'enterprise'},
                      );
                    },
                    child: const Text('Update user properties'),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      recorder.clearUser();
                    },
                    child: const Text('Clear current user'),
                  ),
                ],
              ),
            );
          }

          return ListTile(
            title: Text('Item $index'),
            subtitle: const Text('Scroll and tap to generate telemetry'),
            onTap: () {
              recorder.recordEvent(
                'list_item_selected',
                properties: <String, Object?>{'index': index},
              );
              if (index == 7) {
                recorder.error(
                  StateError('Example item 7 triggered an error'),
                  logger: 'demo',
                );
              }
            },
          );
        },
      ),
    );
  }
}
