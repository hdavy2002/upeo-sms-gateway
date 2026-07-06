import 'package:flutter/material.dart';

import 'screens/about_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/reliability_screen.dart';
import 'screens/settings_screen.dart';

/// Bottom-navigation shell hosting the main screens.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _screens = [
    DashboardScreen(),
    LogsScreen(),
    ReliabilityScreen(),
    SettingsScreen(),
    AboutScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.list_alt), label: 'Log'),
          NavigationDestination(icon: Icon(Icons.shield), label: 'Reliability'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.info_outline), label: 'About'),
        ],
      ),
    );
  }
}
