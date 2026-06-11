// Story Mode M2 — manuscript export + word stats tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/manuscript_export.dart';

void main() {
  Story story() => Story(
        id: 's1',
        title: 'Pyre of Kings',
        premise: 'A fallen kingdom.\nOne heir.',
        chapters: [
          Chapter(id: 'c1', title: 'Sparks', status: ChapterStatus.concluded,
              summary: 'x', passages: [
            Message(id: 'p1', kind: MessageKind.scene, variants: [
              'Dawn broke over the walls.' // 5 words
            ]),
            Message(id: 'p2', kind: MessageKind.char, variants: [
              '<think>plan</think>"Hurry," Alice hissed.' // 3 words after strip
            ]),
            Message(id: 'p3', kind: MessageKind.ooc, variants: ['note to self']),
          ]),
          Chapter(id: 'c2', passages: [
            Message(id: 'p4', kind: MessageKind.user, variants: [
              'I follow her down.', // selected variant below switches
              'I hesitate at the stair.' // 5 words — selected
            ], selectedVariant: 1),
            Message(id: 'p5', kind: MessageKind.scene, variants: ['  ']),
          ]),
          Chapter(id: 'c3', title: 'Empty chapter'),
        ],
      );

  test('storyToMarkdown: title, chapter headings, prose-only paragraphs', () {
    final md = storyToMarkdown(story());
    expect(md, startsWith('# Pyre of Kings\n'));
    expect(md, contains('\n## Sparks\n'));
    expect(md, contains('\n## Chapter 2\n')); // untitled falls back
    expect(md, contains('\n## Empty chapter')); // outline survives
    expect(md, contains('Dawn broke over the walls.'));
    expect(md, contains('"Hurry," Alice hissed.'));
    expect(md, isNot(contains('<think>'))); // reasoning stripped
    expect(md, isNot(contains('note to self'))); // ooc excluded
    // Selected variant wins.
    expect(md, contains('I hesitate at the stair.'));
    expect(md, isNot(contains('I follow her down.')));
    // No premise by default.
    expect(md, isNot(contains('> A fallen kingdom.')));
  });

  test('storyToMarkdown: includePremise renders a blockquote', () {
    final md = storyToMarkdown(story(), includePremise: true);
    expect(md, contains('> A fallen kingdom.\n> One heir.'));
  });

  test('storyWordStats counts prose words per chapter + total', () {
    final stats = storyWordStats(story());
    expect(stats.wordsByChapter['c1'], 8); // 5 + 3
    expect(stats.wordsByChapter['c2'], 5);
    expect(stats.wordsByChapter['c3'], 0);
    expect(stats.totalWords, 13);
  });

  test('countWords handles blanks and runs of whitespace', () {
    expect(countWords(''), 0);
    expect(countWords('   '), 0);
    expect(countWords('one'), 1);
    expect(countWords('one  two\n three'), 3);
  });
}
