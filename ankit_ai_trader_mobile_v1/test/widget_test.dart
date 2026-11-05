import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ankit_ai_trader/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
      '1. Dashboard renders paper account, \$100 equity, connected state, and Trade alert notifications toggle',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(internetChecker: () async => true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ANKIT AI TRADER'), findsOneWidget);
    expect(find.text('PAPER TRADING MODE'), findsOneWidget);
    expect(find.text('Trade alert notifications'), findsOneWidget);
    expect(find.byKey(const Key('trade_alerts_toggle_switch')), findsOneWidget);
    expect(find.text('\$100.00'), findsWidgets);
    expect(find.text('INTERNET CONNECTED'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
