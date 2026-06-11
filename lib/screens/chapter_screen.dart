// Story Mode — the chapter writing surface.
//
// Prose presentation (full-width paragraphs, no chat bubbles): the manuscript
// reads as a manuscript. The bottom bar carries the VOICE SWITCHER — write
// manually as the Narrator, yourself (persona), or any cast member — and the
// AI-continue action, which generates the next passage as the selected voice.
// AI use is fully optional per passage ("chat with self").
//
// Chapter lifecycle: a pinned (collapsible) aim header; the AI suggests
// ending the chapter via the [CHAPTER-END?] marker (non-blocking banner, user
// confirms); "End chapter" is always available from the menu. Concluding
// drafts an AI summary (editable, regenerable, manual fallback), then offers
// to start the next chapter with a fresh aim.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chapter_summary.dart';
import '../services/chat_api.dart';
import '../services/generation_keepalive.dart';
import '../services/live_sheet.dart';
import '../services/manuscript_export.dart';
import '../services/story_prompt_builder.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/chat_text.dart';
import '../widgets/confirm_dialog.dart';
import 'story_screen.dart' show showChapterAimDialog;

/// The voice a passage is written in. Narrator/self map straight onto
/// MessageKind; each cast member is a char voice with their id.
class _Voice {
  final MessageKind kind;
  final Character? character; // when kind == char
  final String label;
  const _Voice(this.kind, this.label, {this.character});
}

class ChapterScreen extends StatefulWidget {
  final String storyId;
  final String chapterId;
  const ChapterScreen(
      {super.key, required this.storyId, required this.chapterId});

  @override
  State<ChapterScreen> createState() => _ChapterScreenState();
}

class _ChapterScreenState extends State<ChapterScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Selected voice index into [_voices] (0 = Narrator).
  int _voiceIndex = 0;

  bool _aimExpanded = true;
  bool _generating = false;
  bool _endSuggested = false;
  String? _streamPassageId;
  int _streamVariantIndex = 0;
  String _streamBuffer = '';
  StreamSubscription<String>? _streamSub;

  // Foreground keep-alive refs (see chat_screen.dart H-1 for rationale).
  int _keepAliveHeld = 0;
  Future<void> _keepAliveStart() {
    _keepAliveHeld++;
    return GenerationKeepAlive.start();
  }

  void _keepAliveStop() {
    if (_keepAliveHeld > 0) {
      _keepAliveHeld--;
      unawaited(GenerationKeepAlive.stop());
    }
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    while (_keepAliveHeld > 0) {
      _keepAliveStop();
    }
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Story? get _story => context.read<AppStore>().storyById(widget.storyId);

  Chapter? _chapterOf(Story? story) {
    if (story == null) return null;
    for (final c in story.chapters) {
      if (c.id == widget.chapterId) return c;
    }
    return null;
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

  List<_Voice> _voices(AppStore store, Story story) {
    final persona = _persona(store, story);
    return [
      const _Voice(MessageKind.scene, 'Narrator'),
      if (persona != null) _Voice(MessageKind.user, '${persona.name} (you)'),
      for (final id in story.characterIds)
        if ((story.characterSnapshots[id] ?? store.characterById(id))
            case final c?)
          _Voice(MessageKind.char, c.name, character: c),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final story = store.storyById(widget.storyId);
    final chapter = _chapterOf(story);
    if (story == null || story.deleted || chapter == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final number = story.chapters.indexOf(chapter) + 1;
    final voices = _voices(store, story);
    if (_voiceIndex >= voices.length) _voiceIndex = 0;
    final concluded = chapter.concluded;
    final words = storyWordStats(story).wordsByChapter[chapter.id] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(chapter.displayTitle(number),
                style: const TextStyle(fontSize: 17)),
            Text('$words words${concluded ? ' · concluded' : ''}',
                style: const TextStyle(
                    fontSize: 11, color: EmberColors.textDim)),
          ],
        ),
        actions: [
          if (!concluded)
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'aim':
                    _editAim(story, chapter);
                    break;
                  case 'rename':
                    _renameChapter(story, chapter, number);
                    break;
                  case 'end':
                    _endChapterFlow(story, chapter);
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'aim', child: Text('Edit aim')),
                PopupMenuItem(value: 'rename', child: Text('Rename chapter')),
                PopupMenuItem(value: 'end', child: Text('End chapter…')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (chapter.aim.trim().isNotEmpty && !concluded)
            _AimHeader(
              aim: chapter.aim.trim(),
              expanded: _aimExpanded,
              onToggle: () => setState(() => _aimExpanded = !_aimExpanded),
            ),
          if (concluded && chapter.summary.trim().isNotEmpty)
            _SummaryHeader(summary: chapter.summary.trim()),
          Expanded(child: _buildManuscript(store, story, chapter, voices)),
          if (_endSuggested && !concluded)
            _EndSuggestedBanner(
              onEnd: () {
                setState(() => _endSuggested = false);
                _endChapterFlow(story, chapter);
              },
              onDismiss: () => setState(() => _endSuggested = false),
            ),
          if (!concluded) _buildInputBar(store, story, chapter, voices),
        ],
      ),
    );
  }

  // ── Manuscript ───────────────────────────────────────────────────────────

  Widget _buildManuscript(
      AppStore store, Story story, Chapter chapter, List<_Voice> voices) {
    if (chapter.passages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            chapter.aim.trim().isEmpty
                ? 'A blank page. Write the first passage — or let the AI '
                    'open the chapter.'
                : 'A blank page. Write the first passage as any voice — or '
                    'tap ✨ to let the AI open the chapter.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: EmberColors.textDim, height: 1.5),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: chapter.passages.length,
      itemBuilder: (context, i) {
        final m = chapter.passages[i];
        final isLast = i == chapter.passages.length - 1;
        final streaming = m.id == _streamPassageId;
        return _PassageView(
          message: m,
          voiceLabel: _passageVoiceLabel(store, story, m),
          streaming: streaming,
          showVariantNav: isLast && m.variants.length > 1 && !_generating,
          onPrevVariant: () => store.setPassageVariant(
              story.id, chapter.id, m.id, m.selectedVariant - 1),
          onNextVariant: () => store.setPassageVariant(
              story.id, chapter.id, m.id, m.selectedVariant + 1),
          onReroll: isLast && !chapter.concluded && !_generating
              ? () => _rerollLast(story, chapter)
              : null,
          onTap: chapter.concluded || _generating
              ? null
              : () => _editPassage(story, chapter, m),
        );
      },
    );
  }

  String? _passageVoiceLabel(AppStore store, Story story, Message m) {
    switch (m.kind) {
      case MessageKind.scene:
        return null; // narrator prose is bare — it IS the manuscript
      case MessageKind.user:
        return _persona(store, story)?.name ?? 'You';
      case MessageKind.char:
        final id = m.characterId;
        if (id == null) return 'Character';
        return (story.characterSnapshots[id] ?? store.characterById(id))
                ?.name ??
            'Character';
      case MessageKind.ooc:
        return 'Author note';
      case MessageKind.system:
        return 'Note';
    }
  }

  // ── Input bar ────────────────────────────────────────────────────────────

  Widget _buildInputBar(
      AppStore store, Story story, Chapter chapter, List<_Voice> voices) {
    final voice = voices[_voiceIndex];
    return Container(
      decoration: const BoxDecoration(
        color: EmberColors.bgPanel,
        border: Border(top: BorderSide(color: EmberColors.stroke)),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 8,
        bottom: 8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: voices.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final v = voices[i];
                final selected = i == _voiceIndex;
                return ChoiceChip(
                  label: Text(v.label, style: const TextStyle(fontSize: 12)),
                  selected: selected,
                  visualDensity: VisualDensity.compact,
                  avatar: v.kind == MessageKind.scene
                      ? const Icon(Icons.auto_stories, size: 14)
                      : null,
                  onSelected: (_) => setState(() => _voiceIndex = i),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !_generating,
                  maxLines: 6,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Write as ${voice.label}…',
                    hintStyle: const TextStyle(color: EmberColors.textDim),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_generating)
                IconButton.filled(
                  tooltip: 'Stop generating',
                  onPressed: _stopGeneration,
                  icon: const Icon(Icons.stop),
                )
              else ...[
                IconButton(
                  tooltip: 'Add your passage',
                  onPressed: () => _addManualPassage(story, chapter, voice),
                  icon: const Icon(Icons.check, color: EmberColors.textMid),
                ),
                IconButton.filled(
                  tooltip: 'AI continues as ${voice.label}',
                  onPressed: () => _aiContinue(story, chapter, voice),
                  icon: const Icon(Icons.auto_awesome, size: 20),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ── Manual writing ───────────────────────────────────────────────────────

  void _addManualPassage(Story story, Chapter chapter, _Voice voice) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final store = context.read<AppStore>();
    store.addPassage(
      story.id,
      chapter.id,
      Message(
        id: newId('msg'),
        kind: voice.kind,
        characterId: voice.character?.id,
        variants: [text],
        mtime: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _input.clear();
    _scrollToBottom();
  }

  Future<void> _editPassage(Story story, Chapter chapter, Message m) async {
    final store = context.read<AppStore>();
    final ctl = TextEditingController(text: m.text);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: EmberColors.bgPanel,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              maxLines: 12,
              minLines: 3,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Edit passage'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: EmberColors.danger),
                  onPressed: () => Navigator.pop(ctx, 'delete'),
                  child: const Text('Delete'),
                ),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, 'save'),
                    child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'save') {
      store.updatePassageText(story.id, chapter.id, m.id, ctl.text);
    } else if (action == 'delete') {
      final ok = await confirmDelete(
        context,
        title: 'Delete passage?',
        message: 'This passage will be removed from the manuscript.',
      );
      if (ok) store.removePassage(story.id, chapter.id, m.id);
    }
  }

  // ── AI generation ────────────────────────────────────────────────────────

  Future<void> _aiContinue(Story story, Chapter chapter, _Voice voice) async {
    final store = context.read<AppStore>();
    final provider = store.activeProvider;
    if (provider == null || provider.baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No provider configured. Open "More → API Connections".')));
      return;
    }

    // Anything typed in the box rides along as the user's own passage first
    // (so "write a line, then let the AI take over" is one tap).
    _addManualPassage(story, chapter, voice);

    final passage = Message(
      id: newId('msg'),
      kind: voice.kind,
      characterId: voice.character?.id,
      variants: [''],
      mtime: DateTime.now().millisecondsSinceEpoch,
    );
    store.addPassage(story.id, chapter.id, passage);
    await _streamInto(story, chapter, voice, passage.id, 0);
  }

  /// Re-roll the LAST passage as a fresh variant, generated with the same
  /// voice the passage already carries.
  Future<void> _rerollLast(Story story, Chapter chapter) async {
    final store = context.read<AppStore>();
    if (chapter.passages.isEmpty || _generating) return;
    final last = chapter.passages.last;
    final voice = _voices(store, story).firstWhere(
      (v) => v.kind == last.kind && v.character?.id == last.characterId,
      orElse: () => _voices(store, story).first,
    );
    final idx = store.addPassageVariant(story.id, chapter.id, last.id);
    if (idx < 0) return;
    await _streamInto(story, chapter, voice, last.id, idx);
  }

  Future<void> _streamInto(Story story, Chapter chapter, _Voice voice,
      String passageId, int variantIndex) async {
    final store = context.read<AppStore>();
    final provider = store.activeProvider;
    if (provider == null) return;

    setState(() {
      _generating = true;
      _endSuggested = false;
      _streamPassageId = passageId;
      _streamVariantIndex = variantIndex;
      _streamBuffer = '';
    });

    final inputs = StoryPromptInputs(
      story: story,
      chapter: chapter,
      voiceKind: voice.kind,
      voiceCharacter: voice.character,
      persona: _persona(store, story),
      preset: null,
      lookupCharacter: store.characterById,
      lookupBook: store.lorebookById,
      inFlightMessageId: passageId,
    );
    final prompt = buildStoryPrompt(inputs);

    await _keepAliveStart();
    try {
      await _streamSub?.cancel();
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        messages: prompt.turns,
        debugTag: 'story',
      ).listen(
        (chunk) {
          if (!mounted) return;
          _streamBuffer += chunk;
          store.updatePassageText(
            story.id,
            chapter.id,
            passageId,
            _stripSentinels(_streamBuffer),
            variantIndex: variantIndex,
          );
          _scrollToBottom();
        },
        onError: (e) => _finishGeneration(story, chapter, passageId,
            error: e),
        onDone: () => _finishGeneration(story, chapter, passageId),
      );
    } catch (e) {
      _finishGeneration(story, chapter, passageId, error: e);
    }
  }

  String _stripSentinels(String raw) => raw
      .replaceAll(pyreFinishSentinelRegex, '')
      .replaceAll(pyreDroppedFramesRegex, '');

  void _finishGeneration(Story story, Chapter chapter, String passageId,
      {Object? error}) {
    _keepAliveStop();
    if (!mounted) return;
    final store = context.read<AppStore>();

    // Chapter-end marker: strip from the stored text, surface the banner.
    final signal =
        extractChapterEndSignal(_stripSentinels(_streamBuffer));
    final text = signal.text.trim();
    if (text.isNotEmpty) {
      store.updatePassageText(story.id, chapter.id, passageId, signal.text,
          variantIndex: _streamVariantIndex);
    } else if (error == null) {
      // Empty generation — drop the empty slot (or the empty variant).
      _dropEmptyResult(store, story, chapter, passageId);
    }

    setState(() {
      _generating = false;
      _streamPassageId = null;
      _endSuggested = signal.endSuggested && text.isNotEmpty;
    });
    store.flushPersist();

    if (error != null) {
      _dropEmptyResult(store, story, chapter, passageId);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Generation failed: $error')));
      return;
    }
    _maybeUpdateLiveSheet(story, chapter, force: false);
  }

  /// Background Live Sheet update — auto-triggered every N AI passages
  /// (same cadence setting as chats), and FORCED once on chapter conclusion
  /// so the carried-forward state is current. Fire-and-forget; failures land
  /// in LiveSheetErrors only.
  void _maybeUpdateLiveSheet(Story story, Chapter chapter,
      {required bool force}) {
    final store = context.read<AppStore>();
    final provider = store.activeProvider;
    if (provider == null || provider.baseUrl.isEmpty) return;
    if (!story.liveSheetEnabled) return;
    if (!force &&
        !shouldUpdateStoryLiveSheet(story, chapter, store.liveSheetSettings)) {
      return;
    }
    unawaited(() async {
      final snap = await generateStoryLiveSheetUpdate(
        story: story,
        chapter: chapter,
        provider: provider,
        settings: store.modelSettings,
        liveSheetSettings: store.liveSheetSettings,
        personaName: _persona(store, story)?.name,
      );
      if (snap == null) return;
      appendStoryLiveSheetSnapshot(story, snap);
      store.touchStory(story);
    }());
  }

  /// Remove an empty streamed result: an empty extra variant is deleted (the
  /// previous roll is restored); a passage whose ONLY variant is empty is
  /// removed entirely.
  void _dropEmptyResult(
      AppStore store, Story story, Chapter chapter, String passageId) {
    final idx = chapter.passages.indexWhere((m) => m.id == passageId);
    if (idx < 0) return;
    final m = chapter.passages[idx];
    if (m.text.trim().isNotEmpty) return;
    if (m.variants.length > 1) {
      m.variants.removeAt(m.selectedVariant);
      m.selectedVariant =
          (m.selectedVariant - 1).clamp(0, m.variants.length - 1);
      store.touchStory(story);
    } else {
      store.removePassage(story.id, chapter.id, m.id);
    }
  }

  void _stopGeneration() {
    final store = context.read<AppStore>();
    final story = _story;
    final chapter = _chapterOf(story);
    final stoppedId = _streamPassageId;
    _streamSub?.cancel();
    _streamSub = null;
    _keepAliveStop();
    setState(() {
      _generating = false;
      _streamPassageId = null;
    });
    // Keep whatever streamed in (a partial passage is still prose); drop a
    // completely empty slot.
    if (story != null && chapter != null && stoppedId != null) {
      _dropEmptyResult(store, story, chapter, stoppedId);
    }
    store.flushPersist();
  }

  // ── Chapter lifecycle ────────────────────────────────────────────────────

  Future<void> _editAim(Story story, Chapter chapter) async {
    final number = story.chapters.indexOf(chapter) + 1;
    final result = await showChapterAimDialog(
      context,
      chapterNumber: number,
      initialTitle: chapter.title,
      initialAim: chapter.aim,
    );
    if (result == null || !mounted) return;
    final store = context.read<AppStore>();
    chapter.title = result.title;
    chapter.aim = result.aim;
    store.touchStory(story);
  }

  Future<void> _renameChapter(
      Story story, Chapter chapter, int number) async {
    final ctl = TextEditingController(text: chapter.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Rename chapter'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: 'Chapter $number'),
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
      chapter.title = ctl.text.trim();
      store.touchStory(story);
    }
  }

  /// End-chapter flow: AI drafts a summary (editable, regenerable, manual
  /// fallback), the user confirms → conclude → offer the next chapter.
  Future<void> _endChapterFlow(Story story, Chapter chapter) async {
    if (chapter.passages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Write something first — an empty chapter has '
              'nothing to conclude.')));
      return;
    }
    final store = context.read<AppStore>();
    final summary = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EndChapterDialog(
        story: story,
        chapter: chapter,
        personaLabel: _persona(store, story)?.name,
      ),
    );
    if (summary == null || !mounted) return;
    store.concludeChapter(story.id, chapter.id, summary: summary);
    // Fold the chapter's tail into the Live Sheet so the next chapter
    // starts from current state (runs in the background).
    _maybeUpdateLiveSheet(story, chapter, force: true);

    // Offer the next chapter immediately — fresh page, fresh aim.
    final next = await showChapterAimDialog(
      context,
      chapterNumber: story.chapters.length + 1,
    );
    if (!mounted) return;
    if (next == null) {
      Navigator.of(context).pop(); // back to the story hub
      return;
    }
    final newChapter =
        store.addChapter(story.id, aim: next.aim, title: next.title);
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) =>
          ChapterScreen(storyId: story.id, chapterId: newChapter.id),
    ));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }
}

// ── Sub-widgets ─────────────────────────────────────────────────────────────

class _AimHeader extends StatelessWidget {
  final String aim;
  final bool expanded;
  final VoidCallback onToggle;
  const _AimHeader(
      {required this.aim, required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Container(
        width: double.infinity,
        color: EmberColors.bgPanel,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.flag_outlined,
                size: 16, color: EmberColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                aim,
                maxLines: expanded ? null : 1,
                overflow: expanded ? null : TextOverflow.ellipsis,
                style: const TextStyle(
                    color: EmberColors.textMid, fontSize: 12.5, height: 1.4),
              ),
            ),
            Icon(expanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: EmberColors.textDim),
          ],
        ),
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  final String summary;
  const _SummaryHeader({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: EmberColors.bgPanel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        'Summary: $summary',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: EmberColors.textDim, fontSize: 12),
      ),
    );
  }
}

class _EndSuggestedBanner extends StatelessWidget {
  final VoidCallback onEnd;
  final VoidCallback onDismiss;
  const _EndSuggestedBanner({required this.onEnd, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: EmberColors.primary.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.flag, size: 16, color: EmberColors.primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'The aim feels fulfilled — end this chapter?',
              style: TextStyle(color: EmberColors.textHigh, fontSize: 13),
            ),
          ),
          TextButton(onPressed: onDismiss, child: const Text('Not yet')),
          FilledButton(onPressed: onEnd, child: const Text('End chapter')),
        ],
      ),
    );
  }
}

class _PassageView extends StatelessWidget {
  final Message message;
  final String? voiceLabel;
  final bool streaming;
  final bool showVariantNav;
  final VoidCallback onPrevVariant;
  final VoidCallback onNextVariant;
  final VoidCallback? onReroll;
  final VoidCallback? onTap;
  const _PassageView({
    required this.message,
    required this.voiceLabel,
    required this.streaming,
    required this.showVariantNav,
    required this.onPrevVariant,
    required this.onNextVariant,
    this.onReroll,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = message.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (voiceLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  voiceLabel!.toUpperCase(),
                  style: const TextStyle(
                      color: EmberColors.textDim,
                      fontSize: 10,
                      letterSpacing: 0.8),
                ),
              ),
            ChatText(
              text.isEmpty && streaming ? '…' : text,
              baseStyle: const TextStyle(
                color: EmberColors.textHigh,
                fontSize: 15.5,
                height: 1.55,
              ),
            ),
            if (showVariantNav || onReroll != null)
              Row(
                children: [
                  if (showVariantNav) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: message.selectedVariant > 0
                          ? onPrevVariant
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text(
                      '${message.selectedVariant + 1}/${message.variants.length}',
                      style: const TextStyle(
                          color: EmberColors.textDim, fontSize: 11),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed:
                          message.selectedVariant < message.variants.length - 1
                              ? onNextVariant
                              : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                  if (onReroll != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      tooltip: 'Re-roll this passage',
                      onPressed: onReroll,
                      icon: const Icon(Icons.refresh,
                          color: EmberColors.textDim),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// The conclude dialog: drafts the AI summary on open, lets the user edit,
/// regenerate, or write their own; resolves with the final summary text.
class _EndChapterDialog extends StatefulWidget {
  final Story story;
  final Chapter chapter;
  final String? personaLabel;
  const _EndChapterDialog(
      {required this.story, required this.chapter, this.personaLabel});

  @override
  State<_EndChapterDialog> createState() => _EndChapterDialogState();
}

class _EndChapterDialogState extends State<_EndChapterDialog> {
  final _ctl = TextEditingController();
  bool _drafting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Rebuild so the Conclude button's enabled state tracks the text.
    _ctl.addListener(() => setState(() {}));
    _draft();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _draft() async {
    final store = context.read<AppStore>();
    final provider = store.activeProvider;
    if (provider == null || provider.baseUrl.isEmpty) {
      setState(() => _error = 'No provider configured — write the summary '
          'yourself, or set one up in More → API Connections.');
      return;
    }
    setState(() {
      _drafting = true;
      _error = null;
    });
    final summary = await generateChapterSummary(
      story: widget.story,
      chapter: widget.chapter,
      provider: provider,
      settings: store.modelSettings,
      personaLabel: widget.personaLabel,
    );
    if (!mounted) return;
    setState(() {
      _drafting = false;
      if (summary == null || summary.isEmpty) {
        _error = ChapterSummaryErrors.log.isNotEmpty
            ? 'Drafting failed (${ChapterSummaryErrors.log.first}). Edit or '
                'write the summary yourself.'
            : 'Drafting failed. Write the summary yourself or retry.';
      } else {
        _ctl.text = summary;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: const Text('End chapter'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'This summary is what the story remembers of the chapter — '
                'it guides every later chapter. Edit it freely.',
                style: TextStyle(color: EmberColors.textDim, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            if (_drafting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Drafting the summary…',
                        style: TextStyle(color: EmberColors.textDim)),
                  ],
                ),
              )
            else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: EmberColors.danger, fontSize: 12)),
                ),
              TextField(
                controller: _ctl,
                maxLines: 10,
                minLines: 4,
                decoration:
                    const InputDecoration(labelText: 'Chapter summary'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_drafting)
          TextButton(
            onPressed: _draft,
            child: const Text('Regenerate'),
          ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _drafting || _ctl.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _ctl.text.trim()),
          child: const Text('Conclude chapter'),
        ),
      ],
    );
  }
}
