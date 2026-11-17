import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';

import 'package:mo_genui/src/a2ui/messages.dart';
import 'package:mo_genui/src/catalog/catalog.dart';
import 'package:mo_genui/src/config.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/entities/search_stock_resolver.dart';
import 'package:mo_genui/src/entities/stock_resolver.dart';
import 'package:mo_research/data/mo_research_explore_repository_impl.dart';
import 'package:mo_portfolio_2_0/data/mo_portfolio_dashboard_repository_impl.dart';
import 'package:mo_genui/src/ui/alert_store.dart';
import 'package:mo_genui/src/ui/board.dart';
import 'package:mo_genui/src/ui/board_picker.dart';
import 'package:mo_genui/src/ui/card_frame.dart' show ChipStrip;
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_genui/src/router/intent_memory.dart';
import 'package:mo_genui/src/router/router_client.dart';

/// The AI view: a chat box whose answers are live widgets from the catalog.
class GenUiScreen extends StatefulWidget {
  const GenUiScreen({super.key});

  @override
  State<GenUiScreen> createState() => _GenUiScreenState();
}

class _Turn {
  _Turn(this.question);
  final String question;
  final GlobalKey key = GlobalKey();
  RouterDecision? decision;
  A2uiMessage? surface;

  /// True for a card the AI view raised on its own (an alert), drawn on the left.
  bool system = false;

  /// A composed answer (plan): several cards with their sizes.
  List<_PlanSurface> surfaces = <_PlanSurface>[];
  String title = '';

  /// Set when the stock could not be resolved: "did you mean" candidates.
  List<ScripRef> suggestions = const <ScripRef>[];
  List<FundRef> fundSuggestions = const <FundRef>[];
  String note = '';
  bool get pending => decision == null;
}

class _PlanSurface {
  const _PlanSurface(this.msg, this.size);
  final A2uiMessage msg;
  final String size;
}

class _GenUiScreenState extends State<GenUiScreen> {
  final RouterClient _router = RouterClient();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_Turn> _turns = <_Turn>[];
  int _surfaces = 0;
  // Pins outlive the session, so surface ids carry a per-launch token or a new card could reuse a pinned id.
  static final String _launch = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  String _mode = 'chat'; // chat | board
  RouterDecision? _last; // last supported answer, for follow-ups like "graph mai"
  ScripRef? _lastScrip;
  FundRef? _lastFund;
  List<FundRef> _fundSuggestions = const <FundRef>[];

  static const List<String> _quickAsks = <String>[
    'Show my portfolio',
    'How is the market today?',
    'Tell me about HDFC Bank',
    'Top gainers as a chart',
    'Show my watchlist',
    'My funds',
    'Best performing stocks this year',
    'Market news',
    'Cancel my pending orders',
    'Best small cap funds',
    'Tell me about Parag Parikh Flexi Cap',
    'How are my mutual funds doing?',
    'My pending orders',
    'Nifty option chain',
    'Bank Nifty OI as a chart',
    'Most active options',
    'My F&O positions',
    'Bullish option strategies',
    'Nifty futures',
    'How is Nifty looking?',
    'Show my board',
    'Show my portfolio and market today side by side',
    'What is my net worth?',
    'Any stock recommendations?',
    'Intraday trading calls',
    'Research report on Tata Motors',
    'Market outlook today',
    'Research snapshot of HDFC Bank',
    'What is dragging my portfolio today?',
    'Any dividends coming?',
    'Is my portfolio too risky?',
    'How much tax will I pay this year?',
    'Alert me when Yes Bank crosses ₹22',
    'Alert me if any of my bank stocks falls 5% in a day',
    'Email me when HDFC Bank posts results',
    'Mail me research reports on Infosys and TCS',
    'Show my alerts',
    'What if the market falls 10%?',
    'Am I beating the market?',
    'Compare TCS and Infosys',
    'HDFC Bank vs Nifty',
    'What is P/E?',
    'How should I rebalance?',
    'I want 50 lakh in 10 years',
    'What is coming up?',
    'Did any SIP fail?',
    'मेरा पोर्टफोलियो कैसा है?',
  ];

  @override
  void initState() {
    super.initState();
    debugPrint('GenUI: screen opened');
    _registerNav();
    IntentMemory.load();
    AlertEngine.start();
    AlertEngine.fired.addListener(_onAlertFired);
    GenUiBoard.load().then((_) {
      if (mounted && GenUiBoard.boards.value.any((b) => b.items.isNotEmpty) && _turns.isEmpty) setState(() => _mode = 'board');
    });
    // Entity resolution goes through the app's real search, never the LLM.
    StockResolver.instance ??= SearchStockResolver();
  }

  /// A tapped row opens its card directly: our code picks the component, the
  /// router is not consulted. Mirrors the classic app's tap-through.
  void _openDirect(String question, String component, Map<String, dynamic> data, {bool system = false, String? note}) {
    final turn = _Turn(question)..system = system;
    final decision = RouterDecision(action: component, confidence: 1, params: data, router: system ? 'alert' : 'tap');
    turn.decision = decision;
    turn.surface = A2uiMessage.createSurface(surfaceId: 's${_launch}_${++_surfaces}', component: component, data: data);
    turn.note = note ?? 'Opened from the previous card';
    setState(() {
      _mode = 'chat';
      _turns.add(turn);
      _last = decision;
      if (data['scrip'] is ScripRef) _lastScrip = data['scrip'] as ScripRef;
      if (data['fund'] is FundRef) _lastFund = data['fund'] as FundRef;
    });
    _scrollToEnd();
  }

  void _registerNav() {
    GenUiNav.onStock = (ref, {view}) => _openDirect('Tell me about ${ref.symbol}', 'stock', <String, dynamic>{'scrip': ref, if (view != null) 'view': view});
    GenUiNav.onFund = (ref) => _openDirect('Tell me about ${ref.shortName}', 'fund', <String, dynamic>{'fund': ref});
    GenUiNav.onIndex = (indexId, exchangeCode, name) => _openDirect(name, 'index', <String, dynamic>{'indexId': indexId, 'exchangeCode': exchangeCode, 'name': name});
    GenUiNav.onAsk = _ask;
  }

  void _flash(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));

  void _pinTurn(_Turn t, {String size = 'M'}) {
    for (final ps in t.surfaces) {
      final it = GenUiCatalog.items[ps.msg.component];
      GenUiBoard.pin(BoardItem(id: ps.msg.surfaceId, title: it?.title ?? ps.msg.component, component: ps.msg.component, data: ps.msg.data, question: t.question, size: ps.size));
    }
    final s = t.surface;
    if (s == null) return;
    final item = GenUiCatalog.items[s.component];
    GenUiBoard.pin(BoardItem(id: s.surfaceId, title: item?.title ?? s.component, component: s.component, data: s.data, question: t.question, size: size));
  }

  /// Board management by chat: create, open, rename, delete a board; pin or move a card to one.
  Future<bool> _boardCommand(String raw) async {
    // Matched case-insensitively on the text as typed, so a board name keeps its casing ("F&O").
    final s = raw.trim();
    final lc = s.toLowerCase();
    final create = RegExp(r'^(?:create|make|add|new|start)\b(?: a| me a| another| new)*\s*(?:board|dashboard)\b(?:\s+(?:called|named|for|about))?\s*(.*)$', caseSensitive: false).firstMatch(s);
    if (create != null) {
      if (!GenUiBoard.canCreate) {
        _flash('You already have $kMaxBoards boards, the most this version allows. Delete one to make room.');
        return true;
      }
      var name = create.group(1)!.trim().replaceAll(RegExp('^["\']|["\']\$'), '');
      if (name.isEmpty) name = (await askBoardName(context, title: 'New board'))?.trim() ?? '';
      if (name.isEmpty) return true;
      final b = GenUiBoard.create(name);
      if (b != null) {
        setState(() => _mode = 'board');
        _flash('Created ${b.name}. Pin answers to it with the pin icon or "pin this to ${b.name}".');
      }
      return true;
    }
    final rename = RegExp(r'^(?:rename|call)\b\s+(?:my |the |this )?(.*?)\s*(?:board|dashboard)?\s+(?:to|as)\s+(.+)$', caseSensitive: false).firstMatch(s);
    if (rename != null && lc.contains('board')) {
      final b = GenUiBoard.findBoard(rename.group(1)!) ?? GenUiBoard.active;
      GenUiBoard.rename(b.id, rename.group(2)!.replaceAll(RegExp('^["\']|["\']\$'), ''));
      _flash('Renamed to ${GenUiBoard.byBoardId(b.id)?.name}.');
      return true;
    }
    final del = RegExp(r'^(?:delete|remove|drop)\b\s+(?:my |the |this )?(.*?)\s*(?:board|dashboard)$', caseSensitive: false).firstMatch(s);
    if (del != null) {
      final b = del.group(1)!.trim().isEmpty ? GenUiBoard.active : GenUiBoard.findBoard(del.group(1)!);
      if (b == null) {
        _flash('No board called "${del.group(1)}". Your boards: ${GenUiBoard.boards.value.map((b) => b.name).join(', ')}.');
        return true;
      }
      GenUiBoard.delete(b.id);
      _flash(GenUiBoard.boards.value.length == 1 && GenUiBoard.boards.value.first.id == b.id ? '${b.name} emptied (it is your only board).' : 'Deleted ${b.name}.');
      return true;
    }
    final pinTo =
        RegExp(r'^(?:pin|save|keep|add)\b.*?\b(?:this|that|it|last|answer|card|widget)\b.*?\b(?:to|on|onto)\s+(?:my |the )?(.+?)\s*(?:board|dashboard)?$', caseSensitive: false).firstMatch(s);
    if (pinTo != null) {
      final t = _turns.lastWhere((t) => t.surface != null || t.surfaces.isNotEmpty, orElse: () => _Turn(''));
      if (t.surface == null && t.surfaces.isEmpty) return false;
      var b = GenUiBoard.findBoard(pinTo.group(1)!);
      if (b == null) {
        if (!GenUiBoard.canCreate) {
          _flash('No board called "${pinTo.group(1)}", and you already have $kMaxBoards boards.');
          return true;
        }
        b = GenUiBoard.create(pinTo.group(1)!);
        if (b == null) return true;
      }
      GenUiBoard.select(b.id);
      _pinTurn(t);
      _flash('Pinned to ${b.name}.');
      return true;
    }
    final moveTo = RegExp(r'^(?:move|put|send)\b\s+(.+?)\s+(?:to|onto|on)\s+(?:my |the )?(.+?)\s*(?:board|dashboard)$', caseSensitive: false).firstMatch(s);
    if (moveTo != null) {
      final it = GenUiBoard.find(moveTo.group(1)!);
      final b = GenUiBoard.findBoard(moveTo.group(2)!);
      if (it == null || b == null) return false;
      GenUiBoard.moveTo(it.id, b.id);
      _flash('Moved ${it.title} to ${b.name}.');
      return true;
    }
    final open = RegExp(r'^(?:show|open|go to|switch to|see|display)\b\s+(?:my |the )?(.+?)\s*(?:board|dashboard)$', caseSensitive: false).firstMatch(s);
    if (open != null && open.group(1)!.trim().isNotEmpty) {
      final b = GenUiBoard.findBoard(open.group(1)!);
      if (b == null) {
        if (GenUiBoard.boards.value.length > 1) {
          _flash('No board called "${open.group(1)}". Your boards: ${GenUiBoard.boards.value.map((b) => b.name).join(', ')}.');
          return true;
        }
        return false;
      }
      GenUiBoard.select(b.id);
      setState(() => _mode = 'board');
      if (b.items.isEmpty) _flash('${b.name} is empty. Pin any answer with the pin icon, or say "pin this to ${b.name}".');
      return true;
    }
    if (RegExp(r'^(?:list|what are|which are|show)\b.*\bboards\b', caseSensitive: false).hasMatch(s)) {
      _flash('Your boards: ${GenUiBoard.boards.value.map((b) => '${b.name} (${b.items.length})').join(', ')}. Up to $kMaxBoards.');
      setState(() => _mode = 'board');
      return true;
    }
    return false;
  }

  /// Layout requests are handled here, without the router: open the board, put two answers
  /// side by side, resize or move a pinned widget, pin or unpin the last answer.
  Future<bool> _layoutCommand(String q) async {
    final s = q.toLowerCase().trim();
    if (await _boardCommand(q)) return true;
    if (RegExp(r'^(show|open|go to|see|display)\b.*\b(board|dashboard|layout)\b').hasMatch(s) || s == 'board' || s == 'my board') {
      setState(() => _mode = 'board');
      if (GenUiBoard.items.value.isEmpty) _flash('Your board is empty. Pin any answer with the pin icon, or ask for two things "side by side".');
      return true;
    }
    if (RegExp(r'\b(side by side|next to each other|beside each other|together on (my|the) board|split screen)\b').hasMatch(s)) {
      final body = s.replaceAll(RegExp(r'\b(side by side|next to each other|beside each other|together on (my|the) board|split screen|on my board|please|show|put|place|keep|me)\b'), ' ');
      final parts = body.split(RegExp(r'\s+(and|&|with|\+)\s+|,')).map((p) => p.trim()).where((p) => p.length > 2).toList();
      if (parts.length < 2) return false;
      final pinned = <_Turn>[];
      for (final p in parts.take(3)) {
        await _ask(p, fromLayout: true);
        if (!mounted) return true;
        final t = _turns.last;
        if (t.surface != null) {
          _pinTurn(t, size: 'S');
          pinned.add(t);
        }
      }
      if (pinned.length >= 2) {
        setState(() => _mode = 'board');
        _flash('Placed ${pinned.length} side by side on your board.');
      } else {
        _flash('I could only answer one of those, so there is nothing to place side by side.');
      }
      return true;
    }
    final size = RegExp(r'\b(make|set|turn|resize|show)\b\s+(.+?)\s+(bigger|larger|full width|full|wide|wider|smaller|half width|half|small|medium|narrow|tall)\b').firstMatch(s);
    if (size != null) {
      final it = GenUiBoard.find(size.group(2)!);
      if (it == null) {
        _flash('Put it on your board first (tap the pin icon), then I can resize it.');
        return true;
      }
      final w = size.group(3)!;
      final to = w.startsWith('tall')
          ? 'L'
          : (w.startsWith('half') || w.startsWith('small') || w.startsWith('narrow') || w == 'smaller')
              ? 'S'
              : w == 'medium'
                  ? 'M'
                  : 'L';
      GenUiBoard.setSize(it.id, to);
      setState(() => _mode = 'board');
      _flash('${it.title}: ${to == 'S' ? 'half' : 'full'} width.');
      return true;
    }
    final move = RegExp(r'\b(move|put|bring)\b\s+(.+?)\s+(to the top|to top|first|up|down|to the bottom|to bottom|last)\b').firstMatch(s);
    if (move != null) {
      final it = GenUiBoard.find(move.group(2)!);
      if (it == null) return false;
      final where = move.group(3)!;
      GenUiBoard.move(
          it.id,
          where.contains('top') || where == 'first'
              ? -1000
              : where.contains('bottom') || where == 'last'
                  ? 1000
                  : where == 'up'
                      ? -1
                      : 1);
      setState(() => _mode = 'board');
      _flash('Moved ${it.title}.');
      return true;
    }
    if (RegExp(r'^(pin|save|keep)\b.*\b(this|that|it|last|previous|answer|card|widget)\b').hasMatch(s) || s == 'pin') {
      final t = _turns.lastWhere((t) => t.surface != null || t.surfaces.isNotEmpty, orElse: () => _Turn(''));
      if (t.surface == null && t.surfaces.isEmpty) return false;
      _pinTurn(t);
      _flash('Pinned to your board.');
      return true;
    }
    final unpin = RegExp(r'^(unpin|remove)\b\s+(.+?)(\s+from (my|the) board)?$').firstMatch(s);
    if (unpin != null && GenUiBoard.items.value.isNotEmpty) {
      final it = GenUiBoard.find(unpin.group(2)!);
      if (it == null) return false;
      GenUiBoard.unpin(it.id);
      _flash('Removed ${it.title} from your board.');
      return true;
    }
    if (RegExp(r'^(export|share|copy)\b.*\b(memory|learned|learnt|intents)\b').hasMatch(s)) {
      final learned = IntentMemory.entries.value.where((e) => e.source != 'classic').length;
      await Clipboard.setData(ClipboardData(text: IntentMemory.exportLearned()));
      _flash('Copied $learned learned intent${learned == 1 ? '' : 's'} to the clipboard. Say "import memory" on another device after pasting there.');
      return true;
    }
    if (RegExp(r'^(import|paste|load)\b.*\b(memory|learned|learnt|intents)\b').hasMatch(s)) {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      try {
        final n = await IntentMemory.importLearned(clip);
        _flash(n == 0 ? 'Nothing new on the clipboard.' : 'Learned $n new thing${n == 1 ? '' : 's'} from the clipboard.');
      } catch (_) {
        _flash('The clipboard does not hold an exported memory.');
      }
      return true;
    }
    if (RegExp(r'^(forget|reset|clear)\b.*\b(memory|learned|learnt|intents)\b').hasMatch(s)) {
      await IntentMemory.forgetLearned();
      _flash('Forgot what I learned. The classic flows are still remembered.');
      return true;
    }
    final clearB = RegExp(r'^(clear|empty|reset)\b\s+(?:my |the )?(.+?)\s*(board|dashboard)\b').firstMatch(s);
    if (clearB != null) {
      final b = GenUiBoard.findBoard(clearB.group(2)!) ?? GenUiBoard.active;
      GenUiBoard.select(b.id);
      GenUiBoard.clear();
      _flash('${b.name} cleared.');
      return true;
    }
    return false;
  }

  Future<void> _ask(String text, {bool fromLayout = false}) async {
    final q = text.trim();
    if (q.isEmpty) return;
    _input.clear();
    if (!fromLayout && await _layoutCommand(q)) return;
    if (!mounted) return;
    final turn = _Turn(q);
    setState(() {
      _mode = 'chat';
      _turns.add(turn);
    });
    _scrollToEnd();
    // Memory first: a phrasing we already know renders without a model call.
    final sw = Stopwatch()..start();
    final hit = IntentMemory.match(q);
    var decision = hit != null ? RouterClient.fromMemory(hit, sw.elapsedMilliseconds) : await _router.route(q, previous: _last);
    if (!mounted) return;
    if (hit != null) IntentMemory.touch(hit);

    if (decision.isPlan) {
      // A composed answer: resolve each card; drop the ones that cannot be resolved.
      final surfaces = <_PlanSurface>[];
      final notes = <String>[];
      for (final card in decision.plan!) {
        final item = GenUiCatalog.items[card.action];
        if (item == null) continue;
        final data = Map<String, dynamic>.from(card.params);
        final problem = await _resolve(item, data, turn);
        if (!mounted) return;
        if (problem != null) {
          notes.add(problem);
          continue;
        }
        surfaces.add(_PlanSurface(A2uiMessage.createSurface(surfaceId: 's${_launch}_${++_surfaces}', component: card.action, data: data), card.size));
      }
      setState(() {
        turn.decision = surfaces.isEmpty ? decision.copyWith(action: GenUiCatalog.unsupported, reply: notes.isEmpty ? "I couldn't put that together." : notes.join(' ')) : decision;
        turn.surfaces = surfaces;
        turn.title = decision.title;
        if (notes.isNotEmpty) turn.note = notes.join(' ');
        _last = null;
      });
      _scrollToEnd();
      if (surfaces.length >= 2) _remember(q, decision);
      return;
    }

    final item = GenUiCatalog.items[decision.action];
    final data = Map<String, dynamic>.from(decision.params);
    if (item != null && decision.isSupported) {
      final problem = await _resolve(item, data, turn);
      if (!mounted) return;
      if (problem != null) decision = decision.copyWith(action: GenUiCatalog.unsupported, reply: problem);
    }

    setState(() {
      turn.decision = decision;
      if (decision.isSupported) {
        // Our code, not the LLM, writes the A2UI message for the chosen catalog item.
        turn.surface = A2uiMessage.createSurface(surfaceId: 's${_launch}_${++_surfaces}', component: decision.action, data: data);
        _last = decision.copyWith(params: data);
      }
    });
    _scrollToEnd();
    if (decision.isSupported) _remember(q, decision);
    if (_turns.where((t) => t.surface != null || t.surfaces.isNotEmpty).length >= 3) _researchNudge();
  }

  /// Params that are safe to replay for a later question with the same intent: choices of
  /// view or kind, never a name, a question or an amount the user typed.
  static const Set<String> _replayable = <String>{'view', 'section', 'kind', 'period', 'scope', 'segment', 'horizon', 'sentiment', 'underlying', 'index', 'intent', 'category', 'timeframe', 'expiry'};

  /// Learn the phrasing → intent → decision, so the next question with this intent is instant.
  void _remember(String q, RouterDecision d) {
    if (d.intent.isEmpty || d.router.startsWith('memory') || d.router == 'tap') return;
    bool replayable(String action, Map<String, dynamic> params) {
      final it = GenUiCatalog.items[action];
      if (it == null || it.needsStock || it.needsFund) return false;
      return params.keys.every(_replayable.contains);
    }

    if (d.isPlan ? !d.plan!.every((c) => replayable(c.action, c.params)) : !replayable(d.action, d.params)) return;
    final existing = IntentMemory.byIntent(d.intent);
    if (existing != null && (existing.isPlan != d.isPlan || (!d.isPlan && existing.action != d.action))) return;
    IntentMemory.remember(
        q,
        existing ??
            IntentEntry(
                intent: d.intent, examples: <String>[], action: d.isPlan ? '' : d.action, params: d.isPlan ? const <String, dynamic>{} : d.params, plan: d.plan, title: d.title, summary: d.reply));
  }

  /// Resolves the stock / fund names in [data] through the app's search. Returns the problem to
  /// show (and fills the turn's suggestions) when something could not be resolved.
  Future<String?> _resolve(CatalogItem item, Map<String, dynamic> data, _Turn turn) async {
    // A card that merely mentions a stock (explain, what-if): resolve it if it can be, carry on if not.
    // A what-if on an index or "the market" is a market shock, not a stock: searching "Nifty" would
    // resolve to an ETF the user does not hold.
    if (item.id == 'what_if' &&
        data['stock'] is String &&
        RegExp(r'^(the )?(market|nifty|nifty ?50|sensex|bank ?nifty|banknifty|fin ?nifty|midcap|index)\b', caseSensitive: false).hasMatch((data['stock'] as String).trim())) {
      data.remove('stock');
    }
    if (!item.needsStock && data['stock'] is String && (data['stock'] as String).trim().isNotEmpty) {
      final name = (data['stock'] as String).trim();
      final ref = await StockResolver.instance!.resolve(name);
      if (!mounted) return 'Closed.';
      if (ref != null) {
        data['scrip'] = ref;
        _lastScrip = ref;
        turn.note = 'Resolved "$name" → ${ref.symbol} (${ref.exchange}) via search';
      } else {
        turn.note = 'Could not find a stock called "$name"; answered without it';
      }
    }
    // Smart alert: the stock named for the prepared order.
    if (data['order_stock'] is String && (data['order_stock'] as String).trim().isNotEmpty) {
      final ref = await StockResolver.instance!.resolve((data['order_stock'] as String).trim());
      if (!mounted) return 'Closed.';
      if (ref != null) data['order_scrip'] = ref;
    }
    if (item.needsStock) {
      final name = (data['stock'] ?? '').toString().trim();
      final resolver = StockResolver.instance!;
      // Follow-up about the same stock: reuse the one already resolved.
      final ref = name.isEmpty ? _lastScrip : await resolver.resolve(name);
      if (!mounted) return 'Closed.';
      if (ref == null) {
        turn.suggestions = name.isEmpty ? const <ScripRef>[] : await resolver.suggest(name);
        return name.isEmpty ? 'Which stock do you mean?' : "I couldn't find a stock called \"$name\".${turn.suggestions.isEmpty ? '' : ' Did you mean:'}";
      }
      data['scrip'] = ref;
      _lastScrip = ref;
      turn.note = name.isEmpty ? 'Reused ${ref.symbol} from the previous answer' : 'Resolved "$name" → ${ref.symbol} (${ref.exchange}) via search';
    }
    if (item.needsFund) {
      final name = (data['fund'] ?? data['stock'] ?? '').toString().trim();
      final ref = name.isEmpty ? _lastFund : await FundResolver.instance.resolve(name);
      if (!mounted) return 'Closed.';
      if (ref == null) {
        _fundSuggestions = name.isEmpty ? const <FundRef>[] : await FundResolver.instance.suggest(name);
        turn.fundSuggestions = _fundSuggestions;
        return name.isEmpty ? 'Which fund do you mean?' : "I couldn't find a mutual fund called \"$name\".${_fundSuggestions.isEmpty ? '' : ' Did you mean:'}";
      }
      data['fund'] = ref;
      _lastFund = ref;
      turn.note = name.isEmpty ? 'Reused ${ref.shortName} from the previous answer' : 'Resolved "$name" → ${ref.shortName} via search';
    }
    // Multi-stock params (compare): resolve each name through search.
    if (data['stocks'] is List) {
      final refs = <ScripRef>[];
      final missed = <String>[];
      for (final n in (data['stocks'] as List)) {
        final r = await StockResolver.instance!.resolve('$n');
        if (r != null) {
          refs.add(r);
        } else {
          missed.add('$n');
        }
      }
      if (!mounted) return 'Closed.';
      if (refs.length < 2) return "I couldn't find ${missed.isEmpty ? 'two stocks to compare' : missed.map((m) => '"$m"').join(' or ')}.";
      data['scrips'] = refs;
      if (refs.isNotEmpty) _lastScrip = refs.first;
      turn.note = 'Resolved ${refs.map((r) => r.symbol).join(', ')} via search${missed.isEmpty ? '' : ' (not found: ${missed.join(', ')})'}';
    }
    // Multi-fund params (compare): resolve each name.
    if (data['funds'] is List) {
      final refs = <FundRef>[];
      for (final n in (data['funds'] as List)) {
        final r = await FundResolver.instance.resolve('$n');
        if (r != null) refs.add(r);
      }
      if (!mounted) return 'Closed.';
      data['fundRefs'] = refs;
      if (refs.isNotEmpty) turn.note = 'Resolved ${refs.map((r) => r.shortName).join(', ')} via search';
    }
    return null;
  }

  /// Pinned strip tap: scroll the chat to that answer, or open the board when it is no longer in the chat.
  void _jumpTo(BoardItem item) {
    final t = _turns.cast<_Turn?>().firstWhere((t) => t!.surface?.surfaceId == item.id || t.surfaces.any((p) => p.msg.surfaceId == item.id), orElse: () => null);
    final ctx = t?.key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.05);
    } else {
      setState(() => _mode = 'board');
    }
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  /// An alert rule fired: say so, and offer the prepared order when there is one.
  void _onAlertFired() {
    final r = AlertEngine.fired.value;
    if (r == null || !mounted) return;
    AlertEngine.fired.value = null;
    // The alert arrives as a card of its own in the chat, like the research alert, so it stays
    // readable later and never covers the composer.
    _openDirect('Alert fired · ${r.title}', 'alerts', <String, dynamic>{'view': r.kind == 'report' ? 'reports' : r.kind}, system: true, note: r.note);
  }

  /// The unprompted research alert: after a few answers, if the desk has published recently on a
  /// stock the user asked about, holds, or subscribed to, a card arrives on its own.
  bool _nudged = false;
  Future<void> _researchNudge() async {
    if (_nudged) return;
    _nudged = true;
    try {
      final seen = <ScripRef>[];
      for (final t in _turns) {
        final sc = t.surface?.data['scrip'];
        if (sc is ScripRef && !seen.any((s) => s.scripCode == sc.scripCode)) seen.add(sc);
      }
      for (final r in AlertStore.rules.value.where((r) => r.kind == 'report')) {
        for (final sc in r.scrips) {
          if (!seen.any((s) => s.scripCode == sc.scripCode)) seen.add(sc);
        }
      }
      if (seen.length < 3) {
        for (final h in (await MoPortfolioDashBoardRepositoryImpl().getEquityDetailAPI(loadFromCache: true)).holdings) {
          if (h.scripId != null && h.scripId!.scripCode != 0 && !seen.any((s) => s.scripCode == '${h.scripId!.scripCode}')) seen.add(GenUiNav.refOf(h.scripId!, h.tradeSymbol, h.companyName));
        }
      }
      final explore = MoResearchExploreRepositoryImpl();
      final cutoff = DateTime.now().subtract(const Duration(days: 180)).millisecondsSinceEpoch ~/ 1000;
      for (final sc in seen.take(6)) {
        final sr = await explore.searchScrip(sc.symbol);
        final mine = sr.reports.where((r) => (r.tradeSymbol.toUpperCase() == sc.symbol.toUpperCase() || r.scripCode == int.tryParse(sc.scripCode)) && r.reportDate >= cutoff).toList()
          ..sort((a, b) => b.reportDate.compareTo(a.reportDate));
        if (mine.isEmpty || !mounted) continue;
        final rep = mine.first;
        _openDirect('Research alert · ${sc.symbol}', 'research_reports', <String, dynamic>{'scrip': sc, 'view': 'company'},
            system: true,
            note:
                'Arrived unprompted: the research desk published "${rep.title}" on ${sc.symbol}, a stock you ${AlertStore.rules.value.any((r) => r.kind == 'report' && r.scrips.any((x) => x.scripCode == sc.scripCode)) ? 'subscribed to' : 'asked about or hold'}.');
        for (final r in AlertStore.rules.value.where((r) => r.kind == 'report' && !r.isTriggered && r.scrips.any((x) => x.scripCode == sc.scripCode))) {
          AlertEngine.fire(r, '${sc.symbol}: ${rep.title}');
        }
        return;
      }
    } catch (e) {
      debugPrint('GenUI research nudge: $e');
    }
  }

  @override
  void dispose() {
    AlertEngine.fired.removeListener(_onAlertFired);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.surfaceBackgroundNeutralSubtle,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: context.surfaceBackgroundNeutralNormal,
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        title: Row(
          children: <Widget>[
            Text('RIISE', style: MOTypography.headingSmall.copyWith(color: context.surfaceTextPrimaryNormal, fontStyle: FontStyle.italic)),
            const Spacer(),
            _ViewToggle(onClassic: () => Navigator.of(context).maybePop()),
          ],
        ),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<BoardItem>>(
          valueListenable: GenUiBoard.items,
          builder: (context, pins, _) => Column(
            children: <Widget>[
              _ModeTabs(mode: _mode, pins: pins.length, onChanged: (m) => setState(() => _mode = m)),
              if (_mode == 'chat' && pins.isNotEmpty) _PinnedStrip(pins: pins, onTap: _jumpTo),
              if (_mode == 'board') _BoardBar(onFlash: _flash),
              Expanded(
                child: _mode == 'board'
                    ? _BoardView(pins: pins, onAsk: _ask)
                    : _turns.isEmpty
                        ? _Welcome(onAsk: _ask)
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            itemCount: _turns.length,
                            itemBuilder: (context, i) => _TurnView(key: _turns[i].key, turn: _turns[i], onAsk: _ask),
                          ),
              ),
              _Composer(controller: _input, onSend: _ask, quickAsks: _quickAsks),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.onClassic});
  final VoidCallback onClassic;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: onClassic,
            borderRadius: BorderRadius.circular(13),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(child: Text('Classic', style: MOTypography.labelSmallSemiboldAbc.copyWith(color: context.surfaceTextNeutralStrong))),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: context.actionBackgroundPrimaryDefault, borderRadius: BorderRadius.circular(13)),
            child: Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, size: 12, color: context.feedbackIconWarningNormal),
                const SizedBox(width: 4),
                Text('AI', style: MOTypography.labelSmallSemiboldAbc.copyWith(color: context.surfaceTextStaticWhiteNormal)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onAsk});
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.auto_awesome, color: context.surfaceTextPrimaryNormal),
          MOSpacing.verticalSpace12,
          Text('Ask RIISE', style: MOTypography.headingMedium.copyWith(color: context.surfaceTextNeutralNormal)),
          MOSpacing.verticalSpace4,
          Text('Ask in English, Hindi or Hinglish. Answers come as live widgets built from your account data.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          MOSpacing.verticalSpace16,
          Text('Router: ${GenUiConfig.routerName} · ${GenUiCatalog.items.length} widgets', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
        ],
      ),
    );
  }
}

class _TurnView extends StatelessWidget {
  const _TurnView({super.key, required this.turn, required this.onAsk});
  final _Turn turn;
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    final d = turn.decision;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: turn.system ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 300),
            margin: const EdgeInsets.only(bottom: 8, top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: turn.system ? context.surfaceBackgroundPrimaryFaded : context.actionBackgroundPrimaryDefault,
              borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16), topRight: const Radius.circular(16), bottomLeft: Radius.circular(turn.system ? 4 : 16), bottomRight: Radius.circular(turn.system ? 16 : 4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              if (turn.system) ...<Widget>[Icon(Icons.notifications_active_outlined, size: 14, color: context.surfaceTextPrimaryNormal), MOSpacing.horizontalSpace6],
              Flexible(child: Text(turn.question, style: MOTypography.bodySmallRegular.copyWith(color: turn.system ? context.surfaceTextPrimaryNormal : context.surfaceTextStaticWhiteNormal))),
            ]),
          ),
        ),
        if (turn.pending)
          Row(children: <Widget>[
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: context.surfaceTextPrimaryNormal)),
            MOSpacing.horizontalSpace8,
            Text('Thinking…', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          ])
        else ...<Widget>[
          if (turn.surfaces.isNotEmpty)
            _PlanView(turn: turn)
          else if (turn.surface != null)
            CardScope(
              surfaceId: turn.surface!.surfaceId,
              component: turn.surface!.component,
              data: turn.surface!.data,
              question: turn.question,
              child: GenUiCatalog.render(context, turn.surface!.component, turn.surface!.data),
            )
          else
            MOCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(d!.reply.isEmpty ? "I can't do that yet." : d.reply, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                  if (turn.fundSuggestions.isNotEmpty) ...<Widget>[
                    MOSpacing.verticalSpace8,
                    Wrap(
                      spacing: MOSpacing.spacing6,
                      runSpacing: MOSpacing.spacing6,
                      children: <Widget>[
                        for (final f in turn.fundSuggestions)
                          ActionChip(
                            label: Text(f.shortName, style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
                            onPressed: () => onAsk('Tell me about ${f.name} fund'),
                            backgroundColor: context.surfaceBackgroundPrimaryFaded,
                            side: BorderSide.none,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                  if (turn.suggestions.isNotEmpty) ...<Widget>[
                    MOSpacing.verticalSpace8,
                    Wrap(
                      spacing: MOSpacing.spacing6,
                      runSpacing: MOSpacing.spacing6,
                      children: <Widget>[
                        for (final s in turn.suggestions)
                          ActionChip(
                            label: Text('${s.symbol} · ${s.name}', style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
                            onPressed: () => onAsk('Tell me about ${s.symbol}'),
                            backgroundColor: context.surfaceBackgroundPrimaryFaded,
                            side: BorderSide.none,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 10, left: 4),
            child: Text(
              '${d!.action}${d.intent.isEmpty ? '' : ' · ${d.intent}'} · ${(d.confidence * 100).round()}% · ${d.router} · ${d.latencyMs} ms'
              '${d.params.isEmpty ? '' : ' · ${d.params}'}${turn.note.isEmpty ? '' : '\n${turn.note}'}',
              style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong),
            ),
          ),
        ],
      ],
    );
  }
}

/// A composed answer: the plan's cards laid out by size, like the board.
class _PlanView extends StatelessWidget {
  const _PlanView({required this.turn});
  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final d = turn.decision!;
    return LayoutBuilder(builder: (context, box) {
      final full = box.maxWidth;
      final half = (full - 8) / 2;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        if (turn.title.isNotEmpty) Text(turn.title, style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
        if (d.reply.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 2, bottom: 8), child: Text(d.reply, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
        Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
          for (final p in turn.surfaces)
            SizedBox(
              width: p.size == 'S' && full >= 360 && GenUiBoard.halfOk(p.msg.component) ? half : full,
              child: CardScope(
                key: ValueKey<String>('plan-${p.msg.surfaceId}'),
                surfaceId: p.msg.surfaceId,
                component: p.msg.component,
                data: p.msg.data,
                question: turn.question,
                child: GenUiCatalog.render(context, p.msg.component, p.msg.data),
              ),
            ),
        ]),
      ]);
    });
  }
}

/// Chat | Board tabs under the app bar.
class _ModeTabs extends StatelessWidget {
  const _ModeTabs({required this.mode, required this.pins, required this.onChanged});
  final String mode;
  final int pins;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(String id, String label) {
      final on = mode == id;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(id),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? context.actionBackgroundPrimaryDefault : Colors.transparent, width: 2))),
            child: Center(child: Text(label, style: MOTypography.bodySmallSemibold.copyWith(color: on ? context.surfaceTextPrimaryNormal : context.surfaceTextNeutralStrong))),
          ),
        ),
      );
    }

    return Container(
      color: context.surfaceBackgroundNeutralNormal,
      child: Row(children: <Widget>[tab('chat', 'Chat'), tab('board', pins == 0 ? 'Board' : 'Board · $pins')]),
    );
  }
}

/// The boards as chips (tap to open, long-press to rename), plus "new board" and a menu
/// for the open board. Up to [kMaxBoards] boards.
class _BoardBar extends StatelessWidget {
  const _BoardBar({required this.onFlash});
  final ValueChanged<String> onFlash;

  Future<void> _rename(BuildContext context, Board b) async {
    final n = await askBoardName(context, title: 'Rename board', initial: b.name);
    if (n != null && n.trim().isNotEmpty) GenUiBoard.rename(b.id, n);
  }

  Future<void> _create(BuildContext context) async {
    if (!GenUiBoard.canCreate) {
      onFlash('You already have $kMaxBoards boards, the most this version allows.');
      return;
    }
    final n = await askBoardName(context, title: 'New board');
    if (n == null || n.trim().isEmpty) return;
    final b = GenUiBoard.create(n);
    if (b != null) onFlash('Created ${b.name}. Pin answers to it with the pin icon.');
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Board>>(
        valueListenable: GenUiBoard.boards,
        builder: (context, boards, _) {
          final activeId = GenUiBoard.activeId.value;
          final idx = boards.indexWhere((b) => b.id == activeId);
          final on = MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal);
          return Container(
            color: context.surfaceBackgroundNeutralNormal,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
            child: ChipStrip(
              height: 34,
              selectedIndex: idx,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                IconButton(
                  tooltip: GenUiBoard.canCreate ? 'New board' : 'Limit of $kMaxBoards boards',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _create(context),
                  icon: Icon(Icons.add_circle_outline, size: 20, color: GenUiBoard.canCreate ? context.surfaceTextPrimaryNormal : context.surfaceIconNeutralNormal),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Board options',
                  padding: EdgeInsets.zero,
                  color: context.surfaceBackgroundNeutralNormal,
                  icon: Icon(Icons.more_vert, size: 20, color: context.surfaceIconNeutralNormal),
                  onSelected: (v) async {
                    final b = GenUiBoard.active;
                    switch (v) {
                      case 'rename':
                        await _rename(context, b);
                      case 'clear':
                        GenUiBoard.clear();
                        onFlash('${b.name} cleared.');
                      case 'delete':
                        GenUiBoard.delete(b.id);
                        onFlash(boards.length == 1 ? '${b.name} emptied (it is your only board).' : 'Deleted ${b.name}.');
                    }
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(value: 'rename', height: 40, child: Text('Rename ${GenUiBoard.active.name}', style: on)),
                    PopupMenuItem<String>(value: 'clear', height: 40, child: Text('Remove all cards', style: on)),
                    PopupMenuItem<String>(
                        value: 'delete',
                        height: 40,
                        child: Text(boards.length == 1 ? 'Empty this board' : 'Delete ${GenUiBoard.active.name}',
                            style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNegativeNormal))),
                  ],
                ),
              ]),
              children: <Widget>[
                for (final b in boards)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: () => _rename(context, b),
                      child: ChoiceChip(
                        label: Text('${b.name}${b.items.isEmpty ? '' : ' · ${b.items.length}'}',
                            style: MOTypography.labelSmallMediumAbc.copyWith(color: b.id == activeId ? context.surfaceTextInverseNormal : context.surfaceTextPrimaryNormal)),
                        selected: b.id == activeId,
                        showCheckmark: false,
                        selectedColor: context.actionBackgroundPrimaryDefault,
                        backgroundColor: context.surfaceBackgroundPrimaryFaded,
                        side: BorderSide.none,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => GenUiBoard.select(b.id),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

/// Compact row of what the user pinned, under the tabs while chatting.
class _PinnedStrip extends StatelessWidget {
  const _PinnedStrip({required this.pins, required this.onTap});
  final List<BoardItem> pins;
  final ValueChanged<BoardItem> onTap;

  @override
  Widget build(BuildContext context) => Container(
        color: context.surfaceBackgroundNeutralNormal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: <Widget>[
              for (final p in pins)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: Icon(Icons.push_pin, size: 12, color: context.surfaceTextPrimaryNormal),
                    label: Text(p.title, style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
                    onPressed: () => onTap(p),
                    backgroundColor: context.surfaceBackgroundPrimaryFaded,
                    side: BorderSide.none,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
      );
}

/// The board: pinned answers laid out by size. S cards sit two to a row; M and L take the full width.
class _BoardView extends StatelessWidget {
  const _BoardView({required this.pins, required this.onAsk});
  final List<BoardItem> pins;
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    if (pins.isEmpty) {
      // Scrolls when the keyboard is up (the fixed column overflowed by 60 px), centred otherwise.
      return LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.dashboard_customize_outlined, color: context.surfaceTextPrimaryNormal),
                        MOSpacing.verticalSpace12,
                        Text(GenUiBoard.active.name, style: MOTypography.headingMedium.copyWith(color: context.surfaceTextNeutralNormal)),
                        MOSpacing.verticalSpace4,
                        Text(
                            'This board is empty. Lay out the answers you care about, your way: side by side, wide or full width. Pin any answer with the pin icon, say "pin this to ${GenUiBoard.active.name}", or ask:',
                            style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                        MOSpacing.verticalSpace12,
                        Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                          for (final q in const <String>[
                            'Show my portfolio and market today side by side',
                            'Show my watchlist and top gainers side by side',
                            'Nifty option chain and F&O pulse side by side'
                          ])
                            ActionChip(
                                label: Text(q, style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
                                onPressed: () => onAsk(q),
                                backgroundColor: context.surfaceBackgroundPrimaryFaded,
                                side: BorderSide.none),
                        ]),
                      ],
                    ),
                  ))));
    }
    return LayoutBuilder(builder: (context, box) {
      final full = box.maxWidth - 32;
      final half = (full - 8) / 2;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('${GenUiBoard.active.name}: your layout. Use the ⋯ menu on a card to resize, reorder or move it to another board, or say "make my portfolio full width".',
              style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          MOSpacing.verticalSpace8,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final p in pins)
                SizedBox(
                  // The board decides: half width only when the card can lay itself out for it
                  // on this screen; otherwise it takes the full width and says why.
                  width: p.size == 'S' && (full >= 720 || (full >= 360 && GenUiBoard.halfOk(p.component))) ? half : full,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
                    CardScope(
                      key: ValueKey<String>('board-${p.id}'),
                      surfaceId: p.id,
                      component: p.component,
                      data: p.data,
                      question: p.question,
                      onBoard: true,
                      child: GenUiCatalog.render(context, p.component, p.data),
                    ),
                    if (p.size == 'S' && full < 720 && !GenUiBoard.halfOk(p.component))
                      Padding(
                        padding: const EdgeInsets.only(left: 4, top: 2),
                        child: Text('Shown full width: this card needs the room on a phone.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                      ),
                  ]),
                ),
            ],
          ),
        ]),
      );
    });
  }
}

/// The suggestion chips: a horizontal strip that scrolls by finger, mouse drag, trackpad or
/// wheel, with a fade at the edge that still has more to show.
class _QuickAsks extends StatefulWidget {
  const _QuickAsks({required this.quickAsks, required this.onSend});
  final List<String> quickAsks;
  final ValueChanged<String> onSend;

  @override
  State<_QuickAsks> createState() => _QuickAsksState();
}

class _QuickAsksState extends State<_QuickAsks> {
  final ScrollController _ctl = ScrollController();
  bool _moreRight = true;
  bool _moreLeft = false;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_edges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _edges());
  }

  void _edges() {
    if (!_ctl.hasClients) return;
    final p = _ctl.position;
    final r = p.pixels < p.maxScrollExtent - 4;
    final l = p.pixels > 4;
    if (r != _moreRight || l != _moreLeft)
      setState(() {
        _moreRight = r;
        _moreLeft = l;
      });
  }

  void _page(int dir) {
    if (!_ctl.hasClients) return;
    final w = _ctl.position.viewportDimension * 0.8;
    _ctl.animateTo((_ctl.offset + dir * w).clamp(0, _ctl.position.maxScrollExtent).toDouble(), duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// Every prompt in a sheet, grouped, so nothing has to be scrolled sideways to be found.
  void _showAll() {
    const groups = <String, List<String>>{
      'Portfolio': <String>[
        'Show my portfolio',
        'Show my stocks',
        'My funds',
        'What is my net worth?',
        'What is dragging my portfolio today?',
        'Any dividends coming?',
        'Is my portfolio too risky?',
        'How much tax will I pay this year?'
      ],
      'Market': <String>['How is the market today?', 'Top gainers as a chart', 'Best performing stocks this year', 'Market news', 'Nifty 50 today'],
      'Stocks & orders': <String>['Tell me about HDFC Bank', 'Compare TCS and Infosys', 'HDFC Bank vs Nifty', 'Show my watchlist', 'My pending orders', 'Cancel my pending orders'],
      'Mutual funds': <String>['Best small cap funds', 'Tell me about Parag Parikh Flexi Cap', 'How are my mutual funds doing?', 'Show my SIPs'],
      'F&O': <String>['Nifty option chain', 'Bank Nifty OI as a chart', 'Most active options', 'My F&O positions', 'Bullish option strategies', 'Nifty futures', 'How is Nifty looking?'],
      'Research': <String>['Any stock recommendations?', 'Intraday trading calls', 'Research report on Tata Motors', 'Market outlook today', 'Research snapshot of HDFC Bank'],
      'Ask the AI': <String>[
        'What if the market falls 10%?',
        'Am I beating the market?',
        'What is P/E?',
        'How should I rebalance?',
        'I want 50 lakh in 10 years',
        'What is coming up?',
        'Did any SIP fail?',
        'Morning brief'
      ],
      'Alerts': <String>[
        'Alert me when Yes Bank crosses ₹22',
        'Alert me if any of my bank stocks falls 5% in a day',
        'Email me when HDFC Bank posts results',
        'Mail me research reports on Infosys and TCS',
        'Show my alerts'
      ],
      'Boards & memory': <String>[
        'Show my board',
        'Create a board called Trading',
        'Show my trading board',
        'Pin this to my funds board',
        'List my boards',
        'Show my portfolio and market today side by side',
        'Make my portfolio full width',
        'Pin this',
        'Clear my board',
        'Forget what you learned'
      ],
      'Hindi / Hinglish': <String>['मेरा पोर्टफोलियो कैसा है?', 'bazaar kaisa hai', 'kaunsa stock khareedna chahiye', 'abhi banking mai paisa daalna chahiye'],
    };
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceBackgroundNeutralNormal,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (sheet, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            Text('Things you can ask', style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
            Text('Tap one to send it. Anything else works too, in English, Hindi or Hinglish.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
            for (final e in groups.entries) ...<Widget>[
              MOSpacing.verticalSpace12,
              Text(e.key, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              MOSpacing.verticalSpace6,
              Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                for (final q in e.value)
                  ActionChip(
                    label: Text(q, style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
                    onPressed: () {
                      Navigator.of(sheet).pop();
                      widget.onSend(q);
                    },
                    backgroundColor: context.surfaceBackgroundPrimaryFaded,
                    side: BorderSide.none,
                    visualDensity: VisualDensity.compact,
                  ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = context.surfaceBackgroundNeutralNormal;
    return SizedBox(
      height: 32,
      child: Stack(children: <Widget>[
        // A vertical wheel or trackpad swipe moves the strip sideways.
        Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && _ctl.hasClients) {
              final d = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
              _ctl.jumpTo((_ctl.offset + d).clamp(0, _ctl.position.maxScrollExtent).toDouble());
            }
          },
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false, dragDevices: PointerDeviceKind.values.toSet()),
            child: ListView(
              controller: _ctl,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              children: <Widget>[
                for (final q in widget.quickAsks)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(q, style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
                      onPressed: () => widget.onSend(q),
                      backgroundColor: context.surfaceBackgroundPrimaryFaded,
                      side: BorderSide.none,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                const SizedBox(width: 72),
              ],
            ),
          ),
        ),
        // The chevron is a button: one tap pages the strip; the list icon opens every prompt.
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            if (_moreRight)
              InkWell(
                onTap: () => _page(1),
                child: Container(
                  width: 56,
                  decoration: BoxDecoration(gradient: LinearGradient(colors: <Color>[bg.withValues(alpha: 0), bg, bg])),
                  alignment: Alignment.centerRight,
                  child: Icon(Icons.chevron_right, size: 20, color: context.surfaceTextPrimaryNormal),
                ),
              )
            else
              Container(width: 8, color: bg),
            InkWell(
              onTap: _showAll,
              child: Container(
                color: bg,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Tooltip(message: 'All prompts', child: Icon(Icons.list_rounded, size: 22, color: context.surfaceTextPrimaryNormal)),
              ),
            ),
          ]),
        ),
        if (_moreLeft)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(child: Container(width: 24, decoration: BoxDecoration(gradient: LinearGradient(colors: <Color>[bg, bg.withValues(alpha: 0)])))),
          ),
      ]),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend, required this.quickAsks});
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final List<String> quickAsks;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.surfaceBackgroundNeutralNormal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _QuickAsks(quickAsks: quickAsks, onSend: onSend),
          MOSpacing.verticalSpace8,
          Container(
            height: 48,
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: BoxDecoration(
              color: context.surfaceBackgroundNeutralNormal,
              border: Border.all(color: context.actionBorderPrimaryNormal, width: 1.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, size: 18, color: context.surfaceTextPrimaryNormal),
                MOSpacing.horizontalSpace8,
                Expanded(
                  child: TextField(
                    controller: controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: onSend,
                    style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Ask RIISE…',
                      hintStyle: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralStrong),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => onSend(controller.text),
                  icon: Icon(Icons.send_rounded, color: context.surfaceTextPrimaryNormal),
                  tooltip: 'Send',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
