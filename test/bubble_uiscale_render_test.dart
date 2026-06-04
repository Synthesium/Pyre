// Pyre 1.1 — F2 (chat bubble customization) + F5 (global UI text-scale):
// render-level coverage for the two VISUAL 1.1 features.
//
// Both features live in PRIVATE widgets in app code (`_BubbleSurface` in
// chat_screen.dart, `_UiScaleWrap` + `_MultipliedTextScaler` in main.dart),
// so they can't be pumped directly from a test. Following the project's
// existing convention (see the `_splitByTopLabels` / `_completionClaimPattern`
// replicas in widget_test.dart), these tests RE-DERIVE the exact same mapping
// the production code uses and pump a faithful mini-widget, then assert the
// observable result:
//   • F2 — ChatSettings → BoxDecoration (color = base × bubbleAlpha,
//          borderRadius = bubbleCornerRadius) + a BackdropFilter present iff
//          bubbleBlurSigma > 0. Mirrors chat_screen.dart lines ~3694–3726 and
//          the `_BubbleSurface.build` structure.
//   • F5 — a TextScaler that multiplies an ambient scaler by uiScale, then
//          clamps into [UiPrefs.kUiScaleMin, kUiScaleMax]. Mirrors
//          `_MultipliedTextScaler` + the clamp in `_UiScaleWrap.build`.
//
// If either production derivation changes, the relevant test below should be
// updated in lockstep — the doc comment in each group records the source.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/theme.dart';

// ---------------------------------------------------------------------------
// F2 — bubble decoration (faithful replica of chat_screen.dart's derivation)
// ---------------------------------------------------------------------------

/// The resolved bubble look, derived from [settings] for a [isUser] turn
/// exactly as `chat_screen.dart` does (the lines that compute `bubbleColor`,
/// `bubbleRadius`, `bubbleBorder`, `bubbleBlur`). Non-empty-variant case only
/// (the normal, filled bubble) — the empty-variant ghost slot is a separate UI
/// state not under test here.
({Color color, BorderRadius radius, Border? border, double blur})
    _resolveBubbleLook(ChatSettings settings, {required bool isUser}) {
  final int? roleColorArgb =
      isUser ? settings.userBubbleColor : settings.aiBubbleColor;
  final Color base =
      roleColorArgb != null ? Color(roleColorArgb) : EmberColors.bgPanel;
  final Color color = base.withValues(alpha: settings.bubbleAlpha);
  final BorderRadius radius =
      BorderRadius.circular(settings.bubbleCornerRadius);
  final Border? border = settings.bubbleBorderWidth > 0
      ? Border.all(
          color: settings.bubbleBorderColor != null
              ? Color(settings.bubbleBorderColor!)
              : EmberColors.stroke,
          width: settings.bubbleBorderWidth,
        )
      : null;
  return (
    color: color,
    radius: radius,
    border: border,
    blur: settings.bubbleBlurSigma,
  );
}

/// A faithful pump-able copy of `_BubbleSurface.build` (chat_screen.dart):
/// a decorated [Container] that, when [blur] > 0, is wrapped in a
/// [ClipRRect] + [BackdropFilter] clipped to the rounded rect.
class _BubblePreview extends StatelessWidget {
  final Color color;
  final BorderRadius radius;
  final Border? border;
  final double blur;
  const _BubblePreview({
    required this.color,
    required this.radius,
    required this.border,
    required this.blur,
  });

  @override
  Widget build(BuildContext context) {
    final inner = Container(
      key: const Key('bubble-inner'),
      width: 120,
      height: 48,
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius,
        border: border,
      ),
    );
    if (blur <= 0) return inner;
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: inner,
      ),
    );
  }
}

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: child),
      ),
    );

// ---------------------------------------------------------------------------
// F5 — UI text-scale (faithful replica of _MultipliedTextScaler + clamp)
// ---------------------------------------------------------------------------

/// Mirror of `_MultipliedTextScaler` (main.dart): wraps a base [TextScaler]
/// and multiplies its result by [factor].
class _MultipliedTextScaler extends TextScaler {
  final TextScaler _base;
  final double _factor;
  const _MultipliedTextScaler(this._base, this._factor);

  @override
  double scale(double fontSize) => _base.scale(fontSize) * _factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => _base.textScaleFactor * _factor;
}

/// A faithful pump-able copy of `_UiScaleWrap.build`: at scale 1.0 it touches
/// nothing (ambient scaler passes through); otherwise it composes the
/// multiplier on top of the ambient scaler and clamps into the supported
/// range, exposing the result via [MediaQuery.textScaler].
class _UiScalePreview extends StatelessWidget {
  final double uiScale;
  final Widget child;
  const _UiScalePreview({required this.uiScale, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (uiScale == 1.0) return child;
    final scaled = _MultipliedTextScaler(media.textScaler, uiScale).clamp(
      minScaleFactor: UiPrefs.kUiScaleMin,
      maxScaleFactor: UiPrefs.kUiScaleMax,
    );
    return MediaQuery(
      data: media.copyWith(textScaler: scaled),
      child: child,
    );
  }
}

/// Reads the ambient [MediaQuery.textScaler] into [out] so a test can assert
/// the EFFECTIVE scaler the subtree sees.
class _TextScalerProbe extends StatelessWidget {
  final void Function(TextScaler) out;
  const _TextScalerProbe(this.out);
  @override
  Widget build(BuildContext context) {
    out(MediaQuery.of(context).textScaler);
    return const SizedBox.shrink();
  }
}

void main() {
  // -------------------------------------------------------------------------
  // F2 — bubble decoration
  // -------------------------------------------------------------------------
  group('F2 bubble decoration (render)', () {
    testWidgets(
        'a custom color + radius + blur produces the expected BoxDecoration '
        'and a BackdropFilter', (tester) async {
      final settings = ChatSettings(
        userBubbleColor: 0xFF2A1D17, // opaque source color
        bubbleCornerRadius: 18.0,
        bubbleBlurSigma: 6.0, // > 0 → frosted
        // bubbleAlpha defaults to 0.55 (the translucency the bubble applies).
      );
      final look = _resolveBubbleLook(settings, isUser: true);

      await tester.pumpWidget(_wrap(_BubblePreview(
        color: look.color,
        radius: look.radius,
        border: look.border,
        blur: look.blur,
      )));

      // The decorated container carries the derived decoration.
      final decoration = tester
          .widget<Container>(find.byKey(const Key('bubble-inner')))
          .decoration as BoxDecoration;

      // Color = base (0xFF2A1D17) with alpha forced to bubbleAlpha (0.55).
      final expectedColor =
          const Color(0xFF2A1D17).withValues(alpha: 0.55);
      expect(decoration.color, expectedColor);
      // Alpha really shifted away from fully-opaque toward the 0.55 default.
      expect((decoration.color!.a - 0.55).abs() < 0.01, isTrue,
          reason: 'bubbleAlpha (0.55) must drive the bubble color alpha');

      // Radius = bubbleCornerRadius (18).
      expect(decoration.borderRadius, BorderRadius.circular(18.0));

      // blur > 0 → a BackdropFilter is present in the tree.
      expect(find.byType(BackdropFilter), findsOneWidget);
      // …and it is clipped to the rounded rect.
      expect(find.byType(ClipRRect), findsOneWidget);
    });

    testWidgets('a user-set border (width > 0) is applied', (tester) async {
      final settings = ChatSettings(
        bubbleBorderWidth: 2.0,
        bubbleBorderColor: 0xFFFF6A3D,
      );
      final look = _resolveBubbleLook(settings, isUser: true);

      await tester.pumpWidget(_wrap(_BubblePreview(
        color: look.color,
        radius: look.radius,
        border: look.border,
        blur: look.blur,
      )));

      final decoration = tester
          .widget<Container>(find.byKey(const Key('bubble-inner')))
          .decoration as BoxDecoration;
      final border = decoration.border as Border;
      expect(border.top.width, 2.0);
      expect(border.top.color, const Color(0xFFFF6A3D));
    });

    testWidgets('the defaults reproduce the legacy look (no blur, radius 12, '
        'bgPanel base, no border)', (tester) async {
      final settings = ChatSettings(); // all F2 knobs at defaults
      final look = _resolveBubbleLook(settings, isUser: true);

      await tester.pumpWidget(_wrap(_BubblePreview(
        color: look.color,
        radius: look.radius,
        border: look.border,
        blur: look.blur,
      )));

      final decoration = tester
          .widget<Container>(find.byKey(const Key('bubble-inner')))
          .decoration as BoxDecoration;
      // Base = bgPanel, alpha = default bubbleAlpha (0.55).
      expect(decoration.color,
          EmberColors.bgPanel.withValues(alpha: 0.55));
      expect(decoration.borderRadius, BorderRadius.circular(12.0));
      expect(decoration.border, isNull);
      // No blur → NO BackdropFilter in the tree.
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // F5 — global UI text-scale
  // -------------------------------------------------------------------------
  group('F5 UI text-scale (render)', () {
    testWidgets('uiScale multiplies the ambient textScaler (in range, no clamp)',
        (tester) async {
      late TextScaler effective;
      // Ambient OS scaler = 1.05, uiScale 1.2 → 1.26, well inside [0.8, 1.4]
      // so the multiply is observable WITHOUT the clamp biting.
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.05)),
          child: _UiScalePreview(
            uiScale: 1.2,
            child: _TextScalerProbe((s) => effective = s),
          ),
        ),
      );
      // Effective factor = 1.05 × 1.2 = 1.26 → scale(10) == 12.6, NOT 10.5
      // (ambient alone) and NOT 12.0 (uiScale alone) — proving composition.
      expect(effective.scale(10.0), closeTo(12.6, 0.001),
          reason: '1.05 (ambient) × 1.2 (uiScale) = 1.26 → 12.6 (no clamp)');
    });

    testWidgets('the composed factor is clamped to kUiScaleMax', (tester) async {
      late TextScaler effective;
      // Ambient 1.3 × uiScale 1.3 = 1.69, well over kUiScaleMax (1.4).
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: _UiScalePreview(
            uiScale: 1.3,
            child: _TextScalerProbe((s) => effective = s),
          ),
        ),
      );
      // Clamped: scale(10) == 10 × kUiScaleMax (1.4) == 14.0, never 16.9.
      expect(effective.scale(10.0), closeTo(14.0, 0.001),
          reason: '1.3 × 1.3 = 1.69 must clamp to kUiScaleMax 1.4');
    });

    testWidgets('uiScale=1.0 passes the ambient scaler through untouched',
        (tester) async {
      late TextScaler effective;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.15)),
          child: _UiScalePreview(
            uiScale: 1.0,
            child: _TextScalerProbe((s) => effective = s),
          ),
        ),
      );
      // No multiply, no clamp — exactly the ambient 1.15.
      expect(effective.scale(10.0), closeTo(11.5, 0.001));
    });
  });
}
