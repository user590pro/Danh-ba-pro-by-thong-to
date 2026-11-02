import 'package:flutter_test/flutter_test.dart';
import 'package:contact_finder/utils/vietnamese_matcher.dart';

void main() {
  group('Vietnamese Matcher Tests', () {
    test('User test case: 3 d 4 diêm 1 (có chữ -> chỉ match theo tên)', () {
      final query = '3 d 4 diêm 1';
      final candidates = [
        '3 d 4 diêm 1',
        '3 đ 4 diêm 1',
        '3d 4 diêm 1',
        '3 đ4 diêm 1',
        '3 đ4 diêm1',
      ];

      for (final name in candidates) {
        final result = VietnameseMatcher.matchContact(
          name: name,
          phones: ['0912345678'],
          query: query,
        );
        expect(result.isMatched, isTrue, reason: 'Candidate "$name" should match "$query"');
        expect(result.score, greaterThan(700), reason: 'Candidate "$name" should have high score');
        expect(result.nameHighlights.isNotEmpty, isTrue);
        expect(result.phoneHighlights.isEmpty, isTrue, reason: 'Phone should NOT match when query has letters');
      }
    });

    test('Query có chữ thì KHÔNG match với số điện thoại', () {
      final query = 'd 123'; // có chữ d
      final result = VietnameseMatcher.matchContact(
        name: 'Nguyen Van A',
        phones: ['0912345678'], // số này có '123'
        query: query,
      );
      expect(result.isMatched, isFalse, reason: 'Name does not match and phone must not be searched');
    });

    test('Query là dãy số thì CHỈ match số điện thoại, KHÔNG match tên', () {
      // 1. Match phone
      final resultPhone = VietnameseMatcher.matchContact(
        name: 'Phát Tài',
        phones: ['0983861234', '+84 983 86 999'],
        query: '8386',
      );

      expect(resultPhone.isMatched, isTrue);
      expect(resultPhone.phoneHighlights.containsKey('0983861234'), isTrue);
      expect(resultPhone.nameHighlights.isEmpty, isTrue);

      // 2. Tên có số 8386 nhưng số điện thoại không có -> KHÔNG match
      final resultNameOnly = VietnameseMatcher.matchContact(
        name: 'Phát Lộc 8386',
        phones: ['0900000000'],
        query: '8386',
      );
      expect(resultNameOnly.isMatched, isFalse, reason: 'Digits-only query must only match phone numbers, not names');
    });
  });
}
