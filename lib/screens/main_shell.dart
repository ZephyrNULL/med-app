import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/active_alarm_banner.dart';
import '../widgets/wrong_bay_banner.dart';
import 'home_screen.dart';
import 'medicine_screen.dart';
import 'alert_screen.dart';
import 'profile_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  void setTab(int index) => setState(() => _index = index);

  late final _screens = <Widget>[
    HomeScreen(onNavigate: setTab),
    const MedicineScreen(),
    const AlertScreen(),
    const ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = appState.repo;

    return Scaffold(
      body: Column(
        children: [
          // A ringing alarm is shown on every tab so it cannot be missed
          // by staying on Home/Medicine/Profile. Identical for both roles;
          // only the caregiver gets the "Stop Alarm" button. Gated on the
          // box actually reporting, so a stale unresolved event restored
          // from the DB cannot keep a phantom banner alive.
          if (repo.showActiveAlarm)
            ActiveAlarmBanner(isCaregiver: appState.isCaregiver),
          // A wrong-bay warning has its own banner on its own alarm channel,
          // so it can ring and clear independently of a reminder banner
          // (both may be up at once: wrong container out, dose due).
          if (repo.showWrongBayAlarm)
            WrongBayBanner(isCaregiver: appState.isCaregiver),
          Expanded(
            child: IndexedStack(index: _index, children: _screens),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.medication_outlined),
            selectedIcon: Icon(Icons.medication),
            label: 'Medicine',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}