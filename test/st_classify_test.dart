// Pure structural classifier for the SillyTavern bulk importer (F7).
//
// Each test feeds ONE representative artifact and asserts the StArtifact label,
// then the disambiguation cases prove the priority order holds (a lorebook is
// not a card, a card is not a lorebook, a preset is not a card).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/st_classify.dart';

void main() {
  group('classifyStJson — happy path per type', () {
    test('chara_card_v2 card → card', () {
      final json = <String, dynamic>{
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {
          'name': 'Aria',
          'description': 'A wandering bard.',
          'personality': 'Cheerful, curious.',
          'first_mes': 'Oh, hello there!',
        },
      };
      expect(classifyStJson(json), StArtifact.card);
    });

    test('chara_card_v3 card → card', () {
      final json = <String, dynamic>{
        'spec': 'chara_card_v3',
        'data': {'name': 'Vex', 'first_mes': 'Hi.'},
      };
      expect(classifyStJson(json), StArtifact.card);
    });

    test('card with `data` wrapper but no spec → card', () {
      final json = <String, dynamic>{
        'data': {
          'name': 'Mara',
          'description': 'A scholar.',
        },
      };
      expect(classifyStJson(json), StArtifact.card);
    });

    test('legacy flat card (name + first_mes) → card', () {
      final json = <String, dynamic>{
        'name': 'Old Bob',
        'first_mes': 'Howdy.',
        'mes_example': '<START>\nBob: Hi',
      };
      expect(classifyStJson(json), StArtifact.card);
    });

    test('standalone uid-keyed World Info lorebook → lorebook', () {
      final json = <String, dynamic>{
        'name': 'Eldoria Lore',
        'entries': {
          '0': {
            'uid': 0,
            'key': ['Eldoria'],
            'content': 'A northern kingdom.',
            'order': 100,
          },
          '1': {
            'uid': 1,
            'key': ['Queen Maeve'],
            'content': 'Rules Eldoria.',
            'order': 90,
          },
        },
      };
      expect(classifyStJson(json), StArtifact.lorebook);
    });

    test('chara_card_v2 character_book (entries as List) → lorebook', () {
      final json = <String, dynamic>{
        'name': 'Bound Book',
        'entries': [
          {
            'keys': ['gate'],
            'content': 'A shimmering portal.',
          },
        ],
        'scan_depth': 2,
        'recursive_scanning': false,
      };
      expect(classifyStJson(json), StArtifact.lorebook);
    });

    test('single ST regex script → regex', () {
      final json = <String, dynamic>{
        'scriptName': 'Strip asterisks',
        'findRegex': '/\\*/g',
        'replaceString': '',
        'trimStrings': <String>[],
        'placement': [2],
        'disabled': false,
      };
      expect(classifyStJson(json), StArtifact.regex);
    });

    test('ST chat-completion preset with prompts → preset', () {
      final json = <String, dynamic>{
        'name': 'FluffPreset - RP',
        'temperature': 1.05,
        'prompts': [
          {'identifier': 'main', 'content': 'You are a writer.'},
          {'identifier': 'chatHistory', 'marker': true},
          {'identifier': 'jailbreak', 'content': 'Stay in character.'},
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
      };
      expect(classifyStJson(json), StArtifact.preset);
    });

    test('ST textgen sampler preset → preset', () {
      final json = <String, dynamic>{
        'name': 'My Sampler',
        'temperature': 0.9,
        'top_p': 0.95,
        'top_k': 40,
        'rep_pen': 1.1,
        'max_length': 2048,
      };
      expect(classifyStJson(json), StArtifact.preset);
    });

    test('ST instruct/context template → preset', () {
      final json = <String, dynamic>{
        'name': 'Alpaca',
        'system_prompt': 'Below is an instruction.',
        'input_sequence': '### Instruction:',
        'output_sequence': '### Response:',
      };
      expect(classifyStJson(json), StArtifact.preset);
    });

    test('Pyre-native preset re-export (mainPrompt) → preset', () {
      final json = <String, dynamic>{
        'name': 'Pyre Default (export)',
        'mainPrompt': 'You are {{char}}.',
        'postHistoryInstructions': '',
      };
      expect(classifyStJson(json), StArtifact.preset);
    });

    test('empty map → unknown', () {
      expect(classifyStJson(<String, dynamic>{}), StArtifact.unknown);
    });

    test('garbage map → unknown', () {
      final json = <String, dynamic>{
        'foo': 'bar',
        'count': 3,
        'nested': {'a': 1},
      };
      expect(classifyStJson(json), StArtifact.unknown);
    });
  });

  group('disambiguation — priority order holds', () {
    test('a lorebook must NOT classify as card', () {
      // Has `name` + `entries` but no first_mes/personality. Must be lorebook.
      final json = <String, dynamic>{
        'name': 'World Info',
        'description': 'Setting notes.',
        'entries': {
          '0': {
            'key': ['town'],
            'content': 'A small town.',
          },
        },
      };
      expect(classifyStJson(json), StArtifact.lorebook);
    });

    test('a card with embedded character_book must classify as card', () {
      // Card markers win over the embedded book's `entries` (the importer
      // routes to the card path, which then handles the embedded book).
      final json = <String, dynamic>{
        'spec': 'chara_card_v2',
        'data': {
          'name': 'Witch',
          'first_mes': 'Welcome.',
          'character_book': {
            'entries': [
              {'keys': ['spell'], 'content': 'Fireball.'},
            ],
          },
        },
        // A top-level `entries` that would otherwise look like a lorebook.
        'entries': [],
      };
      expect(classifyStJson(json), StArtifact.card);
    });

    test('a preset must NOT classify as card', () {
      // Sampler preset carrying a `name` (every preset has one) — the card
      // test requires a card-distinctive field, which this lacks.
      final json = <String, dynamic>{
        'name': 'Creative',
        'temperature': 1.2,
        'top_p': 0.9,
        'top_k': 50,
      };
      expect(classifyStJson(json), StArtifact.preset);
    });

    test('a regex script that also has a name must classify as regex', () {
      final json = <String, dynamic>{
        'scriptName': 'Rename',
        'name': 'Rename',
        'findRegex': '/foo/g',
        'replaceString': 'bar',
      };
      expect(classifyStJson(json), StArtifact.regex);
    });

    test('replaceString may be empty (strip rule) and still be regex', () {
      final json = <String, dynamic>{
        'findRegex': '/x/g',
        'replaceString': '',
      };
      expect(classifyStJson(json), StArtifact.regex);
    });
  });

  group('classifyStFile — array + non-object handling', () {
    test('array of 3 regex scripts → regex', () {
      final arr = <dynamic>[
        {'findRegex': '/a/g', 'replaceString': ''},
        {'findRegex': '/b/g', 'replaceString': 'B'},
        {'findRegex': '/c/', 'replaceString': 'C'},
      ];
      expect(classifyStFile(arr), StArtifact.regex);
    });

    test('array where majority are regex → regex (tolerant)', () {
      final arr = <dynamic>[
        {'findRegex': '/a/g', 'replaceString': ''},
        {'findRegex': '/b/g', 'replaceString': 'B'},
        {'unrelated': true},
      ];
      expect(classifyStFile(arr), StArtifact.regex);
    });

    test('array where most elements are NOT regex → unknown', () {
      final arr = <dynamic>[
        {'findRegex': '/a/g', 'replaceString': ''},
        {'foo': 1},
        {'bar': 2},
      ];
      expect(classifyStFile(arr), StArtifact.unknown);
    });

    test('empty array → unknown', () {
      expect(classifyStFile(<dynamic>[]), StArtifact.unknown);
    });

    test('array of non-objects → unknown', () {
      expect(classifyStFile(<dynamic>['a', 'b', 'c']), StArtifact.unknown);
    });

    test('object delegates to classifyStJson', () {
      final json = <String, dynamic>{
        'spec': 'chara_card_v2',
        'data': {'name': 'X', 'first_mes': 'hi'},
      };
      expect(classifyStFile(json), StArtifact.card);
    });

    test('bare string → unknown', () {
      expect(classifyStFile('hello'), StArtifact.unknown);
    });

    test('null → unknown', () {
      expect(classifyStFile(null), StArtifact.unknown);
    });
  });
}
