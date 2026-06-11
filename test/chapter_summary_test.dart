// Story Mode M2 — chapter summary body/prompt tests (pure parts only; the
// LLM orchestration is exercised end-to-end in M4 verification).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chapter_summary.dart';

void main() {
  Story story() {
    final alice = Character(id: 'alice', name: 'Alice');
    return Story(
      id: 's1',
      title: 'T',
      characterIds: ['alice'],
      characterSnapshots: {'alice': alice},
      chapters: [
        Chapter(
            id: 'c1',
            status: ChapterStatus.concluded,
            summary: 'Alice stole the ledger.'),
        Chapter(id: 'c2', aim: 'Reach the gates.', passages: [
          Message(id: 'p1', kind: MessageKind.scene, variants: [
            '<think>plan</think>Dawn broke over the walls.'
          ]),
          Message(
              id: 'p2',
              kind: MessageKind.char,
              characterId: 'alice',
              variants: ['"Hurry," Alice hissed.']),
          Message(id: 'p3', kind: MessageKind.user, variants: ['I follow.']),
          Message(id: 'p4', kind: MessageKind.ooc, variants: ['pace it slow']),
        ]),
      ],
    );
  }

  test('system prompt carries the anti-continuation discipline', () {
    expect(kChapterSummarySystemPrompt, contains('NOT A STORY CONTINUATION'));
    expect(kChapterSummarySystemPrompt, contains('PAST'));
    expect(kChapterSummarySystemPrompt, contains('150–300 words'));
  });

  test('body: prior summaries as do-not-retell, aim, labeled passages', () {
    final s = story();
    final body = buildChapterSummaryBody(
        story: s, chapter: s.chapters[1], personaLabel: 'Wren');
    final idxPrior = body.indexOf('do NOT retell');
    final idxAim = body.indexOf("The author's aim");
    final idxPassages = body.indexOf('summarise THESE');
    expect(idxPrior, greaterThanOrEqualTo(0));
    expect(idxAim, greaterThan(idxPrior));
    expect(idxPassages, greaterThan(idxAim));
    expect(body, contains('Alice stole the ledger.'));
    expect(body, contains('Reach the gates.'));
    // Labels resolve: narrator, character name, persona label.
    expect(body, contains('Narration: Dawn broke over the walls.'));
    expect(body, contains('Alice: "Hurry," Alice hissed.'));
    expect(body, contains('Wren: I follow.'));
    // Reasoning stripped from the source.
    expect(body, isNot(contains('<think>')));
    // Author notes (ooc) are excluded from the recap source.
    expect(body, isNot(contains('pace it slow')));
  });

  test('body: no prior chapters → no story-so-far header', () {
    final s = story();
    // Make the first chapter active-only (no concluded summaries).
    s.chapters.removeAt(0);
    final body = buildChapterSummaryBody(story: s, chapter: s.chapters.first);
    expect(body, isNot(contains('story so far')));
    expect(body, contains('summarise THESE'));
    // Default persona label applies when none is passed.
    expect(body, contains("The author's character: I follow."));
  });
}
