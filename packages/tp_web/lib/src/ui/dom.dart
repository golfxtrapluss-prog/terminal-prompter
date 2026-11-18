import 'package:web/web.dart' as web;

/// Creates an element with optional class, text and title. Text is set with
/// `textContent`, never `innerHTML` (docs/03 "Sikkerhet i klienten").
///
/// [label] sets the accessible name (`aria-label`); use it for icon-only
/// buttons and whenever [title] (a tooltip) would otherwise become the name.
web.HTMLElement el(
  String tag, {
  String? className,
  String? text,
  String? title,
  String? label,
}) {
  final element = web.document.createElement(tag) as web.HTMLElement;
  if (className != null) element.className = className;
  if (text != null) element.textContent = text;
  if (title != null) element.title = title;
  if (label != null) element.setAttribute('aria-label', label);
  return element;
}
