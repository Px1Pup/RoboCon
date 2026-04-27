import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:robo_trainer/config.dart';

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

class _TeleopHomePageState extends State<TeleopHomePage>
    with SingleTickerProviderStateMixin {
  final _urlController = TextEditingController(text: kDefaultTeleopOfferUrl);
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _rendererReady = false;
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  bool _streaming = false;
  bool _isConnecting = false;
  bool _teleopConnected = false;
  String _stateLabel = 'IDLE';
  String? _lastError;
  NativeDeviceOrientation _deviceOrientation = NativeDeviceOrientation.unknown;
  StreamSubscription<NativeDeviceOrientation>? _orientationSub;
  late final AnimationController _rotateHintController;

  String _friendlyConnectionLabel(dynamic state) {
    final raw = state.toString().toLowerCase();
    if (raw.contains('disconnected')) return 'DISCONNECTED';
    if (raw.contains('failed')) return 'FAILED';
    if (raw.contains('closed')) return 'CLOSED';
    if (raw.contains('connecting')) return 'CONNECTING';
    if (raw.contains('connected')) return 'LIVE';
    if (raw.contains('new')) return 'NEW';
    return 'CONNECTING';
  }

  bool get _isTargetOrientation =>
      _deviceOrientation == NativeDeviceOrientation.landscapeLeft;

  bool get _showRotateGuide => _teleopConnected && !_isTargetOrientation;

  Future<void> _waitIceGatheringComplete(
    RTCPeerConnection pc, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      final current = await pc.getIceGatheringState();
      if (current == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initRenderer());
    _rotateHintController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _orientationSub = NativeDeviceOrientationCommunicator()
        .onOrientationChanged(useSensor: true)
        .listen((orientation) {
      if (!mounted) return;
      setState(() {
        _deviceOrientation = orientation;
      });
    });
  }

  Future<void> _initRenderer() async {
    await _localRenderer.initialize();
    if (!mounted) return;
    setState(() {
      _rendererReady = true;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _orientationSub?.cancel();
    _rotateHintController.dispose();
    unawaited(_teardown(silent: true));
    if (_rendererReady) {
      unawaited(_localRenderer.dispose());
    }
    super.dispose();
  }

  Future<void> _teardown({bool silent = false}) async {
    final peer = _peer;
    final local = _localStream;
    _peer = null;
    _localStream = null;

    try {
      if (local != null) {
        for (final track in local.getTracks()) {
          await track.stop();
        }
        await local.dispose();
      }
    } catch (e) {
      if (!silent) {
        if (mounted) {
          setState(() => _lastError = e.toString());
        }
      }
    }

    try {
      if (peer != null) {
        await peer.close();
      }
    } catch (_) {
      // ignore
    }
    if (_rendererReady) {
      _localRenderer.srcObject = null;
    }

    if (mounted) {
      setState(() {
        _streaming = false;
        _isConnecting = false;
        _teleopConnected = false;
        _stateLabel = 'IDLE';
      });
    }
  }

  Future<void> _onStop() async {
    await _teardown();
  }

  Future<void> _onTeleop() async {
    if (_streaming || _isConnecting) return;
    setState(() {
      _lastError = null;
      _isConnecting = true;
      _stateLabel = 'CONNECTING';
    });

    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _lastError = '需要摄像头权限才能推流';
        _isConnecting = false;
        _stateLabel = 'IDLE';
      });
      return;
    }

    final offerUrl = _urlController.text.trim();
    if (offerUrl.isEmpty) {
      setState(() {
        _lastError = '请填写信令地址';
        _isConnecting = false;
        _stateLabel = 'IDLE';
      });
      return;
    }

    try {
      final localStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'ideal': 30, 'max': 30},
        }
      });
      _localStream = localStream;
      if (_rendererReady) {
        _localRenderer.srcObject = localStream;
      }

      final pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ],
        'sdpSemantics': 'unified-plan',
      });
      _peer = pc;

      for (final track in localStream.getVideoTracks()) {
        await pc.addTrack(track, localStream);
      }

      pc.onConnectionState = (state) {
        if (!mounted) return;
        final raw = state.toString().toLowerCase();
        setState(() {
          _stateLabel = _friendlyConnectionLabel(state);
          if (raw.contains('connected') && !raw.contains('disconnected')) {
            _teleopConnected = true;
          }
          if (raw.contains('failed') ||
              raw.contains('closed') ||
              raw.contains('disconnected')) {
            _teleopConnected = false;
          }
        });
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _waitIceGatheringComplete(pc);
      final localDesc = await pc.getLocalDescription();
      if (localDesc == null) {
        throw Exception('无法生成本地 SDP');
      }

      final resp = await http.post(
        Uri.parse(offerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'sdp': localDesc.sdp, 'type': localDesc.type}),
      );
      if (resp.statusCode != 200) {
        throw Exception('信令失败: ${resp.statusCode} ${resp.body}');
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      await pc.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String, data['type'] as String),
      );
    } catch (e) {
      await _teardown(silent: true);
      if (mounted) {
        setState(() {
          _lastError = '启动 WebRTC 失败: $e';
          _isConnecting = false;
          _stateLabel = 'IDLE';
        });
      }
      return;
    }

    setState(() {
      _streaming = true;
      _isConnecting = false;
      _stateLabel = 'LIVE';
      _teleopConnected = true;
    });
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
                        enabled: !(_streaming || _isConnecting),
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: Color(0xFFE0E1DD),
                        ),
                        decoration: const InputDecoration(
                          labelText: 'WebRTC 信令地址(HTTP)',
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
                          onPressed: (_streaming || _isConnecting)
                              ? null
                              : _onTeleop,
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
                          onPressed: (_streaming || _isConnecting)
                              ? _onStop
                              : null,
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
                        label: (_streaming || _isConnecting)
                            ? _stateLabel
                            : 'IDLE',
                        active: _streaming || _isConnecting,
                        activeColor: const Color(0xFF2A9D8F),
                      ),
                      const Spacer(),
                      Text(
                        _isConnecting
                            ? '正在建立teleop连接'
                            : (_streaming ? 'WebRTC 推流中' : '等待推流'),
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
                      child: _streaming && _rendererReady && _localRenderer.srcObject != null
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                RTCVideoView(
                                  _localRenderer,
                                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                                  mirror: true,
                                ),
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
                                if (_showRotateGuide)
                                  Positioned.fill(
                                    child: DecoratedBox(
                                      decoration: const BoxDecoration(
                                        color: Color(0x66000000),
                                      ),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            RotationTransition(
                                              turns: Tween<double>(
                                                begin: 0,
                                                end: -1,
                                              ).animate(_rotateHintController),
                                              child: const Icon(
                                                Icons.rotate_left_rounded,
                                                size: 68,
                                                color: Color(0xFF4CC9F0),
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            Text(
                                              _deviceOrientation ==
                                                      NativeDeviceOrientation
                                                          .portraitUp
                                                  ? '请逆时针旋转手机90°至目标横屏位置'
                                                  : '请继续旋转手机至目标横屏位置',
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: Color(0xFFE0E1DD),
                                                fontSize: 13,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
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
