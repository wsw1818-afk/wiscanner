import 'package:flutter_test/flutter_test.dart';
import 'package:wiscaner/app.dart';

void main() {
  testWidgets('WiScanerApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const WiScanerApp());
    expect(find.text('WiScaner'), findsOneWidget);
  });
}
