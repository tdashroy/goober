import 'package:flutter/material.dart';

import 'src/api_client.dart';
import 'src/dev_login.dart';
import 'src/models.dart';
import 'src/screens/feed_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/theme.dart';
import 'src/token_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    GooberApp(
      api: ApiClient(),
      tokenStore: SharedPrefsTokenStore(),
      devLogin: DevLogin.fromEnvironment(),
    ),
  );
}

/// Root widget. The [api], [tokenStore] and [devLogin] are injected so widget
/// tests can drive the whole boot flow against fakes with no network or platform
/// storage.
class GooberApp extends StatelessWidget {
  const GooberApp({
    super.key,
    required this.api,
    required this.tokenStore,
    this.devLogin,
  });

  final ApiClient api;
  final TokenStore tokenStore;

  /// Set only in a debug build launched with a client profile: the app then boots
  /// already signed in as that seeded person instead of showing onboarding. Always
  /// null in a release build — see [DevLogin] for how that is enforced.
  final DevLogin? devLogin;

  @override
  Widget build(BuildContext context) {
    final dev = devLogin;
    Widget home = RootRouter(api: api, tokenStore: tokenStore, devLogin: dev);
    // Which relative is this window? With several emulators side by side, say it
    // on screen rather than making someone guess.
    if (dev != null) {
      home = Banner(
        message: dev.memberKey,
        location: BannerLocation.topEnd,
        color: GooberColors.coral,
        child: home,
      );
    }

    return MaterialApp(
      title: 'Goober',
      debugShowCheckedModeBanner: false,
      theme: buildGooberTheme(),
      home: home,
    );
  }
}

/// Decides the first screen: if a token is already persisted, go straight to the
/// feed; otherwise show onboarding. On successful onboarding it persists the
/// session and swaps to the feed.
class RootRouter extends StatefulWidget {
  const RootRouter({
    super.key,
    required this.api,
    required this.tokenStore,
    this.devLogin,
  });

  final ApiClient api;
  final TokenStore tokenStore;
  final DevLogin? devLogin;

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
    final session = await _devSession() ?? await widget.tokenStore.read();
    if (!mounted) return;
    setState(() {
      _session = session;
      _loading = false;
    });
  }

  /// The seeded person this build was launched as, signed in fresh from the
  /// server. It takes precedence over whatever token is already on the device, so
  /// relaunching an emulator as a different relative actually switches relative.
  ///
  /// Null — leaving the normal boot untouched — both when no profile is set and
  /// when the server cannot produce that session (it is not a seeded dev server,
  /// or is not up yet), so a missing seed falls back to onboarding rather than
  /// stranding the app.
  Future<Session?> _devSession() async {
    final dev = widget.devLogin;
    if (dev == null) return null;
    try {
      final session = await dev.signIn(widget.api);
      await widget.tokenStore.save(session);
      return session;
    } catch (error, stackTrace) {
      // Falling back to onboarding is intended, but doing it in silence is how a
      // broken dev harness passes for an unseeded one. Leave a trace: this only
      // runs in a debug build, since a profile is the sole way to get here.
      debugPrint('dev sign-in as "${dev.memberKey}" failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
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
