// Wave 1.1 (F3): LoreEntry model round-trip for the new SillyTavern-style
// keyword options. The hard requirement is that a pre-1.1 entry (no new
// fields set) round-trips with the exact defaults that reproduce today's
// triggering, AND that JSON of a default entry stays free of the new keys.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('LoreEntry defaults reproduce pre-1.1 behaviour', () {
    test('a bare entry has the safe defaults', () {
      final e = LoreEntry(id: 'e1', keys: const ['Gate'], content: 'lore');
      expect(e.secondaryKeys, isEmpty);
      expect(e.selectiveLogic, LoreSelectiveLogic.andAny);
      expect(e.caseSensitive, isNull);
      expect(e.matchWholeWords, isNull);
      expect(e.probability, 100);
      expect(e.useProbability, isFalse);
    });

    test('toJson of a default entry emits NONE of the new keys', () {
      final e = LoreEntry(id: 'e1', keys: const ['Gate'], content: 'lore');
      final j = e.toJson();
      expect(j.containsKey('secondaryKeys'), isFalse);
      expect(j.containsKey('selectiveLogic'), isFalse);
      expect(j.containsKey('caseSensitive'), isFalse);
      expect(j.containsKey('matchWholeWords'), isFalse);
      expect(j.containsKey('probability'), isFalse);
      expect(j.containsKey('useProbability'), isFalse);
      // The pre-1.1 keys are all still there.
      expect(j['keys'], const ['Gate']);
      expect(j['content'], 'lore');
      expect(j['constant'], isFalse);
      expect(j['enabled'], isTrue);
      expect(j['order'], 0);
    });

    test('a legacy JSON (no new keys) loads with default options', () {
      final legacy = <String, dynamic>{
        'id': 'e1',
        'keys': ['Gate'],
        'content': 'lore',
        'constant': false,
        'enabled': true,
        'order': 7,
      };
      final e = LoreEntry.fromJson(legacy);
      expect(e.keys, const ['Gate']);
      expect(e.order, 7);
      expect(e.secondaryKeys, isEmpty);
      expect(e.selectiveLogic, LoreSelectiveLogic.andAny);
      expect(e.caseSensitive, isNull);
      expect(e.matchWholeWords, isNull);
      expect(e.probability, 100);
      expect(e.useProbability, isFalse);
    });
  });

  group('LoreEntry full round-trip of the new fields', () {
    test('all new fields survive toJson -> fromJson', () {
      final e = LoreEntry(
        id: 'e2',
        keys: const ['castle'],
        content: 'A castle.',
        order: 3,
        secondaryKeys: const ['siege', 'banner'],
        selectiveLogic: LoreSelectiveLogic.andAll,
        caseSensitive: true,
        matchWholeWords: false,
        probability: 42,
        useProbability: true,
      );
      final back = LoreEntry.fromJson(e.toJson());
      expect(back.keys, const ['castle']);
      expect(back.content, 'A castle.');
      expect(back.order, 3);
      expect(back.secondaryKeys, const ['siege', 'banner']);
      expect(back.selectiveLogic, LoreSelectiveLogic.andAll);
      expect(back.caseSensitive, isTrue);
      expect(back.matchWholeWords, isFalse);
      expect(back.probability, 42);
      expect(back.useProbability, isTrue);
    });

    test('every selectiveLogic value round-trips by name', () {
      for (final logic in LoreSelectiveLogic.values) {
        final e = LoreEntry(
          id: 'e',
          keys: const ['k'],
          secondaryKeys: const ['s'],
          selectiveLogic: logic,
        );
        expect(LoreEntry.fromJson(e.toJson()).selectiveLogic, logic);
      }
    });
  });

  group('selectiveLogic ST integer codec', () {
    test('fromSt maps ST ordering (0=AND_ANY,1=NOT_ALL,2=NOT_ANY,3=AND_ALL)',
        () {
      expect(loreSelectiveLogicFromSt(0), LoreSelectiveLogic.andAny);
      expect(loreSelectiveLogicFromSt(1), LoreSelectiveLogic.notAll);
      expect(loreSelectiveLogicFromSt(2), LoreSelectiveLogic.notAny);
      expect(loreSelectiveLogicFromSt(3), LoreSelectiveLogic.andAll);
      // Missing / unknown → andAny (safe default).
      expect(loreSelectiveLogicFromSt(null), LoreSelectiveLogic.andAny);
      expect(loreSelectiveLogicFromSt(99), LoreSelectiveLogic.andAny);
    });

    test('toSt is the inverse', () {
      for (final logic in LoreSelectiveLogic.values) {
        expect(loreSelectiveLogicFromSt(loreSelectiveLogicToSt(logic)), logic);
      }
    });
  });
}
