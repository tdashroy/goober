import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models.dart';

/// Which seeded person this build signs in as, from
/// `--dart-define=CLIENT_PROFILE=bob`. Empty in a normal build.
const String _clientProfileDefine = String.fromEnvironment('CLIENT_PROFILE');

/// A dev launch profile: boot the app already signed in as one of the people the
/// server's seed profile created, so testing a multi-person flow doesn't mean
/// typing a name and a phone number into every emulator.
///
/// ## This is an auth bypass, and it cannot survive a release build
///
/// Signing in without proving who you are is exactly what the app must never do
/// in anyone's hands. Two independent things have to be true for it to happen,
/// and neither is true of a shipped app:
///
/// 1. **The app must be a debug build.** [fromEnvironment] returns `null` unless
///    [kDebugMode], which the compiler folds to a constant `false` in release and
///    profile builds — the sign-in path is then dead code and is tree-shaken out.
///    A release APK built *with* `--dart-define=CLIENT_PROFILE=bob` ignores it and
///    shows the normal onboarding screen.
/// 2. **The server must be a dev-seed build that has been seeded.** The only
///    session this can obtain comes from the server's `/dev/session/{key}` route,
///    which exists solely in a server compiled with its `dev-seed` feature and
///    only ever resolves a *seeded* member. A production server has no such URL,
///    so there is nothing for a tampered client to call.
///
/// With no profile set, boot is unchanged: persisted token, or onboarding.
@immutable
class DevLogin {
  const DevLogin(this.memberKey);

  /// The seeded person's handle — `bob`, `grandma` — matching a member of the
  /// server's seed profile.
  final String memberKey;

  /// The profile this build was compiled with, or `null` for a normal boot.
  /// Always `null` outside a debug build, whatever was defined at build time.
  static DevLogin? fromEnvironment() =>
      resolve(profile: _clientProfileDefine, debugBuild: kDebugMode);

  /// The gate itself, with its two inputs passed in so a test can prove that a
  /// non-debug build refuses a profile it would otherwise honor.
  @visibleForTesting
  static DevLogin? resolve({
    required String profile,
    required bool debugBuild,
  }) {
    if (!debugBuild) return null;
    final key = profile.trim();
    if (key.isEmpty) return null;
    return DevLogin(key);
  }

  /// Fetch the seeded person's session (their real bearer token) from the server.
  Future<Session> signIn(ApiClient api) => api.devSession(memberKey: memberKey);
}
