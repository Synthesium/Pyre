// Story Mode M1 — Story / Chapter data model tests.
//
// Covers: symmetric fromJson/toJson round-trips, tolerant decode of
// absent/corrupt fields (the same guarantees Chat/Message give), the
// liveSheetEnabled constructor-true / fromJson-absent-false split, and the
// activeChapter accessor semantics.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('Chapter', () {
    test('round-trips through JSON symmetrically', () {
      final c = Chapter(
        id: 'ch1',
        title: 'The Long Road',
        aim: 'Reach the city gates before nightfall.',
        summary: 'They reached the gates.',
        status: ChapterStatus.concluded,
        passages: [
          Message(id: 'p1', kind: MessageKind.scene, variants: ['Dawn broke.']),
          Message(
              id: 'p2',
              kind: MessageKind.char,
              characterId: 'alice',
              variants: ['"We ride," Alice said.', 'Alice nodded.'],
              selectedVariant: 1),
        ],
        createdAt: 1000,
        updatedAt: 2000,
        mtime: 3000,
      );
      final back = Chapter.fromJson(c.toJson());
      expect(back.id, 'ch1');
      expect(back.title, 'The Long Road');
      expect(back.aim, 'Reach the city gates before nightfall.');
      expect(back.summary, 'They reached the gates.');
      expect(back.status, ChapterStatus.concluded);
      expect(back.concluded, isTrue);
      expect(back.passages.length, 2);
      expect(back.passages[0].kind, MessageKind.scene);
      expect(back.passages[1].characterId, 'alice');
      expect(back.passages[1].selectedVariant, 1);
      expect(back.passages[1].text, 'Alice nodded.');
      expect(back.createdAt, 1000);
      expect(back.updatedAt, 2000);
      expect(back.mtime, 3000);
    });

    test('tolerates absent / junk fields', () {
      final c = Chapter.fromJson(const {});
      expect(c.id, isNotEmpty); // generated
      expect(c.title, '');
      expect(c.aim, '');
      expect(c.summary, '');
      expect(c.status, ChapterStatus.active);
      expect(c.passages, isEmpty);

      final junk = Chapter.fromJson(const {
        'id': 'x',
        'status': 'bogus-value',
        'passages': 'not-a-list',
        'mtime': 'NaN',
      });
      expect(junk.status, ChapterStatus.active); // unknown → active
      expect(junk.passages, isEmpty);
      expect(junk.mtime, 0);
    });

    test('displayTitle falls back to Chapter N when blank', () {
      expect(Chapter(id: 'a').displayTitle(3), 'Chapter 3');
      expect(Chapter(id: 'a', title: '  ').displayTitle(1), 'Chapter 1');
      expect(Chapter(id: 'a', title: 'Embers').displayTitle(2), 'Embers');
    });
  });

  group('Story', () {
    Story buildStory() => Story(
          id: 's1',
          title: 'Pyre of Kings',
          premise: 'A fallen kingdom, one heir, one match.',
          characterIds: ['alice'],
          characterSnapshots: {
            'alice': Character(id: 'alice', name: 'Alice'),
          },
          personaId: 'me',
          attachedLorebookIds: ['lb1'],
          disabledInheritedLorebookIds: ['lb2'],
          presetId: 'preset1',
          chapters: [
            Chapter(id: 'ch1', status: ChapterStatus.concluded, summary: 'x'),
            Chapter(id: 'ch2', aim: 'Find the heir.'),
          ],
          createdAt: 10,
          updatedAt: 20,
          mtime: 30,
        );

    test('round-trips through JSON symmetrically', () {
      final s = buildStory();
      final back = Story.fromJson(s.toJson());
      expect(back.id, 's1');
      expect(back.title, 'Pyre of Kings');
      expect(back.premise, 'A fallen kingdom, one heir, one match.');
      expect(back.characterIds, ['alice']);
      expect(back.characterSnapshots['alice']!.name, 'Alice');
      expect(back.personaId, 'me');
      expect(back.attachedLorebookIds, ['lb1']);
      expect(back.disabledInheritedLorebookIds, ['lb2']);
      expect(back.presetId, 'preset1');
      expect(back.chapters.length, 2);
      expect(back.chapters[0].concluded, isTrue);
      expect(back.chapters[1].aim, 'Find the heir.');
      expect(back.createdAt, 10);
      expect(back.updatedAt, 20);
      expect(back.mtime, 30);
      expect(back.deleted, isFalse);
    });

    test('deleted flag round-trips (tombstone sync)', () {
      final s = buildStory()..deleted = true;
      expect(Story.fromJson(s.toJson()).deleted, isTrue);
    });

    test('tolerates absent / junk fields', () {
      final s = Story.fromJson(const {'id': 's2'});
      expect(s.title, '');
      expect(s.premise, '');
      expect(s.characterIds, isEmpty);
      expect(s.characterSnapshots, isEmpty);
      expect(s.chapters, isEmpty);
      expect(s.liveSheetSnapshots, isEmpty);
      expect(s.deleted, isFalse);

      final junk = Story.fromJson(const {
        'id': 's3',
        'chapters': [42, 'nope'],
        'characterIds': ['ok', 7],
        'characterSnapshots': {'a': 'not-a-map'},
      });
      expect(junk.chapters, isEmpty); // non-map entries filtered
      expect(junk.characterIds, ['ok']); // non-string entries filtered
      expect(junk.characterSnapshots, isEmpty);
    });

    test('liveSheetEnabled: constructor defaults true, fromJson-absent false',
        () {
      // Freshly created story → ON.
      expect(Story(id: 'fresh').liveSheetEnabled, isTrue);
      // Persisted before the field existed → stays OFF.
      expect(Story.fromJson(const {'id': 'old'}).liveSheetEnabled, isFalse);
      // A stored value always wins.
      expect(
          Story.fromJson(const {'id': 'on', 'liveSheetEnabled': true})
              .liveSheetEnabled,
          isTrue);
    });

    test('activeChapter is the last chapter only while it is active', () {
      final s = buildStory();
      expect(s.activeChapter!.id, 'ch2');
      s.chapters.last.status = ChapterStatus.concluded;
      expect(s.activeChapter, isNull); // all concluded
      expect(Story(id: 'empty').activeChapter, isNull); // no chapters
    });
  });
}
