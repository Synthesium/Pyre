// Story Mode — chapter summary generation.
//
// When a chapter concludes, ONE recap (150–300 words of flowing prose) is
// drafted by the LLM, shown to the user for editing, and stored as
// `Chapter.summary`. Concluded chapters are frozen, so unlike chat LTM
// checkpoints there is no branch validity to track — the summary is the
// chapter's single carried-forward memory, injected into every later
// chapter's prompt as "the story so far".
//
// The LLM hygiene (anti-continuation discipline, retry-on-blip, bounded
// continuation of truncated output, reasoning-fallback sanitising) is shared
// with the chat summariser via memory.dart's public helpers — the two recap
// paths must never drift.
//
// Body + system prompt builders are PURE (unit-tested);
// [generateChapterSummary] is the orchestration wrapper.

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/models.dart';
import 'chat_api.dart';
import 'memory.dart' as ltm;
import 'story_prompt_builder.dart' show buildPriorChaptersRecap;

/// In-memory error log for chapter-summary LLM failures (mirrors
/// MemoryErrors — capped, newest first, cleared by the UI via [clear]).
class ChapterSummaryErrors {
  ChapterSummaryErrors._();
  static final List<String> log = [];
  static const int _max = 20;

  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[ChapterSummary] $msg');
    log.insert(0, msg);
    if (log.length > _max) {
      log.removeRange(_max, log.length);
    }
  }

  static void clear() => log.clear();
}

/// Maximum number of EXTRA continuation calls after the first response —
/// same bound and rationale as the chat summariser.
const int _kMaxContinuations = 2;

const String _kContinuePrompt =
    'Continue the chapter summary from where you left off. '
    'Do not repeat anything, no preamble, and keep summarising — '
    'do not start writing new story.';

/// The anti-continuation discipline is identical in spirit to the chat
/// summariser's block (memory.dart resolveSystemPrompt): the task is a
/// RECAP of events that already happened, never an extension of them.
const String kChapterSummarySystemPrompt =
    'IMPORTANT — YOUR TASK IS A CHAPTER RECAP, NOT A STORY CONTINUATION. '
    'You are SUMMARISING a finished chapter of a novel so it can be carried '
    'forward as long-term memory. Do NOT advance the plot. Do NOT invent '
    'new events. Do NOT write any action, dialogue, or outcome that does '
    'not appear in the passages provided. RETELL what happened in the PAST '
    'tense.\n\n'
    'Summarise this chapter in 150–300 words of flowing narrative prose '
    '(not a bulleted log), covering: what happened, the decisions made, how '
    'characters and relationships changed, and where things stand as the '
    'chapter ends. Output the summary text only — no title, no preamble.';

/// PURE: the user-turn body for the summariser call — prior chapter
/// summaries as established canon (do-NOT-retell), then this chapter's
/// passages verbatim. [personaLabel] names the author's-persona passages
/// (falls back to 'The author\'s character'); character passages are
/// labeled with the speaking character's name when resolvable.
String buildChapterSummaryBody({
  required Story story,
  required Chapter chapter,
  String? personaLabel,
}) {
  final body = StringBuffer();

  final priorRecap = buildPriorChaptersRecap(
    story,
    excludeChapterId: chapter.id,
  );
  if (priorRecap.isNotEmpty) {
    body.writeln(
        '## The story so far (already summarised — context only, do NOT retell):');
    body.writeln(priorRecap);
    body.writeln();
  }

  if (chapter.aim.trim().isNotEmpty) {
    body.writeln("## The author's aim for this chapter was:");
    body.writeln(chapter.aim.trim());
    body.writeln();
  }

  body.writeln('## The chapter\'s passages — summarise THESE:');
  for (final m in chapter.passages) {
    final text = m.text.trim();
    if (text.isEmpty) continue;
    final String label;
    switch (m.kind) {
      case MessageKind.scene:
        label = 'Narration';
        break;
      case MessageKind.user:
        label = personaLabel ?? "The author's character";
        break;
      case MessageKind.char:
        label = _characterName(story, m.characterId) ?? 'Character';
        break;
      case MessageKind.ooc:
        // Author notes are process, not story — they don't belong in a
        // manuscript recap.
        continue;
      case MessageKind.system:
        label = 'Note';
        break;
    }
    // AI-written passages can carry <think> reasoning in their stored text —
    // never feed chain-of-thought to the summariser.
    body.writeln('$label: ${stripStreamArtifacts(text)}');
  }
  return body.toString();
}

String? _characterName(Story story, String? characterId) {
  if (characterId == null) return null;
  return story.characterSnapshots[characterId]?.name;
}

/// Floors maxTokens at 1024 so a low global setting can't truncate a
/// compliant 150–300-word recap (same guard as the chat summariser).
ModelSettings _summarySettings(ModelSettings base) {
  if (base.maxTokens >= 1024) return base;
  return ModelSettings.fromJson(base.toJson())..maxTokens = 1024;
}

/// Draft the chapter summary. Returns the recap text, or null on failure
/// (recorded in [ChapterSummaryErrors]) — the UI then offers retry or a
/// manual write-it-yourself fallback. The caller stores the (possibly
/// user-edited) result via `AppStore.concludeChapter`.
Future<String?> generateChapterSummary({
  required Story story,
  required Chapter chapter,
  required ApiProvider provider,
  required ModelSettings settings,
  String? personaLabel,
}) async {
  if (provider.baseUrl.isEmpty) {
    ChapterSummaryErrors.record(
        'generateChapterSummary', 'provider has no base URL');
    return null;
  }
  final turns = <ChatTurn>[
    ChatTurn('system', kChapterSummarySystemPrompt),
    ChatTurn(
        'user',
        buildChapterSummaryBody(
          story: story,
          chapter: chapter,
          personaLabel: personaLabel,
        )),
  ];

  try {
    // ONE automatic retry on an empty/errored first call (transient provider
    // blips self-heal), then a bounded continuation loop for truncated
    // output — mirrors generateCheckpoint.
    var firstChunk = '';
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      try {
        firstChunk = (await ltm.completeRecapSanitized(
          provider: provider,
          settings: _summarySettings(settings),
          messages: turns,
          debugTag: 'chsum',
        ))
            .trim();
        if (firstChunk.isNotEmpty) break;
        lastErr = 'empty reply';
      } catch (e) {
        lastErr = e;
      }
    }
    if (firstChunk.isEmpty) {
      ChapterSummaryErrors.record('generateChapterSummary',
          'LLM returned no summary after retry: $lastErr');
      return null;
    }

    var accumulated = firstChunk;
    final continuationTurns = List<ChatTurn>.from(turns);
    for (var i = 0; i < _kMaxContinuations; i++) {
      if (ltm.recapLooksComplete(accumulated)) break;
      continuationTurns.add(ChatTurn('assistant', accumulated));
      continuationTurns.add(ChatTurn('user', _kContinuePrompt));
      final chunk = (await ltm.completeRecapSanitized(
        provider: provider,
        settings: _summarySettings(settings),
        messages: continuationTurns,
        debugTag: 'chsum',
      ))
          .trim();
      if (chunk.isEmpty) break;
      accumulated = '$accumulated $chunk';
    }
    return accumulated.trim();
  } catch (e) {
    ChapterSummaryErrors.record('generateChapterSummary', e);
    return null;
  }
}
