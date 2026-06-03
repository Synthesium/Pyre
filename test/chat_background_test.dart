// Wave CY.18.156: per-chat background override (source + custom image +
// opacity) on the Chat model. null fields = "inherit the global ChatSettings"
// and are OMITTED from JSON so existing chats are byte-identical + unaffected.
//
// Wave CY.18.203: extended for backgroundFit + boxFitFor.

import 'package:flutter/material.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('Chat background override', () {
    test('no override → null fields, keys omitted from JSON (inherit)', () {
      final c = Chat(id: 'c1', characterIds: const ['x']);
      final json = c.toJson();
      expect(json.containsKey('backgroundSource'), isFalse);
      expect(json.containsKey('customBackgroundDataUrl'), isFalse);
      expect(json.containsKey('backgroundOpacity'), isFalse);

      final back = Chat.fromJson(json);
      expect(back.backgroundSource, isNull);
      expect(back.customBackgroundDataUrl, isNull);
      expect(back.backgroundOpacity, isNull);
    });

    test('a full override survives a round-trip', () {
      final c = Chat(
        id: 'c2',
        characterIds: const ['x'],
        backgroundSource: ChatBackgroundSource.custom,
        customBackgroundDataUrl: 'data:image/png;base64,AAAA',
        backgroundOpacity: 0.3,
      );
      final back = Chat.fromJson(c.toJson());
      expect(back.backgroundSource, ChatBackgroundSource.custom);
      expect(back.customBackgroundDataUrl, 'data:image/png;base64,AAAA');
      expect(back.backgroundOpacity, 0.3);
    });

    test('an explicit "none" override is distinct from inherit-null', () {
      final c = Chat(
        id: 'c3',
        characterIds: const ['x'],
        backgroundSource: ChatBackgroundSource.none,
      );
      final back = Chat.fromJson(c.toJson());
      expect(back.backgroundSource, ChatBackgroundSource.none);
    });

    test('enum ↔ name mapping is stable + null/garbage → null', () {
      for (final s in ChatBackgroundSource.values) {
        expect(chatBgSourceFromNameOrNull(chatBgSourceToName(s)), s);
      }
      expect(chatBgSourceFromNameOrNull(null), isNull);
      expect(chatBgSourceFromNameOrNull('bogus'), isNull);
      expect(chatBgSourceFromNameOrNull(42), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Wave CY.18.203: ChatBackgroundFit + boxFitFor
  // -------------------------------------------------------------------------
  group('ChatBackgroundFit', () {
    test('chatBgFitToName / chatBgFitFromNameOrNull round-trip for all values',
        () {
      for (final f in ChatBackgroundFit.values) {
        final name = chatBgFitToName(f);
        expect(chatBgFitFromNameOrNull(name), f,
            reason: 'round-trip failed for $f (name=$name)');
      }
    });

    test('chatBgFitFromNameOrNull returns null for null/unknown', () {
      expect(chatBgFitFromNameOrNull(null), isNull);
      expect(chatBgFitFromNameOrNull('bogus'), isNull);
      expect(chatBgFitFromNameOrNull(42), isNull);
    });

    test('boxFitFor maps each enum value to the correct BoxFit', () {
      expect(boxFitFor(ChatBackgroundFit.cover), BoxFit.cover);
      expect(boxFitFor(ChatBackgroundFit.contain), BoxFit.contain);
      expect(boxFitFor(ChatBackgroundFit.fitWidth), BoxFit.fitWidth);
      expect(boxFitFor(ChatBackgroundFit.fill), BoxFit.fill);
    });

    test('ChatSettings.backgroundFit defaults to cover + survives round-trip',
        () {
      final s = ChatSettings();
      expect(s.backgroundFit, ChatBackgroundFit.cover);

      final j = s.toJson();
      expect(j['backgroundFit'], 'cover');

      final back = ChatSettings.fromJson(j);
      expect(back.backgroundFit, ChatBackgroundFit.cover);
    });

    test('ChatSettings.backgroundFit can be set to contain + persists', () {
      final s = ChatSettings(backgroundFit: ChatBackgroundFit.contain);
      final back = ChatSettings.fromJson(s.toJson());
      expect(back.backgroundFit, ChatBackgroundFit.contain);
    });

    test('ChatSettings.fromJson missing backgroundFit key → cover (default)',
        () {
      // Simulate loading from an old JSON blob that has no backgroundFit key.
      final j = <String, dynamic>{
        'backgroundSource': 'characterAvatar',
        'backgroundOpacity': 0.55,
      };
      final s = ChatSettings.fromJson(j);
      expect(s.backgroundFit, ChatBackgroundFit.cover);
    });

    test('Chat.backgroundFit: null (inherit) is omitted from JSON', () {
      final c = Chat(id: 'c4', characterIds: const ['x']);
      final json = c.toJson();
      expect(json.containsKey('backgroundFit'), isFalse);

      final back = Chat.fromJson(json);
      expect(back.backgroundFit, isNull);
    });

    test('Chat.backgroundFit: set value survives round-trip', () {
      final c = Chat(
        id: 'c5',
        characterIds: const ['x'],
        backgroundFit: ChatBackgroundFit.fitWidth,
      );
      final back = Chat.fromJson(c.toJson());
      expect(back.backgroundFit, ChatBackgroundFit.fitWidth);
    });

    test('Chat.backgroundFit: all non-cover values persist correctly', () {
      for (final f in ChatBackgroundFit.values) {
        final c = Chat(id: 'cx', characterIds: const ['x'], backgroundFit: f);
        expect(Chat.fromJson(c.toJson()).backgroundFit, f);
      }
    });
  });

  // -------------------------------------------------------------------------
  // Pyre 1.1 — F2: chat bubble customization (separate user vs AI color,
  // corner radius, border, blur, text scale).
  //
  // The cardinal rule: every new field defaults so the DEFAULT render is
  // byte-for-byte the legacy look. These tests pin those defaults and the
  // round-trip so a future change can't silently shift existing users.
  // -------------------------------------------------------------------------
  group('ChatSettings bubble customization (F2)', () {
    test('defaults reproduce the original bubble look', () {
      final s = ChatSettings();
      // Colors null → the wiring falls back to EmberColors.bgPanel.
      expect(s.userBubbleColor, isNull);
      expect(s.aiBubbleColor, isNull);
      expect(s.bubbleBorderColor, isNull);
      // Numeric knobs at their legacy hard-coded values.
      expect(s.bubbleCornerRadius, 12.0);
      expect(s.bubbleBorderWidth, 0.0);
      expect(s.bubbleBlurSigma, 0.0);
      expect(s.bubbleTextScale, 1.0);
    });

    test('a default ChatSettings omits the nullable color keys from JSON', () {
      final j = ChatSettings().toJson();
      expect(j.containsKey('userBubbleColor'), isFalse);
      expect(j.containsKey('aiBubbleColor'), isFalse);
      expect(j.containsKey('bubbleBorderColor'), isFalse);
      // The numeric knobs are always written, at their defaults.
      expect(j['bubbleCornerRadius'], 12.0);
      expect(j['bubbleBorderWidth'], 0.0);
      expect(j['bubbleBlurSigma'], 0.0);
      expect(j['bubbleTextScale'], 1.0);
    });

    test('an OLD saved blob (no F2 keys) loads with the legacy defaults', () {
      // Simulate a settings JSON written before F2 shipped.
      final legacy = <String, dynamic>{
        'deleteBehavior': 'onlyThis',
        'hideReasoning': true,
        'bubbleAlpha': 0.55,
        'backgroundSource': 'characterAvatar',
        'backgroundOpacity': 0.55,
        'backgroundFit': 'cover',
        'askPersonaOnNewChat': true,
      };
      final s = ChatSettings.fromJson(legacy);
      expect(s.userBubbleColor, isNull);
      expect(s.aiBubbleColor, isNull);
      expect(s.bubbleBorderColor, isNull);
      expect(s.bubbleCornerRadius, 12.0);
      expect(s.bubbleBorderWidth, 0.0);
      expect(s.bubbleBlurSigma, 0.0);
      expect(s.bubbleTextScale, 1.0);
    });

    test('all F2 fields survive a full round-trip', () {
      final s = ChatSettings(
        userBubbleColor: 0xFF2A1D17,
        aiBubbleColor: 0xFF1A2230,
        bubbleCornerRadius: 18.0,
        bubbleBorderWidth: 2.0,
        bubbleBorderColor: 0xFFFF6A3D,
        bubbleBlurSigma: 6.0,
        bubbleTextScale: 1.25,
      );
      final back = ChatSettings.fromJson(s.toJson());
      expect(back.userBubbleColor, 0xFF2A1D17);
      expect(back.aiBubbleColor, 0xFF1A2230);
      expect(back.bubbleCornerRadius, 18.0);
      expect(back.bubbleBorderWidth, 2.0);
      expect(back.bubbleBorderColor, 0xFFFF6A3D);
      expect(back.bubbleBlurSigma, 6.0);
      expect(back.bubbleTextScale, 1.25);
    });

    test('setting only one color leaves the other null (independent)', () {
      final s = ChatSettings(userBubbleColor: 0xFF152619);
      final j = s.toJson();
      expect(j.containsKey('userBubbleColor'), isTrue);
      expect(j.containsKey('aiBubbleColor'), isFalse);

      final back = ChatSettings.fromJson(j);
      expect(back.userBubbleColor, 0xFF152619);
      expect(back.aiBubbleColor, isNull);
    });
  });
}
