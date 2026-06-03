// Wave 1.1 (F3): matching engine for the SillyTavern-style lorebook keyword
// options. The pure `evaluateLoreEntryTrigger` is exercised directly for each
// selectiveLogic mode + probability boundaries, plus regressions that a
// default-options entry triggers EXACTLY as it did before 1.1.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_inject.dart';

void main() {
  // The scanned window text used across the logic tests.
  const text = 'The Sunken Gate yawned open as the siege began at dawn.';

  LoreEntry entry({
    List<String> keys = const ['Gate'],
    List<String> secondary = const [],
    LoreSelectiveLogic logic = LoreSelectiveLogic.andAny,
    bool? caseSensitive,
    bool? wholeWords,
    int probability = 100,
    bool useProbability = false,
  }) =>
      LoreEntry(
        id: 'e',
        keys: keys,
        secondaryKeys: secondary,
        selectiveLogic: logic,
        caseSensitive: caseSensitive,
        matchWholeWords: wholeWords,
        probability: probability,
        useProbability: useProbability,
      );

  group('regression: default options = pre-1.1 behaviour', () {
    test('primary match with no secondary keys → triggers (case-insensitive)',
        () {
      // "Gate" appears as "Gate"; default is case-insensitive whole-word.
      expect(evaluateLoreEntryTrigger(text, entry()).triggered, isTrue);
    });

    test('no primary match → never triggers', () {
      expect(
        evaluateLoreEntryTrigger(text, entry(keys: const ['dragon'])).triggered,
        isFalse,
      );
    });

    test('short key does NOT match inside a larger word (word boundary)', () {
      // "at" must not fire inside "Gate"/"dawn". Default whole-word.
      expect(
        evaluateLoreEntryTrigger('Gate at dawn', entry(keys: const ['at']))
            .triggered,
        isTrue, // standalone "at" present
      );
      expect(
        evaluateLoreEntryTrigger('Gateway', entry(keys: const ['Gate']))
            .triggered,
        isFalse, // "Gate" inside "Gateway" must NOT fire
      );
    });
  });

  group('per-entry case / whole-word overrides', () {
    test('caseSensitive=true only matches exact case', () {
      expect(
        evaluateLoreEntryTrigger('the gate', entry(keys: const ['Gate']))
            .triggered,
        isTrue, // default case-insensitive
      );
      expect(
        evaluateLoreEntryTrigger('the gate',
                entry(keys: const ['Gate'], caseSensitive: true))
            .triggered,
        isFalse, // case-sensitive: 'Gate' != 'gate'
      );
    });

    test('matchWholeWords=false allows substring match', () {
      expect(
        evaluateLoreEntryTrigger('Gateway',
                entry(keys: const ['Gate'], wholeWords: false))
            .triggered,
        isTrue,
      );
    });
  });

  group('selectiveLogic on secondary keys (primary already matched)', () {
    // primary "Gate" matches in `text`. secondary present: "siege"; absent:
    // "ambush".
    test('andAny: at least one secondary present → fires', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'ambush'],
                    logic: LoreSelectiveLogic.andAny))
            .triggered,
        isTrue,
      );
    });

    test('andAny: NO secondary present → does not fire', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['ambush', 'volcano'],
                    logic: LoreSelectiveLogic.andAny))
            .triggered,
        isFalse,
      );
    });

    test('andAll: all secondaries present → fires; one absent → no', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'dawn'],
                    logic: LoreSelectiveLogic.andAll))
            .triggered,
        isTrue,
      );
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'ambush'],
                    logic: LoreSelectiveLogic.andAll))
            .triggered,
        isFalse,
      );
    });

    test('notAny: none present → fires; one present → no', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['ambush', 'volcano'],
                    logic: LoreSelectiveLogic.notAny))
            .triggered,
        isTrue,
      );
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege'],
                    logic: LoreSelectiveLogic.notAny))
            .triggered,
        isFalse,
      );
    });

    test('notAll: at least one absent → fires; all present → no', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'ambush'],
                    logic: LoreSelectiveLogic.notAll))
            .triggered,
        isTrue, // ambush absent
      );
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'dawn'],
                    logic: LoreSelectiveLogic.notAll))
            .triggered,
        isFalse, // both present
      );
    });

    test('secondary logic never fires when the primary did not match', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    keys: const ['dragon'],
                    secondary: const ['siege'],
                    logic: LoreSelectiveLogic.andAny))
            .triggered,
        isFalse,
      );
    });
  });

  group('probability gate', () {
    test('useProbability=false → probability ignored, always fires', () {
      // roll would say "no" but useProbability is off, so it must fire.
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 0, useProbability: false),
        roll: (_) => 0,
      );
      expect(d.triggered, isTrue);
    });

    test('probability 100 always fires (never consults the roll)', () {
      var rolled = false;
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 100, useProbability: true),
        roll: (_) {
          rolled = true;
          return 99;
        },
      );
      expect(d.triggered, isTrue);
      expect(rolled, isFalse, reason: 'p>=100 short-circuits the roll');
    });

    test('probability 0 never fires', () {
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 0, useProbability: true),
        roll: (_) => 0,
      );
      expect(d.triggered, isFalse);
    });

    test('roll < probability → fires', () {
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 50, useProbability: true),
        roll: (_) => 49,
      );
      expect(d.triggered, isTrue);
    });

    test('roll >= probability → does not fire', () {
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 50, useProbability: true),
        roll: (_) => 50,
      );
      expect(d.triggered, isFalse);
    });

    test('probability gate runs AFTER selective logic (logic fail = no roll)',
        () {
      var rolled = false;
      final d = evaluateLoreEntryTrigger(
        text,
        entry(
          secondary: const ['ambush'], // absent → andAny fails
          logic: LoreSelectiveLogic.andAny,
          probability: 100,
          useProbability: true,
        ),
        roll: (_) {
          rolled = true;
          return 0;
        },
      );
      expect(d.triggered, isFalse);
      expect(rolled, isFalse);
    });
  });

  group('scanLorebookHits integration (defaults unchanged)', () {
    Message msg(String t) => Message(id: t, kind: MessageKind.user, variants: [t]);

    test('a default-options entry fires off the scanned window', () {
      final book = Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LoreEntry(id: 'e1', keys: const ['Gate'], content: 'lore'),
        ],
      );
      final res = scanLorebookHits([book], [msg('Through the Gate we go.')]);
      expect(res.hits.length, 1);
      expect(res.hits.first.content, 'lore');
    });

    test('constant entry always fires; disabled is skipped', () {
      final book = Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LoreEntry(id: 'c', content: 'always', constant: true),
          LoreEntry(
              id: 'd', keys: const ['Gate'], content: 'off', enabled: false),
        ],
      );
      final res = scanLorebookHits([book], [msg('no keyword here')]);
      expect(res.hits.map((e) => e.content), const ['always']);
      expect(res.skippedDisabled, 1);
    });

    test('secondary-key entry honours selectiveLogic in a full scan', () {
      final book = Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LoreEntry(
            id: 'e',
            keys: const ['Gate'],
            content: 'siege lore',
            secondaryKeys: const ['siege'],
            selectiveLogic: LoreSelectiveLogic.andAny,
          ),
        ],
      );
      expect(
        scanLorebookHits([book], [msg('Gate and siege')]).hits.length,
        1,
      );
      expect(
        scanLorebookHits([book], [msg('Gate alone, no second word')]).hits,
        isEmpty,
      );
    });
  });
}
