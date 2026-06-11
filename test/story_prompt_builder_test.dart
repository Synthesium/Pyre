// Story Mode M2 — story prompt assembly tests.
//
// Covers: section order in the system turn; the voice selector changing only
// the cast block + final instruction; prior-chapter recap (concluded-only,
// oldest-trimmed-first budget); lore hits scanned from the CURRENT chapter's
// passages only; the [CHAPTER-END?] marker instruction gating on a non-blank
// aim; history role mapping + reasoning strip; and the end-signal extractor.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/story_prompt_builder.dart';

Character _char(String id, String name,
        {String description = '', String? tagline, List<String>? books}) =>
    Character(
        id: id,
        name: name,
        description: description,
        tagline: tagline,
        lorebookIds: books ?? []);

Story _story({List<Chapter>? chapters, List<String>? castIds}) {
  final alice = _char('alice', 'Alice',
      description: 'A sharp-eyed thief.\nSecond line of card.');
  final bram = _char('bram', 'Bram', tagline: 'A weary blacksmith');
  return Story(
    id: 's1',
    title: 'Pyre of Kings',
    premise: 'A fallen kingdom, one heir, one match.',
    characterIds: castIds ?? ['alice', 'bram'],
    characterSnapshots: {'alice': alice, 'bram': bram},
    chapters: chapters ?? [],
  );
}

StoryPromptInputs _inputs(
  Story story,
  Chapter chapter, {
  MessageKind voice = MessageKind.scene,
  Character? voiceCharacter,
  Persona? persona,
  Lorebook? Function(String)? lookupBook,
  int recapBudget = kStoryRecapCharBudget,
}) =>
    StoryPromptInputs(
      story: story,
      chapter: chapter,
      voiceKind: voice,
      voiceCharacter: voiceCharacter,
      persona: persona,
      lookupCharacter: (_) => null,
      lookupBook: lookupBook ?? (_) => null,
      recapCharBudget: recapBudget,
    );

void main() {
  group('buildStoryPrompt — system turn', () {
    test('sections appear in the documented order', () {
      final concluded = Chapter(
          id: 'c1',
          title: 'Sparks',
          status: ChapterStatus.concluded,
          summary: 'Alice stole the ledger.');
      final active = Chapter(id: 'c2', aim: 'Reach the gates before dawn.');
      final story = _story(chapters: [concluded, active]);

      final r = buildStoryPrompt(_inputs(story, active));
      final sys = r.turns.first;
      expect(sys.role, 'system');
      final idxFraming = sys.content.indexOf('co-writing a novel');
      final idxPremise = sys.content.indexOf('--- Premise ---');
      final idxCast = sys.content.indexOf('--- Cast ---');
      final idxSoFar =
          sys.content.indexOf('--- The story so far (previous chapters) ---');
      final idxAim = sys.content.indexOf("--- This chapter's aim");
      expect(idxFraming, greaterThanOrEqualTo(0));
      expect(idxPremise, greaterThan(idxFraming));
      expect(idxCast, greaterThan(idxPremise));
      expect(idxSoFar, greaterThan(idxCast));
      expect(idxAim, greaterThan(idxSoFar));
      expect(sys.content, contains('A fallen kingdom, one heir, one match.'));
      expect(sys.content, contains('Sparks: Alice stole the ledger.'));
      expect(sys.content, contains('Reach the gates before dawn.'));
    });

    test('narrator voice: cast is all one-line; instruction says narrator',
        () {
      final active = Chapter(id: 'c1', aim: 'x');
      final story = _story(chapters: [active]);
      final r = buildStoryPrompt(_inputs(story, active));
      final sys = r.turns.first.content;
      expect(sys, contains('• Alice: A sharp-eyed thief.'));
      expect(sys, contains('• Bram: A weary blacksmith'));
      // Full card body (line 2) is NOT included for non-voice characters.
      expect(sys, isNot(contains('Second line of card.')));
      expect(r.turns.last.content, contains('written as the narrator'));
    });

    test('character voice: full card for the voice character only', () {
      final active = Chapter(id: 'c1', aim: 'x');
      final story = _story(chapters: [active]);
      final alice = story.characterSnapshots['alice']!;
      final r = buildStoryPrompt(_inputs(story, active,
          voice: MessageKind.char, voiceCharacter: alice));
      final sys = r.turns.first.content;
      expect(sys, contains('Second line of card.')); // full description
      expect(sys, contains('• Bram:')); // others stay one-line
      expect(sys, isNot(contains('• Alice:')));
      expect(r.turns.last.content, contains('written as Alice'));
    });

    test('persona voice: instruction names the persona; cast lists them', () {
      final active = Chapter(id: 'c1', aim: 'x');
      final story = _story(chapters: [active]);
      final persona =
          Persona(id: 'me', name: 'Wren', description: 'A wandering scribe.');
      final r = buildStoryPrompt(_inputs(story, active,
          voice: MessageKind.user, persona: persona));
      expect(r.turns.first.content,
          contains("• Wren (the author's own character): A wandering scribe."));
      expect(r.turns.last.content, contains('written as Wren'));
    });
  });

  group('buildPriorChaptersRecap', () {
    test('only concluded chapters with summaries contribute, in order', () {
      final story = _story(chapters: [
        Chapter(
            id: 'a',
            status: ChapterStatus.concluded,
            summary: 'First summary.'),
        Chapter(id: 'b', status: ChapterStatus.concluded, summary: ''),
        Chapter(id: 'c', aim: 'active'), // active — excluded
        Chapter(
            id: 'd',
            title: 'Embers',
            status: ChapterStatus.concluded,
            summary: 'Fourth summary.'),
      ]);
      final recap = buildPriorChaptersRecap(story, excludeChapterId: 'c');
      expect(recap, contains('Chapter 1: First summary.'));
      expect(recap, contains('Embers: Fourth summary.'));
      expect(recap.indexOf('Chapter 1'), lessThan(recap.indexOf('Embers')));
      expect(recap, isNot(contains('Chapter 2')));
    });

    test('budget drops the OLDEST chapters first, keeps newest whole', () {
      final story = _story(chapters: [
        for (var i = 0; i < 5; i++)
          Chapter(
              id: 'ch$i',
              status: ChapterStatus.concluded,
              summary: 'Summary $i ${'x' * 200}'),
      ]);
      final recap = buildPriorChaptersRecap(story, charBudget: 500);
      expect(recap, contains('Summary 4'));
      expect(recap, contains('Summary 3')); // alwaysWholeNewest = 2
      expect(recap, isNot(contains('Summary 0')));
    });
  });

  group('lore + history', () {
    test('lore hits scan the CURRENT chapter passages only', () {
      final book = Lorebook(id: 'lb', name: 'World', entries: [
        LoreEntry(id: 'e1', keys: ['dragon'], content: 'Dragons are extinct.'),
        LoreEntry(id: 'e2', keys: ['ledger'], content: 'The ledger is cursed.'),
      ]);
      final prior = Chapter(
          id: 'c1',
          status: ChapterStatus.concluded,
          summary: 's',
          passages: [
            Message(
                id: 'p0',
                kind: MessageKind.scene,
                variants: ['A dragon roared.'])
          ]);
      final active = Chapter(id: 'c2', aim: 'x', passages: [
        Message(
            id: 'p1',
            kind: MessageKind.user,
            variants: ['I open the ledger.']),
      ]);
      final story = _story(chapters: [prior, active])
        ..attachedLorebookIds = ['lb'];
      final r = buildStoryPrompt(_inputs(story, active,
          lookupBook: (id) => id == 'lb' ? book : null));
      final sys = r.turns.first.content;
      expect(sys, contains('The ledger is cursed.'));
      // 'dragon' appears only in the PRIOR chapter — must not fire.
      expect(sys, isNot(contains('Dragons are extinct.')));
    });

    test('history role mapping + reasoning strip + in-flight skip', () {
      final active = Chapter(id: 'c1', aim: 'x', passages: [
        Message(id: 'p1', kind: MessageKind.user, variants: ['I walk in.']),
        Message(
            id: 'p2',
            kind: MessageKind.scene,
            variants: ['<think>plan</think>The door creaks.']),
        Message(
            id: 'p3',
            kind: MessageKind.char,
            characterId: 'alice',
            variants: ['"Stop," Alice said.']),
        Message(id: 'p4', kind: MessageKind.ooc, variants: ['keep it tense']),
        Message(id: 'p5', kind: MessageKind.char, variants: ['streaming…']),
      ]);
      final story = _story(chapters: [active]);
      final r = buildStoryPrompt(_inputs(story, active));
      final inputs = StoryPromptInputs(
        story: story,
        chapter: active,
        voiceKind: MessageKind.scene,
        persona: null,
        lookupCharacter: (_) => null,
        lookupBook: (_) => null,
        inFlightMessageId: 'p5',
      );
      final r2 = buildStoryPrompt(inputs);
      // r (without skip) has one more history turn than r2 (with skip).
      expect(r.turns.length, r2.turns.length + 1);
      final roles = r2.turns.map((t) => t.role).toList();
      // system, user(p1), assistant(p2), assistant(p3), user(p4), system(instruction)
      expect(roles, ['system', 'user', 'assistant', 'assistant', 'user', 'system']);
      expect(r2.turns[2].content, 'The door creaks.'); // think stripped
      expect(r2.turns[4].content, contains("[Author's note]: keep it tense"));
    });
  });

  group('chapter-end marker protocol', () {
    test('instruction includes the marker only when an aim is set', () {
      final withAim = Chapter(id: 'c1', aim: 'Reach the gates.');
      final noAim = Chapter(id: 'c2');
      final story = _story(chapters: [withAim]);
      final r1 = buildStoryPrompt(_inputs(story, withAim));
      expect(r1.turns.last.content, contains(kChapterEndMarker));
      final story2 = _story(chapters: [noAim]);
      final r2 = buildStoryPrompt(_inputs(story2, noAim));
      expect(r2.turns.last.content, isNot(contains(kChapterEndMarker)));
    });

    test('extractChapterEndSignal strips a trailing marker', () {
      final s = extractChapterEndSignal(
          'The gates opened at last.\n\n[CHAPTER-END?]');
      expect(s.endSuggested, isTrue);
      expect(s.text, 'The gates opened at last.');
    });

    test('tolerates markdown decoration and case', () {
      for (final raw in [
        'Done.\n**[CHAPTER-END?]**',
        'Done.\n`[chapter-end?]`',
        'Done.\n[CHAPTER END?]',
        'Done. [CHAPTER-END?]  ',
      ]) {
        final s = extractChapterEndSignal(raw);
        expect(s.endSuggested, isTrue, reason: raw);
        expect(s.text, 'Done.', reason: raw);
      }
    });

    test('never fires on a mid-text mention', () {
      const raw =
          'She wrote [CHAPTER-END?] on the slate, then kept walking home.';
      final s = extractChapterEndSignal(raw);
      expect(s.endSuggested, isFalse);
      expect(s.text, raw);
    });
  });

  group('{{char}}/{{user}} name fill', () {
    test('macros in cards resolve to voice + persona names', () {
      final alice = _char('alice', 'Alice',
          description: 'She watches {{user}} closely.');
      final story = Story(
        id: 's1',
        title: 'T',
        premise: 'About {{user}}.',
        characterIds: ['alice'],
        characterSnapshots: {'alice': alice},
      );
      final active = Chapter(id: 'c1', aim: 'x');
      story.chapters.add(active);
      final persona = Persona(id: 'me', name: 'Wren', description: '');
      final r = buildStoryPrompt(_inputs(story, active,
          voice: MessageKind.char,
          voiceCharacter: alice,
          persona: persona));
      expect(r.turns.first.content, contains('She watches Wren closely.'));
      expect(r.turns.first.content, contains('About Wren.'));
      expect(r.turns.first.content, isNot(contains('{{user}}')));
    });
  });
}
