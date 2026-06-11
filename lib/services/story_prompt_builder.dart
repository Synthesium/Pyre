// Story Mode — PURE prompt assembly for collaborative human+AI fiction.
//
// `buildStoryPrompt` is the story-mode sibling of `buildChatPrompt`
// (chat_prompt_builder.dart): it takes a `StoryPromptInputs` bundle resolved
// by the chapter screen from the AppStore and returns the outgoing
// `List<ChatTurn>` plus a labeled `PromptSegment` breakdown.
//
// Context layout — deliberately COMPACT and labeled for small local models:
//   System turn (one block):
//     1. Writer framing (prose, not chat)
//     2. --- Premise ---
//     3. --- Cast --- (full card for the chosen VOICE character only;
//        everyone else as a one-line roster; the persona as "the author's
//        character")
//     4. --- The story so far --- (concluded-chapter summaries, oldest
//        trimmed first via recencyBoundedRecap)
//     5. --- Lore --- (keyword hits over the current chapter's passages)
//     6. Current state (live sheet block, carries its own header)
//     7. --- This chapter's aim --- (anti-rush framing adapted from the
//        Story Roadmap)
//   History turns: the CURRENT chapter's passages only (fresh history per
//   chapter is the context-efficiency core of story mode).
//   Post-history system turn: the per-generation instruction — write the
//   next passage as <voice>, plus the [CHAPTER-END?] marker protocol.
//
// CONSTRAINT (same as chat_prompt_builder.dart): imports ONLY models.dart +
// chat_api.dart (ChatTurn / stripStreamArtifacts) + pure sibling services.
// NO app_store.dart, NO package:flutter.

import '../models/models.dart';
import 'chat_api.dart';
import 'chat_prompt_builder.dart'
    show PromptSegment, PromptSegmentKind, fillNamePlaceholders;
import 'live_sheet.dart' as lsheet;
import 'lorebook_inject.dart';
import 'memory.dart' as ltm;
import 'preset_assembly.dart';

/// Soft character budget for the prior-chapter recap block. Chapter
/// summaries run 150–300 words (~1k–2k chars); ~6000 chars keeps roughly the
/// last 3–5 chapters verbatim and trims older ones first — sized below the
/// chat LTM budget because story prompts also carry premise + cast + aim.
const int kStoryRecapCharBudget = 6000;

/// How many of the most-recent chapter summaries are ALWAYS kept whole.
const int _kRecapAlwaysWholeNewest = 2;

/// The marker a generation ends with when the model judges the chapter's aim
/// fulfilled. Detected (and stripped) by [extractChapterEndSignal]; the UI
/// turns it into a non-blocking "end this chapter?" banner.
const String kChapterEndMarker = '[CHAPTER-END?]';

const String _kWriterFraming =
    'You are co-writing a novel with the author. Write polished narrative '
    'prose in the established voice and tense of the story (default: past '
    'tense, third person). Output ONLY manuscript text — no chat formatting, '
    'no headings, no out-of-character commentary, no summaries of what you '
    'wrote.';

const String _kAimHeader =
    "--- This chapter's aim (the author's intention — it has NOT been "
    'fulfilled yet) ---';

/// Anti-rush framing for the chapter aim, adapted from the Story Roadmap
/// (story_roadmap.dart): the aim is a destination, not the next paragraph.
const String _kAimFraming =
    'Build toward this aim GRADUALLY across the chapter. Foreshadow and set '
    'up; advance at most a small step per passage, and only when the story '
    'organically reaches it. Never resolve the whole aim in one passage, and '
    'never state its specific payload before the story has earned it. '
    'Anything already established in the story is done — keep it consistent.';

/// Everything [buildStoryPrompt] needs — bundled so the function has NO
/// AppStore / Flutter dependency (the screen resolves these from the store;
/// tests build them from fixtures).
class StoryPromptInputs {
  final Story story;

  /// The chapter being written (the story's active chapter).
  final Chapter chapter;

  /// The voice the NEXT passage is written in:
  ///   [MessageKind.scene] → the narrator,
  ///   [MessageKind.user]  → the author's persona character,
  ///   [MessageKind.char]  → [voiceCharacter].
  final MessageKind voiceKind;

  /// The cast member whose voice is requested (when [voiceKind] == char).
  final Character? voiceCharacter;

  /// The author's persona (honours `story.personaId`), or null.
  final Persona? persona;

  /// Optional style preset — its ASSEMBLED system text is prepended as
  /// style framing. Post-history preset text is intentionally ignored in
  /// story mode (the per-generation instruction owns that slot).
  final Preset? preset;

  /// Resolves a character id to a library record (`store.characterById`);
  /// the story's frozen snapshot is consulted FIRST at each call site.
  final Character? Function(String id) lookupCharacter;

  /// Resolves a lorebook id (`store.lorebookById`).
  final Lorebook? Function(String id) lookupBook;

  /// The in-flight streaming passage id to SKIP in history replay.
  final String? inFlightMessageId;

  /// Recap budget override (tests); defaults to [kStoryRecapCharBudget].
  final int recapCharBudget;

  const StoryPromptInputs({
    required this.story,
    required this.chapter,
    required this.voiceKind,
    this.voiceCharacter,
    required this.persona,
    this.preset,
    required this.lookupCharacter,
    required this.lookupBook,
    this.inFlightMessageId,
    this.recapCharBudget = kStoryRecapCharBudget,
  });
}

/// The outgoing turns plus a labeled segment breakdown (same shape as
/// `ChatPromptResult` — story mode reuses [PromptSegment] so the prompt-lab
/// tooling can attribute story prompts too).
class StoryPromptResult {
  final List<ChatTurn> turns;
  final List<PromptSegment> segments;
  const StoryPromptResult({required this.turns, required this.segments});
}

/// PURE assembly of the story-mode turns. See the file header for the layout.
StoryPromptResult buildStoryPrompt(StoryPromptInputs inputs) {
  final story = inputs.story;
  final chapter = inputs.chapter;
  final persona = inputs.persona;
  final voiceChar = inputs.voiceKind == MessageKind.char
      ? inputs.voiceCharacter
      : null;
  final segments = <PromptSegment>[];
  final buffer = StringBuffer();

  // 1. Writer framing (+ optional preset style text).
  buffer.writeln(_kWriterFraming);
  segments.add(const PromptSegment(
      PromptSegmentKind.systemPrompt, _kWriterFraming,
      note: 'story writer framing'));
  if (inputs.preset != null) {
    final styleText = assemblePreset(inputs.preset!).systemPrompt.trim();
    if (styleText.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(styleText);
      segments.add(PromptSegment(PromptSegmentKind.systemPrompt, styleText,
          note: 'preset.mainPrompt (style)'));
    }
  }

  // 2. Premise.
  final premise = story.premise.trim();
  if (premise.isNotEmpty) {
    final block = '--- Premise ---\n$premise';
    buffer.writeln();
    buffer.writeln(block);
    segments.add(PromptSegment(PromptSegmentKind.systemPrompt, block,
        note: 'story premise'));
  }

  // 3. Cast — full card for the chosen voice character only, one-line
  // roster for everyone else (mirrors the group-chat roster shape).
  final castBlock = _buildCastBlock(
    story: story,
    voiceCharacter: voiceChar,
    persona: persona,
    lookupCharacter: inputs.lookupCharacter,
  );
  if (castBlock.isNotEmpty) {
    buffer.writeln();
    buffer.writeln(castBlock);
    segments.add(PromptSegment(PromptSegmentKind.character, castBlock));
  }

  // 4. The story so far — concluded chapters' summaries, oldest trimmed
  // first under the budget (reuses the LTM recency-bounded joiner).
  final recap = buildPriorChaptersRecap(
    story,
    excludeChapterId: chapter.id,
    charBudget: inputs.recapCharBudget,
  );
  if (recap.isNotEmpty) {
    final block = '--- The story so far (previous chapters) ---\n$recap';
    buffer.writeln();
    buffer.writeln(block);
    segments.add(PromptSegment(PromptSegmentKind.ltmRecap, block,
        note: 'concluded chapter summaries'));
  }

  // 5. Lore — keyword hits over the CURRENT chapter's passages.
  final books = collectStoryLorebooks(
    story: story,
    persona: persona,
    lookupBook: inputs.lookupBook,
    lookupCharacter: inputs.lookupCharacter,
  );
  final scan = scanLorebookHits(books, chapter.passages);
  if (scan.hits.isNotEmpty) {
    final loreText = scan.hits.map((h) => h.content).join('\n');
    final block = '--- Lore ---\n$loreText';
    buffer.writeln();
    buffer.writeln(block);
    segments.add(PromptSegment(PromptSegmentKind.lorebookBefore, block,
        note:
            '${scan.hits.length} entr${scan.hits.length == 1 ? "y" : "ies"} fired'));
  }

  // 6. Current state (live sheet — block carries its own header/footer).
  if (story.liveSheetEnabled) {
    final liveSheet = lsheet.buildLiveSheetBlockFromSnapshot(
        lsheet.activeStoryLiveSheetSnapshot(story));
    if (liveSheet.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(liveSheet);
      segments.add(PromptSegment(PromptSegmentKind.liveSheet, liveSheet));
    }
  }

  // 7. The chapter's aim, with anti-rush framing.
  final aimBlock = buildChapterAimBlock(chapter);
  if (aimBlock.isNotEmpty) {
    buffer.writeln();
    buffer.writeln(aimBlock);
    segments.add(PromptSegment(PromptSegmentKind.script, aimBlock,
        note: 'chapter aim'));
  }

  final turns = <ChatTurn>[ChatTurn('system', buffer.toString().trim())];

  // History — the current chapter's passages only. Prose carries its own
  // attribution, so bodies go through verbatim (no speaker prefixes);
  // narrator + character passages are assistant turns, the author's
  // persona passages are user turns.
  final historyTurns = <ChatTurn>[];
  for (final m in chapter.passages) {
    if (m.id == inputs.inFlightMessageId) continue;
    final txt = m.text;
    if (txt.trim().isEmpty) continue;
    switch (m.kind) {
      case MessageKind.user:
        historyTurns.add(ChatTurn('user', txt));
        break;
      case MessageKind.char:
      case MessageKind.scene:
        // AI-written passages can carry <think> reasoning in their STORED
        // text (per-passage toggle) — strip it from the outgoing context.
        historyTurns.add(ChatTurn('assistant', stripStreamArtifacts(txt)));
        break;
      case MessageKind.ooc:
        // Author notes ride along as bracketed user guidance.
        historyTurns.add(ChatTurn('user', '[Author\'s note]: $txt'));
        break;
      case MessageKind.system:
        historyTurns.add(ChatTurn('system', txt));
        break;
    }
  }
  turns.addAll(historyTurns);
  if (historyTurns.isNotEmpty) {
    segments.add(PromptSegment(
      PromptSegmentKind.history,
      historyTurns.map((t) => '${t.role}: ${t.content}').join('\n'),
      note: '${historyTurns.length} passage(s)',
    ));
  }

  // Post-history: the per-generation instruction.
  final instruction = _buildGenerationInstruction(
    voiceKind: inputs.voiceKind,
    voiceCharacter: voiceChar,
    persona: persona,
    hasAim: chapter.aim.trim().isNotEmpty,
  );
  turns.add(ChatTurn('system', instruction));
  segments.add(PromptSegment(PromptSegmentKind.postHistory, instruction,
      note: 'generation instruction'));

  // Global name-only macro pass (cards/lore authored with {{char}}/{{user}}),
  // mirroring the chat builder's final pass.
  String nameFill(String s) => fillNamePlaceholders(
        s,
        charName: voiceChar?.name,
        personaName: persona?.name,
      );
  return StoryPromptResult(
    turns: [for (final t in turns) ChatTurn(t.role, nameFill(t.content))],
    segments: [
      for (final s in segments) PromptSegment(s.kind, nameFill(s.text), note: s.note),
    ],
  );
}

/// PURE: the prior-chapter recap — every CONCLUDED chapter's summary (in
/// story order, excluding [excludeChapterId]), formatted as
/// `Chapter N — Title: summary` and joined through the LTM recency-bounded
/// budget so the OLDEST chapters trim first. Chapters without a summary
/// contribute nothing.
String buildPriorChaptersRecap(
  Story story, {
  String? excludeChapterId,
  int charBudget = kStoryRecapCharBudget,
}) {
  final parts = <String>[];
  for (var i = 0; i < story.chapters.length; i++) {
    final c = story.chapters[i];
    if (c.id == excludeChapterId) continue;
    if (!c.concluded) continue;
    final summary = c.summary.trim();
    if (summary.isEmpty) continue;
    parts.add('${c.displayTitle(i + 1)}: $summary');
  }
  return ltm.recencyBoundedRecap(
    parts,
    charBudget: charBudget,
    alwaysWholeNewest: _kRecapAlwaysWholeNewest,
  );
}

/// PURE: the aim block injected into the system prompt — header + anti-rush
/// framing + the author's aim. Empty when the chapter has no aim.
String buildChapterAimBlock(Chapter chapter) {
  final aim = chapter.aim.trim();
  if (aim.isEmpty) return '';
  return '$_kAimHeader\n$_kAimFraming\n$aim\n--- end aim ---';
}

String _buildCastBlock({
  required Story story,
  required Character? voiceCharacter,
  required Persona? persona,
  required Character? Function(String id) lookupCharacter,
}) {
  final buf = StringBuffer();
  buf.writeln('--- Cast ---');
  var any = false;

  // Full card for the chosen voice character (the model writes AS them, so
  // it needs the complete sheet; the rest of the cast stays one-line to keep
  // the context compact for local models).
  if (voiceCharacter != null) {
    any = true;
    buf.writeln('${voiceCharacter.name}:');
    if (voiceCharacter.description.trim().isNotEmpty) {
      buf.writeln(voiceCharacter.description.trim());
    }
    if (voiceCharacter.personality.trim().isNotEmpty) {
      buf.writeln('Personality: ${voiceCharacter.personality.trim()}');
    }
    buf.writeln();
  }

  for (final id in story.characterIds) {
    if (id == voiceCharacter?.id) continue;
    final c = story.characterSnapshots[id] ?? lookupCharacter(id);
    if (c == null) continue;
    any = true;
    final line = (c.tagline?.trim().isNotEmpty ?? false)
        ? c.tagline!.trim()
        : c.description.split('\n').first.trim();
    buf.writeln('• ${c.name}: $line');
  }

  if (persona != null) {
    any = true;
    final desc = persona.description.trim();
    buf.writeln(
        '• ${persona.name} (the author\'s own character)${desc.isEmpty ? '' : ': $desc'}');
  }

  if (!any) return '';
  return buf.toString().trimRight();
}

String _buildGenerationInstruction({
  required MessageKind voiceKind,
  required Character? voiceCharacter,
  required Persona? persona,
  required bool hasAim,
}) {
  final String voicePhrase;
  switch (voiceKind) {
    case MessageKind.char:
      final name = voiceCharacter?.name ?? 'the character';
      voicePhrase = '$name — their point of view, actions, and dialogue. '
          'Other characters may appear, but $name carries the passage';
      break;
    case MessageKind.user:
      final name = persona?.name ?? 'the author\'s character';
      voicePhrase = '$name — their point of view, actions, and dialogue';
      break;
    case MessageKind.scene:
    case MessageKind.ooc:
    case MessageKind.system:
      voicePhrase = 'the narrator — third-person prose moving the scene '
          'forward, free to describe any character\'s actions and dialogue';
      break;
  }
  final buf = StringBuffer()
    ..writeln('Continue the story with the next passage, written as '
        '$voicePhrase.')
    ..write('Stay consistent with the premise, the story so far, the lore, '
        'and the current state. Write 200–400 words and stop at a natural '
        'beat — do not finish the whole scene in one passage.');
  if (hasAim) {
    buf
      ..writeln()
      ..write('If — and ONLY if — this passage brings the chapter\'s aim to '
          'a natural, satisfying close, end your output with the marker '
          '$kChapterEndMarker alone on the final line. Otherwise never write '
          'that marker.');
  }
  return buf.toString();
}

/// Result of [extractChapterEndSignal]: the passage text with any trailing
/// chapter-end marker removed, plus whether the marker was present.
class ChapterEndSignal {
  final String text;
  final bool endSuggested;
  const ChapterEndSignal(this.text, this.endSuggested);
}

/// Trailing-marker matcher: the marker on (or near) the final line, tolerant
/// of surrounding whitespace and markdown decoration (`**…**`, backticks,
/// stray punctuation) that small models like to add. Anchored to the END of
/// the text so a mid-passage mention can never fire.
final RegExp _kEndMarkerTail = RegExp(
  r'[\s*_`>~-]*\[\s*CHAPTER[-\s]?END\s*\??\s*\][\s*_`.!~-]*$',
  caseSensitive: false,
);

/// PURE: detect + strip the [kChapterEndMarker] from a finished generation.
/// The stored passage text must never carry the marker (it is a protocol
/// artifact, not manuscript), so callers store `.text` and read
/// `.endSuggested` for the confirm-banner.
ChapterEndSignal extractChapterEndSignal(String raw) {
  final m = _kEndMarkerTail.firstMatch(raw);
  if (m == null) return ChapterEndSignal(raw, false);
  return ChapterEndSignal(raw.substring(0, m.start).trimRight(), true);
}
