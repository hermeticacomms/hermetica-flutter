import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'client.dart';
import 'models.dart';

/// Renders a message yourself: call [onButton] when a button is tapped and [onDismiss] when it is closed, so the
/// host reports the click or dismissal and moves on.
typedef InAppMessageBuilder = Widget Function(BuildContext context, InAppMessage message, void Function(InAppButton button) onButton, VoidCallback onDismiss);

/// Runs for `deep_link`, `url` and `event` buttons. Return true when you handled it, to skip the default
/// (deep links go to [Hermetica.onDeepLink], events are tracked).
typedef InAppActionHandler = bool Function(String action, String value, InAppMessage message);

/// Shows in-app messages over [child]. Put it once near the root, e.g. `MaterialApp(builder: (context, child) =>
/// HermeticaInAppHost(child: child!))`. It fetches messages on mount (`app_open`) and on every screen or event the
/// client reports, shows the best one at a time (each message once per host), and tracks impression, click and dismiss.
class HermeticaInAppHost extends StatefulWidget {
  const HermeticaInAppHost({super.key, this.client, this.builder, this.onAction, this.fetchOnMount = true, required this.child});

  /// Defaults to [Hermetica.instance].
  final Hermetica? client;
  final InAppMessageBuilder? builder;
  final InAppActionHandler? onAction;
  final bool fetchOnMount;
  final Widget child;

  @override
  State<HermeticaInAppHost> createState() => _HostState();
}

class _HostState extends State<HermeticaInAppHost> {
  final _queue = <InAppMessage>[];
  final _seen = <String>{};
  StreamSubscription<InAppTrigger>? _sub;

  Hermetica get _client => widget.client ?? Hermetica.instance;

  @override
  void initState() {
    super.initState();
    _sub = _client.triggers.listen(_run);
    if (widget.fetchOnMount) unawaited(_run(const InAppTrigger.appOpen()));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _run(InAppTrigger t) async {
    final items = await _client.fetchInAppMessages(t);
    if (!mounted || items.isEmpty || !_seen.add(items.first.id)) return;
    setState(() => _queue.add(items.first));
    if (_queue.length == 1) _impress();
  }

  void _impress() => unawaited(_client.reportInAppEvent(_queue.first, 'impression'));

  InAppMessage _next() {
    final m = _queue.first;
    setState(() => _queue.removeAt(0));
    if (_queue.isNotEmpty) _impress();
    return m;
  }

  void _dismiss() {
    if (_queue.isEmpty) return;
    unawaited(_client.reportInAppEvent(_queue.first, 'dismiss'));
    _next();
  }

  void _button(InAppButton b) {
    if (_queue.isEmpty) return;
    unawaited(_client.reportInAppEvent(_queue.first, 'click', button: b.label));
    final m = _next();
    final v = b.value;
    if (b.action == 'dismiss' || v == null || v.isEmpty) return;
    if (widget.onAction?.call(b.action, v, m) ?? false) return;
    if (b.action == 'event') {
      _client.track(v, properties: {'hermetica_message_id': m.id});
    } else {
      _client.onDeepLink?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _queue.isEmpty ? null : _queue.first;
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      if (m != null) _place(m, widget.builder?.call(context, m, _button, _dismiss) ?? _Card(message: m, onButton: _button, onDismiss: _dismiss)),
    ]);
  }

  // shortcut: the Android back button does not close a message (the host sits above the Navigator); add a PopScope route if needed.
  Widget _place(InAppMessage m, Widget card) {
    final align = switch (m.layout) {
      'banner_top' => Alignment.topCenter,
      'banner_bottom' || 'bottom_sheet' => Alignment.bottomCenter,
      _ => Alignment.center,
    };
    final placed = SafeArea(
      key: ValueKey(m.id),
      child: Align(alignment: align, child: m.layout == 'fullscreen' ? SizedBox.expand(child: card) : card),
    );
    // Banners leave the app usable; the other layouts dim and block it. The transparent Material lets custom builders
    // use Material widgets: the host sits above the Navigator, outside any Scaffold.
    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: m.layout.startsWith('banner') ? placed : ColoredBox(color: const Color(0x80000000), child: placed),
      ),
    );
  }
}

/// CSS hex (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`) to a Color; [fallback] when it does not parse.
Color hexColor(String hex, Color fallback) {
  var h = hex.startsWith('#') ? hex.substring(1) : hex;
  if (h.length == 3 || h.length == 4) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 6) h = '${h}ff';
  final v = h.length == 8 ? int.tryParse(h, radix: 16) : null;
  if (v == null) return fallback;
  return Color(((v & 0xff) << 24) | (v >> 8)); // rrggbbaa -> aarrggbb
}

class _Card extends StatelessWidget {
  const _Card({required this.message, required this.onButton, required this.onDismiss});

  final InAppMessage message;
  final void Function(InAppButton) onButton;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = message.style;
    final fg = hexColor(s.textColor, const Color(0xff111111));
    final radius = switch (message.layout) {
      'modal' => BorderRadius.circular(s.radius),
      'bottom_sheet' => BorderRadius.vertical(top: Radius.circular(s.radius)),
      _ => BorderRadius.zero,
    };
    final card = Material(
      color: hexColor(s.background, const Color(0xffffffff)),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, s.dismissible ? 32 : 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final b in message.blocks) _block(b, fg)],
          ),
        ),
        if (s.dismissible)
          Positioned(
            top: 4,
            right: 4,
            child: Semantics(
              button: true,
              label: 'Close',
              child: InkWell(onTap: onDismiss, child: Padding(padding: const EdgeInsets.all(8), child: Text('×', style: TextStyle(color: fg, fontSize: 20)))),
            ),
          ),
      ]),
    );
    if (message.layout != 'modal') return card;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: card),
    );
  }

  Widget _block(InAppBlock b, Color fg) {
    final s = message.style;
    switch (b.type) {
      case 'heading':
        return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(b.text ?? '', style: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w700)));
      case 'text':
        return Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(b.text ?? '', style: TextStyle(color: fg, fontSize: 16)));
      case 'image':
        final url = b.url;
        if (url == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(min(s.radius, 12.0)),
            child: Image.network(url, height: 160, fit: BoxFit.cover, semanticLabel: b.alt, errorBuilder: (context, error, stack) => const SizedBox.shrink()),
          ),
        );
      case 'buttons':
        return Wrap(spacing: 8, runSpacing: 8, children: [for (final x in b.buttons) _button(x)]);
      default:
        return const SizedBox.shrink(); // a block type this SDK version does not know
    }
  }

  Widget _button(InAppButton x) {
    final s = message.style;
    final accent = hexColor(s.accentColor, const Color(0xff2563eb));
    final primary = x.style != 'secondary';
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(min(s.radius, 10.0)), side: BorderSide(color: accent));
    return Semantics(
      button: true,
      child: Material(
        color: primary ? accent : Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: () => onButton(x),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            child: Text(x.label, style: TextStyle(color: primary ? const Color(0xffffffff) : accent, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
