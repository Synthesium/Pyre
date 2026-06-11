// Story Mode M1 — AppStore stories collection tests.
//
// Covers: persist/load round-trip of the `stories` key, mutator
// mtime/updatedAt stamping (LWW sync metadata), chapter lifecycle
// (add → write → conclude → next), reorder bounds, passage variant
// re-roll plumbing, and delete + tombstone logging.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemBackend implements StoreBackend {
  Map<String, dynamic>? blob;

  @override
  Future<Map<String, dynamic>?> load() async => blob;

  @override
  Future<void> save(Map<String, dynamic> b) async {
    blob = b;
  }

  @override
  Future<void> clear() async {
    blob = null;
  }
}

void main() {
  // AppStore.load() touches SharedPreferences (attachment migration) — give
  // it the test binding + an empty mock prefs store.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('AppStore stories', () {
    test('startStoryWith snapshots cast and stamps mtime', () {
      final s = AppStore();
      final alice = Character(id: 'alice', name: 'Alice');
      final story = s.startStoryWith(
        title: 'Pyre of Kings',
        premise: 'A fallen kingdom.',
        cast: [alice],
      );
      expect(s.stories, hasLength(1));
      expect(story.characterIds, ['alice']);
      expect(story.characterSnapshots['alice']!.name, 'Alice');
      expect(story.mtime, greaterThan(0));
      // Snapshot is frozen — mutating the library card doesn't leak in.
      alice.name = 'Renamed';
      expect(story.characterSnapshots['alice']!.name, 'Alice');
    });

    test('persist round-trips the stories collection in the blob', () async {
      // Full AppStore.load() drags in platform channels (attachment GC),
      // so round-trip via the persisted blob + Story.fromJson — exactly
      // the path load()'s `_parseList<Story>` takes.
      final backend = _MemBackend();
      final s = AppStore(storage: backend);
      final story = s.startStoryWith(
          title: 'T', premise: 'P', cast: [Character(id: 'c', name: 'C')]);
      final ch = s.addChapter(story.id, aim: 'Reach the gates.');
      s.addPassage(story.id, ch.id,
          Message(id: 'p1', kind: MessageKind.scene, variants: ['Dawn.']));
      await s.flushPersist();

      final rawStories = backend.blob!['stories'] as List;
      expect(rawStories, hasLength(1));
      final loaded =
          Story.fromJson((rawStories.first as Map).cast<String, dynamic>());
      expect(loaded.title, 'T');
      expect(loaded.characterSnapshots['c']!.name, 'C');
      expect(loaded.chapters, hasLength(1));
      expect(loaded.chapters.first.aim, 'Reach the gates.');
      expect(loaded.chapters.first.passages.first.text, 'Dawn.');
    });

    test('chapter lifecycle: add → conclude → next chapter', () {
      final s = AppStore();
      final story =
          s.startStoryWith(title: 'T', premise: 'P', cast: const []);
      final ch1 = s.addChapter(story.id, aim: 'Aim one');
      expect(story.activeChapter!.id, ch1.id);

      s.concludeChapter(story.id, ch1.id, summary: '  They made it.  ');
      expect(ch1.concluded, isTrue);
      expect(ch1.summary, 'They made it.'); // trimmed
      expect(ch1.mtime, greaterThan(0));
      expect(story.activeChapter, isNull);

      final ch2 = s.addChapter(story.id, aim: 'Aim two');
      expect(story.activeChapter!.id, ch2.id);
      expect(story.chapters.map((c) => c.id), [ch1.id, ch2.id]);
    });

    test('mutators stamp story mtime (sync metadata)', () {
      final s = AppStore();
      final story =
          s.startStoryWith(title: 'T', premise: 'P', cast: const []);
      final ch = s.addChapter(story.id, aim: 'a');
      story.mtime = 0; // reset so the stamp is observable
      s.addPassage(story.id, ch.id,
          Message(id: 'p1', kind: MessageKind.user, variants: ['I walk.']));
      expect(story.mtime, greaterThan(0));

      story.mtime = 0;
      s.updatePassageText(story.id, ch.id, 'p1', 'I run.');
      expect(story.mtime, greaterThan(0));
      expect(ch.passages.first.text, 'I run.');
    });

    test('passage variants: add, pinned-index write, select', () {
      final s = AppStore();
      final story =
          s.startStoryWith(title: 'T', premise: 'P', cast: const []);
      final ch = s.addChapter(story.id, aim: 'a');
      s.addPassage(story.id, ch.id,
          Message(id: 'p1', kind: MessageKind.char, variants: ['First roll']));

      final idx = s.addPassageVariant(story.id, ch.id, 'p1');
      expect(idx, 1);
      final msg = ch.passages.first;
      expect(msg.selectedVariant, 1);

      // Pinned write keeps landing on the stream's variant even if the
      // user swipes back mid-stream.
      s.setPassageVariant(story.id, ch.id, 'p1', 0);
      s.updatePassageText(story.id, ch.id, 'p1', 'Second roll',
          variantIndex: idx);
      expect(msg.variants[1], 'Second roll');
      expect(msg.variants[0], 'First roll');

      // Out-of-range select is ignored.
      s.setPassageVariant(story.id, ch.id, 'p1', 99);
      expect(msg.selectedVariant, 0);
    });

    test('reorderChapters moves within bounds and ignores junk indices', () {
      final s = AppStore();
      final story =
          s.startStoryWith(title: 'T', premise: 'P', cast: const []);
      final a = s.addChapter(story.id, aim: 'a');
      final b = s.addChapter(story.id, aim: 'b');
      final c = s.addChapter(story.id, aim: 'c');

      s.reorderChapters(story.id, 0, 2);
      expect(story.chapters.map((x) => x.id), [b.id, c.id, a.id]);

      s.reorderChapters(story.id, -1, 0); // ignored
      s.reorderChapters(story.id, 0, 99); // ignored
      expect(story.chapters.map((x) => x.id), [b.id, c.id, a.id]);
    });

    test('removeStory hard-removes and logs a tombstone', () {
      final s = AppStore();
      final story =
          s.startStoryWith(title: 'T', premise: 'P', cast: const []);
      s.removeStory(story.id);
      expect(s.stories, isEmpty);
      expect(
          s.isTombstonedNewer('story', story.id, 0), isTrue);
    });

    test('removePassage deletes by id', () {
      final s = AppStore();
      final story =
          s.startStoryWith(title: 'T', premise: 'P', cast: const []);
      final ch = s.addChapter(story.id, aim: 'a');
      s.addPassage(story.id, ch.id,
          Message(id: 'p1', kind: MessageKind.scene, variants: ['x']));
      s.addPassage(story.id, ch.id,
          Message(id: 'p2', kind: MessageKind.scene, variants: ['y']));
      s.removePassage(story.id, ch.id, 'p1');
      expect(ch.passages.map((m) => m.id), ['p2']);
    });
  });
}
