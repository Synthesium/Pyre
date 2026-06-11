// Story Mode — the Stories tab: the writer's bookshelf.
//
// Lists every story (Pure-Writer style: title, chapter count, word count,
// last-touched time) and hosts the new-story flow (title + premise + cast +
// persona) which drops the user straight into Chapter 1's aim prompt.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/manuscript_export.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import 'story_screen.dart';

class StoriesScreen extends StatelessWidget {
  const StoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Inside an ActiveTabGate — read, not watch (the gate governs rebuilds;
    // see chats_screen.dart for the rationale).
    final store = context.read<AppStore>();
    final stories = store.stories.where((s) => !s.deleted).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stories',
            style: TextStyle(
                color: EmberColors.primary, fontWeight: FontWeight.w700)),
        centerTitle: true,
      ),
      body: stories.isEmpty
          ? EmptyState(
              icon: Icons.menu_book_outlined,
              title: 'No stories yet',
              subtitle:
                  'Write long-form fiction in chapters — by yourself, with '
                  'your characters, or with the AI as co-writer.',
              ctaLabel: 'Start a story',
              ctaIcon: Icons.add,
              onCta: () => _startNewStory(context),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: stories.length,
              itemBuilder: (context, i) =>
                  _StoryTile(story: stories[i]),
            ),
      floatingActionButton: stories.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: () => _startNewStory(context),
              child: const Icon(Icons.add),
            ),
    );
  }
}

Future<void> _startNewStory(BuildContext context) async {
  final created = await Navigator.of(context).push<Story>(
    MaterialPageRoute(builder: (_) => const NewStoryScreen()),
  );
  if (created == null || !context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => StoryScreen(storyId: created.id, promptFirstChapter: true),
  ));
}

class _StoryTile extends StatelessWidget {
  final Story story;
  const _StoryTile({required this.story});

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    final stats = storyWordStats(story);
    final chapterCount = story.chapters.length;
    final meta = [
      '$chapterCount chapter${chapterCount == 1 ? '' : 's'}',
      '${stats.totalWords} words',
      _relativeTime(story.updatedAt),
    ].join(' · ');
    final premise = story.premise.trim();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: EmberColors.bgElevated,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.menu_book_outlined,
            color: EmberColors.primary),
      ),
      title: Text(
        story.title.trim().isEmpty ? 'Untitled story' : story.title.trim(),
        style: const TextStyle(
            color: EmberColors.textHigh, fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (premise.isNotEmpty)
            Text(premise,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: EmberColors.textMid, fontSize: 13)),
          Text(meta,
              style:
                  const TextStyle(color: EmberColors.textDim, fontSize: 12)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, color: EmberColors.textDim),
        tooltip: 'Delete story',
        onPressed: () async {
          final ok = await confirmDelete(
            context,
            title: 'Delete story?',
            message:
                '"${story.title.trim().isEmpty ? 'Untitled story' : story.title.trim()}" '
                'and all its chapters will be lost forever.',
          );
          if (ok) store.removeStory(story.id);
        },
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StoryScreen(storyId: story.id),
      )),
    );
  }
}

String _relativeTime(int millis) {
  final delta = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(millis));
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  if (delta.inDays < 30) return '${delta.inDays}d ago';
  return '${delta.inDays ~/ 30}mo ago';
}

/// Full-screen new-story flow: title, premise, cast multi-select, persona.
class NewStoryScreen extends StatefulWidget {
  const NewStoryScreen({super.key});

  @override
  State<NewStoryScreen> createState() => _NewStoryScreenState();
}

class _NewStoryScreenState extends State<NewStoryScreen> {
  final _title = TextEditingController();
  final _premise = TextEditingController();
  final _castSearch = TextEditingController();
  final Set<String> _selectedCast = {};
  // null = inherit global active persona; kExplicitNoPersonaId = none.
  String? _personaId;

  @override
  void dispose() {
    _title.dispose();
    _premise.dispose();
    _castSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final query = _castSearch.text.trim().toLowerCase();
    final characters = store.characters
        .where((c) => !c.deleted)
        .where((c) => query.isEmpty || c.name.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final personas = store.personas.where((p) => !p.deleted).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('New story'),
        actions: [
          TextButton(
            onPressed: _create,
            child: const Text('Create'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Title',
              hintText: 'Working titles are fine',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _premise,
            maxLines: 4,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Premise',
              hintText:
                  'The logline or world setup — the AI sees this on every '
                  'generation, and it anchors the whole story.',
            ),
          ),
          const SizedBox(height: 24),
          const Text('CAST',
              style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 12,
                  letterSpacing: 0.4)),
          const SizedBox(height: 4),
          const Text(
            'Pick the characters who appear in this story. You can write as '
            'any of them — and so can the AI. (Optional: a story can be pure '
            'narration.)',
            style: TextStyle(color: EmberColors.textDim, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (store.characters.where((c) => !c.deleted).length > 8)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _castSearch,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search characters',
                ),
              ),
            ),
          if (characters.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No characters in your library yet.',
                  style: TextStyle(color: EmberColors.textDim)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in characters)
                  FilterChip(
                    avatar: AvatarBubble(
                        dataUrl: c.avatar, fallback: c.name, radius: 12),
                    label: Text(c.name),
                    selected: _selectedCast.contains(c.id),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _selectedCast.add(c.id);
                      } else {
                        _selectedCast.remove(c.id);
                      }
                    }),
                  ),
              ],
            ),
          const SizedBox(height: 24),
          const Text('YOU',
              style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 12,
                  letterSpacing: 0.4)),
          const SizedBox(height: 4),
          const Text(
            'The persona you write yourself as (the "self" voice).',
            style: TextStyle(color: EmberColors.textDim, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('None — narrator & cast only'),
                selected: _personaId == kExplicitNoPersonaId,
                onSelected: (_) =>
                    setState(() => _personaId = kExplicitNoPersonaId),
              ),
              for (final p in personas)
                ChoiceChip(
                  avatar: AvatarBubble(
                      dataUrl: p.avatar, fallback: p.name, radius: 12),
                  label: Text(p.name),
                  selected: _personaId == p.id ||
                      (_personaId == null && p.id == store.activePersonaId),
                  onSelected: (_) => setState(() => _personaId = p.id),
                ),
            ],
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.auto_stories),
            label: const Text('Create story'),
          ),
        ],
      ),
    );
  }

  void _create() {
    final store = context.read<AppStore>();
    final cast = [
      for (final id in _selectedCast)
        if (store.characterById(id) != null) store.characterById(id)!,
    ];
    final story = store.startStoryWith(
      title: _title.text,
      premise: _premise.text,
      cast: cast,
      personaId: _personaId,
    );
    Navigator.of(context).pop(story);
  }
}
