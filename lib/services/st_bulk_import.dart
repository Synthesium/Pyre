// Pyre 1.1 (F7) — bulk "Import from SillyTavern" orchestration.
//
// The user multi-selects a pile of mixed ST `.json` files (and `.png` cards).
// For each file this orchestrator:
//   1. decodes / parses it,
//   2. asks the PURE classifier (st_classify.dart) what kind it is,
//   3. routes it to the SAME pre-existing per-type importer each dedicated
//      screen already uses — NO import logic is reimplemented here:
//        card     → parseCharaCardJson / parseCharaCardPng + characterFromCharaCard
//        lorebook → tryParseLorebookJson
//        regex    → parseStRegexScripts
//        preset   → parseSillyTavernPreset
//   4. records a per-file result so the UI can summarise.
//
// SPLIT for testability:
//   - [routeStFile] is PURE: bytes in → a routed result holding the artifact
//     label + the PARSED Pyre object(s) (Character / Lorebook / RegexRules /
//     Preset) WITHOUT touching the store. This is what's unit-tested.
//   - [BulkStImporter.run] (UI-side) loops [routeStFile] over the picked files
//     and calls the real `store.addCharacter / addLorebook / addRegexRule /
//     addPreset` so analytics, persistence and sync behave identically to a
//     single-screen import.
//
// One bad file NEVER aborts the batch — every file is wrapped in try/catch and
// produces either an `ok` result or a `Failed: <reason>` / skipped result.

import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'card_import.dart';
import 'lorebook_import.dart';
import 'png_parser.dart';
import 'regex_rules.dart';
import 'st_classify.dart';
import 'st_preset_import.dart';

/// Outcome of routing ONE file: the detected artifact, the parsed Pyre
/// object(s) ready to add to the store (null when parsing failed / skipped),
/// and a human-readable detail + success flag for the summary UI.
class StRouteResult {
  /// Source filename (for the per-file summary list).
  final String name;

  /// What the classifier decided this file is.
  final StArtifact artifact;

  /// True when the file parsed into at least one usable Pyre object.
  final bool ok;

  /// Human-readable outcome, e.g. "Lorebook 'Eldoria' (12 entries)",
  /// "3 regex rules", "Preset 'FluffPreset'", "Card 'Aria'", or
  /// `Failed: <reason>` / "Unknown format — skipped".
  final String detail;

  // Exactly one of these is non-null on a successful parse (regexRules may hold
  // many). They are the SAME model types the per-type screens persist.
  final Character? character;
  final Lorebook? lorebook;
  final List<RegexRule>? regexRules;
  final Preset? preset;

  /// The raw chara_card_v2 `data` map for a successfully parsed CARD. The
  /// UI-side loop uses it to run the existing embedded-`character_book` flow
  /// (handleEmbeddedBookForCharacter) so a card's bundled lorebook still gets
  /// offered, exactly like a single-card import.
  final Map<String, dynamic>? cardData;

  StRouteResult({
    required this.name,
    required this.artifact,
    required this.ok,
    required this.detail,
    this.character,
    this.lorebook,
    this.regexRules,
    this.preset,
    this.cardData,
  });

  StRouteResult._fail(this.name, this.artifact, this.detail)
      : ok = false,
        character = null,
        lorebook = null,
        regexRules = null,
        preset = null,
        cardData = null;
}

/// PURE routing: decode [bytes] for [filename], classify, and parse via the
/// pre-existing importer for the detected type. Returns a [StRouteResult] —
/// NEVER throws (all failures are captured as a `Failed:` / skipped result) and
/// NEVER mutates any store.
///
/// `.png` files are always routed to the card path (they're chara_card PNGs).
/// `.json` files are decoded then classified by structure.
StRouteResult routeStFile(String filename, Uint8List bytes) {
  final ext = _ext(filename);

  // PNG → always a character card (chara_card_v2 embedded in tEXt chunks).
  if (ext == 'png') {
    try {
      final card = parseCharaCardPng(bytes);
      final character = characterFromCharaCard(card);
      return StRouteResult(
        name: filename,
        artifact: StArtifact.card,
        ok: true,
        detail: "Card '${character.name}'",
        character: character,
        cardData: card.card,
      );
    } catch (e) {
      return StRouteResult._fail(filename, StArtifact.card, 'Failed: $e');
    }
  }

  // Everything else is treated as JSON. Decode first.
  final dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (e) {
    return StRouteResult._fail(
      filename,
      StArtifact.unknown,
      'Failed: not valid JSON ($e)',
    );
  }

  final artifact = classifyStFile(decoded);
  switch (artifact) {
    case StArtifact.card:
      return _routeCardJson(filename, decoded);
    case StArtifact.lorebook:
      return _routeLorebook(filename, decoded);
    case StArtifact.regex:
      return _routeRegex(filename, decoded);
    case StArtifact.preset:
      return _routePreset(filename, decoded);
    case StArtifact.unknown:
      return StRouteResult._fail(
        filename,
        StArtifact.unknown,
        'Unknown format — skipped',
      );
  }
}

StRouteResult _routeCardJson(String filename, dynamic decoded) {
  try {
    // The classifier only labels Maps as card, so decoded is a Map here.
    final text = jsonEncode(decoded);
    final card = parseCharaCardJson(text);
    final character = characterFromCharaCard(card);
    return StRouteResult(
      name: filename,
      artifact: StArtifact.card,
      ok: true,
      detail: "Card '${character.name}'",
      character: character,
      cardData: card.card,
    );
  } catch (e) {
    return StRouteResult._fail(filename, StArtifact.card, 'Failed: $e');
  }
}

StRouteResult _routeLorebook(String filename, dynamic decoded) {
  try {
    if (decoded is! Map) {
      return StRouteResult._fail(
          filename, StArtifact.lorebook, 'Failed: not a lorebook object');
    }
    final nameFallback = _stripExt(filename);
    final book = tryParseLorebookJson(
      decoded.cast<String, dynamic>(),
      nameFallback: nameFallback,
    );
    if (book == null) {
      return StRouteResult._fail(
          filename, StArtifact.lorebook, 'Failed: could not parse lorebook');
    }
    return StRouteResult(
      name: filename,
      artifact: StArtifact.lorebook,
      ok: true,
      detail: "Lorebook '${book.name}' (${book.entries.length} "
          "${book.entries.length == 1 ? 'entry' : 'entries'})",
      lorebook: book,
    );
  } catch (e) {
    return StRouteResult._fail(filename, StArtifact.lorebook, 'Failed: $e');
  }
}

StRouteResult _routeRegex(String filename, dynamic decoded) {
  try {
    final rules = parseStRegexScripts(decoded);
    if (rules.isEmpty) {
      return StRouteResult._fail(
          filename, StArtifact.regex, 'Failed: no usable regex rules');
    }
    return StRouteResult(
      name: filename,
      artifact: StArtifact.regex,
      ok: true,
      detail:
          '${rules.length} regex ${rules.length == 1 ? 'rule' : 'rules'}',
      regexRules: rules,
    );
  } catch (e) {
    return StRouteResult._fail(filename, StArtifact.regex, 'Failed: $e');
  }
}

StRouteResult _routePreset(String filename, dynamic decoded) {
  try {
    // parseSillyTavernPreset takes the raw JSON TEXT (it re-decodes inside).
    final text = jsonEncode(decoded);
    final result = parseSillyTavernPreset(text);
    return StRouteResult(
      name: filename,
      artifact: StArtifact.preset,
      ok: true,
      detail: "Preset '${result.preset.name}'",
      preset: result.preset,
    );
  } catch (e) {
    return StRouteResult._fail(filename, StArtifact.preset, 'Failed: $e');
  }
}

/// A one-line plain-English summary of a batch result list, e.g.
/// "2 lorebooks, 4 regex rules, 1 preset, 1 card imported; 1 file skipped".
/// Regex counts sum the RULE count (a 3-rule file contributes 3). Failures +
/// unknowns count as "skipped".
String summariseStBatch(List<StRouteResult> results) {
  var cards = 0;
  var lorebooks = 0;
  var regexRules = 0;
  var presets = 0;
  var skipped = 0;
  for (final r in results) {
    if (!r.ok) {
      skipped++;
      continue;
    }
    switch (r.artifact) {
      case StArtifact.card:
        cards++;
      case StArtifact.lorebook:
        lorebooks++;
      case StArtifact.regex:
        regexRules += r.regexRules?.length ?? 0;
      case StArtifact.preset:
        presets++;
      case StArtifact.unknown:
        skipped++;
    }
  }

  String plural(int n, String unit) =>
      '$n $unit${n == 1 ? '' : 's'}';

  final parts = <String>[];
  if (lorebooks > 0) parts.add(plural(lorebooks, 'lorebook'));
  if (regexRules > 0) parts.add(plural(regexRules, 'regex rule'));
  if (presets > 0) parts.add(plural(presets, 'preset'));
  if (cards > 0) parts.add(plural(cards, 'card'));

  final buf = StringBuffer();
  if (parts.isEmpty) {
    buf.write('Nothing imported');
  } else {
    buf.write('${parts.join(', ')} imported');
  }
  if (skipped > 0) {
    buf.write('; ${plural(skipped, 'file')} skipped');
  }
  buf.write('.');
  return buf.toString();
}

String _ext(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return '';
  return filename.substring(dot + 1).toLowerCase();
}

String _stripExt(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot <= 0 ? filename : filename.substring(0, dot);
}
