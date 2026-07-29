import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:calibre_web_companion/features/settings/bloc/settings_bloc.dart';

class AppTransitions {
  AppTransitions._();

  static bool _isEInkMode(BuildContext context) {
    // The bloc lives above the navigator, but a route can also be built in
    // contexts where it isn't reachable (isolated widget tests/previews).
    try {
      return context.read<SettingsBloc>().state.isEInkMode;
    } catch (_) {
      return false;
    }
  }

  static Widget slideTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_isEInkMode(context)) {
      return child;
    }

    const begin = Offset(1.0, 0.0);
    const end = Offset.zero;
    const curve = Curves.ease;

    final tween = Tween(begin: begin, end: end);
    final curvedAnimation = CurvedAnimation(parent: animation, curve: curve);

    return SlideTransition(
      position: tween.animate(curvedAnimation),
      child: child,
    );
  }

  /// Builds a route for [page] using the platform-appropriate transition.
  ///
  /// On iOS this is a [CupertinoPageRoute] so the system back-swipe gesture
  /// (drag from the left screen edge) works. A bare [PageRouteBuilder] does
  /// not mix in `CupertinoRouteTransitionMixin`, which silently disables that
  /// gesture on every screen it pushes.
  ///
  /// Android keeps the custom horizontal slide, so its behaviour is unchanged.
  /// E-Ink mode suppresses the animation on both platforms.
  static Route<T> createSlideRoute<T>(Widget page) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _EInkAwareCupertinoPageRoute<T>(builder: (_) => page);
    }

    return PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: slideTransition,
    );
  }
}

/// A [CupertinoPageRoute] that drops the push/pop animation in E-Ink mode
/// while keeping the interactive back-swipe gesture intact.
///
/// The gesture detector is installed by
/// [CupertinoRouteTransitionMixin.buildPageTransitions], so E-Ink mode cannot
/// simply return the child unwrapped — that would disable the swipe again.
/// Instead the transition is fed constant animations, which renders the page
/// in its final position with no motion. As soon as the user starts dragging
/// back, the real animations are used again so the page follows the finger.
class _EInkAwareCupertinoPageRoute<T> extends CupertinoPageRoute<T> {
  _EInkAwareCupertinoPageRoute({required super.builder});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!popGestureInProgress && AppTransitions._isEInkMode(context)) {
      return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
        this,
        context,
        kAlwaysCompleteAnimation,
        kAlwaysDismissedAnimation,
        child,
      );
    }

    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
