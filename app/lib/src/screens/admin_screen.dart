import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import 'manage_places_screen.dart';

/// One row on the admin screen: what it is called, what it is for, and the
/// screen it opens. A future admin-only feature becomes another entry in
/// [_AdminScreenState._actions] — it does not need its own entry point
/// elsewhere in the app.
class _AdminAction {
  const _AdminAction({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.open,
  });

  final Key key;
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder open;
}

/// The group admin's home for the things only an admin can do.
///
/// Admin features are gathered behind this one labeled door instead of each
/// hanging off its own unlabeled shortcut somewhere in the app, so an admin has
/// a single obvious place to look and a member is never shown a control they
/// cannot use. Reaching it requires an admin-only entry point, and the server
/// enforces every action here regardless of what the client chooses to show.
class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.api,
    required this.session,
    this.onUnauthenticated,
  });

  final ApiClient api;
  final Session session;

  /// Forwarded to the screens opened from here so a stale persisted token drops
  /// the session back to onboarding rather than looping on a failing request.
  final VoidCallback? onUnauthenticated;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late final List<_AdminAction> _actions = [
    _AdminAction(
      key: const Key('manage-places-action'),
      icon: Icons.place,
      title: 'Manage places',
      subtitle:
          'Add, edit, and remove the houses and landmarks your group rides '
          'between.',
      open: (_) => ManagePlacesScreen(
        api: widget.api,
        session: widget.session,
        onUnauthenticated: widget.onUnauthenticated,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView.separated(
        // The banner sits above the actions, hence the extra leading item.
        itemCount: _actions.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == 0) return const _AdminOnlyNote();
          final action = _actions[i - 1];
          return ListTile(
            key: action.key,
            leading: Icon(action.icon, color: GooberColors.coral),
            title: Text(action.title),
            subtitle: Text(action.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: action.open)),
          );
        },
      ),
    );
  }
}

/// Spells out that this area is admin-only, so an admin knows the controls here
/// are ones their group's members never see.
class _AdminOnlyNote extends StatelessWidget {
  const _AdminOnlyNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: GooberColors.cartTeal),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "You're a group admin. Only you see these controls — members "
              'see the results of what you set up here.',
              style: TextStyle(fontSize: 15, color: GooberColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}
