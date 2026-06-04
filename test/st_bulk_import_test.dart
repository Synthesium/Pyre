// Bulk SillyTavern importer — PURE routing layer (F7).
//
// routeStFile takes (filename, bytes) and returns a StRouteResult holding the
// detected artifact + the parsed Pyre object(s), WITHOUT mutating any store.
// These tests prove each type routes to the correct pre-existing importer and
// produces a usable object + a sensible detail string, that bad files fail
// gracefully (one bad file never throws), and that summariseStBatch counts
// correctly.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/st_bulk_import.dart';
import 'package:pyre/services/st_classify.dart';

Uint8List jsonBytes(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  group('routeStFile — routes each type to its parser', () {
    test('chara_card_v2 JSON → Character', () {
      final bytes = jsonBytes({
        'spec': 'chara_card_v2',
        'data': {
          'name': 'Aria',
          'description': 'A bard.',
          'first_mes': 'Hello!',
        },
      });
      final r = routeStFile('aria.json', bytes);
      expect(r.artifact, StArtifact.card);
      expect(r.ok, isTrue);
      expect(r.character, isNotNull);
      expect(r.character!.name, 'Aria');
      expect(r.cardData, isNotNull);
      expect(r.detail, contains('Aria'));
    });

    test('standalone World Info JSON → Lorebook (entry count in detail)', () {
      final bytes = jsonBytes({
        'name': 'Eldoria Lore',
        'entries': {
          '0': {
            'key': ['Eldoria'],
            'content': 'A kingdom.',
          },
          '1': {
            'key': ['Maeve'],
            'content': 'The queen.',
          },
        },
      });
      final r = routeStFile('eldoria.json', bytes);
      expect(r.artifact, StArtifact.lorebook);
      expect(r.ok, isTrue);
      expect(r.lorebook, isNotNull);
      expect(r.lorebook!.entries.length, 2);
      expect(r.detail, contains('Eldoria Lore'));
      expect(r.detail, contains('2 entries'));
    });

    test('single regex script JSON → 1 RegexRule', () {
      final bytes = jsonBytes({
        'scriptName': 'Strip asterisks',
        'findRegex': '/\\*/g',
        'replaceString': '',
      });
      final r = routeStFile('strip.json', bytes);
      expect(r.artifact, StArtifact.regex);
      expect(r.ok, isTrue);
      expect(r.regexRules, isNotNull);
      expect(r.regexRules!.length, 1);
      expect(r.detail, '1 regex rule');
    });

    test('array of 3 regex scripts JSON → 3 RegexRules', () {
      final bytes = jsonBytes([
        {'scriptName': 'a', 'findRegex': '/a/g', 'replaceString': ''},
        {'scriptName': 'b', 'findRegex': '/b/g', 'replaceString': 'B'},
        {'scriptName': 'c', 'findRegex': '/c/', 'replaceString': 'C'},
      ]);
      final r = routeStFile('rules.json', bytes);
      expect(r.artifact, StArtifact.regex);
      expect(r.ok, isTrue);
      expect(r.regexRules!.length, 3);
      expect(r.detail, '3 regex rules');
    });

    test('ST chat-completion preset JSON → Preset', () {
      final bytes = jsonBytes({
        'name': 'FluffPreset',
        'temperature': 1.05,
        'prompts': [
          {'identifier': 'main', 'content': 'You are a writer.'},
          {'identifier': 'chatHistory', 'marker': true},
        ],
        'prompt_order': [
          {
            'character_id': 100000,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
        ],
      });
      final r = routeStFile('fluff.json', bytes);
      expect(r.artifact, StArtifact.preset);
      expect(r.ok, isTrue);
      expect(r.preset, isNotNull);
      expect(r.detail, contains('FluffPreset'));
    });

    test('card-with-data-wrapper (no spec) → Character', () {
      final bytes = jsonBytes({
        'data': {
          'name': 'Mara',
          'description': 'A scholar.',
          'first_mes': 'Greetings.',
        },
      });
      final r = routeStFile('mara.json', bytes);
      expect(r.artifact, StArtifact.card);
      expect(r.character!.name, 'Mara');
    });

    test(
        'sampler-only textgen preset → preset artifact, fails gracefully '
        '(existing importer is chat-completion-only)', () {
      // The classifier honestly labels a temperature+sampler-cluster file as a
      // preset, but the PRE-EXISTING parseSillyTavernPreset only handles the
      // chat-completion `prompts` pipeline. Rather than duplicate logic here,
      // the route reports a graceful failure (one bad file never aborts the
      // batch).
      final bytes = jsonBytes({
        'name': 'TextgenSampler',
        'temperature': 0.9,
        'top_p': 0.95,
        'top_k': 40,
        'rep_pen': 1.1,
      });
      final r = routeStFile('sampler.json', bytes);
      expect(r.artifact, StArtifact.preset);
      expect(r.ok, isFalse);
      expect(r.detail, contains('Failed'));
    });
  });

  group('routeStFile — failure handling (never throws)', () {
    test('garbage JSON object → unknown, ok=false, skipped detail', () {
      final bytes = jsonBytes({'foo': 'bar', 'n': 1});
      final r = routeStFile('weird.json', bytes);
      expect(r.artifact, StArtifact.unknown);
      expect(r.ok, isFalse);
      expect(r.detail, contains('skipped'));
    });

    test('invalid JSON bytes → unknown, ok=false, JSON failure detail', () {
      final bytes = Uint8List.fromList(utf8.encode('not json {{{'));
      final r = routeStFile('broken.json', bytes);
      expect(r.artifact, StArtifact.unknown);
      expect(r.ok, isFalse);
      expect(r.detail, contains('Failed'));
    });

    test('png that is not a chara card → card artifact, ok=false', () {
      // 8-byte PNG signature + nothing parseable as a chara card.
      final bytes = Uint8List.fromList(
          [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      final r = routeStFile('image.png', bytes);
      expect(r.artifact, StArtifact.card);
      expect(r.ok, isFalse);
      expect(r.detail, contains('Failed'));
    });
  });

  group('summariseStBatch — count rollup', () {
    test('mixed batch counts by type, regex sums rules, skips counted', () {
      final results = [
        // 2 lorebooks
        routeStFile('lore1.json',
            jsonBytes({'name': 'A', 'entries': {'0': {'key': ['x'], 'content': 'y'}}})),
        routeStFile('lore2.json',
            jsonBytes({'name': 'B', 'entries': {'0': {'key': ['z'], 'content': 'w'}}})),
        // 4 regex rules (one file of 3 + one file of 1)
        routeStFile('r3.json', jsonBytes([
          {'findRegex': '/a/g', 'replaceString': ''},
          {'findRegex': '/b/g', 'replaceString': ''},
          {'findRegex': '/c/g', 'replaceString': ''},
        ])),
        routeStFile('r1.json',
            jsonBytes({'findRegex': '/d/g', 'replaceString': ''})),
        // 1 preset (chat-completion — the shape the existing importer parses)
        routeStFile('p.json', jsonBytes({
          'name': 'P',
          'prompts': [
            {'identifier': 'main', 'content': 'You are a writer.'},
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'character_id': 100000,
              'order': [
                {'identifier': 'main', 'enabled': true},
                {'identifier': 'chatHistory', 'enabled': true},
              ],
            },
          ],
        })),
        // 1 card
        routeStFile('c.json', jsonBytes({
          'spec': 'chara_card_v2',
          'data': {'name': 'Z', 'first_mes': 'hi'},
        })),
        // 1 skipped (unknown)
        routeStFile('junk.json', jsonBytes({'foo': 1})),
      ];
      final summary = summariseStBatch(results);
      expect(summary, contains('2 lorebooks'));
      expect(summary, contains('4 regex rules'));
      expect(summary, contains('1 preset'));
      expect(summary, contains('1 card'));
      expect(summary, contains('1 file skipped'));
    });

    test('all-skipped batch → "Nothing imported; N files skipped"', () {
      final results = [
        routeStFile('a.json', jsonBytes({'foo': 1})),
        routeStFile('b.json', jsonBytes({'bar': 2})),
      ];
      final summary = summariseStBatch(results);
      expect(summary, contains('Nothing imported'));
      expect(summary, contains('2 files skipped'));
    });

    test('singular units when exactly one', () {
      final results = [
        routeStFile('c.json', jsonBytes({
          'spec': 'chara_card_v2',
          'data': {'name': 'One', 'first_mes': 'hi'},
        })),
      ];
      final summary = summariseStBatch(results);
      expect(summary, contains('1 card imported'));
      expect(summary, isNot(contains('cards')));
    });
  });
}
