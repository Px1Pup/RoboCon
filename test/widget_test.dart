// Basic smoke test: app builds and shows teleop button.

import 'package:flutter_test/flutter_test.dart';
import 'package:robo_trainer/main.dart';

void main() {
  testWidgets('Teleop and Stop buttons present', (WidgetTester tester) async {
    await tester.pumpWidget(const RoboTrainerApp());
    expect(find.text('TELEOP'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
  });
}
