import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_app/main.dart';

void main() {
  testWidgets('login flow navigates to dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartDoorbellApp());
    await tester.pumpAndSettle();

    expect(find.text('Smart Doorbell Login'), findsOneWidget);

    final emailField = find.byType(TextFormField).first;
    final passField = find.byType(TextFormField).at(1);

    await tester.enterText(emailField, 'homeowner@smartdoor.com');
    await tester.enterText(passField, 'password123');

    await tester.tap(find.text('Login'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Smart Doorbell'), findsOneWidget);
    expect(find.text('Remote Unlock'), findsOneWidget);
  });

  testWidgets('signup navigation works', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartDoorbellApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text("Don't have an account? Sign up"));
    await tester.pumpAndSettle();

    expect(find.text('Sign Up'), findsOneWidget);
  });
}
