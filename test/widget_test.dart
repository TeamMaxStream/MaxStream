import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/main.dart';

void main() {
  testWidgets('ErrorApp surfaces a startup failure instead of a blank screen', (
    tester,
  ) async {
    await tester.pumpWidget(const ErrorApp(error: 'firebase unavailable'));

    expect(find.textContaining('Failed to initialize the app'), findsOneWidget);
    expect(find.textContaining('firebase unavailable'), findsOneWidget);
  });
}
