// WebSocket 地址：部署到公网后把这里改成 wss://你的域名/ws/teleop
// Android 模拟器访问本机服务：ws://10.0.2.2:8000/ws/teleop
// 真机与电脑同一 WiFi：用电脑的局域网 IP，如 ws://192.168.1.10:8000/ws/teleop
const String kDefaultTeleopWsUrl = 'ws://10.0.2.2:8000/ws/teleop';
