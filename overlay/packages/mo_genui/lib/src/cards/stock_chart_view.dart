import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/preferences.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The app's own price chart (the same web chart the classic Charts screen
/// loads), embedded inside a card. Contract copied from the classic
/// `ChartController`: load the chart page, wait for its `PageReady` message on
/// the `ChartAppDelegate` channel, then `ChartApp.v1.authorize(token)` and
/// `ChartApp.v1.loadChart('<exchange>:<scripCode>', 'LightWeightChart', theme, true)`.
class StockChartView extends StatefulWidget {
  const StockChartView({super.key, required this.scrip, this.height = 320});
  final ScripId scrip;
  final double height;

  @override
  State<StockChartView> createState() => _StockChartViewState();
}

class _StockChartViewState extends State<StockChartView> {
  late final WebViewController _web;
  String _status = 'Loading chart…';
  bool _loaded = false;
  Timer? _fallback;

  String get _symbol => '${widget.scrip.exchange.value}:${widget.scrip.scripCode}';

  String _url(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    var url = Preferences.getChartBaseUrl();
    if (url.isEmpty) return '';
    final theme = dark ? 'dark' : 'light';
    if (url.contains('{theme}')) return url.replaceAll('{theme}', theme);
    if (url.contains('theme=')) return url.replaceAll(RegExp(r'theme=(dark|light)'), 'theme=$theme');
    return '$url${url.contains('?') ? '&' : '?'}theme=$theme';
  }

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('ChartAppDelegate', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          // If the page never announces PageReady, try once after a short wait.
          _fallback ??= Timer(const Duration(seconds: 4), () {
            if (!_loaded) _load();
          });
        },
        onWebResourceError: (e) {
          if (mounted) setState(() => _status = 'Chart page error: ${e.description}');
        },
        onHttpError: (e) {
          final code = e.response?.statusCode ?? 0;
          if (code >= 500 && mounted) setState(() => _status = 'The chart server (UAT) returned HTTP $code, so the chart cannot load right now. Returns and technicals still work.');
        },
      ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final url = _url(context);
      if (url.isEmpty) {
        setState(() => _status = 'No chart URL configured for this build.');
        return;
      }
      _web.loadRequest(Uri.parse(url));
    });
  }

  @override
  void dispose() {
    _fallback?.cancel();
    super.dispose();
  }

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      final ctx = '${j['context'] ?? ''}';
      if (ctx == 'PageReady') _load();
      if (j['error'] != null && mounted) setState(() => _status = 'Chart: ${j['error']}');
    } catch (_) {}
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final dark = mounted && Theme.of(context).brightness == Brightness.dark;
    final token = Preferences.getAccessToken();
    try {
      await _web.runJavaScript("ChartApp.v1.authorize('$token')");
      await _web.runJavaScript("ChartApp.v1.loadChart('$_symbol', 'LightWeightChart', '${dark ? 'dark' : 'light'}', true)");
      if (mounted) setState(() => _status = '');
    } catch (e) {
      if (mounted) setState(() => _status = 'Chart script error: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        if (_status.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: Text(_status, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
        ClipRRect(
          borderRadius: BorderRadius.circular(MOSpacing.spacing8),
          child: SizedBox(height: widget.height, child: WebViewWidget(controller: _web)),
        ),
        Text('Same chart as the classic Charts screen. Pinch to zoom, drag to pan.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
      ]);
}
