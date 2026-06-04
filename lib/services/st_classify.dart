// Pyre 1.1 (F7) — pure structural classifier for SillyTavern artifacts.
//
// SillyTavern exports four kinds of JSON the user might pile together: a
// character CARD (chara_card_v2/v3 or a legacy flat card), a standalone
// World Info LOREBOOK, one-or-many REGEX scripts, and a chat-completion /
// text-gen PRESET. They share no top-level discriminator, so this module
// sniffs each by STRUCTURE.
//
// PURE: no Flutter, no AppStore, no IO. It returns ONLY a label — it never
// parses into a Pyre model and never mutates anything. The bulk importer
// (st_bulk_import.dart) takes the label and routes the file to the SAME
// pre-existing per-type importer each dedicated screen uses. Unit-tested in
// isolation (test/st_classify_test.dart).
//
// CLASSIFY PRIORITY (most specific first — order matters; see classifyStJson):
//   1. REGEX    — has `findRegex` AND `replaceString`.
//   2. CARD     — chara_card_v2/v3 spec, a `data` wrapper with card fields,
//                 or a legacy flat card (name + first_mes/personality/...).
//   3. LOREBOOK — has `entries` (a List OR a uid-keyed Map).
//   4. PRESET   — ST prompt-pipeline (`prompts`), a sampler-field cluster, or
//                 instruct/context-template markers.
//   5. UNKNOWN  — none of the above.

/// The kind of SillyTavern artifact a decoded JSON value represents.
enum StArtifact { card, lorebook, regex, preset, unknown }

/// Classify a decoded JSON OBJECT (not an array — use [classifyStFile] for the
/// array case). Sniffs by structure in a most-specific-first priority order so
/// the disambiguation cases (a lorebook that lacks first_mes must not look like
/// a card; a card that lacks `entries` must not look like a lorebook; a preset
/// that carries a `temperature` must not look like a card) resolve correctly.
StArtifact classifyStJson(Map<String, dynamic> json) {
  // 1. REGEX — the most distinctive signature: an ST regex script always
  //    carries BOTH a find pattern and a replacement string. Checked first so
  //    a script that happens to also carry stray sampler-ish keys can't be
  //    mistaken for a preset.
  if (_looksLikeRegexScript(json)) return StArtifact.regex;

  // 2. CARD — check before lorebook AND preset. A card may carry sampler-like
  //    numbers in extensions and may even embed a `character_book`, so it must
  //    win over both when the unmistakable card markers are present.
  if (_looksLikeCard(json)) return StArtifact.card;

  // 3. LOREBOOK — `entries` as a List (chara_card_v2 character_book) or a
  //    uid-keyed Map (ST standalone World Info export). Ruled out as a card
  //    above, so a book's lack of first_mes/personality is fine here.
  if (_looksLikeLorebook(json)) return StArtifact.lorebook;

  // 4. PRESET — tolerant "looks like a preset" heuristic, AFTER card/lorebook/
  //    regex are ruled out (so a card's `temperature` or a book's fields can't
  //    trip it).
  if (_looksLikePreset(json)) return StArtifact.preset;

  return StArtifact.unknown;
}

/// Classify a decoded JSON value that may be an OBJECT or an ARRAY.
///
/// - Object → delegates to [classifyStJson].
/// - Array  → recognised as [StArtifact.regex] when the MAJORITY of its
///   elements look like regex scripts (ST exports a "regex scripts" file as a
///   bare array of script objects). An empty array, or one where most elements
///   aren't regex scripts, is [StArtifact.unknown].
/// - Anything else (string / number / bool / null) → [StArtifact.unknown].
StArtifact classifyStFile(dynamic decodedJson) {
  if (decodedJson is Map) {
    return classifyStJson(decodedJson.cast<String, dynamic>());
  }
  if (decodedJson is List) {
    if (decodedJson.isEmpty) return StArtifact.unknown;
    var regexLike = 0;
    var objects = 0;
    for (final e in decodedJson) {
      if (e is Map) {
        objects++;
        if (_looksLikeRegexScript(e.cast<String, dynamic>())) regexLike++;
      }
    }
    if (objects == 0) return StArtifact.unknown;
    // Majority of the object elements are regex scripts → a regex-scripts file.
    if (regexLike * 2 >= objects) return StArtifact.regex;
    return StArtifact.unknown;
  }
  return StArtifact.unknown;
}

// ===========================================================================
// Per-type structural sniffers.
// ===========================================================================

/// An ST regex script always carries BOTH `findRegex` and `replaceString`.
/// (`replaceString` may legitimately be an empty string — a strip rule — so we
/// test KEY PRESENCE with a String type, not non-emptiness.)
bool _looksLikeRegexScript(Map<String, dynamic> json) =>
    json['findRegex'] is String && json['replaceString'] is String;

/// True when [json] looks like a character card. Three accepted shapes:
///
///   - chara_card_v2 / v3 spec: `spec` starts with `chara_card_v` (the value
///     is `chara_card_v2` / `chara_card_v3`), OR a `data` map that holds the
///     real card fields.
///   - `data` wrapper: `data` is a Map carrying `name` + at least one of
///     `description` / `first_mes` / `personality`.
///   - legacy flat card: top-level `name` + a clear card field
///     (`first_mes` / `mes_example`, or both `personality` and `description`).
///
/// The legacy-flat test deliberately requires a card-DISTINCTIVE field so a
/// standalone lorebook (which has a `name` too, but no first_mes/personality)
/// can't be mistaken for a card.
bool _looksLikeCard(Map<String, dynamic> json) {
  // chara_card_v2 / v3 by spec marker.
  final spec = json['spec'];
  if (spec is String && spec.startsWith('chara_card_v')) return true;

  // `data` wrapper carrying card fields.
  final data = json['data'];
  if (data is Map) {
    final d = data.cast<String, dynamic>();
    if (d['name'] is String &&
        (d['description'] is String ||
            d['first_mes'] is String ||
            d['personality'] is String)) {
      return true;
    }
  }

  // Legacy flat card. Requires a card-DISTINCTIVE field beyond `name`.
  if (json['name'] is String) {
    if (json['first_mes'] is String || json['mes_example'] is String) {
      return true;
    }
    if (json['personality'] is String && json['description'] is String) {
      return true;
    }
  }
  return false;
}

/// True when [json] carries an `entries` collection in either supported shape:
/// a List (chara_card_v2 `character_book`) or a Map keyed by uid (ST standalone
/// World Info export). The card check runs first, so a card with an embedded
/// `character_book` is already classified as a card before this is reached.
bool _looksLikeLorebook(Map<String, dynamic> json) {
  final entries = json['entries'];
  return entries is List || entries is Map;
}

/// Tolerant "looks like a preset" heuristic. Reached ONLY after card / lorebook
/// / regex are ruled out, so it can lean on weaker signals without risking a
/// misclassification. Recognises three ST preset families:
///
///   - chat-completion preset: a `prompts` array of prompt objects (optionally
///     with a `prompt_order`).
///   - text-gen / sampler preset: a `temperature` field plus at least two more
///     sampler fields (top_p / top_k / rep_pen / penalties / max_length / ...).
///   - instruct / context template: a `system_prompt` together with an
///     input/output sequence, or explicit `instruct` / `context` blocks.
///
/// Also accepts an explicit Pyre-native re-export marker (`mainPrompt`) so a
/// round-tripped Pyre preset classifies correctly.
bool _looksLikePreset(Map<String, dynamic> json) {
  // Pyre's own preset export (round-trip) — handled by the ST preset importer's
  // pass-through path.
  if (json['mainPrompt'] is String) return true;

  // Chat-completion preset: the `prompts` pipeline.
  if (json['prompts'] is List) return true;
  if (json['prompt_order'] is List) return true;

  // Text-gen / sampler preset: temperature + a cluster of sampler fields.
  const samplerKeys = <String>[
    'top_p',
    'top_k',
    'rep_pen',
    'repetition_penalty',
    'frequency_penalty',
    'presence_penalty',
    'max_length',
    'genamt',
    'min_p',
    'top_a',
    'typical_p',
    'tfs',
  ];
  if (_hasNum(json, 'temperature')) {
    var hits = 0;
    for (final k in samplerKeys) {
      if (json.containsKey(k)) hits++;
    }
    if (hits >= 2) return true;
  }

  // Instruct / context template markers.
  if (json['system_prompt'] is String &&
      (json.containsKey('input_sequence') ||
          json.containsKey('output_sequence'))) {
    return true;
  }
  if (json['instruct'] is Map || json['context'] is Map) return true;

  return false;
}

/// True when [json] holds a numeric value (int or double) at [key].
bool _hasNum(Map<String, dynamic> json, String key) => json[key] is num;
