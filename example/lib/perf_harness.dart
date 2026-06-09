import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_session_recorder/flutter_session_recorder.dart';

enum _Scenario {
  baselineNoRecorder('baseline_no_recorder', simBlockMs: 0),
  recorderSnapshotsOff('recorder_snapshots_off', simBlockMs: 0),
  recorderSnapshots500ms('recorder_snapshots_500ms', simBlockMs: 0),
  recorderSnapshots2000ms('recorder_snapshots_2000ms', simBlockMs: 0),
  // Simulators: no recorder, just a periodic Dart busy-loop on the UI isolate
  // every 500ms, to reproduce the shape of the iOS snapshot main-thread block
  // on devices with a more forgiving frame budget (e.g. iPhone XR at 60Hz).
  simBlock10ms('sim_block_10ms_every_500ms', simBlockMs: 10),
  simBlock15ms('sim_block_15ms_every_500ms', simBlockMs: 15),
  simBlock25ms('sim_block_25ms_every_500ms', simBlockMs: 25);

  const _Scenario(this.label, {required this.simBlockMs});
  final String label;
  final int simBlockMs;
}

class PerfHarness extends StatefulWidget {
  const PerfHarness({
    required this.child,
    required this.scrollController,
    super.key,
  });

  final Widget child;
  final ScrollController scrollController;

  @override
  State<PerfHarness> createState() => _PerfHarnessState();
}

class _PerfHarnessState extends State<PerfHarness> {
  static const Duration _sweepDuration = Duration(milliseconds: 1500);
  static const int _sweepCount = 3;

  final List<FrameTiming> _samples = <FrameTiming>[];
  final List<_RunResult> _history = <_RunResult>[];
  _Scenario? _running;
  bool _capturing = false;
  int _liveFrameCount = 0;
  int _liveDropped = 0;
  double _dropThresholdMs = 16.7;
  double _detectedRefreshHz = 60.0;
  Timer? _simulatorTimer;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _detectRefreshRate());
  }

  void _detectRefreshRate() {
    if (!mounted) {
      return;
    }
    final double hz = View.of(context).display.refreshRate;
    if (hz > 0) {
      setState(() {
        _detectedRefreshHz = hz;
        _dropThresholdMs = 1000.0 / hz;
      });
    }
  }

  @override
  void dispose() {
    _simulatorTimer?.cancel();
    _simulatorTimer = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _installSimulator(int blockMs) {
    _simulatorTimer?.cancel();
    if (blockMs <= 0) {
      _simulatorTimer = null;
      return;
    }
    final int blockUs = blockMs * 1000;
    _simulatorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < blockUs) {
        // Busy-loop: must actually block the UI isolate. A Future.delayed
        // would yield to the event loop, which is the opposite of what we
        // need to mimic a main-thread block.
      }
    });
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_capturing) {
      return;
    }
    int newDropped = 0;
    for (final FrameTiming t in timings) {
      final double ms = t.totalSpan.inMicroseconds / 1000.0;
      if (ms > _dropThresholdMs) {
        newDropped += 1;
      }
    }
    _samples.addAll(timings);
    _liveFrameCount = _samples.length;
    _liveDropped += newDropped;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _runScenario(_Scenario scenario) async {
    if (_running != null) {
      return;
    }
    setState(() {
      _running = scenario;
      _samples.clear();
      _liveFrameCount = 0;
      _liveDropped = 0;
      _capturing = false;
    });

    await _applyScenario(scenario);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    _samples.clear();
    _liveFrameCount = 0;
    _liveDropped = 0;
    setState(() => _capturing = true);

    try {
      await _autoScroll();
    } finally {
      setState(() => _capturing = false);
    }

    final _FrameStats stats = _FrameStats.fromTimings(
      _samples,
      dropThresholdMs: _dropThresholdMs,
    );
    final String csv =
        '[PERF] scenario=${scenario.label} ${stats.csv()}';
    // Use plain print() — debugPrint is intercepted by the recorder, and on
    // the iOS simulator the indirection swallows the line. print() goes
    // straight to the Dart VM's stdout sink.
    // ignore: avoid_print
    print(csv);

    setState(() {
      _history.add(_RunResult(label: scenario.label, stats: stats));
      _running = null;
    });
  }

  void _clearHistory() {
    setState(_history.clear);
  }

  Future<void> _copyHistory() async {
    if (_history.isEmpty) {
      return;
    }
    final StringBuffer buf = StringBuffer()
      ..writeln(
        'display=${_detectedRefreshHz.toStringAsFixed(0)}Hz  '
        'budget=${_dropThresholdMs.toStringAsFixed(2)}ms',
      );
    for (final _RunResult r in _history) {
      buf
        ..writeln()
        ..writeln(r.label)
        ..writeln(r.stats.prettyMultiline());
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Results copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _applyScenario(_Scenario scenario) async {
    // Always clear any previous simulator before applying a new scenario.
    _installSimulator(0);

    switch (scenario) {
      case _Scenario.baselineNoRecorder:
        if (recorder.isRecording) {
          await recorder.stop();
        }
        break;
      case _Scenario.recorderSnapshotsOff:
        if (!recorder.isRecording) {
          await recorder.start();
        }
        await WidgetsBinding.instance.endOfFrame;
        await recorder.stopSnapshotCapture();
        break;
      case _Scenario.recorderSnapshots500ms:
        await _ensureRecorderWithInterval(
          const Duration(milliseconds: 500),
        );
        break;
      case _Scenario.recorderSnapshots2000ms:
        await _ensureRecorderWithInterval(
          const Duration(milliseconds: 2000),
        );
        break;
      case _Scenario.simBlock10ms:
      case _Scenario.simBlock15ms:
      case _Scenario.simBlock25ms:
        if (recorder.isRecording) {
          await recorder.stop();
        }
        _installSimulator(scenario.simBlockMs);
        break;
    }
  }

  Future<void> _ensureRecorderWithInterval(Duration interval) async {
    final SessionRecorderConfig config = SessionRecorderConfig.lightweight(
      nativeSnapshotInterval: interval,
      // Replace with your app's domain when measuring against a real
      // backend; the noop transport below keeps the perf harness
      // self-contained for local-only measurements.
      recordingDomain: 'your-app.example.com',
    );
    await recorder.initialize(
      config: config,
      transport: const NoopSessionRecorderTransport(),
    );
  }

  Future<void> _autoScroll() async {
    final ScrollController controller = widget.scrollController;
    if (!controller.hasClients) {
      return;
    }
    final double maxExtent = controller.position.maxScrollExtent;
    if (maxExtent <= 0) {
      return;
    }
    for (int i = 0; i < _sweepCount; i++) {
      await controller.animateTo(
        maxExtent,
        duration: _sweepDuration,
        curve: Curves.linear,
      );
      await controller.animateTo(
        0,
        duration: _sweepDuration,
        curve: Curves.linear,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          left: 8,
          right: 8,
          top: MediaQuery.of(context).padding.top + 8,
          child: _HarnessPanel(
            running: _running,
            capturing: _capturing,
            liveFrameCount: _liveFrameCount,
            liveDropped: _liveDropped,
            refreshHz: _detectedRefreshHz,
            dropThresholdMs: _dropThresholdMs,
            history: _history,
            onRun: _runScenario,
            onClear: _clearHistory,
            onCopy: _copyHistory,
          ),
        ),
      ],
    );
  }
}

class _HarnessPanel extends StatelessWidget {
  const _HarnessPanel({
    required this.running,
    required this.capturing,
    required this.liveFrameCount,
    required this.liveDropped,
    required this.refreshHz,
    required this.dropThresholdMs,
    required this.history,
    required this.onRun,
    required this.onClear,
    required this.onCopy,
  });

  final _Scenario? running;
  final bool capturing;
  final int liveFrameCount;
  final int liveDropped;
  final double refreshHz;
  final double dropThresholdMs;
  final List<_RunResult> history;
  final ValueChanged<_Scenario> onRun;
  final VoidCallback onClear;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.of(context).size.height * 0.55;
    return Material(
      elevation: 4,
      color: Colors.black.withOpacity(0.82),
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  running == null
                      ? 'idle — pick a scenario'
                      : 'running: ${running!.label}'
                          '${capturing ? "  [capturing]" : "  [warmup]"}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'display=${refreshHz.toStringAsFixed(0)}Hz  '
                  'budget=${dropThresholdMs.toStringAsFixed(2)}ms',
                ),
                Text(
                  'live frames=$liveFrameCount  '
                  'dropped(>${dropThresholdMs.toStringAsFixed(1)}ms)='
                  '$liveDropped',
                ),
                if (history.isNotEmpty) ...<Widget>[
                  const Divider(color: Colors.white24, height: 14),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (final _RunResult r in history) ...<Widget>[
                            Text(
                              r.label,
                              style: const TextStyle(
                                color: Colors.amberAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(r.stats.prettyMultiline()),
                            const SizedBox(height: 6),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final _Scenario s in _Scenario.values)
                      _ScenarioButton(
                        label: s.label,
                        enabled: running == null,
                        onTap: () => onRun(s),
                      ),
                    if (history.isNotEmpty) ...<Widget>[
                      _ScenarioButton(
                        label: 'copy',
                        enabled: running == null,
                        onTap: onCopy,
                      ),
                      _ScenarioButton(
                        label: 'clear',
                        enabled: running == null,
                        onTap: onClear,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RunResult {
  const _RunResult({required this.label, required this.stats});
  final String label;
  final _FrameStats stats;
}

class _ScenarioButton extends StatelessWidget {
  const _ScenarioButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: enabled ? onTap : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
        textStyle: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
      child: Text(label),
    );
  }
}

class _FrameStats {
  _FrameStats({
    required this.frameCount,
    required this.p50,
    required this.p95,
    required this.p99,
    required this.maxMs,
    required this.dropped,
    required this.buildP99,
    required this.rasterP99,
  });

  final int frameCount;
  final double p50;
  final double p95;
  final double p99;
  final double maxMs;
  final int dropped;
  final double buildP99;
  final double rasterP99;

  static _FrameStats fromTimings(
    List<FrameTiming> samples, {
    required double dropThresholdMs,
  }) {
    if (samples.isEmpty) {
      return _FrameStats(
        frameCount: 0,
        p50: 0,
        p95: 0,
        p99: 0,
        maxMs: 0,
        dropped: 0,
        buildP99: 0,
        rasterP99: 0,
      );
    }
    final List<double> totals = samples
        .map((FrameTiming t) => t.totalSpan.inMicroseconds / 1000.0)
        .toList()
      ..sort();
    final List<double> builds = samples
        .map((FrameTiming t) => t.buildDuration.inMicroseconds / 1000.0)
        .toList()
      ..sort();
    final List<double> rasters = samples
        .map((FrameTiming t) => t.rasterDuration.inMicroseconds / 1000.0)
        .toList()
      ..sort();

    double pct(List<double> sorted, double p) {
      final int idx = ((sorted.length - 1) * p).round();
      return sorted[idx];
    }

    int dropped = 0;
    for (final double v in totals) {
      if (v > dropThresholdMs) {
        dropped += 1;
      }
    }

    return _FrameStats(
      frameCount: totals.length,
      p50: pct(totals, 0.5),
      p95: pct(totals, 0.95),
      p99: pct(totals, 0.99),
      maxMs: totals.last,
      dropped: dropped,
      buildP99: pct(builds, 0.99),
      rasterP99: pct(rasters, 0.99),
    );
  }

  String csv() {
    return 'frames=$frameCount '
        'p50=${p50.toStringAsFixed(2)} '
        'p95=${p95.toStringAsFixed(2)} '
        'p99=${p99.toStringAsFixed(2)} '
        'max=${maxMs.toStringAsFixed(2)} '
        'dropped=$dropped '
        'build_p99=${buildP99.toStringAsFixed(2)} '
        'raster_p99=${rasterP99.toStringAsFixed(2)}';
  }

  String prettyMultiline() {
    return 'frames=$frameCount dropped=$dropped\n'
        'total ms  p50=${p50.toStringAsFixed(1)}'
        '  p95=${p95.toStringAsFixed(1)}'
        '  p99=${p99.toStringAsFixed(1)}'
        '  max=${maxMs.toStringAsFixed(1)}\n'
        'build p99=${buildP99.toStringAsFixed(1)}'
        '  raster p99=${rasterP99.toStringAsFixed(1)}';
  }
}
