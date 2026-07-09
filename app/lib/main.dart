import 'package:flutter/material.dart';

import 'src/api_client.dart';
import 'src/models.dart';
import 'src/screens/feed_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/theme.dart';
import 'src/token_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GooberApp(api: ApiClient(), tokenStore: SharedPrefsTokenStore()));
}

/// Root widget. Both the [api] and [tokenStore] are injected so widget tests can
/// drive the whole boot flow against fakes with no network or platform storage.
class GooberApp extends StatelessWidget {
  const GooberApp({super.key, required this.api, required this.tokenStore});

  final ApiClient api;
  final TokenStore tokenStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Goober',
      debugShowCheckedModeBanner: false,
      theme: buildGooberTheme(),
      home: RootRouter(api: api, tokenStore: tokenStore),
    );
  }
}

/// Decides the first screen: if a token is already persisted, go straight to the
/// feed; otherwise show onboarding. On successful onboarding it persists the
/// session and swaps to the feed.
class RootRouter extends StatefulWidget {
  const RootRouter({super.key, required this.api, required this.tokenStore});

  final ApiClient api;
  final TokenStore tokenStore;

  @override
  State<RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<RootRouter> {
  Session? _session;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final session = await widget.tokenStore.read();
    if (!mounted) return;
    setState(() {
      _session = session;
      _loading = false;
    });
  }

  Future<void> _onAuthenticated(Session session) async {
    await widget.tokenStore.save(session);
    if (!mounted) return;
    setState(() => _session = session);
  }

  /// The persisted token was rejected (401). Drop it and fall back to
  /// onboarding so the user can re-join into a fresh, valid session.
  Future<void> _onUnauthenticated() async {
    await widget.tokenStore.clear();
    if (!mounted) return;
    setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final session = _session;
    if (session == null) {
      return OnboardingScreen(
        api: widget.api,
        onAuthenticated: _onAuthenticated,
      );
    }
    return FeedScreen(
      api: widget.api,
      session: session,
      onUnauthenticated: _onUnauthenticated,
    );
  }
}
