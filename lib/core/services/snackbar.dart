import 'package:flutter/material.dart';

import 'package:calibre_web_companion/core/utils/network_error.dart';
import 'package:calibre_web_companion/l10n/app_localizations.dart';

/// English fallback used when localizations are unavailable (e.g. before the
/// localization delegates are wired up, or in tests).
const String kNetworkErrorFallbackMessage =
    "Can't reach your server. Check your connection or server URL.";

extension SnackBarExtension on BuildContext {
  void showSnackBar(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    // Raw network failures ("SocketException: ... errno = 61") are meaningless
    // to users, so replace them with a friendly, actionable message instead of
    // swallowing the feedback entirely.
    final String text =
        isError && isNetworkErrorMessage(message)
            ? (AppLocalizations.of(this)?.networkErrorGeneric ??
                kNetworkErrorFallbackMessage)
            : message;

    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor:
            isError
                ? Theme.of(this).colorScheme.error
                : Theme.of(this).colorScheme.primary,
        duration: duration,
      ),
    );
  }
}
