import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/splash.dart';

void main() {
  testWidgets('splash plays, fades out and reports done', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(home: TropaSplash(onDone: () => done++)));
    await tester.pump(const Duration(milliseconds: 900));
    expect(done, 0);
    await tester.pump(const Duration(milliseconds: 1100)); // the walk ends
    await tester.pump(const Duration(milliseconds: 600)); // short hold
    await tester.pump(const Duration(milliseconds: 400)); // fade
    expect(done, 1);
  });

  testWidgets('a tap skips the splash', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(home: TropaSplash(onDone: () => done++)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byType(TropaSplash));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(done, 1);
  });
}
