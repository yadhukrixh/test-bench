import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Throwaway Phase 0 fixture. Screens exist so spikes can measure touch,
/// inspector selection, and HTTP profiling against known behavior.
void main() {
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spike Fixture',
      home: const TouchLab(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Spike Fixture')),
      body: ListView(
        children: [
          ListTile(
            key: const Key('open_touch'),
            title: const Text('Touch lab'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TouchLab()),
              );
            },
          ),
          ListTile(
            key: const Key('open_text'),
            title: const Text('Text lab'),
            subtitle: const Text('ログイン'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TextLab()),
              );
            },
          ),
          ListTile(
            key: const Key('open_network'),
            title: const Text('Network lab'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const NetworkLab()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class TouchLab extends StatefulWidget {
  const TouchLab({super.key});

  @override
  State<TouchLab> createState() => _TouchLabState();
}

class _TouchLabState extends State<TouchLab> {
  Color _color = const Color(0xFFFFFFFF);
  String _report = 'no-touch';

  void _hit(Offset local, double dpr) {
    final px = local.dx * dpr;
    final py = local.dy * dpr;
    setState(() {
      _color = _color == const Color(0xFFFFFFFF)
          ? const Color(0xFFFF0000)
          : const Color(0xFFFFFFFF);
      _report =
          'logical ${local.dx.toStringAsFixed(2)},${local.dy.toStringAsFixed(2)} '
          'px ${px.toStringAsFixed(1)},${py.toStringAsFixed(1)} dpr ${dpr.toStringAsFixed(3)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => _hit(details.localPosition, dpr),
        child: ColoredBox(
          color: _color,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 80, left: 16, right: 16),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    _report,
                    key: const Key('touch_report'),
                    style: const TextStyle(fontSize: 18, color: Color(0xFF000000)),
                  ),
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    key: const Key('open_text'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const TextLab()),
                      );
                    },
                    child: const Text('Text'),
                  ),
                  TextButton(
                    key: const Key('open_network'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const NetworkLab()),
                      );
                    },
                    child: const Text('Network'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TextLab extends StatefulWidget {
  const TextLab({super.key});

  @override
  State<TextLab> createState() => _TextLabState();
}

class _TextLabState extends State<TextLab> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Text lab')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Hello from the spike fixture'),
            const SizedBox(height: 12),
            const Text('ログインして続行'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('paste_field'),
              controller: _controller,
              decoration: const InputDecoration(labelText: 'Paste here'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Text('field: ${_controller.text}', key: const Key('field_echo')),
          ],
        ),
      ),
    );
  }
}

class NetworkLab extends StatefulWidget {
  const NetworkLab({super.key});

  @override
  State<NetworkLab> createState() => _NetworkLabState();
}

class _NetworkLabState extends State<NetworkLab> {
  String _status = 'idle';

  Future<void> _run() async {
    setState(() => _status = 'running');
    final notes = <String>[];
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('https://example.com/dart-io'));
      request.headers.contentType = ContentType.json;
      request.add('{"source":"dart:io"}'.codeUnits);
      final response = await request.close();
      await response.drain<void>();
      notes.add('dart:io ${response.statusCode}');
    } catch (error) {
      notes.add('dart:io error');
    } finally {
      client.close();
    }
    try {
      final response = await http.get(Uri.parse('https://example.com/http-pkg'));
      notes.add('http ${response.statusCode}');
    } catch (error) {
      notes.add('http error');
    }
    try {
      final response = await Dio().get<String>('https://example.com/dio-pkg');
      notes.add('dio ${response.statusCode}');
    } catch (error) {
      notes.add('dio error');
    }
    setState(() => _status = notes.join(' | '));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network lab')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton(
              key: const Key('fire_dart_io'),
              onPressed: _run,
              child: const Text('GET example.com via dart:io'),
            ),
            const SizedBox(height: 12),
            Text(_status, key: const Key('net_status')),
          ],
        ),
      ),
    );
  }
}
