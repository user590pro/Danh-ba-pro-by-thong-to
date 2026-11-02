class MatchHighlight {
  final int start;
  final int end;
  const MatchHighlight(this.start, this.end);
}

class SearchMatchResult {
  final bool isMatched;
  final int score;
  final List<MatchHighlight> nameHighlights;
  final Map<String, List<MatchHighlight>> phoneHighlights;

  const SearchMatchResult({
    required this.isMatched,
    required this.score,
    this.nameHighlights = const [],
    this.phoneHighlights = const {},
  });
}

class PreparedPhone {
  final String raw;
  final String digits;

  PreparedPhone(this.raw) : digits = VietnameseMatcher.extractDigits(raw);
}

class PreparedContact {
  final String id;
  final String displayName;
  final String displayNameLower;
  final String displayNameBase;
  final String displayNameCollapsedBase;
  final List<PreparedPhone> phones;

  PreparedContact({
    required this.id,
    required this.displayName,
    required List<String> rawPhones,
  })  : displayNameLower = displayName.toLowerCase(),
        displayNameBase = VietnameseMatcher.removeDiacritics(displayName),
        displayNameCollapsedBase = VietnameseMatcher.removeDiacritics(displayName)
            .replaceAll(RegExp(r'\s+'), ''),
        phones = rawPhones.map((p) => PreparedPhone(p)).toList();
}

class PreparedQuery {
  final String raw;
  final String trimmed;
  final bool hasLetters;
  final String digits;
  final String altDigits;
  final String lower;
  final String base;
  final String collapsedBase;
  final List<String> tokens;
  final List<String> tokenBases;

  PreparedQuery(this.raw)
      : trimmed = raw.trim(),
        hasLetters = RegExp(r'[\p{L}]', unicode: true).hasMatch(raw.trim()),
        digits = VietnameseMatcher.extractDigits(raw.trim()),
        altDigits = _getAltDigits(VietnameseMatcher.extractDigits(raw.trim())),
        lower = raw.trim().toLowerCase(),
        base = VietnameseMatcher.removeDiacritics(raw.trim()),
        collapsedBase = VietnameseMatcher.removeDiacritics(raw.trim())
            .replaceAll(RegExp(r'\s+'), ''),
        tokens = raw.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(),
        tokenBases = raw
            .trim()
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .map(VietnameseMatcher.removeDiacritics)
            .toList();

  static String _getAltDigits(String d) {
    if (d.startsWith('0')) return '84${d.substring(1)}';
    if (d.startsWith('84')) return '0${d.substring(2)}';
    return '';
  }
}

class VietnameseMatcher {
  /// Map each character to its lower-case base ASCII character, mapping đ/Đ to d
  static String removeDiacritics(String str) {
    final buffer = StringBuffer();
    for (int i = 0; i < str.length; i++) {
      buffer.write(_toBaseAscii(str[i]));
    }
    return buffer.toString();
  }

  /// Normalize Vietnamese accents but KEEP đ and accents in canonical lowercase
  static String normalizeVietnamese(String str) {
    return str.toLowerCase().trim();
  }

  /// Mapping char to ascii lower (including đ -> d)
  static String _toBaseAscii(String char) {
    switch (char) {
      case 'à': case 'á': case 'ả': case 'ã': case 'ạ':
      case 'ă': case 'ằ': case 'ắ': case 'ẳ': case 'ẵ': case 'ặ':
      case 'â': case 'ầ': case 'ấ': case 'ẩ': case 'ẫ': case 'ậ':
      case 'À': case 'Á': case 'Ả': case 'Ã': case 'Ạ':
      case 'Ă': case 'Ằ': case 'Ắ': case 'Ẳ': case 'Ẵ': case 'Ặ':
      case 'Â': case 'Ầ': case 'Ấ': case 'Ẩ': case 'Ẫ': case 'Ậ':
        return 'a';

      case 'è': case 'é': case 'ẻ': case 'ẽ': case 'ẹ':
      case 'ê': case 'ề': case 'ế': case 'ể': case 'ễ': case 'ệ':
      case 'È': case 'É': case 'Ẻ': case 'Ẽ': case 'Ẹ':
      case 'Ê': case 'Ề': case 'Ế': case 'Ể': case 'Ễ': case 'Ệ':
        return 'e';

      case 'ì': case 'í': case 'ỉ': case 'ĩ': case 'ị':
      case 'Ì': case 'Í': case 'Ỉ': case 'Ĩ': case 'Ị':
        return 'i';

      case 'ò': case 'ó': case 'ỏ': case 'õ': case 'ọ':
      case 'ô': case 'ồ': case 'ố': case 'ổ': case 'ỗ': case 'ộ':
      case 'ơ': case 'ờ': case 'ớ': case 'ở': case 'ỡ': case 'ợ':
      case 'Ò': case 'Ó': case 'Ỏ': case 'Õ': case 'Ọ':
      case 'Ô': case 'Ồ': case 'Ố': case 'Ổ': case 'Ỗ': case 'Ộ':
      case 'Ơ': case 'Ờ': case 'Ớ': case 'Ở': case 'Ỡ': case 'Ợ':
        return 'o';

      case 'ù': case 'ú': case 'ủ': case 'ũ': case 'ụ':
      case 'ư': case 'ừ': case 'ứ': case 'ử': case 'ữ': case 'ự':
      case 'Ù': case 'Ú': case 'Ủ': case 'Ũ': case 'Ụ':
      case 'Ư': case 'Ừ': case 'Ứ': case 'Ử': case 'Ữ': case 'Ự':
        return 'u';

      case 'ỳ': case 'ý': case 'ỷ': case 'ỹ': case 'ỵ':
      case 'Ỳ': case 'Ý': case 'Ỷ': case 'Ỹ': case 'Ỵ':
        return 'y';

      case 'đ': case 'Đ':
        return 'd';

      default:
        return char.toLowerCase();
    }
  }

  /// Clean phone number to digits only
  static String extractDigits(String phone) {
    final buffer = StringBuffer();
    for (int i = 0; i < phone.length; i++) {
      final code = phone.codeUnitAt(i);
      if (code >= 48 && code <= 57) {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  /// Fast phone match locating highlight span in original phone string
  static List<MatchHighlight>? matchPhone(String originalPhone, String queryDigits, [String altQuery = '']) {
    if (queryDigits.isEmpty) return null;
    
    final rawDigits = extractDigits(originalPhone);
    String matchTarget = queryDigits;
    int matchIndexInRaw = rawDigits.indexOf(queryDigits);

    if (matchIndexInRaw == -1 && altQuery.isNotEmpty) {
      matchIndexInRaw = rawDigits.indexOf(altQuery);
      if (matchIndexInRaw != -1) {
        matchTarget = altQuery;
      }
    }

    if (matchIndexInRaw == -1) return null;

    int digitCount = 0;
    int startChar = -1;
    int endChar = -1;

    for (int i = 0; i < originalPhone.length; i++) {
      final code = originalPhone.codeUnitAt(i);
      if (code >= 48 && code <= 57) {
        if (digitCount == matchIndexInRaw && startChar == -1) {
          startChar = i;
        }
        if (digitCount == matchIndexInRaw + matchTarget.length - 1) {
          endChar = i + 1;
          break;
        }
        digitCount++;
      }
    }

    if (startChar != -1 && endChar != -1) {
      return [MatchHighlight(startChar, endChar)];
    }
    return null;
  }

  /// Ultra-fast match against a pre-computed contact
  static SearchMatchResult matchPreparedContact({
    required PreparedContact contact,
    required PreparedQuery query,
  }) {
    if (query.trimmed.isEmpty) {
      return const SearchMatchResult(isMatched: true, score: 0);
    }

    // 1. NẾU LÀ DÃY SỐ (KHÔNG CÓ CHỮ) -> CHỈ MATCH SỐ ĐIỆN THOẠI
    if (!query.hasLetters) {
      if (query.digits.isEmpty) {
        return const SearchMatchResult(isMatched: false, score: 0);
      }

      int bestPhoneScore = 0;
      final Map<String, List<MatchHighlight>> phoneHighlights = {};

      for (int i = 0; i < contact.phones.length; i++) {
        final p = contact.phones[i];
        final phoneDigits = p.digits;
        if (phoneDigits.isEmpty) continue;

        // Fast check before character span calculation
        final bool matchedDirect = phoneDigits.contains(query.digits);
        final bool matchedAlt = query.altDigits.isNotEmpty && phoneDigits.contains(query.altDigits);

        if (matchedDirect || matchedAlt) {
          final hl = matchPhone(p.raw, query.digits, query.altDigits);
          if (hl != null) {
            phoneHighlights[p.raw] = hl;
            int phoneScore = 600;
            if (phoneDigits == query.digits || (query.altDigits.isNotEmpty && phoneDigits == query.altDigits)) {
              phoneScore = 1200;
            } else if (phoneDigits.endsWith(query.digits) || (query.altDigits.isNotEmpty && phoneDigits.endsWith(query.altDigits))) {
              phoneScore = 950;
            } else if (phoneDigits.startsWith(query.digits) || (query.altDigits.isNotEmpty && phoneDigits.startsWith(query.altDigits))) {
              phoneScore = 900;
            } else {
              phoneScore = 800 + (query.digits.length * 10);
            }
            if (phoneScore > bestPhoneScore) {
              bestPhoneScore = phoneScore;
            }
          }
        }
      }

      return SearchMatchResult(
        isMatched: phoneHighlights.isNotEmpty,
        score: bestPhoneScore,
        phoneHighlights: phoneHighlights,
        nameHighlights: const [],
      );
    }

    // 2. NẾU CÓ CHỮ -> CHỈ MATCH TÊN LIÊN HỆ
    final nameLower = contact.displayNameLower;
    final queryLower = query.lower;

    // Direct Exact Match
    if (nameLower == queryLower) {
      return SearchMatchResult(
        isMatched: true,
        score: 1500,
        nameHighlights: [MatchHighlight(0, contact.displayName.length)],
        phoneHighlights: const {},
      );
    }

    // Direct Substring Match
    final subIdx = nameLower.indexOf(queryLower);
    if (subIdx != -1) {
      final score = 1200 + ((queryLower.length / nameLower.length) * 100).toInt();
      return SearchMatchResult(
        isMatched: true,
        score: score,
        nameHighlights: [MatchHighlight(subIdx, subIdx + queryLower.length)],
        phoneHighlights: const {},
      );
    }

    // Fast check for collapsed match:
    // If the precomputed collapsed base doesn't even contain collapsed query,
    // we only check tokens if query has multiple tokens.
    final bool hasCollapsedMatch = contact.displayNameCollapsedBase.contains(query.collapsedBase);

    if (hasCollapsedMatch) {
      final collapsedMatch = _findCollapsedMatch(
        contact.displayName,
        contact.displayNameBase,
        query.collapsedBase,
      );

      if (collapsedMatch != null) {
        int score = 700;
        final matchedOriginal = contact.displayName.substring(collapsedMatch.start, collapsedMatch.end);

        int accentMatches = 0;
        int minLen = queryLower.length < matchedOriginal.length ? queryLower.length : matchedOriginal.length;
        for (int i = 0; i < minLen; i++) {
          if (queryLower[i] == matchedOriginal.toLowerCase()[i]) {
            accentMatches++;
          }
        }
        score += (accentMatches * 10);

        final normalizedQuery = query.lower.replaceAll(RegExp(r'\s+'), '').replaceAll('đ', 'd');
        final normalizedMatched = matchedOriginal.toLowerCase().replaceAll(RegExp(r'\s+'), '').replaceAll('đ', 'd');
        if (normalizedQuery == normalizedMatched) {
          score += 200;
        }

        if (contact.displayNameCollapsedBase == query.collapsedBase) {
          score += 200;
        } else if (contact.displayNameCollapsedBase.startsWith(query.collapsedBase)) {
          score += 100;
        }

        return SearchMatchResult(
          isMatched: true,
          score: score,
          nameHighlights: [collapsedMatch],
          phoneHighlights: const {},
        );
      }
    }

    // Token-based matching if multi-word query
    if (query.tokens.length > 1) {
      final tokenHighlights = <MatchHighlight>[];
      int matchedTokens = 0;
      int lastSearchIndex = 0;

      for (int i = 0; i < query.tokenBases.length; i++) {
        final tBase = query.tokenBases[i];
        final match = _findCollapsedMatch(
          contact.displayName,
          contact.displayNameBase,
          tBase,
          startIndex: lastSearchIndex,
        );
        if (match != null) {
          tokenHighlights.add(match);
          matchedTokens++;
          lastSearchIndex = match.end;
        }
      }

      if (matchedTokens == query.tokens.length) {
        final score = 600 + (query.tokens.length * 20);
        return SearchMatchResult(
          isMatched: true,
          score: score,
          nameHighlights: tokenHighlights,
          phoneHighlights: const {},
        );
      } else if (matchedTokens > 0) {
        final score = 300 * matchedTokens ~/ query.tokens.length;
        return SearchMatchResult(
          isMatched: true,
          score: score,
          nameHighlights: tokenHighlights,
          phoneHighlights: const {},
        );
      }
    }

    return const SearchMatchResult(
      isMatched: false,
      score: 0,
      nameHighlights: [],
      phoneHighlights: {},
    );
  }

  /// Legacy helper for raw strings
  static SearchMatchResult matchContact({
    required String name,
    required List<String> phones,
    required String query,
  }) {
    final prepContact = PreparedContact(id: '', displayName: name, rawPhones: phones);
    final prepQuery = PreparedQuery(query);
    return matchPreparedContact(contact: prepContact, query: prepQuery);
  }

  /// Finds match in `original` by locating `queryNoSpaceBase` in `nameBase` ignoring whitespace
  static MatchHighlight? _findCollapsedMatch(
    String original,
    String nameBase,
    String queryNoSpaceBase, {
    int startIndex = 0,
  }) {
    if (queryNoSpaceBase.isEmpty) return null;

    final targetLen = nameBase.length;
    final queryLen = queryNoSpaceBase.length;

    for (int i = startIndex; i < targetLen; i++) {
      int queryPtr = 0;
      int origPtr = i;

      while (origPtr < targetLen && queryPtr < queryLen) {
        final code = nameBase.codeUnitAt(origPtr);
        // Skip spaces, dash, dot, comma, underscore
        if (code == 32 || code == 45 || code == 46 || code == 44 || code == 95) {
          origPtr++;
          continue;
        }

        if (nameBase[origPtr] == queryNoSpaceBase[queryPtr]) {
          queryPtr++;
          origPtr++;
        } else {
          break;
        }
      }

      if (queryPtr == queryLen) {
        return MatchHighlight(i, origPtr);
      }
    }

    return null;
  }
}
