// Pyre 1.1 (F7) — UI flow for the bulk "Import from SillyTavern" entry.
//
// One entry where the user multi-selects a pile of mixed ST `.json` files (and
// `.png` cards). The PURE classifier + parser layer lives in
// services/st_bulk_import.dart; this file is the thin UI shell:
//   1. file_picker (allowMultiple, .json + .png),
//   2. routeStFile per file (pure → parsed Pyre objects, no store mutation),
//   3. the store-add loop here, calling the SAME add methods each per-type
//      screen uses (store.addCharacter / addLorebook / addRegexRule /
//      addPreset) so analytics / persistence / sync behave identically,
//   4. a summary sheet: a one-line rollup + a scrollable per-file ✓/✗ list.
//
// ignore_for_file: use_build_context_synchronously

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/lorebook_import.dart' show handleEmbeddedBookForCharacter;
import '../services/st_bulk_import.dart';
import '../services/st_classify.dart';
import '../state/app_store.dart';
import '../theme.dart';

/// Entry point wired from the More screen. Picks files, routes + persists them,
/// then shows the summary. Safe to call with a stale context — every async gap
/// is guarded.
Future<void> runStBulkImport(BuildContext context, AppStore store) async {
  final messenger = ScaffoldMessenger.of(context);

  final FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json', 'png'],
      allowMultiple: true,
      withData: true,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open picker: $e')));
    return;
  }
  if (result == null || result.files.isEmpty) return;

  // Route every file through the PURE layer first (no store mutation yet).
  final routed = <StRouteResult>[];
  for (final f in result.files) {
    final bytes = f.bytes;
    final name = f.name;
    if (bytes == null) {
      // No bytes (rare — e.g. a path-only pick). Record a skip; don't abort.
      routed.add(_byteslessResult(name));
      continue;
    }
    routed.add(routeStFile(name, Uint8List.fromList(bytes)));
  }

  // Apply: add each successfully-parsed object via the real store methods. A
  // single bad add can't abort the batch (per-file try/catch), and a failed
  // add downgrades that file's result to a failure in the summary.
  final applied = <StRouteResult>[];
  for (final r in routed) {
    applied.add(await _applyRouted(context, store, r));
  }

  if (!context.mounted) return;
  await _showSummary(context, applied);
}

/// Persist ONE routed result via the matching real AppStore add method.
/// Returns the same result on success, or a failure-flavoured copy if the add
/// threw. Cards run the existing embedded-`character_book` flow first, exactly
/// like a single-card import.
Future<StRouteResult> _applyRouted(
  BuildContext context,
  AppStore store,
  StRouteResult r,
) async {
  if (!r.ok) return r; // already a failure / skip — nothing to add.
  try {
    switch (r.artifact) {
      case StArtifact.card:
        final character = r.character!;
        // Offer the embedded character_book (if any) exactly as the single
        // import does, BEFORE persisting so lorebookIds round-trip.
        if (r.cardData != null && context.mounted) {
          await handleEmbeddedBookForCharacter(
            context: context,
            store: store,
            character: character,
            charaCardData: r.cardData!,
          );
        }
        store.addCharacter(character);
      case StArtifact.lorebook:
        store.addLorebook(r.lorebook!);
      case StArtifact.regex:
        for (final rule in r.regexRules!) {
          store.addRegexRule(rule);
        }
      case StArtifact.preset:
        store.addPreset(r.preset!);
      case StArtifact.unknown:
        break; // never ok=true with unknown, but keep the switch total.
    }
    return r;
  } catch (e) {
    return _failedCopy(r, 'Failed to save: $e');
  }
}

StRouteResult _failedCopy(StRouteResult r, String detail) => StRouteResult(
      name: r.name,
      artifact: r.artifact,
      ok: false,
      detail: detail,
    );

StRouteResult _byteslessResult(String name) => StRouteResult(
      name: name,
      artifact: StArtifact.unknown,
      ok: false,
      detail: 'Failed: could not read file bytes',
    );

/// Bottom-sheet summary: a bold one-line rollup + a scrollable per-file list
/// with ✓/✗ and the detail string. Failures stay legible (filename + reason).
Future<void> _showSummary(
  BuildContext context,
  List<StRouteResult> results,
) async {
  final summary = summariseStBatch(results);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    builder: (sheet) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (ctx, scrollController) {
          return Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: EmberColors.stroke,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.download_done,
                        color: EmberColors.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Import from SillyTavern',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    summary,
                    style: const TextStyle(
                      color: EmberColors.textHigh,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: EmberColors.stroke, height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  itemCount: results.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _ResultRow(results[i]),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Done'),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ResultRow extends StatelessWidget {
  final StRouteResult r;
  const _ResultRow(this.r);

  @override
  Widget build(BuildContext context) {
    final ok = r.ok;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: EmberColors.bgElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            size: 18,
            color: ok ? EmberColors.success : EmberColors.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.name,
                  style: const TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  r.detail,
                  style: TextStyle(
                    color: ok ? EmberColors.textMid : EmberColors.danger,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
