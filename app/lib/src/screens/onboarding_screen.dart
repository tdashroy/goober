import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';

/// First-run screen. For the walking skeleton this starts a new trip: the person
/// enters a trip name + their own name + phone, which creates a group with them
/// as its admin and returns the bearer token the app persists.
///
/// (Joining an existing group by id is exercised by [ApiClient.joinGroup] and the
/// server tests; the invite-link join flow comes later.)
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.api,
    required this.onAuthenticated,
  });

  final ApiClient api;

  /// Called with the new [Session] after a successful create, so the app can
  /// persist the token and move to the feed.
  final ValueChanged<Session> onAuthenticated;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tripController = TextEditingController(text: 'Beach 2027');
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _tripController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final session = await widget.api.createGroup(
        groupName: _tripController.text.trim(),
        name: _nameController.text.trim(),
        phone: _phoneController.text.trim(),
      );
      widget.onAuthenticated(session);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = "Couldn't reach Goober — is the server running?");
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _required(String? v, String label) =>
      (v == null || v.trim().isEmpty) ? 'Enter $label' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🥜 Goober')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Start your beach trip',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'You’ll be the trip’s admin. Everyone else can join after.',
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _tripController,
                decoration: const InputDecoration(
                  labelText: 'Trip name',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => _required(v, 'a trip name'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
                validator: (v) => _required(v, 'your name'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  border: OutlineInputBorder(),
                ),
                // Phone-typed field so OS autofill offers the number.
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                validator: (v) => _required(v, 'your phone number'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: GooberColors.coral),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 56,
                child: FilledButton(
                  key: const Key('create-group-button'),
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: GooberColors.cartTeal,
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Start the trip'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
