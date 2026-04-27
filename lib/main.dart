import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:robo_trainer/config.dart';
import 'package:robo_trainer/teleop_jpeg.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RoboTrainerApp());
}

class RoboTrainerApp extends StatelessWidget {
  const RoboTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0D1B2A);
    return MaterialApp(
      title: 'Robo Trainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
          primary: const Color(0xFF4CC9F0),
          surface: const Color(0xFF0D1B2A),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D1B2A),
          foregroundColor: Color(0xFFE0E1DD),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1B2A),
        fontFamily: 'Roboto',
      ),
      home: const TeleopHomePage(),
    );
  }
}

class TeleopHomePage extends StatefulWidget {
  const TeleopHomePage({super.key});

  @override
  State<TeleopHomePage> createState() => _TeleopHomePageState();
}

class _TeleopHomePageState extends State<TeleopHomePage> {
  final _urlController = TextEditingController(text: kDefaultTeleopWsUrl);
  WebSocketChannel? _channel;
  CameraController? _camera;
  bool _streaming = false;
  int _streamTick = 0;
  int _framesSent = 0;
  String? _lastError;

  @override
  void dispose() {
    _urlController.dispose();
    unawaited(_teardown(silent: true));
    super.dispose();
  }

  Future<void> _teardown({bool silent = false}) async {
    final c = _camera;
    _camera = null;
    try {
      if (c != null) {
        if (c.value.isStreamingImages) {
          await c.stopImageStream();
        }
        await c.dispose();
      }
    } catch (e) {
      if (!silent) {
        if (mounted) {
          setState(() => _lastError = e.toString());
        }
      }
    }
    try {
      await _channel?.sink.close();
    } catch (_) {
      // ignore
    }
    _channel = null;
    if (mounted) {
      setState(() {
        _streaming = false;
      });
    }
  }

  Future<void> _onStop() async {
    await _teardown();
  }

  Future<void> _onTeleop() async {
    if (_streaming) return;
    setState(() {
      _lastError = null;
    });

    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _lastError = '需要摄像头权限才能推流';
      });
      return;
    }

    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _lastError = '请填写 WebSocket 地址');
      return;
    }

    final cameras = await availableCameras();
    CameraDescription? front;
    for (final c in cameras) {
      if (c.lensDirection == CameraLensDirection.front) {
        front = c;
        break;
      }
    }
    if (front == null) {
      if (mounted) {
        setState(
          () => _lastError = '未找到前置摄像头',
        );
      }
      return;
    }

    WebSocketChannel? ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse(url));
      // 等待一帧，尽早暴露连接错误
      await ch.ready;
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastError = '无法连接服务器: $e';
        });
      }
      return;
    }

    final controller = CameraController(
      front,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await controller.initialize();
    } catch (e) {
      await ch.sink.close();
      if (mounted) {
        setState(() {
          _lastError = '摄像头初始化失败: $e';
        });
      }
      return;
    }

    _streamTick = 0;
    _framesSent = 0;
    _channel = ch;
    _camera = controller;
    setState(() {
      _streaming = true;
    });

    unawaited(
      controller.startImageStream((CameraImage frame) {
        if (!_streaming || _camera != controller) return;
        _streamTick++;
        // 约 1/2 帧率，减轻 CPU 与带宽
        if (_streamTick % 2 != 0) {
          return;
        }
        final chLocal = _channel;
        if (chLocal == null) return;
        final jpeg = yuv420ToJpegColor(
          frame,
          quality: 60,
          maxWidth: 480,
        );
        if (jpeg == null) return;
        try {
          chLocal.sink.add(jpeg);
          _framesSent++;
          if (mounted && (_framesSent % 10 == 0)) {
            setState(() {});
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _lastError = '发送失败: $e';
            });
            unawaited(_onStop());
          }
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Robo Teleop'),
        centerTitle: true,
        elevation: 0,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF415A77),
                        width: 1,
                      ),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF1B263B),
                          Color(0xFF0D1B2A),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: TextField(
                        controller: _urlController,
                        enabled: !_streaming,
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: Color(0xFFE0E1DD),
                        ),
                        decoration: const InputDecoration(
                          labelText: 'WebSocket 地址',
                          labelStyle: TextStyle(color: Color(0xFF778DA9)),
                          border: InputBorder.none,
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _streaming ? null : _onTeleop,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2A9D8F),
                            foregroundColor: const Color(0xFF0D1B2A),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'TELEOP',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _streaming ? _onStop : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF415A77),
                            foregroundColor: const Color(0xFFE0E1DD),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'STOP',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      _StatusChip(
                        label: _streaming ? 'LIVE' : 'IDLE',
                        active: _streaming,
                        activeColor: const Color(0xFF2A9D8F),
                      ),
                      const Spacer(),
                      Text(
                        '已发帧: $_framesSent',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  if (_lastError != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _lastError!,
                      style: const TextStyle(
                        color: Color(0xFFF4A261),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: _streaming && _camera != null
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                CameraPreview(_camera!),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                    ),
                                    color: const Color(0x66000000),
                                    child: const Text(
                                      'FRONT · PREVIEW',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Color(0xFFE0E1DD),
                                        fontSize: 11,
                                        letterSpacing: 0.6,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ColoredBox(
                              color: const Color(0xFF1B263B),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.videocam_outlined,
                                      size: 48,
                                      color: colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.4),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '按 TELEOP 开始',
                                      style: TextStyle(
                                        color: colorScheme.onSurfaceVariant,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.active,
    required this.activeColor,
  });

  final String label;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? activeColor.withValues(alpha: 0.2) : const Color(0xFF1B263B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? activeColor : const Color(0xFF415A77),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: active ? activeColor : const Color(0xFF778DA9),
        ),
      ),
    );
  }
}
