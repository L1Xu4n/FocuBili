import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/search_content_filter.dart';

Map<String, Object?> settings({int minimumPlayCount = 12345}) => {
  'learningOnly': true,
  'minimumPlayCount': minimumPlayCount,
};

void main() {
  test('legacy two-field settings retain their explicit choices', () {
    final filter = SearchContentFilter.fromJsonStrict(settings());
    expect(filter.learningOnly, isTrue);
    expect(filter.minimumPlayCount, 12345);
    expect(filter.titleKeywords, isEmpty);
    expect(filter.ownerKeywords, isEmpty);
  });

  test(
    'JSON-decoded new settings preserve case and order while normalizing terms',
    () {
      final filter = SearchContentFilter.fromJsonStrict(
        jsonDecode(
          jsonEncode({
            'learningOnly': false,
            'minimumPlayCount': 0,
            'titleKeywords': [' Beta，ALPHA ', 'beta', '中文\nC++', ''],
            'ownerKeywords': [' Studio;UP ', 'studio', '另一位作者'],
          }),
        ),
      );
      expect(filter.learningOnly, isFalse);
      expect(filter.titleKeywords, ['Beta', 'ALPHA', '中文', 'C++']);
      expect(filter.ownerKeywords, ['Studio', 'UP', '另一位作者']);
    },
  );

  test('either keyword field can be omitted independently', () {
    final titleOnly = SearchContentFilter.fromJsonStrict({
      ...settings(),
      'titleKeywords': ['Title'],
    });
    final ownerOnly = SearchContentFilter.fromJsonStrict({
      ...settings(),
      'ownerKeywords': ['Owner'],
    });
    expect(titleOnly.titleKeywords, ['Title']);
    expect(titleOnly.ownerKeywords, isEmpty);
    expect(ownerOnly.titleKeywords, isEmpty);
    expect(ownerOnly.ownerKeywords, ['Owner']);
  });

  for (final minimum in [0, SearchContentFilter.maximumPlayCount]) {
    test('minimum play count accepts inclusive boundary $minimum', () {
      final filter = SearchContentFilter.fromJsonStrict(
        settings(minimumPlayCount: minimum),
      );
      expect(filter.minimumPlayCount, minimum);
    });
  }

  test('empty lists and blank terms normalize to no exclusions', () {
    final filter = SearchContentFilter.fromJsonStrict({
      ...settings(),
      'titleKeywords': <String>[],
      'ownerKeywords': [' ', '\n,，;；'],
    });
    expect(filter.titleKeywords, isEmpty);
    expect(filter.ownerKeywords, isEmpty);
  });

  test('validation neither mutates nor retains mutable input collections', () {
    final titles = [' Title ', 'Second'];
    final source = {...settings(), 'titleKeywords': titles};
    final before = jsonEncode(source);
    final filter = SearchContentFilter.fromJsonStrict(source);
    expect(jsonEncode(source), before);
    titles[0] = 'Changed';
    expect(filter.titleKeywords, ['Title', 'Second']);
    expect(() => filter.titleKeywords.add('Third'), throwsUnsupportedError);
  });

  final invalidRoots = <Object?>[null, false, 42, 'settings', <Object?>[]];
  for (var index = 0; index < invalidRoots.length; index++) {
    test('non-object root $index throws FormatException', () {
      expect(
        () => SearchContentFilter.fromJsonStrict(invalidRoots[index]),
        throwsFormatException,
      );
    });
  }

  for (final required in ['learningOnly', 'minimumPlayCount']) {
    test('missing required field $required is rejected', () {
      final source = settings()..remove(required);
      expect(
        () => SearchContentFilter.fromJsonStrict(source),
        throwsFormatException,
      );
    });
  }

  test('unknown fields and non-string keys are rejected', () {
    for (final source in <Map<Object?, Object?>>[
      {...settings(), 'unexpected': true},
      {...settings(), null: 'unknown'},
      {...settings(), 1: 'unknown'},
    ]) {
      expect(
        () => SearchContentFilter.fromJsonStrict(source),
        throwsFormatException,
      );
    }
  });

  test('learning choice requires a boolean and never infers a default', () {
    for (final value in <Object?>[null, 0, 1, 'true', <Object?>[]]) {
      expect(
        () => SearchContentFilter.fromJsonStrict({
          ...settings(),
          'learningOnly': value,
        }),
        throwsFormatException,
      );
    }
  });

  test('minimum play count rejects out-of-range and non-integer values', () {
    for (final value in <Object?>[
      null,
      -1,
      SearchContentFilter.maximumPlayCount + 1,
      0.0,
      123.5,
      double.nan,
      double.infinity,
      '12345',
      true,
    ]) {
      expect(
        () => SearchContentFilter.fromJsonStrict({
          ...settings(),
          'minimumPlayCount': value,
        }),
        throwsFormatException,
      );
    }
  });

  for (final key in ['titleKeywords', 'ownerKeywords']) {
    test(
      '$key rejects present null, non-lists and mixed/non-string entries',
      () {
        for (final value in <Object?>[
          null,
          'Title',
          1,
          false,
          {'term': 'Title'},
          {'Title'},
          [1],
          ['Title', null],
          ['Title', false],
          [
            'Title',
            {'term': 'Other'},
          ],
        ]) {
          expect(
            () =>
                SearchContentFilter.fromJsonStrict({...settings(), key: value}),
            throwsFormatException,
          );
        }
      },
    );
  }
}
