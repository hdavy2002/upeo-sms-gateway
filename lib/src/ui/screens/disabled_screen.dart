import 'package:flutter/material.dart';

/// [TAKEDOWN-HDFC-DARK-1 2026-09-20] Shown instead of [HomeShell]/[SetupScreen]
/// whenever `K.railDisabled` is true. The gateway service is never started and
/// no SMS is read while this screen is up — see main.dart and app.dart.
class DisabledScreen extends StatelessWidget {
  const DisabledScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.pause_circle_outline, size: 48),
              SizedBox(height: 16),
              Text(
                'This app is disabled',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                'The internal ₹1 test harness this app supports is currently '
                'turned off. It is not reading or sending any SMS.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
