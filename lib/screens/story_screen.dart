// Story Mode — the per-story hub, doubling as the "story so far" panel.
//
// Shows the premise, cast, the reorderable chapter list (status, word count,
// summary excerpt), and the running storyline (the literal recap text the AI
// receives). Hosts: chapter aim flow (new chapter), concluded-chapter summary
// viewing/editing, manuscript export, story detail edits, delete.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show XFile;

import '../models/models.dart';
import '../services/chat_export.dart' show safeExportStem, writeExportFile;
import '../services/manuscript_export.dart';
import '../services/story_prompt_builder.dart' show buildPriorChaptersRecap;
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/export_snack.dart';
import 'chapter_screen.dart';

class StoryScreen extends StatefulWidget {
  final String storyId;

  /// When true (the new-story flow), the Chapter 1 aim dialog opens on the
  /// first frame so the user lands ready to write.
  final bool promptFirstChapter;

  const StoryScreen(
      {super.key, required this.storyId, this.promptFirstChapter = false});

  @override
  State<StoryScreen> createState() => _StoryScreenState();
}

class _StoryScreenState extends State<StoryScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.promptFirstChapter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final store = context.read<AppStore>();
        final story = store.storyById(widget.storyId);
        if (story != null && story.chapters.isEmpty) {
          _startNextChapter(story);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final story = store.storyById(widget.storyId);
    if (story == null || story.deleted) {
      // Deleted under us (e.g. via sync) — back out gracefully.
      return const Scaffold(body: SizedBox.shrink());
    }
    final stats = storyWordStats(story);
    final title =
        story.title.trim().isEmpty ? 'Untitled story' : story.title.trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'edit':
                  _editDetails(story);
                  break;
                case 'export':
                  _exportManuscript(story);
                  break;
                case 'delete':
                  _deleteStory(story);
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'edit', child: Text('Edit title & premise')),
              PopupMenuItem(
                  value: 'export', child: Text('Export manuscript')),
              PopupMenuItem(value: 'delete', child: Text('Delete story')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (story.premise.trim().isNotEmpty) ...[
            _SectionLabel('PREMISE'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: EmberColors.bgPanel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: EmberColors.stroke),
              ),
              child: Text(story.premise.trim(),
                  style: const TextStyle(
                      color: EmberColors.textMid, height: 1.4)),
            ),
            const SizedBox(height: 16),
          ],
          if (story.characterIds.isNotEmpty || _persona(store, story) != null) ...[
            _SectionLabel('CAST'),
            _CastRow(story: story),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              _SectionLabel('CHAPTERS'),
              const Spacer(),
              Text('${stats.totalWords} words total',
                  style: const TextStyle(
                      color: EmberColors.textDim, fontSize: 12)),
            ],
          ),
          if (story.chapters.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No chapters yet — start the first one below.',
                style: TextStyle(color: EmberColors.textDim),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: story.chapters.length,
              // onReorderItem already adjusts newIndex for the removed slot
              // (unlike the deprecated onReorder).
              onReorderItem: (oldIdx, newIdx) => context
                  .read<AppStore>()
                  .reorderChapters(story.id, oldIdx, newIdx),
              itemBuilder: (context, i) {
                final c = story.chapters[i];
                return _ChapterTile(
                  key: ValueKey(c.id),
                  story: story,
                  chapter: c,
                  number: i + 1,
                  index: i,
                  words: stats.wordsByChapter[c.id] ?? 0,
                  onTap: () => _openChapter(story, c),
                );
              },
            ),
          const SizedBox(height: 16),
          if (story.chapters.any((c) => c.concluded)) ...[
            _SectionLabel('THE STORY SO FAR'),
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'The running storyline carried into every new chapter — '
                'exactly what the AI is told about previous chapters.',
                style: TextStyle(color: EmberColors.textDim, fontSize: 12),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: EmberColors.bgPanel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: EmberColors.stroke),
              ),
              child: Text(
                buildPriorChaptersRecap(story),
                style: const TextStyle(
                    color: EmberColors.textMid, height: 1.45, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          final active = story.activeChapter;
          if (active != null) {
            _openChapter(story, active);
          } else {
            _startNextChapter(story);
          }
        },
        icon: Icon(story.activeChapter != null
            ? Icons.edit_outlined
            : Icons.add),
        label: Text(story.activeChapter != null
            ? 'Continue writing'
            : (story.chapters.isEmpty ? 'Start Chapter 1' : 'Next chapter')),
      ),
    );
  }

  Persona? _persona(AppStore store, Story story) {
    final pid = story.personaId;
    if (pid == kExplicitNoPersonaId) return null;
    if (pid != null) {
      final p = store.personaById(pid);
      if (p != null && !p.deleted) return p;
    }
    return store.activePersona;
  }

  void _openChapter(Story story, Chapter chapter) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          ChapterScreen(storyId: story.id, chapterId: chapter.id),
    ));
  }

  Future<void> _startNextChapter(Story story) async {
    final result = await showChapterAimDialog(
      context,
      chapterNumber: story.chapters.length + 1,
    );
    if (result == null || !mounted) return;
    final store = context.read<AppStore>();
    final chapter =
        store.addChapter(story.id, aim: result.aim, title: result.title);
    _openChapter(story, chapter);
  }

  Future<void> _editDetails(Story story) async {
    final titleCtl = TextEditingController(text: story.title);
    final premiseCtl = TextEditingController(text: story.premise);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Story details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtl,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: premiseCtl,
              maxLines: 4,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Premise'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final store = context.read<AppStore>();
      story.title = titleCtl.text.trim();
      story.premise = premiseCtl.text.trim();
      store.touchStory(story);
    }
  }

  Future<void> _deleteStory(Story story) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete story?',
      message: 'All chapters and passages will be lost forever.',
    );
    if (!ok || !mounted) return;
    context.read<AppStore>().removeStory(story.id);
    Navigator.of(context).pop();
  }

  Future<void> _exportManuscript(Story story) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final content = storyToMarkdown(story);
      final stem = safeExportStem(
          story.title.trim().isEmpty ? 'story' : story.title.trim());

      if (kIsWeb) {
        await Clipboard.setData(ClipboardData(text: content));
        messenger.showSnackBar(const SnackBar(
            content: Text(
                'Web: copied Markdown to clipboard. Paste into a text editor and save.')));
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final path = await writeExportFile(
        baseDir: dir,
        stem: stem,
        extension: 'md',
        content: content,
      );
      if (!mounted) return;
      await deliverExport(
        messenger,
        [XFile(path, mimeType: 'text/markdown')],
        savedBanner: 'Exported — ${Uri.file(path).pathSegments.last}',
        shareSubject: 'Manuscript — ${story.title}',
        shareText: 'Markdown manuscript exported from Pyre.',
        saveBytes: Uint8List.fromList(utf8.encode(content)),
        saveFileName: Uri.file(path).pathSegments.last,
        saveExtensions: const ['md'],
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                letterSpacing: 0.4)),
      );
}

class _CastRow extends StatelessWidget {
  final Story story;
  const _CastRow({required this.story});

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    Persona? persona;
    final pid = story.personaId;
    if (pid != kExplicitNoPersonaId) {
      persona = (pid != null ? store.personaById(pid) : null) ??
          store.activePersona;
    }
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (persona != null)
            _castChip(persona.avatar, persona.name, '(you)'),
          for (final id in story.characterIds)
            if ((story.characterSnapshots[id] ?? store.characterById(id))
                case final c?)
              _castChip(c.avatar, c.name, null),
        ],
      ),
    );
  }

  Widget _castChip(String? avatar, String name, String? tag) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AvatarBubble(dataUrl: avatar, fallback: name, radius: 20),
            const SizedBox(height: 4),
            Text(
              tag == null ? name : '$name $tag',
              style: const TextStyle(
                  color: EmberColors.textDim, fontSize: 11),
            ),
          ],
        ),
      );
}

class _ChapterTile extends StatelessWidget {
  final Story story;
  final Chapter chapter;
  final int number;
  final int index;
  final int words;
  final VoidCallback onTap;
  const _ChapterTile({
    super.key,
    required this.story,
    required this.chapter,
    required this.number,
    required this.index,
    required this.words,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final concluded = chapter.concluded;
    final summary = chapter.summary.trim();
    return Card(
      color: EmberColors.bgPanel,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: EmberColors.stroke),
      ),
      child: ListTile(
        onTap: onTap,
        title: Row(
          children: [
            Flexible(
              child: Text(
                chapter.displayTitle(number),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: EmberColors.textHigh,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: concluded
                    ? EmberColors.bgElevated
                    : EmberColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                concluded ? 'Concluded' : 'Active',
                style: TextStyle(
                  fontSize: 10,
                  color: concluded
                      ? EmberColors.textDim
                      : EmberColors.primary,
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (concluded && summary.isNotEmpty)
              Text(summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: EmberColors.textMid, fontSize: 12.5)),
            if (!concluded && chapter.aim.trim().isNotEmpty)
              Text('Aim: ${chapter.aim.trim()}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: EmberColors.textMid, fontSize: 12.5)),
            Text('$words words',
                style: const TextStyle(
                    color: EmberColors.textDim, fontSize: 11)),
          ],
        ),
        trailing: ReorderableDragStartListener(
          index: index,
          child: const Icon(Icons.drag_handle, color: EmberColors.textDim),
        ),
      ),
    );
  }
}

/// The aim entered when starting a chapter (optional title + the intention).
class ChapterAimResult {
  final String title;
  final String aim;
  const ChapterAimResult({required this.title, required this.aim});
}

/// The chapter-aim dialog — shared by the story screen (next chapter) and
/// the chapter screen's end-of-chapter flow. Returns null on cancel.
Future<ChapterAimResult?> showChapterAimDialog(
  BuildContext context, {
  required int chapterNumber,
  String? initialTitle,
  String? initialAim,
}) {
  final titleCtl = TextEditingController(text: initialTitle ?? '');
  final aimCtl = TextEditingController(text: initialAim ?? '');
  return showDialog<ChapterAimResult>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text('Chapter $chapterNumber'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: titleCtl,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Title (optional)',
              hintText: 'Chapter $chapterNumber',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: aimCtl,
            maxLines: 4,
            minLines: 2,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Aim for this chapter',
              hintText:
                  'Where should this chapter take the story? The AI builds '
                  'toward this gradually and suggests ending the chapter '
                  'when it\'s reached.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(
              ctx,
              ChapterAimResult(
                  title: titleCtl.text.trim(), aim: aimCtl.text.trim())),
          child: const Text('Start writing'),
        ),
      ],
    ),
  );
}
