import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';

/// The group's curated places — houses and landmarks with map coordinates.
///
/// Every member sees the list. The group's admin also gets add / edit / delete
/// affordances; for non-admins the screen is read-only (and the server enforces
/// that regardless of what the client shows).
///
/// Coordinates are entered as plain latitude/longitude numbers for now. A richer
/// drop-a-pin-on-a-map picker is deliberately deferred — the data and API it
/// would feed already exist here.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({
    super.key,
    required this.api,
    required this.session,
    this.onUnauthenticated,
  });

  final ApiClient api;
  final Session session;

  /// Called if a request comes back 401 (a stale persisted token), so the app
  /// can drop the token and return to onboarding rather than looping.
  final VoidCallback? onUnauthenticated;

  bool get isAdmin => session.member.isAdmin;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  late Future<Places> _placesFuture;

  @override
  void initState() {
    super.initState();
    _placesFuture = _load();
  }

  Future<Places> _load() async {
    try {
      return await widget.api.fetchPlaces(
        groupId: widget.session.groupId,
        token: widget.session.token,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        widget.onUnauthenticated?.call();
      }
      rethrow;
    }
  }

  void _reload() => setState(() => _placesFuture = _load());

  /// Run a mutation, showing a spinner via an updated future, and surface any
  /// error as a snackbar without losing the current list.
  Future<void> _mutate(Future<Places> Function() action) async {
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() {
        _placesFuture = Future.value(updated);
      });
    } on ApiException catch (e) {
      if (e.statusCode == 401) widget.onUnauthenticated?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addPlace() async {
    final draft = await showDialog<_PlaceDraft>(
      context: context,
      builder: (_) => const PlaceEditDialog(),
    );
    if (draft == null) return;
    await _mutate(
      () => widget.api.createPlace(
        groupId: widget.session.groupId,
        token: widget.session.token,
        name: draft.name,
        lat: draft.lat,
        lng: draft.lng,
      ),
    );
  }

  Future<void> _editPlace(Place place) async {
    final draft = await showDialog<_PlaceDraft>(
      context: context,
      builder: (_) => PlaceEditDialog(existing: place),
    );
    if (draft == null) return;
    await _mutate(
      () => widget.api.updatePlace(
        groupId: widget.session.groupId,
        token: widget.session.token,
        placeId: place.id,
        name: draft.name,
        lat: draft.lat,
        lng: draft.lng,
      ),
    );
  }

  /// Thin "copy last year's places" starting point: the admin pastes the id of
  /// another group they ran and its places are copied in as an editable base.
  /// A nicer picker over the admin's own past groups is deferred until the app
  /// tracks group history — the server already does the copy.
  Future<void> _copyFromGroup() async {
    final fromGroupId = await showDialog<String>(
      context: context,
      builder: (_) => const CopyFromGroupDialog(),
    );
    if (fromGroupId == null) return;
    await _mutate(
      () => widget.api.copyPlaces(
        groupId: widget.session.groupId,
        token: widget.session.token,
        fromGroupId: fromGroupId,
      ),
    );
  }

  Future<void> _deletePlace(Place place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${place.name}”?'),
        content: const Text(
          'This removes the place for everyone in the group.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-place'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mutate(
      () => widget.api.deletePlace(
        groupId: widget.session.groupId,
        token: widget.session.token,
        placeId: place.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Places'),
        actions: [
          if (widget.isAdmin)
            PopupMenuButton<String>(
              key: const Key('places-menu-button'),
              onSelected: (value) {
                if (value == 'copy') _copyFromGroup();
              },
              itemBuilder: (_) => const [
                PopupMenuItem<String>(
                  key: Key('copy-places-menu-item'),
                  value: 'copy',
                  child: Text('Copy from another group'),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: widget.isAdmin
          ? FloatingActionButton.extended(
              key: const Key('add-place-button'),
              onPressed: _addPlace,
              backgroundColor: GooberColors.cartTeal,
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Add place'),
            )
          : null,
      body: FutureBuilder<Places>(
        future: _placesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _PlacesError(error: snapshot.error, onRetry: _reload);
          }
          final places = snapshot.data;
          if (places == null || places.isEmpty) {
            return EmptyPlaces(isAdmin: widget.isAdmin);
          }
          return ListView.separated(
            itemCount: places.places.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final place = places.places[i];
              return ListTile(
                key: Key('place-${place.id}'),
                leading: const Icon(Icons.place, color: GooberColors.coral),
                title: Text(place.name),
                subtitle: Text(_formatCoords(place.lat, place.lng)),
                trailing: widget.isAdmin
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: Key('edit-place-${place.id}'),
                            icon: const Icon(Icons.edit),
                            onPressed: () => _editPlace(place),
                          ),
                          IconButton(
                            key: Key('delete-place-${place.id}'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deletePlace(place),
                          ),
                        ],
                      )
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}

String _formatCoords(double lat, double lng) =>
    '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

/// Friendly empty state. Admins get a nudge to add the first place; members are
/// told the admin hasn't added any yet.
class EmptyPlaces extends StatelessWidget {
  const EmptyPlaces({super.key, required this.isAdmin});

  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📍', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            const Text(
              'No places yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              isAdmin
                  ? 'Add the houses and landmarks your group will ride between.'
                  : "Your group's admin hasn't added any places yet.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: GooberColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlacesError extends StatelessWidget {
  const _PlacesError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException
        ? (error as ApiException).message
        : "Couldn't reach Goober";
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😵', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// Prompts the admin for the id of a group to copy places from. Pops the
/// trimmed id on confirm, or null on cancel.
class CopyFromGroupDialog extends StatefulWidget {
  const CopyFromGroupDialog({super.key});

  @override
  State<CopyFromGroupDialog> createState() => _CopyFromGroupDialogState();
}

class _CopyFromGroupDialogState extends State<CopyFromGroupDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Copy places'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Paste another group's id to copy its places in as a starting "
            'point. You can then edit the list.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('copy-from-group-field'),
            controller: _controller,
            decoration: const InputDecoration(labelText: 'Group id'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-copy-places'),
          onPressed: () {
            final id = _controller.text.trim();
            if (id.isEmpty) return;
            Navigator.of(context).pop(id);
          },
          child: const Text('Copy'),
        ),
      ],
    );
  }
}

/// The validated values a create/edit dialog hands back.
class _PlaceDraft {
  const _PlaceDraft({required this.name, required this.lat, required this.lng});
  final String name;
  final double lat;
  final double lng;
}

/// Add/edit form for a place: a name plus latitude/longitude. Pops a
/// [_PlaceDraft] on save, or null on cancel.
class PlaceEditDialog extends StatefulWidget {
  const PlaceEditDialog({super.key, this.existing});

  /// When set, the dialog pre-fills for editing; otherwise it's a fresh add.
  final Place? existing;

  @override
  State<PlaceEditDialog> createState() => _PlaceEditDialogState();
}

class _PlaceEditDialogState extends State<PlaceEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _lat;
  late final TextEditingController _lng;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _lat = TextEditingController(text: e == null ? '' : e.lat.toString());
    _lng = TextEditingController(text: e == null ? '' : e.lng.toString());
  }

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  String? _validateLat(String? raw) => _validateCoord(raw, 90, 'Latitude');
  String? _validateLng(String? raw) => _validateCoord(raw, 180, 'Longitude');

  String? _validateCoord(String? raw, double limit, String label) {
    final value = double.tryParse((raw ?? '').trim());
    if (value == null) return '$label must be a number';
    if (value < -limit || value > limit) return '$label must be ≤ $limit';
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _PlaceDraft(
        name: _name.text.trim(),
        lat: double.parse(_lat.text.trim()),
        lng: double.parse(_lng.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit place' : 'Add place'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('place-name-field'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: "e.g. Grandma's",
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            TextFormField(
              key: const Key('place-lat-field'),
              controller: _lat,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: _validateLat,
            ),
            TextFormField(
              key: const Key('place-lng-field'),
              controller: _lng,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: _validateLng,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-place-button'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
