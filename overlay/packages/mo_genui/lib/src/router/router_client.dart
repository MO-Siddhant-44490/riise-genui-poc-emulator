import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:mo_genui/src/catalog/catalog.dart';
import 'package:mo_genui/src/config.dart';
import 'package:mo_genui/src/router/intent_memory.dart';

export 'package:mo_genui/src/router/intent_memory.dart' show PlanCard;

/// The LLM's only job: pick one catalog action and fill its documented params.
class RouterDecision {
  const RouterDecision({
    required this.action,
    required this.confidence,
    this.reply = '',
    this.params = const <String, dynamic>{},
    this.latencyMs = 0,
    this.router = '',
    this.intent = '',
    this.plan,
    this.title = '',
  });

  /// A plan of several cards (composed answers). Then [action] is [planAction].
  static const String planAction = 'plan';

  final String action;

  /// Canonical intent slug the model (or memory) assigned, e.g. `portfolio.stocks`.
  final String intent;
  final List<PlanCard>? plan;
  final String title;
  bool get isPlan => plan != null && plan!.isNotEmpty;
  final double confidence;

  /// One short sentence for the user (used mostly for `unsupported`).
  final String reply;

  /// Parameters as the LLM wrote them (e.g. stock name as typed). Our code
  /// validates and resolves them before anything is shown.
  final Map<String, dynamic> params;
  final int latencyMs;
  final String router;

  bool get isSupported => action != GenUiCatalog.unsupported;

  RouterDecision copyWith({String? action, Map<String, dynamic>? params, String? reply, String? router, int? latencyMs}) => RouterDecision(
        action: action ?? this.action,
        confidence: confidence,
        reply: reply ?? this.reply,
        params: params ?? this.params,
        latencyMs: latencyMs ?? this.latencyMs,
        router: router ?? this.router,
        intent: intent,
        plan: plan,
        title: title,
      );

  @override
  String toString() => 'RouterDecision($action ${(confidence * 100).round()}% $params via $router ${latencyMs}ms)';
}

class RouterClient {
  RouterClient({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 20)));

  final Dio _dio;

  static String get _systemPrompt {
    final actions = GenUiCatalog.items.values.map((c) {
      final views = c.views.length > 1 ? ' "view": one of ${c.views.map((v) => '"$v"').join('|')} (pick from the wording, else omit).' : '';
      final params = c.params.isEmpty ? '' : ' params: ${c.params}.';
      final wide = c.narrow ? '' : ' (wide table: size M only)';
      return '- ${c.id}: ${c.description}.$params$views$wide';
    }).join('\n');
    final known = IntentMemory.intents;
    final knownLine = known.isEmpty ? '' : '\nKnown intents (reuse one when it fits): ${known.take(120).join(', ')}.';
    return '''
You route questions in an Indian stock-broking app. Questions may be English, Hindi or Hinglish.
Choose exactly one action from this list and fill only its documented params:
$actions
- ${GenUiCatalog.unsupported}: anything else, or anything you are not sure about.

Rules:
- Copy names exactly as the user wrote them; never invent symbols, codes or numbers. Do not answer the question yourself.
- For order: only extract what the user said; never invent a quantity or price. If the user asks about buying or selling without naming a stock, use ${GenUiCatalog.unsupported}. "<stock> buy", "buy <stock>", "<stock> kharido" with a company name IS an order (side from the word, no quantity needed) with high confidence; only a buy/sell with no stock named is unsupported.
- For ${GenUiCatalog.unsupported}, "reply" must say, in the user's language, that this is not available in the AI view yet and name two things that are (for example portfolio, market, a stock, watchlist). Never ask the user for more details and never offer advice.
- "Add money / add funds / withdraw money / withdraw rupees" with no fund named is the funds action (trading-account money), even right after a mutual fund answer. Redeem / sell units of a fund is mf_action.
- SIP, lumpsum, NAV, scheme, fund, flexi cap, mid cap, small cap, ELSS, index fund: these are mutual fund words. "Start a SIP in X" or "invest in X fund" is the fund action with mode sip or lumpsum; "my SIPs" is mf_sips. Use stock_sip only when the user literally says stock SIP or share SIP. A category alone ("a small cap fund", "some flexi cap scheme", "an index fund") with no scheme name is find_funds with that category as query, never fund.
- An index by name with no option/future/OI words ("Nifty 50 today", "how is Sensex", "stocks in Bank Nifty", "Nifty IT constituents") is index. "How is Nifty looking" with support/resistance/PCR/VIX words stays fno_pulse.
- Derivatives: option chain / strike / CE / PE / call / put / OI / max pain / greeks is option_chain; "buy a Nifty 24000 call" or any option or future trade is option_chain or futures (never order, which is for shares). VIX, PCR, support, resistance, "how is Nifty looking" is fno_pulse. "<index> OI", "open interest of Nifty", "OI chart", "OI by strike" is option_chain with view oi for that underlying; only "OI gainers", "OI losers", "OI buildup", "most active contracts", "options in momentum" is fno_movers. MTM or F&O/option/futures positions is fno_positions. Spread, straddle, strangle, condor, "bullish/bearish strategy" is fno_strategies. Futures price, basis, premium/discount, rollover is futures. Nifty, Bank Nifty, Fin Nifty, Midcap Nifty, Sensex are indices, not stocks.
- Portfolio depth: "net worth / total wealth / other brokers / family" is networth; "what moved / dragging / my gainers today" is day_movers; dividend, bonus, split, record date is dividends; "too risky / diversified / concentration / overlap" is portfolio_risk; "tax / capital gains / save tax" is tax; non-tradable, delisted, suspended is nontradable; gold, silver, crude, MCX positions is commodity_positions. Plain "my portfolio" or "my stocks" stays portfolio.
- Research: "recommendations / what to buy / trading calls / intraday calls / tips" is research_calls (not stock, not best); "research report on <company> / target price / what does research say about <company>" is stock_research; "research reports / market outlook / sector report" is research_reports; "ready-made portfolio / research basket / model portfolio" is ready_portfolios; "research experts / analysts" is research_experts; "option brain / trading guide signals" is option_brain; any other open research question ("research snapshot of X", "summarise research on IT sector", "is it a good time to buy banks") is research_assistant with the full question.
- AI-native: "what if the market / <stock> falls X%" is what_if with shock as a signed number. Nifty, Sensex, Bank Nifty or "the market" in a what-if means the whole market: omit "stock". "Am I beating the market", "my portfolio vs Nifty" is pf_vs_market; "<stock> vs Nifty / against the market" is stock_vs_index; "compare <stock> and <stock>", "<stock> vs <stock>" is stock_compare with "stocks" as a list (never stock_vs_index unless one side is an index). "What is <term>", "explain <term>", "<term> kya hota hai" is explain with the term (and "stock" if named), not stock and not research_assistant. But "my XIRR", "my returns", "how much have I made" ask for the user's own number: that is pf_vs_market, not explain. "Rebalance", "what should I trim", "too concentrated" is rebalance. "How much to invest monthly for X in N years", "what will ₹X a month become", "plan for retirement/car/house" is goal with target in rupees (1 lakh = 100000, 1 crore = 10000000). "What is coming up / due / my calendar" is upcoming. "Did any SIP fail / missed SIP" is failed_sips. "Morning brief / my day" is a plan (market, news scope portfolio, portfolio, research_calls).
- Alerts: "alert me when <stock> crosses/falls below <price>" is price_alert (condition above|below, price as a number). A rule on a group ("any of my bank stocks", "my holdings", several named stocks) with a percentage is smart_alert; if the same message also prepares an order on one stock ("if HDFC Bank goes below 1850, get a buy order ready for 5"), put that in smart_alert\'s order_stock / order_price / order_condition / action / qty. "Email/tell me when <stock> posts results" is results_alert. "Mail me research reports on <stocks>" is report_sub. "My alerts" is alerts. Never use order for an alert.
- A "Previous answer" line may be given. If the new message only changes how that answer is shown (e.g. "as a graph", "graph mai", "list me dikhao", "table"), return the previous action with the same params and the new view. If it asks a follow-up about the same stock without naming it, reuse that stock.
- "intent": a short dotted lowercase slug naming what the user wants, independent of wording, language, names and numbers (portfolio.stocks, market.gainers, stock.overview, fund.invest, fno.option_chain). The same intent must come out for "show my stocks", "my holdings" and "mere stocks dikhao".$knownLine
- If the message asks for two or more different things at once (joined by "and", commas, "along with", "plus"), or asks for an overview, dashboard, brief, "everything about", "my day", "what should I know": reply with a plan of 2 to 4 cards instead of one action: {"intent": "<slug>", "title": "<3-5 word title>", "summary": "<one sentence>", "plan": [{"action": "<id>", "params": {...}, "size": "S"|"M"}, ...], "confidence": <0-1>}. Size S for two small cards that sit side by side (market, index, movers, watchlist, news, fno_pulse); M for lists and tables and for any action marked wide. Never a plan for a single thing, and never the same action twice with the same params.
Reply with JSON only, no prose:
{"action": "<id>", "intent": "<slug>", "confidence": <0-1>, "params": {<documented params only>}, "reply": "<one short sentence for the user>"}''';
  }

  Future<RouterDecision> route(String question, {RouterDecision? previous}) async {
    final q = question.trim();
    if (q.isEmpty) return const RouterDecision(action: GenUiCatalog.unsupported, confidence: 1, reply: 'Ask me something.');
    final quick = _quickOrder(q);
    if (quick != null) return quick;
    if (!GenUiConfig.hasLlm) return _offline(q, previous);
    final sw = Stopwatch()..start();
    try {
      final message = _withContext(q, previous);
      var text = GenUiConfig.aiServiceUrl.isNotEmpty ? await _viaService(message) : await _viaBedrock(message);
      if (!RegExp(r'\{[\s\S]*\}').hasMatch(text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), ''))) {
        // The model occasionally answers with prose or an unterminated think block; ask once more.
        debugPrint('GenUI router: no JSON in reply, retrying. Raw: ${text.length > 400 ? text.substring(0, 400) : text}');
        text = GenUiConfig.aiServiceUrl.isNotEmpty ? await _viaService('$message\nReply with the JSON object only.') : await _viaBedrock('$message\nReply with the JSON object only.');
      }
      sw.stop();
      final d = _parse(text, sw.elapsedMilliseconds, GenUiConfig.routerName);
      // Observability (debug builds): the model's raw answer and what we made of it.
      final shown = text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
      debugPrint('GenUI router raw [${sw.elapsedMilliseconds} ms]: ${shown.length > 700 ? shown.substring(0, 700) : shown}');
      debugPrint('GenUI router decision: $d intent=${d.intent}${d.isPlan ? ' plan=${d.plan!.map((c) => '${c.action}${c.params.isEmpty ? '' : c.params}/${c.size}').join(',')}' : ''}');
      return d;
    } catch (e, st) {
      sw.stop();
      debugPrint('GenUI router error: $e\n$st');
      final fallback = _offline(q, previous);
      return RouterDecision(
        action: fallback.action,
        confidence: fallback.confidence,
        reply: fallback.reply,
        params: fallback.params,
        latencyMs: sw.elapsedMilliseconds,
        router: 'offline rules (LLM error: ${e.runtimeType})',
      );
    }
  }

  static String _withContext(String q, RouterDecision? previous) {
    if (previous == null || !previous.isSupported) return q;
    // Resolved objects (ScripRef, FundRef, lists of them) are not JSON; describe them as text.
    final shown = <String, dynamic>{};
    previous.params.forEach((k, v) {
      if (k == 'scrip' || k == 'fund' || k == 'fundRefs') return;
      shown[k] = v is num || v is bool || v is String || v == null ? v : (v is List ? v.map((e) => '$e').toList() : '$v');
    });
    return 'Previous answer: action=${previous.action} params=${jsonEncode(shown)}\nMessage: $q';
  }

  /// Direct Bedrock Converse call with the short-term bearer key (dev only).
  Future<String> _viaBedrock(String message) async {
    final url = 'https://bedrock-runtime.${GenUiConfig.region}.amazonaws.com/model/${Uri.encodeComponent(GenUiConfig.model)}/converse';
    final res = await _dio.post<Map<String, dynamic>>(
      url,
      options: Options(headers: <String, String>{
        'Authorization': 'Bearer ${GenUiConfig.bedrockKey}',
        'Content-Type': 'application/json',
      }),
      data: <String, dynamic>{
        'system': <Map<String, String>>[
          {'text': _systemPrompt}
        ],
        'messages': <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': <Map<String, String>>[
              {'text': message}
            ]
          },
        ],
        'inferenceConfig': <String, dynamic>{'maxTokens': 700},
      },
    );
    final content = (res.data?['output']?['message']?['content'] as List<dynamic>?) ?? const <dynamic>[];
    return content.map((c) => (c as Map<String, dynamic>)['text'] ?? '').join();
  }

  /// The router service (Lambda Function URL): it calls Bedrock with its own execution role, so
  /// the app holds no AWS credential and nothing expires. Same reply contract as the direct call.
  Future<String> _viaService(String message) async {
    final res = await _dio.post<dynamic>(
      GenUiConfig.aiServiceUrl,
      options: Options(headers: <String, String>{'x-genui-token': GenUiConfig.aiToken, 'Content-Type': 'application/json'}),
      data: <String, dynamic>{'system': _systemPrompt, 'message': message, 'model': GenUiConfig.model},
    );
    final data = res.data;
    if (data is Map && data['text'] is String) return data['text'] as String;
    if (data is String) {
      try {
        final j = jsonDecode(data);
        if (j is Map && j['text'] is String) return j['text'] as String;
      } catch (_) {}
      return data;
    }
    return jsonEncode(data);
  }

  RouterDecision _parse(String raw, int ms, String router) {
    final text = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    Map<String, dynamic>? json;
    if (match != null) {
      try {
        json = jsonDecode(match.group(0)!) as Map<String, dynamic>;
      } catch (_) {
        json = null;
      }
    }
    if (json == null) {
      debugPrint('GenUI router: unparsable reply: ${raw.length > 400 ? raw.substring(0, 400) : raw}');
      return RouterDecision(action: GenUiCatalog.unsupported, confidence: 0, reply: "I couldn't work that out.", latencyMs: ms, router: router);
    }
    var action = (json['action'] ?? '').toString().trim();
    // A reply that names a catalog action but omits "confidence" (seen on retries) is taken as 0.7,
    // not 0, so a usable answer is not thrown away.
    final confidence = ((json['confidence'] as num?) ?? (GenUiCatalog.items.containsKey(action) && action != GenUiCatalog.unsupported ? 0.7 : 0)).toDouble().clamp(0, 1).toDouble();
    final intent = (json['intent'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9._]'), '');
    // A plan: several catalog cards. Only catalog actions survive, 2..4 of them, params as documented.
    if (json['plan'] is List && confidence >= 0.5) {
      final cards = <PlanCard>[];
      for (final c in json['plan'] as List) {
        if (c is! Map) continue;
        final a = '${c['action'] ?? ''}'.trim();
        if (!GenUiCatalog.items.containsKey(a) || a == GenUiCatalog.unsupported) continue;
        final p = <String, dynamic>{};
        if (c['params'] is Map) p.addAll(Map<String, dynamic>.from(c['params'] as Map));
        p.removeWhere((_, v) => v == null || (v is String && v.trim().isEmpty));
        if (p['view'] is String) p['view'] = (p['view'] as String).toLowerCase();
        final size = c['size'] == 'S' && GenUiCatalog.halfOk(a) ? 'S' : 'M';
        if (cards.any((x) => x.action == a && mapEquals(x.params, p))) continue;
        cards.add(PlanCard(action: a, params: p, size: size));
      }
      if (cards.length >= 2) {
        return RouterDecision(
            action: RouterDecision.planAction,
            confidence: confidence,
            reply: (json['summary'] ?? json['reply'] ?? '').toString(),
            latencyMs: ms,
            router: router,
            intent: intent,
            plan: cards.take(4).toList(),
            title: (json['title'] ?? '').toString());
      }
      if (cards.length == 1) action = cards.first.action;
    }
    // Guard rail: only catalog actions are ever executed, and only with enough confidence.
    if (!GenUiCatalog.items.containsKey(action) || confidence < 0.5) action = GenUiCatalog.unsupported;
    final params = <String, dynamic>{};
    final nested = json['params'];
    if (nested is Map) params.addAll(Map<String, dynamic>.from(nested));
    json.forEach((k, v) {
      if (!const <String>{'action', 'confidence', 'reply', 'params', 'intent', 'plan', 'title', 'summary'}.contains(k) && v != null) params[k] = v;
    });
    params.removeWhere((_, v) => v == null || (v is String && v.trim().isEmpty));
    if (params['view'] is String) params['view'] = (params['view'] as String).toLowerCase();
    return RouterDecision(
      action: action,
      confidence: confidence,
      reply: (json['reply'] ?? '').toString(),
      params: params,
      latencyMs: ms,
      router: router,
      intent: intent,
    );
  }

  /// "HDFC buy", "buy 10 tcs", "reliance kharido": a plain share order needs no model. The model
  /// wavered on these (0.8 one run, 0.5 the next, below which the ticket is withheld), so they are
  /// matched here deterministically. Anything with derivative, fund, alert or conditional words
  /// still goes to the model.
  static RouterDecision? _quickOrder(String q) {
    final l = q.toLowerCase().trim();
    if (l.split(RegExp(r'\s+')).length > 6) return null;
    if (RegExp(
            r'\b(option|options|call|put|ce|pe|strike|future|futures|fut|sip|fund|funds|scheme|mf|alert|when|if|agar|jab|nifty|sensex|mtf|basket|ipo|gold|silver|crude|all|everything|position|positions|holding|holdings)\b')
        .hasMatch(l)) return null;
    const buyWords = <String>{'buy', 'purchase', 'kharido', 'kharid', 'lelo', 'le', 'lo'};
    const sellWords = <String>{'sell', 'becho', 'bech', 'bechdo'};
    final lead = RegExp(
            r'^(buy|purchase|sell|kharido|becho)\s+(?:me\s+)?(\d+)?\s*(?:shares?\s+of\s+|stocks?\s+of\s+|units?\s+of\s+|of\s+)?([a-z0-9&.\- ]+?)(?:\s+(?:shares?|stocks?|ka\s+share|ke\s+share))?\s*$')
        .firstMatch(l);
    final trail = RegExp(r'^([a-z0-9&.\- ]+?)\s+(?:ke\s+|ka\s+|ki\s+)?(\d+)?\s*(?:shares?\s+|stocks?\s+)?(buy|sell|kharido|kharid lo|becho|bech do|le lo|lelo)\s*$').firstMatch(l);
    String? stock;
    String? side;
    String? qty;
    if (lead != null) {
      side = buyWords.contains(lead.group(1)) ? 'buy' : (sellWords.contains(lead.group(1)) ? 'sell' : null);
      qty = lead.group(2);
      stock = lead.group(3);
    } else if (trail != null) {
      final w = trail.group(3)!.split(' ').first;
      side = buyWords.contains(w) ? 'buy' : (sellWords.contains(w) ? 'sell' : null);
      qty = trail.group(2);
      stock = trail.group(1);
    }
    if (stock == null || side == null) return null;
    stock = stock.trim();
    if (stock.isEmpty || stock.split(' ').length > 4 || RegExp(r'^\d+$').hasMatch(stock)) return null;
    // Keep the user's own casing for the search query.
    final original = RegExp(RegExp.escape(stock), caseSensitive: false).firstMatch(q)?.group(0) ?? stock;
    return RouterDecision(
      action: 'order',
      confidence: 1,
      params: <String, dynamic>{'stock': original, 'side': side, if (qty != null) 'qty': int.tryParse(qty)},
      router: 'rules',
      intent: 'order.$side',
    );
  }

  /// A decision built from the intent memory: no model call.
  static RouterDecision fromMemory(IntentEntry e, int ms) => e.isPlan
      ? RouterDecision(action: RouterDecision.planAction, confidence: 1, reply: e.summary, latencyMs: ms, router: 'memory · ${e.source}', intent: e.intent, plan: e.plan, title: e.title)
      : RouterDecision(action: e.action, confidence: 1, params: Map<String, dynamic>.from(e.params), latencyMs: ms, router: 'memory · ${e.source}', intent: e.intent);

  /// Keyword rules used when no LLM is configured (release builds, or no key).
  RouterDecision _offline(String q, RouterDecision? previous) {
    final l = q.toLowerCase();
    const viewWords = <String, String>{'graph': 'chart', 'chart': 'chart', 'bars': 'bars', 'list': 'list', 'table': 'table', 'tiles': 'tiles', 'strip': 'strip'};
    String? askedView;
    viewWords.forEach((w, v) {
      if (l.contains(w)) askedView = v;
    });
    // Pure view change on the previous answer.
    if (previous != null && previous.isSupported && askedView != null && l.split(' ').length <= 4) {
      final item = GenUiCatalog.items[previous.action]!;
      final v = item.views.contains(askedView) ? askedView : (item.views.contains('chart') ? 'chart' : item.views.firstOrNull);
      return RouterDecision(action: previous.action, confidence: 0.6, params: <String, dynamic>{...previous.params, if (v != null) 'view': v}, router: 'offline rules');
    }
    for (final item in GenUiCatalog.items.values) {
      if (item.keywords.any(l.contains)) {
        final params = <String, dynamic>{};
        for (final v in item.views) {
          if (l.contains(v)) params['view'] = v;
        }
        if (askedView != null && item.views.contains(askedView)) params['view'] = askedView;
        return RouterDecision(action: item.id, confidence: 0.6, reply: item.title, params: params, router: 'offline rules');
      }
    }
    return const RouterDecision(
      action: GenUiCatalog.unsupported,
      confidence: 0.6,
      reply: "I can't do that yet. Try: show my portfolio.",
      router: 'offline rules',
    );
  }
}
