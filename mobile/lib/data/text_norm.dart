/// Shared text normalisation: the diacritic
/// stripping both the IQAir matcher and the
/// picture matcher need.
///
/// Dart has no built-in Unicode NFKD normalisation,
/// so the accented Latin characters the destination
/// and city names carry (Cancún, Montréal, Đà Nẵng)
/// are decomposed with an explicit map. Characters
/// outside the maps are left for the caller's
/// non-alphanumeric collapse to replace with a
/// space — the same miss the Python side's
/// `unicodedata.normalize("NFKD", ...)` records.
library;

/// Decompose the accented Latin characters to
/// their ASCII base.
String stripDiacritics(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    buffer.write(_diacritics[char] ?? _vietnamese[char] ?? char);
  }
  return buffer.toString();
}

/// Accented character -> ASCII base. Covers the
/// Latin-1 Supplement and Latin Extended-A blocks,
/// which is what the workbook's city and country
/// names use.
const _diacritics = <String, String>{
  'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A',
  'Æ': 'AE', 'Ç': 'C',
  'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E',
  'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I',
  'Ð': 'D', 'Ñ': 'N',
  'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ø': 'O',
  'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U',
  'Ý': 'Y', 'Þ': 'Th', 'ß': 'ss',
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'æ': 'ae', 'ç': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ð': 'd', 'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'þ': 'th', 'ÿ': 'y',
  // Latin Extended-A
  'Ā': 'A', 'ā': 'a', 'Ă': 'A', 'ă': 'a', 'Ą': 'A', 'ą': 'a',
  'Ć': 'C', 'ć': 'c', 'Ĉ': 'C', 'ĉ': 'C', 'Ċ': 'C', 'ċ': 'c',
  'Č': 'C', 'č': 'c', 'Ď': 'D', 'ď': 'd', 'Đ': 'D', 'đ': 'd',
  'Ē': 'E', 'ē': 'e', 'Ĕ': 'E', 'ĕ': 'e', 'Ė': 'E', 'ė': 'e',
  'Ę': 'E', 'ę': 'e', 'Ě': 'E', 'ě': 'e',
  'Ĝ': 'G', 'ĝ': 'g', 'Ğ': 'G', 'ğ': 'g', 'Ġ': 'G', 'ġ': 'g',
  'Ģ': 'G', 'ģ': 'g', 'Ĥ': 'H', 'ĥ': 'h', 'Ħ': 'H', 'ħ': 'h',
  'Ĩ': 'I', 'ĩ': 'i', 'Ī': 'I', 'ī': 'i', 'Ĭ': 'I', 'ĭ': 'i',
  'Į': 'I', 'į': 'i', 'İ': 'I', 'ı': 'i', 'Ĳ': 'IJ', 'ĳ': 'ij',
  'Ĵ': 'J', 'ĵ': 'j', 'Ķ': 'K', 'ķ': 'k', 'ĸ': 'k',
  'Ĺ': 'L', 'ĺ': 'l', 'Ļ': 'L', 'ļ': 'l', 'Ľ': 'L', 'ľ': 'l',
  'Ŀ': 'L', 'ŀ': 'l', 'Ł': 'L', 'ł': 'l',
  'Ń': 'N', 'ń': 'n', 'Ņ': 'N', 'ņ': 'n', 'Ň': 'N', 'ň': 'n',
  'Ŋ': 'N', 'ŋ': 'n',
  'Ō': 'O', 'ō': 'o', 'Ŏ': 'O', 'ŏ': 'o', 'Ő': 'O', 'ő': 'o',
  'Œ': 'OE', 'œ': 'oe',
  'Ŕ': 'R', 'ŕ': 'r', 'Ŗ': 'R', 'ŗ': 'r', 'Ř': 'R', 'ř': 'r',
  'Ś': 'S', 'ś': 's', 'Ŝ': 'S', 'ŝ': 's', 'Ş': 'S', 'ş': 's',
  'Š': 'S', 'š': 's',
  'Ţ': 'T', 'ţ': 't', 'Ť': 'T', 'ť': 't', 'Ŧ': 'T', 'ŧ': 't',
  'Ũ': 'U', 'ũ': 'u', 'Ū': 'U', 'ū': 'u', 'Ŭ': 'U', 'ŭ': 'u',
  'Ů': 'U', 'ů': 'u', 'Ű': 'U', 'ű': 'u', 'Ų': 'U', 'ų': 'u',
  'Ŵ': 'W', 'ŵ': 'w', 'Ŷ': 'Y', 'ŷ': 'y', 'Ÿ': 'Y',
  'Ź': 'Z', 'ź': 'z', 'Ż': 'Z', 'ż': 'z', 'Ž': 'Z', 'ž': 'z',
};

/// The Vietnamese letters (Latin Extended-B and the
/// Latin Extended Additional block): the catalogue's
/// Southeast-Asian names carry them, and the ranking
/// spells those cities ASCII ("Da Nang").
const _vietnamese = <String, String>{
  'Đ': 'D', 'đ': 'd',
  'Ă': 'A', 'ă': 'a',
  'Ơ': 'O', 'ơ': 'o',
  'Ư': 'U', 'ư': 'u',
  'Ạ': 'A', 'ạ': 'a', 'Ả': 'A', 'ả': 'a',
  'Ấ': 'A', 'ấ': 'a', 'Ầ': 'A', 'ầ': 'a',
  'Ẩ': 'A', 'ẩ': 'a', 'Ẫ': 'A', 'ẫ': 'a',
  'Ậ': 'A', 'ậ': 'a',
  'Ắ': 'A', 'ắ': 'a', 'Ằ': 'A', 'ằ': 'a',
  'Ẳ': 'A', 'ẳ': 'a', 'Ẵ': 'A', 'ẵ': 'a',
  'Ặ': 'A', 'ặ': 'a',
  'Ẹ': 'E', 'ẹ': 'e', 'Ẻ': 'E', 'ẻ': 'e',
  'Ẽ': 'E', 'ẽ': 'e',
  'Ế': 'E', 'ế': 'e', 'Ề': 'E', 'ề': 'e',
  'Ể': 'E', 'ể': 'e', 'Ễ': 'E', 'ễ': 'e',
  'Ệ': 'E', 'ệ': 'e',
  'Ỉ': 'I', 'ỉ': 'i', 'Ị': 'I', 'ị': 'i',
  'Ọ': 'O', 'ọ': 'o', 'Ỏ': 'O', 'ỏ': 'o',
  'Ố': 'O', 'ố': 'o', 'Ồ': 'O', 'ồ': 'o',
  'Ổ': 'O', 'ổ': 'o', 'Ỗ': 'O', 'ỗ': 'o',
  'Ộ': 'O', 'ộ': 'o',
  'Ớ': 'O', 'ớ': 'o', 'Ờ': 'O', 'ờ': 'o',
  'Ở': 'O', 'ở': 'o', 'Ỡ': 'O', 'ỡ': 'o',
  'Ợ': 'O', 'ợ': 'o',
  'Ụ': 'U', 'ụ': 'u', 'Ủ': 'U', 'ủ': 'u',
  'Ứ': 'U', 'ứ': 'u', 'Ừ': 'U', 'ừ': 'u',
  'Ử': 'U', 'ử': 'u', 'Ữ': 'U', 'ữ': 'u',
  'Ự': 'U', 'ự': 'u',
  'Ỳ': 'Y', 'ỳ': 'y', 'Ỵ': 'Y', 'ỵ': 'y',
  'Ỷ': 'Y', 'ỷ': 'y', 'Ỹ': 'Y', 'ỹ': 'y',
};
