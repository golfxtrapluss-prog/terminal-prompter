import 'package:web/web.dart' as web;

/// Creates an element with optional class, text and title. Text is set with
/// `textContent`, never `innerHTML` (docs/03 "Sikkerhet i klienten").
web.HTMLElement el(
  String tag, {
  String? className,
  String? text,
  String? title,
}) {
  final element = web.document.createElement(tag) as web.HTMLElement;
  if (className != null) element.className = className;
  if (text != null) element.textContent = text;
  if (title != null) element.title = title;
  return element;
}
