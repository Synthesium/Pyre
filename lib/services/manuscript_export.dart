// Story Mode — manuscript export + word statistics. PURE (no AppStore, no
// Flutter, no I/O — the screen handles file save/share like chat_export's
// consumers do).
//
// The manuscript is the manuscript: every narrative passage (narrator,
// character, author's-persona) joins as flowing paragraphs regardless of who
// — human or AI — wrote it. Author notes (ooc) and system passages are
// process, not prose, and are excluded.

import '../models/models.dart';
import 'chat_api.dart' show stripStreamArtifacts;

/// Word counts for a story — totals plus a per-chapter breakdown (keyed by
/// chapter id). Powers both the export footer and the Pure-Writer-style
/// counts in the story / chapter screens.
class StoryWordStats {
  final int totalWords;
  final Map<String, int> wordsByChapter;
  const StoryWordStats({required this.totalWords, required this.wordsByChapter});
}

/// Whitespace-split word count; empty/blank → 0.
int countWords(String text) {
  final t = text.trim();
  if (t.isEmpty) return 0;
  return t.split(RegExp(r'\s+')).length;
}

/// True for passage kinds that are manuscript prose (everything the export
/// and the word counts include).
bool isProsePassage(Message m) =>
    m.kind == MessageKind.scene ||
    m.kind == MessageKind.char ||
    m.kind == MessageKind.user;

/// The passage's manuscript text: the selected variant, reasoning-stripped.
String passageProse(Message m) => stripStreamArtifacts(m.text).trim();

StoryWordStats storyWordStats(Story story) {
  var total = 0;
  final byChapter = <String, int>{};
  for (final c in story.chapters) {
    var words = 0;
    for (final m in c.passages) {
      if (!isProsePassage(m)) continue;
      words += countWords(passageProse(m));
    }
    byChapter[c.id] = words;
    total += words;
  }
  return StoryWordStats(totalWords: total, wordsByChapter: byChapter);
}

/// Compile [story] into one Markdown document: `# Title`, optional premise
/// blockquote, `## Chapter N — Title` headings, passages as paragraphs
/// separated by blank lines. Chapters with no prose still emit their heading
/// (the outline survives the export).
String storyToMarkdown(
  Story story, {
  bool includePremise = false,
}) {
  final buf = StringBuffer();
  final title = story.title.trim();
  buf.writeln('# ${title.isEmpty ? 'Untitled story' : title}');
  if (includePremise && story.premise.trim().isNotEmpty) {
    buf.writeln();
    for (final line in story.premise.trim().split('\n')) {
      buf.writeln('> $line');
    }
  }
  for (var i = 0; i < story.chapters.length; i++) {
    final c = story.chapters[i];
    buf.writeln();
    buf.writeln('## ${c.displayTitle(i + 1)}');
    for (final m in c.passages) {
      if (!isProsePassage(m)) continue;
      final prose = passageProse(m);
      if (prose.isEmpty) continue;
      buf.writeln();
      buf.writeln(prose);
    }
  }
  return '${buf.toString().trimRight()}\n';
}
