import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/entities/stock_resolver.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_broadcaster/models/request_models.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:trader_proto_gen/Watchlist/Watchlist.pb.dart';
import 'package:trader_watchlist/data/watchlist_repository_impl.dart';

/// The user's watchlists with live prices, plus create / add flows that use
/// the same `WatchlistRepository` calls as the classic watchlist screen
/// (`createCustomWatchlist`, `addScripToWatchlist`, `removeScrips`).
///
/// `intent`: view (default) | create | add. `stocks` are names as the user
/// wrote them; they are resolved through the real search API before anything
/// is saved. `theme` ("bank stocks") seeds the stock picker from search,
/// because the app has no sector-list API.
class WatchlistCard extends StatefulWidget {
  const WatchlistCard({super.key, this.name, this.view, this.intent, this.stocks = const <String>[], this.theme});
  final String? name;
  final String? view;
  final String? intent;
  final List<String> stocks;
  final String? theme;
  static const List<String> views = <String>['list', 'strip'];

  @override
  State<WatchlistCard> createState() => _WatchlistCardState();
}

class _Loaded {
  _Loaded(this.info, this.scrips, this.all);
  final WatchlistInfo? info;
  final List<WatchlistScrip> scrips;
  final List<WatchlistInfo> all;
}

class _WatchlistCardState extends State<WatchlistCard> {
  final WatchlistRepositoryImpl _repo = WatchlistRepositoryImpl();
  late Future<_Loaded> _future = _load();
  late String _view = WatchlistCard.views.contains(widget.view) ? widget.view! : 'list';
  late String _mode = (widget.intent == 'create' || widget.intent == 'add' || widget.theme != null) ? (widget.intent == 'add' ? 'add' : 'create') : 'view';
  int? _selectedId;

  Future<_Loaded> _load() async {
    final WatchlistResponse res = await _repo.fetchWatchlist(null);
    final summary = res.watchlist;
    final all = summary.watchlists.toList();
    WatchlistInfo? pick;
    final wanted = (widget.name ?? '').trim().toLowerCase();
    if (_selectedId != null) {
      pick = all.where((w) => w.id == _selectedId).firstOrNull;
    } else if (wanted.isNotEmpty) {
      pick = all.where((w) => w.name.toLowerCase().contains(wanted)).firstOrNull;
    }
    if (pick == null || pick.id == summary.scrips.name.id) {
      return _Loaded(summary.scrips.name, summary.scrips.scrips.toList(), all);
    }
    final WatchlistScrips scrips = await _repo.fetchWatchlistById(id: pick.id, callback: null);
    return _Loaded(pick, scrips.scrips.toList(), all);
  }

  void _reload({int? select}) => setState(() {
        if (select != null) _selectedId = select;
        _future = _load();
      });

  Future<void> _remove(_Loaded d, WatchlistScrip s) async {
    final id = d.info?.id;
    if (id == null) return;
    await _repo.removeScrips(id, <int>[s.scrip.scripCode]);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return CardFrame(
      live: true,
      title: _mode == 'create' ? 'New watchlist' : _mode == 'add' ? 'Add to watchlist' : 'Watchlist',
      views: _mode == 'view' ? WatchlistCard.views : const <String>[],
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: () => _reload(),
      child: FutureBuilder<_Loaded>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching watchlist…');
          if (snap.hasError || !snap.hasData) {
            return CardError(title: "Couldn't load your watchlist.", message: '${snap.error ?? 'No data'}', onRetry: () => _reload());
          }
          final d = snap.data!;
          if (_mode != 'view') {
            return _Editor(
              repo: _repo,
              mode: _mode,
              all: d.all,
              initialName: widget.name ?? widget.theme ?? '',
              stocks: widget.stocks,
              theme: widget.theme,
              onDone: (int? id) => setState(() {
                _mode = 'view';
                _reload(select: id);
              }),
              onCancel: () => setState(() => _mode = 'view'),
            );
          }
          subscribeLive(d.scrips.map((s) => BroadcastSymbol.forScrip(scripCode: s.scrip.scripCode, exchangeCode: s.scrip.exchange.value)));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                height: 30,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    for (final w in d.all)
                      Padding(
                        padding: EdgeInsets.only(right: MOSpacing.spacing6),
                        child: ChoiceChip(
                          label: Text(w.name, style: MOTypography.labelSmallMediumAbc.copyWith(
                              color: w.id == d.info?.id ? context.surfaceTextStaticWhiteNormal : context.surfaceTextNeutralStrong)),
                          selected: w.id == d.info?.id,
                          selectedColor: context.actionBackgroundPrimaryDefault,
                          backgroundColor: context.surfaceBackgroundNeutralFaded,
                          side: BorderSide.none,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => _reload(select: w.id),
                        ),
                      ),
                    ActionChip(label: const Text('+ New'), visualDensity: VisualDensity.compact, onPressed: () => setState(() => _mode = 'create')),
                    MOSpacing.horizontalSpace6,
                    ActionChip(label: const Text('+ Add stock'), visualDensity: VisualDensity.compact, onPressed: () => setState(() => _mode = 'add')),
                  ],
                ),
              ),
              MOSpacing.verticalSpace8,
              if (d.scrips.isEmpty)
                Text('This watchlist is empty.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))
              else if (_view == 'strip')
                SizedBox(
                  height: 64,
                  child: ListView(scrollDirection: Axis.horizontal, children: <Widget>[for (final s in d.scrips) _StripTile(scrip: s)]),
                )
              else
                Column(children: <Widget>[for (final s in d.scrips) _Row(scrip: s, onRemove: () => _remove(d, s))]),
            ],
          );
        },
      ),
    );
  }
}

/// Create a watchlist, or add stocks to an existing one.
class _Editor extends StatefulWidget {
  const _Editor({required this.repo, required this.mode, required this.all, required this.initialName, required this.stocks, required this.onDone, required this.onCancel, this.theme});
  final WatchlistRepositoryImpl repo;
  final String mode; // create | add
  final List<WatchlistInfo> all;
  final String initialName;
  final List<String> stocks;
  final String? theme;
  final ValueChanged<int?> onDone;
  final VoidCallback onCancel;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);
  final TextEditingController _search = TextEditingController();
  final List<ScripRef> _picked = <ScripRef>[];
  final List<String> _unresolved = <String>[];
  List<ScripRef> _suggestions = const <ScripRef>[];
  int? _target;
  bool _resolving = true;
  bool _saving = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _target = widget.all.isEmpty ? null : widget.all.first.id;
    _seed();
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _seed() async {
    final resolver = StockResolver.instance;
    if (resolver != null) {
      for (final s in widget.stocks) {
        final ref = await resolver.resolve(s);
        if (ref == null) {
          _unresolved.add(s);
        } else if (!_picked.any((p) => p.scripId == ref.scripId)) {
          _picked.add(ref);
        }
      }
      if (widget.theme != null && widget.stocks.isEmpty) {
        _suggestions = await resolver.suggest(widget.theme!, limit: 10);
      }
    }
    if (mounted) setState(() => _resolving = false);
  }

  Future<void> _find(String q) async {
    final resolver = StockResolver.instance;
    if (resolver == null || q.trim().length < 2) return;
    final res = await resolver.suggest(q.trim(), limit: 6);
    if (mounted) setState(() => _suggestions = res);
  }

  Future<void> _save() async {
    if (_picked.isEmpty) return _fail('Pick at least one stock.');
    setState(() {
      _saving = true;
      _status = widget.mode == 'create' ? 'Creating…' : 'Adding…';
    });
    try {
      int? id = _target;
      if (widget.mode == 'create') {
        final name = _name.text.trim();
        if (name.isEmpty) return _fail('Give the watchlist a name.');
        final info = await widget.repo.createCustomWatchlist(name, false);
        id = info.id;
      }
      if (id == null) return _fail('Pick a watchlist.');
      var ok = 0;
      for (final p in _picked) {
        final res = await widget.repo.addScripToWatchlist(ScripId(scripCode: int.tryParse(p.scripCode) ?? 0, exchange: Exchange.valueOf(p.exchangeCode ?? 0) ?? Exchange.NSE), <int>[id]);
        if (res.message.isEmpty || !res.message.toLowerCase().contains('fail')) ok++;
      }
      if (!mounted) return;
      setState(() => _status = '$ok of ${_picked.length} added.');
      widget.onDone(id);
    } catch (e) {
      _fail('$e');
    }
  }

  void _fail(String m) {
    if (mounted) setState(() {
      _saving = false;
      _status = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    if (_resolving) return const CardLoading(text: 'Looking up the stocks…');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (widget.mode == 'create')
        TextField(style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal), controller: _name, decoration: const InputDecoration(labelText: 'Watchlist name', isDense: true, border: OutlineInputBorder()))
      else ...<Widget>[
        Text('Add to', style: label),
        Wrap(spacing: 6, children: <Widget>[for (final w in widget.all) ChoiceChip(label: Text(w.name), selected: _target == w.id, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _target = w.id))]),
      ],
      MOSpacing.verticalSpace8,
      Text('Stocks', style: label),
      Wrap(spacing: 6, runSpacing: 4, children: <Widget>[
        for (final p in _picked) InputChip(label: Text(p.symbol), visualDensity: VisualDensity.compact, onDeleted: () => setState(() => _picked.remove(p))),
        if (_picked.isEmpty) Text('None yet', style: label),
      ]),
      if (_unresolved.isNotEmpty) Text("Couldn't find: ${_unresolved.join(', ')}", style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNegativeNormal)),
      MOSpacing.verticalSpace6,
      TextField(
        style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal),
        controller: _search,
        onChanged: _find,
        decoration: InputDecoration(labelText: widget.theme != null ? 'Search more (${widget.theme})' : 'Search a stock to add', isDense: true, border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.search, size: 18)),
      ),
      if (_suggestions.isNotEmpty)
        Wrap(spacing: 6, runSpacing: 4, children: <Widget>[
          for (final s in _suggestions.where((s) => !_picked.any((p) => p.scripId == s.scripId)))
            ActionChip(label: Text('${s.symbol} · ${s.exchange}'), visualDensity: VisualDensity.compact, onPressed: () => setState(() => _picked.add(s))),
        ]),
      if (_status.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: Text(_status, style: label)),
      MOSpacing.verticalSpace8,
      Row(children: <Widget>[
        TextButton(onPressed: _saving ? null : widget.onCancel, child: const Text('Cancel')),
        const Spacer(),
        MOButton(label: widget.mode == 'create' ? 'Create watchlist' : 'Add ${_picked.length}', onPressed: _saving ? null : _save, isLoading: _saving, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small),
      ]),
    ]);
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.scrip, required this.onRemove});
  final WatchlistScrip scrip;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => LivePrice.scrip(
        scrip: scrip.scrip,
        builder: (context, t) => InkWell(
          onTap: () => GenUiNav.openStock(GenUiNav.refOf(scrip.scrip, scrip.tradingSymbol, scrip.description)),
          child: Padding(
          padding: MOSpacing.paddingVertical6,
          child: AdaptiveRow(
            leading: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(scrip.tradingSymbol, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                Text(scrip.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
              ],
            ),
            trailing: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(t == null || t.ltp == 0 ? '—' : _money(t.ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                Text(t == null || t.ltp == 0 ? '' : '${signed(t.change)} (${pct(t.perChange)})',
                    style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, t?.change ?? 0))),
              ],
            ),
            end: IconButton(icon: const Icon(Icons.close, size: 16), visualDensity: VisualDensity.compact, tooltip: 'Remove', onPressed: onRemove),
          ),
        ),
        ),
      );
}

class _StripTile extends StatelessWidget {
  const _StripTile({required this.scrip});
  final WatchlistScrip scrip;

  @override
  Widget build(BuildContext context) => LivePrice.scrip(
        scrip: scrip.scrip,
        builder: (context, t) => Container(
          margin: EdgeInsets.only(right: MOSpacing.spacing8),
          padding: EdgeInsets.symmetric(horizontal: MOSpacing.spacing12, vertical: MOSpacing.spacing8),
          decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(scrip.tradingSymbol, style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              Text(t == null || t.ltp == 0 ? '—' : _money(t.ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              Text(t == null || t.ltp == 0 ? '' : pct(t.perChange), style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, t?.change ?? 0))),
            ],
          ),
        ),
      );
}

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
