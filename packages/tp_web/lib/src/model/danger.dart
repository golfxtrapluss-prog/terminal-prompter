/// Detection of commands that deserve a confirmation (docs/03). The list is
/// user-configurable; these are the defaults.
final class DangerDetector {
  /// Creates a detector from regular-expression sources.
  DangerDetector([List<String>? patterns])
    : patterns = List.unmodifiable(patterns ?? defaultPatterns),
      _regexes = [
        for (final p in patterns ?? defaultPatterns)
          RegExp(p, caseSensitive: false),
      ];

  /// Default patterns.
  static const List<String> defaultPatterns = [
    r'\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\b',
    r'\brm\s+-[a-z]*r[a-z]*\s+/(\s|$)',
    r'\bmkfs(\.\w+)?\b',
    r'\bdd\s+.*\bof=/dev/',
    r'>\s*/dev/(sd|nvme|vd|hd)',
    r'(^|[;&|]\s*|\bsudo\s+)(shutdown|poweroff|halt|reboot)\b',
    r'\bchmod\s+(-R\s+)?[0-7]*777\s+/(\s|$)',
    r'\bchown\s+-R\b.*\s/(\s|$)',
    r':\(\)\s*\{\s*:\|:&\s*\};:',
    r'\bdocker\s+(system\s+prune|volume\s+prune|rm\s+-f)\b',
    r'\bgit\s+push\s+.*--force\b',
    r'\bDROP\s+(TABLE|DATABASE)\b',
    r'\btruncate\s+-s\s*0\b',
  ];

  /// Pattern sources in use.
  final List<String> patterns;
  final List<RegExp> _regexes;

  /// Returns the first matching pattern source, or null when harmless.
  String? match(String command) {
    for (var i = 0; i < _regexes.length; i++) {
      if (_regexes[i].hasMatch(command)) return patterns[i];
    }
    return null;
  }

  /// True when [command] needs confirmation.
  bool isDangerous(String command) => match(command) != null;
}
