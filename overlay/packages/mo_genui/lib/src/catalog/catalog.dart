import 'package:flutter/widgets.dart';

import 'package:mo_genui/src/cards/account_cards.dart';
import 'package:mo_genui/src/cards/charges_card.dart';
import 'package:mo_genui/src/cards/discover_cards.dart';
import 'package:mo_genui/src/cards/fno_cards.dart';
import 'package:mo_genui/src/cards/funds_card.dart';
import 'package:mo_genui/src/cards/index_card.dart';
import 'package:mo_genui/src/cards/notifications_card.dart';
import 'package:mo_genui/src/cards/market_cards.dart';
import 'package:mo_genui/src/cards/mf_discover_cards.dart';
import 'package:mo_genui/src/cards/mf_fund_card.dart';
import 'package:mo_genui/src/cards/mf_transact_cards.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/cards/mtf_borrow_card.dart';
import 'package:mo_genui/src/cards/order_ticket_card.dart';
import 'package:mo_genui/src/cards/orders_card.dart';
import 'package:mo_genui/src/cards/portfolio_card.dart';
import 'package:mo_genui/src/cards/portfolio_depth_cards.dart';
import 'package:mo_genui/src/cards/research_cards.dart';
import 'package:mo_genui/src/cards/stock_card.dart';
import 'package:mo_genui/src/cards/ai_native_cards.dart';
import 'package:mo_genui/src/cards/alert_cards.dart';
import 'package:mo_genui/src/cards/stock_sip_card.dart';
import 'package:mo_genui/src/cards/watchlist_card.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';

typedef CatalogBuilder = Widget Function(BuildContext context, Map<String, dynamic> data);

int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.replaceAll(RegExp(r'[₹,\s]'), ''));
List<String> _strings(Object? v) => v is List
    ? v.map((e) => '$e').where((e) => e.trim().isNotEmpty).toList()
    : v is String && v.trim().isNotEmpty
        ? v.split(RegExp(r'[,;]|\band\b|\baur\b')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
        : const <String>[];

/// One widget the AI is allowed to show. The LLM can only name an `id` from
/// this catalog and fill the documented `params`; it never describes layout
/// or data.
class CatalogItem {
  const CatalogItem({
    required this.id,
    required this.title,
    required this.description,
    required this.keywords,
    required this.builder,
    this.params = '',
    this.views = const <String>[],
    this.needsStock = false,
    this.needsFund = false,
    this.narrow = true,
  });

  final String id;
  final String title;

  /// Shown to the LLM in the routing prompt.
  final String description;

  /// Parameter contract shown to the LLM, e.g. `"stock": company name as written`.
  final String params;

  /// Views the card can switch between; the first is the default.
  final List<String> views;

  /// When true the screen resolves `params["stock"]` through [StockResolver]
  /// before the card is created (`data["scrip"]` is then a [ScripRef]), and
  /// asks the user if it cannot.
  final bool needsStock;

  /// When true the screen resolves `params["fund"]` through [FundResolver]
  /// (`data["fund"]` is then a [FundRef]).
  final bool needsFund;

  /// Offline fallback matcher.
  final List<String> keywords;

  /// False for fixed-column tables that cannot fold into a half-width slot on a phone.
  /// Everything else lays itself out for the slot it gets (see AdaptiveRow / CardLayout).
  final bool narrow;
  final CatalogBuilder builder;
}

class GenUiCatalog {
  GenUiCatalog._();

  static const String unsupported = 'unsupported';

  static final Map<String, CatalogItem> items = <String, CatalogItem>{
    'portfolio': CatalogItem(
      id: 'portfolio',
      title: 'My portfolio',
      description: 'how the user\'s own investments are doing: portfolio value, profit or loss, today\'s change; the full list of stocks / mutual funds / bonds / US stocks they hold ("how are my mutual funds doing" → section mf); a trend or line chart comparing their stocks, their funds and Nifty over time',
      params: '"section": "all" | "stocks" | "mf" | "bonds" | "us" (which holdings the user asked for); "view": "trend" when the user asks for a line chart, performance over time, or to compare their stocks / funds / Nifty; "chart" for the invested-vs-current bars',
      views: PortfolioCard.views,
      keywords: <String>['portfolio', 'holdings', 'my investments', 'how am i doing', 'net worth', 'पोर्टफोलियो'],
      builder: (context, data) {
        final section = (data['section'] as String?)?.toLowerCase();
        var view = data['view'] as String?;
        const bySection = <String, String>{'stocks': 'stocks', 'equity': 'stocks', 'mf': 'funds', 'funds': 'funds', 'bonds': 'bonds', 'us': 'us'};
        if ((view == null || view == 'summary') && bySection.containsKey(section)) view = bySection[section];
        return PortfolioCard(section: section, view: view);
      },
    ),
    'stock': CatalogItem(
      id: 'stock',
      title: 'Stock details',
      description: 'anything about one listed company or stock: price, price chart / graph, how it is doing, returns, fundamentals/ratios, financial statements (P&L, balance sheet, cash flow, quarterly results), technicals, peers and analyst rating, similar stocks, news about that stock',
      params: '"stock": the company name or symbol exactly as the user wrote it',
      views: StockCard.views,
      needsStock: true,
      keywords: <String>['share price', 'stock', 'tell me about', 'fundamentals', 'technicals', 'news on'],
      builder: (context, data) => StockCard(ref: data['scrip'] as ScripRef, view: data['view'] as String?),
    ),
    'market': CatalogItem(
      id: 'market',
      title: 'Market today',
      description: 'overall market or index levels: Nifty, Sensex, Bank Nifty, how the market is doing today',
      views: MarketOverviewCard.views,
      keywords: <String>['market', 'nifty', 'sensex', 'indices', 'बाज़ार', 'bazaar'],
      builder: (context, data) => MarketOverviewCard(view: data['view'] as String?),
    ),
    'index': CatalogItem(
      id: 'index',
      title: 'Index',
      description: 'one market index by name (Nifty 50, Bank Nifty, Sensex, Nifty IT, Fin Nifty, Midcap...): its level, advances and declines, returns, and the stocks inside it with today\'s gainers and losers',
      params: '"index": index name as written; "view": "gainers" | "losers" | "all" if the user asks for the stocks in the index',
      views: IndexCard.views,
      keywords: <String>['nifty', 'sensex', 'bank nifty', 'index', 'constituents', 'stocks in nifty'],
      builder: (context, data) => IndexCard(indexId: data['indexId'] as String?, exchangeCode: _int(data['exchangeCode']), name: (data['name'] ?? data['index']) as String?, view: data['view'] as String?),
    ),
    'movers': CatalogItem(
      id: 'movers',
      title: 'Top gainers and losers',
      description: 'today\'s top gainers or top losers, biggest movers',
      params: '"kind": "gainers" | "losers"',
      views: MoversCard.views,
      keywords: <String>['gainers', 'losers', 'movers', 'top stocks'],
      builder: (context, data) => MoversCard(kind: data['kind'] as String?, view: data['view'] as String?),
    ),
    'order': CatalogItem(
      id: 'order',
      title: 'Buy or sell a stock',
      description: 'the user wants to buy, sell, purchase or exit shares of one stock (kharidna, bechna, le lo, bech do)',
      params: '"stock": name or symbol as written; "side": "buy" | "sell"; "qty": number of shares if said; "amount": rupees to invest if the user gave money instead of shares; "type": "market" | "limit" | "sl" | "gtt" if said; "price": limit price if said; "trigger": trigger price if said; "product": "delivery" | "intraday" | "mtf" | "t+5" if said; "validity": "day" | "ioc" | "gtd" if said; "amo": true if the user said after-market order; "target": target price if said; "stoploss": stop-loss price if said',
      needsStock: true,
      keywords: <String>['buy', 'sell', 'kharid', 'bech', 'le lo', 'purchase', 'gtt', 'trigx'],
      builder: (context, data) => OrderTicketCard(
        ref: data['scrip'] as ScripRef,
        side: data['side'] as String?,
        qty: _int(data['qty']),
        amount: _num(data['amount']),
        orderType: data['type'] as String?,
        price: _num(data['price']),
        trigger: _num(data['trigger']),
        product: data['product'] as String?,
        validity: data['validity'] as String?,
        amo: data['amo'] == true || '${data['amo']}'.toLowerCase() == 'true',
        target: _num(data['target']),
        stopLoss: _num(data['stoploss'] ?? data['stop_loss'] ?? data['sl']),
      ),
    ),
    'orders': CatalogItem(
      id: 'orders',
      title: 'My orders and positions',
      description: 'the user\'s order book (pending or completed orders today), open positions and MTM, GTT / TrigX / bracket orders, cancelling or modifying an order they already placed, or exiting / squaring off a position',
      params: '"stock": name or symbol if the user named one; "intent": "cancel" | "modify" | "exit" if the user wants to cancel or change an existing order or exit a position',
      views: OrdersCard.views,
      keywords: <String>['my orders', 'order book', 'pending orders', 'positions', 'mtm', 'cancel', 'modify', 'square off', 'exit position', 'my gtt'],
      builder: (context, data) => OrdersCard(
        view: data['view'] as String?,
        stock: data['stock'] as String?,
        intent: data['intent'] as String?,
      ),
    ),
    'funds': CatalogItem(
      id: 'funds',
      title: 'My funds',
      description: 'the user\'s trading balance, available margin, ledger balance, adding money to the account or withdrawing money to the bank',
      params: '"intent": "view" | "add" | "withdraw"; "amount": number in rupees if said',
      views: FundsCard.views,
      keywords: <String>['funds', 'balance', 'margin', 'add money', 'paise', 'withdraw', 'ledger'],
      builder: (context, data) => FundsCard(
        view: data['view'] as String? ?? FundsCard.viewForIntent(data['intent'] as String?),
        amount: (data['amount'] is num) ? (data['amount'] as num).toDouble() : double.tryParse('${data['amount'] ?? ''}'),
      ),
    ),
    'watchlist': CatalogItem(
      id: 'watchlist',
      title: 'My watchlist',
      description: 'the user\'s watchlists and the prices in them; creating a new watchlist; adding stocks to a watchlist; building a watchlist around a theme like bank stocks',
      params: '"name": watchlist name if said; "intent": "view" | "create" | "add"; "stocks": list of stock names exactly as written; "theme": the theme or sector words if the user asked for a themed list',
      views: WatchlistCard.views,
      keywords: <String>['watchlist', 'watch list'],
      builder: (context, data) => WatchlistCard(
        name: data['name'] as String?,
        view: data['view'] as String?,
        intent: data['intent'] as String?,
        stocks: _strings(data['stocks']),
        theme: data['theme'] as String?,
      ),
    ),
    'charges': CatalogItem(
      id: 'charges',
      title: 'Charges for an order',
      description: 'brokerage, taxes and charges to buy or sell a stock',
      params: '"stock": name or symbol as written; "side": "buy" | "sell"; "qty": shares if said; "product": "delivery" | "intraday" if said',
      needsStock: true,
      keywords: <String>['charges', 'brokerage', 'stt', 'taxes on'],
      builder: (context, data) => ChargesCard(ref: data['scrip'] as ScripRef, side: data['side'] as String?, product: data['product'] as String?, qty: _int(data['qty'])),
    ),
    'best': CatalogItem(
      id: 'best',
      title: 'Best performing stocks',
      description: 'best performing stocks over a period (1 week to 10 years)',
      params: '"period": "1W" | "1M" | "3M" | "6M" | "YTD" | "1Y" | "2Y" | "5Y" | "10Y" if said',
      views: BestPerformersCard.views,
      keywords: <String>['best performing', 'best stocks', 'top performers', 'multibagger'],
      builder: (context, data) => BestPerformersCard(period: data['period'] as String?, view: data['view'] as String?),
    ),
    'trending': CatalogItem(
      id: 'trending',
      title: 'Trending stocks',
      description: 'what is trending, most searched or most traded on the app today',
      params: '"kind": "searched" | "traded" if said',
      views: TrendingCard.views,
      keywords: <String>['trending', 'most searched', 'most traded', 'most bought', 'popular'],
      builder: (context, data) => TrendingCard(kind: data['kind'] as String? ?? data['view'] as String?),
    ),
    'etf': CatalogItem(
      id: 'etf',
      title: 'ETFs',
      description: 'exchange traded funds (ETFs) to invest in',
      keywords: <String>['etf', 'etfs'],
      builder: (context, data) => const EtfCard(),
    ),
    'fii': CatalogItem(
      id: 'fii',
      title: 'FII / DII activity',
      description: 'what foreign (FII) and domestic (DII) institutions are buying or selling',
      views: FiiDiiCard.views,
      keywords: <String>['fii', 'dii', 'institutional', 'foreign investors'],
      builder: (context, data) => FiiDiiCard(view: data['view'] as String?),
    ),
    'news': CatalogItem(
      id: 'news',
      title: 'Market news',
      description: 'general market news today, news about the user\'s portfolio stocks, or global news (not news about one named stock)',
      params: '"scope": "all" | "portfolio" | "global" if said',
      views: NewsCard.views,
      keywords: <String>['news today', 'market news', 'headlines', 'what happened'],
      builder: (context, data) => NewsCard(scope: data['scope'] as String? ?? data['view'] as String?),
    ),
    'mtf': CatalogItem(
      id: 'mtf',
      title: 'MTF stocks',
      description: 'stocks the user can buy on margin trading facility (MTF / pay later), MTF gainers or losers',
      params: '"kind": "gainers" | "losers" if said',
      views: MtfStocksCard.views,
      keywords: <String>['mtf', 'margin trading', 'pay later stocks'],
      builder: (context, data) => MtfStocksCard(kind: data['kind'] as String? ?? data['view'] as String?),
    ),
    'ipo': CatalogItem(
      id: 'ipo',
      title: 'IPOs',
      description: 'open, upcoming or recently listed IPOs',
      views: IpoCard.views,
      keywords: <String>['ipo', 'ipos', 'public issue'],
      builder: (context, data) => IpoCard(view: data['view'] as String?),
    ),
    'stock_sip': CatalogItem(
      id: 'stock_sip',
      title: 'Stock SIP',
      description: 'recurring purchase of SHARES of a listed company, only when the message literally says "stock SIP" or "share SIP" or names a listed company with the word stock. Any SIP in a fund / scheme / cap / ELSS / index fund is the fund action, never this one',
      params: '"stock": name or symbol as written if the user wants to start one; "amount": rupees per instalment if said; "qty": shares per instalment if said; "frequency": "daily" | "weekly" | "monthly" if said; "intent": "view" | "start"',
      keywords: <String>['stock sip', 'sip in', 'recurring'],
      builder: (context, data) => StockSipCard(stock: data['stock'] as String?, amount: _num(data['amount']), qty: _int(data['qty']), frequency: data['frequency'] as String?, intent: data['intent'] as String?),
    ),
    'mtfbook': CatalogItem(
      id: 'mtfbook',
      title: 'My MTF borrowings',
      description: 'how much the user has borrowed on MTF (margin trading / pay later), MTF holdings and interest charged',
      views: MtfBorrowCard.views,
      keywords: <String>['mtf interest', 'borrowed', 'mtf book', 'my mtf'],
      builder: (context, data) => MtfBorrowCard(view: data['view'] as String?),
    ),
    'pnl': CatalogItem(
      id: 'pnl',
      title: 'Profit and loss',
      description: 'realised profit and loss report for a period (this financial year, last FY, one year, all time)',
      params: '"period": "fy" | "lastfy" | "1y" | "all" if said',
      views: PnlCard.views,
      keywords: <String>['p&l', 'pnl', 'profit and loss', 'realised', 'capital gain'],
      builder: (context, data) => PnlCard(period: data['period'] as String? ?? data['view'] as String?),
    ),
    'baskets': CatalogItem(
      id: 'baskets',
      title: 'Stock baskets',
      description: 'the user\'s invested stock baskets, or baskets to explore',
      views: BasketsCard.views,
      keywords: <String>['basket', 'baskets'],
      builder: (context, data) => BasketsCard(view: data['view'] as String?),
    ),
    'profile': CatalogItem(
      id: 'profile',
      title: 'My profile and plan',
      description: 'the user\'s profile: client code, contact, segments, demat, bank, nominee, brokerage plan',
      keywords: <String>['profile', 'my plan', 'my account details', 'nominee', 'client code'],
      builder: (context, data) => const ProfileCard(),
    ),
    'settings': CatalogItem(
      id: 'settings',
      title: 'Settings',
      description: 'account settings: order preferences, notification preferences',
      keywords: <String>['settings', 'preferences'],
      builder: (context, data) => const SettingsCard(),
    ),
    'fund': CatalogItem(
      id: 'fund',
      title: 'Mutual fund details',
      description: 'anything about one named mutual fund scheme: NAV, returns, rank, risk, expense ratio, NAV chart, holdings, similar funds, or investing in it',
      params: '"fund": the fund name exactly as written; "amount": rupees if the user wants to invest; "mode": "sip" | "lumpsum" if said; "frequency": "monthly" | "quarterly" if said',
      views: FundCard.views,
      needsFund: true,
      keywords: <String>['fund', 'mutual fund', 'nav', 'sip in', 'invest in'],
      builder: (context, data) => FundCard(ref: data['fund'] as FundRef, view: data['view'] as String? ?? (data['amount'] != null || data['mode'] != null ? 'invest' : null), amount: _num(data['amount']), mode: data['mode'] as String?, frequency: data['frequency'] as String?),
    ),
    'find_funds': CatalogItem(
      id: 'find_funds',
      title: 'Find mutual funds',
      description: 'find or list mutual funds by category or theme (small cap, mid cap, large cap, flexi cap, ELSS / tax saving, index, debt, liquid, gold), best or top funds, most bought funds, new fund offers (NFO)',
      params: '"query": the category or theme words as written; "kind": "category" | "mostbought" | "nfo"',
      views: FindFundsCard.views,
      keywords: <String>['best funds', 'top funds', 'cap funds', 'elss', 'index fund', 'nfo', 'mutual funds'],
      builder: (context, data) => FindFundsCard(query: data['query'] as String?, kind: data['kind'] as String?, view: data['view'] as String?),
    ),
    'mf_baskets': CatalogItem(
      id: 'mf_baskets',
      title: 'Mutual fund baskets',
      description: 'ready-made mutual fund baskets (curated combinations of funds)',
      keywords: <String>['mf basket', 'fund basket', 'mutual fund baskets'],
      builder: (context, data) => const MfBasketsCard(),
    ),
    'compare_funds': CatalogItem(
      id: 'compare_funds',
      title: 'Compare mutual funds',
      description: 'compare two or more named mutual funds side by side (returns, rank, risk, NAV chart)',
      params: '"funds": list of the fund names exactly as written',
      keywords: <String>['compare fund', 'compare mutual', 'vs fund'],
      builder: (context, data) => CompareFundsCard(refs: (data['fundRefs'] as List<FundRef>?) ?? const <FundRef>[]),
    ),
    'mf_sips': CatalogItem(
      id: 'mf_sips',
      title: 'My mutual fund SIPs and orders',
      description: 'the user\'s SIPs (mutual fund SIPs; "my SIPs" means this), pausing or cancelling one, and mutual fund order history',
      views: MfSipsCard.views,
      keywords: <String>['my sips', 'sips', 'mf orders', 'mutual fund orders', 'pause sip', 'cancel sip'],
      builder: (context, data) => MfSipsCard(view: data['view'] as String?),
    ),
    'mf_action': CatalogItem(
      id: 'mf_action',
      title: 'Redeem or switch a fund',
      description: 'redeem / withdraw / sell units of a mutual fund the user holds, or switch from one fund to another',
      params: '"fund": the fund name as written; "action": "redeem" | "switch"; "amount": rupees if said; "to": the target fund name for a switch if said',
      needsFund: true,
      keywords: <String>['redeem', 'withdraw from fund', 'switch fund', 'sell fund'],
      builder: (context, data) => MfActionCard(ref: data['fund'] as FundRef, action: data['action'] as String?, amount: _num(data['amount']), toFund: data['to'] as String?),
    ),
    'option_chain': CatalogItem(
      id: 'option_chain',
      narrow: false,
      title: 'Option chain',
      description: 'option chain, strikes, call/put prices, open interest by strike, greeks, PCR, max pain for an index (Nifty, Bank Nifty, Fin Nifty, Midcap Nifty, Sensex) or an F&O stock; "buy a Nifty 24000 call" also starts here',
      params: '"underlying": index name or stock as written (default Nifty); "expiry": "weekly" | "monthly" | "next" | a date as written, if said; "strikes": number of strikes each side if said; "strike": the strike price if the user named one (e.g. 25000); "type": "call" | "put" if said; "side": "buy" | "sell" if the user wants to trade it; "view": "oi" when the user asks for open interest, OI chart or support/resistance of the chain',
      views: OptionChainCard.views,
      keywords: <String>['option chain', 'strike', 'call', 'put', 'ce', 'pe', 'open interest', 'oi', 'greeks', 'max pain', 'pcr'],
      builder: (context, data) => OptionChainCard(
        underlying: data['underlying'] as String?,
        expiry: data['expiry'] as String?,
        strikes: _int(data['strikes']),
        view: data['view'] as String?,
        strike: _num(data['strike']),
        optionType: data['type'] as String?,
        side: data['side'] as String?,
      ),
    ),
    'fno_pulse': CatalogItem(
      id: 'fno_pulse',
      title: 'F&O pulse',
      description: 'derivatives market mood: India VIX, put-call ratio, F&O advance/decline, and Motilal Oswal\'s index view with support and resistance levels ("how is Nifty looking", "Nifty support resistance", "market sentiment F&O")',
      params: '"index": index name if said (default Nifty)',
      views: FnoPulseCard.views,
      keywords: <String>['vix', 'pcr', 'put call ratio', 'support', 'resistance', 'sentiment', 'nifty view', 'levels'],
      builder: (context, data) => FnoPulseCard(index: data['index'] as String?, view: data['view'] as String?),
    ),
    'fno_movers': CatalogItem(
      id: 'fno_movers',
      narrow: false,
      title: 'F&O movers',
      description: 'most active options or futures contracts, open-interest gainers and losers, options in momentum (trending options right now)',
      params: '"kind": "active" | "oi_gainers" | "oi_losers" | "momentum"; "segment": "options" | "futures" (default options); "timeframe": "5m" | "15m" | "30m" | "1h" | "1d" for momentum if said; "underlying": index name if said',
      views: FnoMoversCard.views,
      keywords: <String>['most active', 'active options', 'oi gainers', 'oi losers', 'oi buildup', 'momentum options', 'trending options', 'active futures'],
      builder: (context, data) => FnoMoversCard(kind: data['kind'] as String?, segment: data['segment'] as String?, timeframe: data['timeframe'] as String?, view: data['view'] as String?, underlying: data['underlying'] as String?),
    ),
    'fno_positions': CatalogItem(
      id: 'fno_positions',
      title: 'F&O positions',
      description: 'the user\'s open futures and options positions with live mark-to-market (MTM), booked P&L, margin, and exiting a derivative position',
      params: '',
      views: FnoPositionsCard.views,
      keywords: <String>['mtm', 'f&o positions', 'option positions', 'futures positions', 'square off', 'mark to market'],
      builder: (context, data) => FnoPositionsCard(view: data['view'] as String?),
    ),
    'fno_strategies': CatalogItem(
      id: 'fno_strategies',
      title: 'Option strategy ideas',
      description: 'ready-made option strategies from Predict & Trade (bull call spread, iron condor, straddle, etc.) with max profit, max loss, breakeven and funds needed; "I am bullish on Nifty, what should I trade"',
      params: '"sentiment": "bullish" | "bearish" | "neutral" if said',
      views: FnoStrategiesCard.views,
      keywords: <String>['strategy', 'spread', 'straddle', 'strangle', 'iron condor', 'bullish', 'bearish', 'predict and trade'],
      builder: (context, data) => FnoStrategiesCard(sentiment: (data['sentiment'] ?? data['view']) as String?),
    ),
    'futures': CatalogItem(
      id: 'futures',
      narrow: false,
      title: 'Futures',
      description: 'futures contracts for an index or stock: price per expiry, basis (premium/discount to spot), open interest, lot size, and buying or selling a future',
      params: '"underlying": index name or stock as written (default Nifty)',
      keywords: <String>['futures', 'fut', 'basis', 'premium', 'discount', 'rollover', 'lot size'],
      builder: (context, data) => FuturesCard(underlying: data['underlying'] as String?),
    ),
    'networth': CatalogItem(
      id: 'networth',
      title: 'Net worth',
      description: 'the user\'s total net worth or total wealth across all assets and cash; portfolios held with other brokers (external, account aggregator, "track my other investments"); family portfolio',
      params: '"view": "external" when asking about other brokers / linked portfolios, "family" for family members\' portfolios',
      views: NetWorthCard.views,
      keywords: <String>['net worth', 'total wealth', 'external portfolio', 'other brokers', 'family portfolio', 'account aggregator'],
      builder: (context, data) => NetWorthCard(view: data['view'] as String?),
    ),
    'day_movers': CatalogItem(
      id: 'day_movers',
      title: 'Today in my portfolio',
      description: 'what moved in the user\'s own portfolio today: which of their holdings gained or lost, what is dragging or lifting the portfolio today, today\'s P&L by holding',
      params: '"kind": "gainers" | "losers" | "all"',
      views: DayMoversCard.views,
      keywords: <String>['dragging', 'today in my portfolio', 'my gainers today', 'my losers today', 'why is my portfolio down'],
      builder: (context, data) => DayMoversCard(kind: data['kind'] as String?, view: data['view'] as String?),
    ),
    'dividends': CatalogItem(
      id: 'dividends',
      title: 'Dividends & corporate events',
      description: 'dividends the user received or will receive, upcoming corporate actions on their holdings (dividend, bonus, split, record date, ex-date), dividend history by year',
      params: '"view": "upcoming" | "received" | "history"; "period": "this year" | "last year" | "all" if said',
      views: DividendsCard.views,
      keywords: <String>['dividend', 'bonus', 'split', 'record date', 'ex-date', 'corporate action', 'payout'],
      builder: (context, data) => DividendsCard(view: data['view'] as String?, period: data['period'] as String?),
    ),
    'nontradable': CatalogItem(
      id: 'nontradable',
      title: 'Non-tradable holdings',
      description: 'the user\'s non-tradable, suspended, delisted, locked-in or unlisted holdings in demat',
      params: '',
      keywords: <String>['non-tradable', 'non tradable', 'delisted', 'suspended', 'locked in', 'unlisted shares'],
      builder: (context, data) => const NonTradableCard(),
    ),
    'portfolio_risk': CatalogItem(
      id: 'portfolio_risk',
      title: 'Portfolio health check',
      description: 'is the user\'s portfolio too risky or concentrated, diversification, sector or market-cap exposure, stock concentration, fund overlap, underperforming funds, risk flags and insights on their holdings',
      params: '"view": "stocks" | "funds"',
      views: RiskCard.views,
      keywords: <String>['risky', 'risk', 'diversified', 'diversification', 'concentration', 'overlap', 'sector exposure', 'health check', 'insights'],
      builder: (context, data) => RiskCard(view: data['view'] as String?),
    ),
    'tax': CatalogItem(
      id: 'tax',
      title: 'Tax on my investments',
      description: 'how much capital-gains tax the user will pay this financial year on realised gains (short-term vs long-term, intraday, F&O), and how to save tax: loss harvesting, LTCG exemption, ELSS',
      params: '"view": "save" when the user asks how to save or reduce tax, else "summary"; "period": "last year" if said',
      views: TaxCard.views,
      keywords: <String>['tax', 'capital gains', 'stcg', 'ltcg', 'save tax', 'tax harvesting', '80c'],
      builder: (context, data) => TaxCard(view: data['view'] as String?, period: data['period'] as String?),
    ),
    'commodity_positions': CatalogItem(
      id: 'commodity_positions',
      title: 'Commodity positions',
      description: 'the user\'s commodity (MCX: gold, silver, crude, natural gas) or currency positions and their MTM',
      params: '"segment": "commodity" | "currency"',
      keywords: <String>['commodity', 'mcx', 'gold position', 'silver', 'crude', 'currency position'],
      builder: (context, data) => FnoPositionsCard(assetType: (data['segment'] as String?) == 'currency' ? 'Currency' : 'Commodity'),
    ),
    'research_calls': CatalogItem(
      id: 'research_calls',
      title: 'Research calls',
      description: 'stock recommendations and trading calls from Motilal Oswal research: investment picks, intraday / BTST / positional trading calls, live open calls, recently closed calls and their outcome; for stocks, F&O or commodities',
      params: '"kind": "investment" | "trading" | "live" | "closed"; "segment": "equity" | "fno" | "commodity" if said; "horizon": "intraday" | "btst" | "short" | "positional" | "long" if said',
      views: ResearchCallsCard.views,
      keywords: <String>['recommendation', 'recommend', 'research call', 'trading call', 'intraday call', 'btst', 'picks', 'what to buy', 'tips', 'closed calls'],
      builder: (context, data) => ResearchCallsCard(kind: (data['kind'] ?? data['view']) as String?, segment: data['segment'] as String?, horizon: data['horizon'] as String?),
    ),
    'research_reports': CatalogItem(
      id: 'research_reports',
      title: 'Research reports',
      description: 'Motilal Oswal research reports in general: latest company reports with target price, market analysis and sector reports, today\'s market outlook ("explain the latest research report", "market outlook today")',
      params: '"view": "company" | "market" | "outlook"',
      views: ResearchReportsCard.views,
      keywords: <String>['research report', 'reports', 'market outlook', 'sector report', 'market analysis', 'morning report'],
      builder: (context, data) => ResearchReportsCard(view: data['view'] as String?),
    ),
    'stock_research': CatalogItem(
      id: 'stock_research',
      title: 'Research report on a stock',
      description: 'the research report, analyst target price, rating and key points for ONE named company ("research report on JSL", "what does research say about Tata Motors", "target price for Infosys")',
      params: '"stock": company name or symbol as written',
      needsStock: true,
      keywords: <String>['research report on', 'target price', 'analyst view', 'what does research say'],
      builder: (context, data) => ResearchReportsCard(ref: data['scrip'] as ScripRef, view: 'company'),
    ),
    'ready_portfolios': CatalogItem(
      id: 'ready_portfolios',
      title: 'Ready-to-invest portfolios',
      description: 'ready-made, research-built portfolios and baskets to invest in: stock baskets by analysts, expert baskets, fund baskets',
      params: '"view": "stocks" | "experts" | "funds"',
      views: ReadyPortfoliosCard.views,
      keywords: <String>['ready made portfolio', 'ready-to-invest', 'research basket', 'model portfolio', 'expert basket'],
      builder: (context, data) => ReadyPortfoliosCard(view: data['view'] as String?),
    ),
    'research_experts': CatalogItem(
      id: 'research_experts',
      title: 'Research experts',
      description: 'who the research experts / analysts are, their specialisation and experience',
      params: '',
      keywords: <String>['research experts', 'analysts', 'who is behind research', 'research team'],
      builder: (context, data) => const ResearchExpertsCard(),
    ),
    'research_assistant': CatalogItem(
      id: 'research_assistant',
      title: 'Research Assistant',
      description: 'an open research question answered from Motilal Oswal research by the Research Assistant AI: a research snapshot or summary of a company or sector, "what does research think about X", comparisons, outlook questions that no other card answers',
      params: '"question": the user\'s question as written',
      keywords: <String>['research snapshot', 'research summary', 'ask research', 'research assistant', 'what does research think'],
      builder: (context, data) => ResearchAssistantCard(question: (data['question'] ?? '') as String),
    ),
    'option_brain': CatalogItem(
      id: 'option_brain',
      title: 'Option Brain',
      description: 'Option Brain / Trading Guide Signals: research-generated option strategies and signals with legs, entry, target and stop loss',
      params: '',
      keywords: <String>['option brain', 'trading guide', 'tgs', 'signals', 'trendicator'],
      builder: (context, data) => const OptionBrainCard(),
    ),
    // ---- AI-native: no classic screen; composed from the user's own data ----
    'what_if': CatalogItem(
      id: 'what_if',
      title: 'What if',
      description: 'a what-if on the user\'s holdings: "what if the market falls 10%", "what happens to my portfolio if Nifty drops 5%", "what if HDFC Bank falls 20%" (re-prices their holdings by that move)',
      params: '"shock": the percentage move as a signed number (fall → negative, e.g. -10); "stock": company name if the move is about one stock',
      keywords: <String>['what if', 'falls by', 'drops by', 'crash'],
      builder: (context, data) => WhatIfCard(shock: data['shock'] is num ? data['shock'] as num : num.tryParse('${data['shock'] ?? ''}'.replaceAll('%', '')), scrip: data['scrip'] as ScripRef?),
    ),
    'pf_vs_market': CatalogItem(
      id: 'pf_vs_market',
      title: 'My portfolio vs the market',
      description: 'whether the user is beating the market: their portfolio\'s return against Nifty over a period ("am I beating the market", "my portfolio vs nifty", "how do I compare with the index this year")',
      params: '"period": "1M" | "3M" | "6M" | "1Y" | "3Y" | "5Y" if said; "benchmark": "Nifty 50" | "Nifty 100" | "Nifty 500" if said',
      keywords: <String>['beating the market', 'vs the market', 'vs nifty', 'against nifty', 'compared to the market'],
      builder: (context, data) => PfVsMarketCard(period: data['period'] as String?, benchmark: data['benchmark'] as String?),
    ),
    'stock_vs_index': CatalogItem(
      id: 'stock_vs_index',
      title: 'A stock vs the market',
      description: 'ONE named stock\'s returns against an index, period by period ("how has Infosys done against Nifty", "is TCS beating the market", "Reliance vs Sensex")',
      params: '"stock": company name or symbol as written; "index": index name if said (default Nifty 50)',
      needsStock: true,
      narrow: false,
      keywords: <String>['against nifty', 'vs nifty', 'vs sensex', 'beating the market'],
      builder: (context, data) => StockVsIndexCard(scrip: data['scrip'] as ScripRef, index: data['index'] as String?),
    ),
    'stock_compare': CatalogItem(
      id: 'stock_compare',
      title: 'Compare stocks',
      description: 'two or three named stocks side by side: price, returns, P/E, P/B, ROE ("compare TCS and Infosys", "HDFC Bank vs ICICI Bank", "which is better, Tata Motors or M&M")',
      params: '"stocks": list of the company names or symbols exactly as written (2 or 3)',
      narrow: false,
      keywords: <String>['compare', ' vs ', 'which is better'],
      builder: (context, data) => StockCompareCard(scrips: (data['scrips'] as List<ScripRef>?) ?? const <ScripRef>[]),
    ),
    'explain': CatalogItem(
      id: 'explain',
      title: 'Explain',
      description: 'explain a market or investing term in plain words, with the user\'s own number where one exists ("what is P/E", "explain XIRR", "what does PCR mean", "what is LTCG", "explain P/E for HDFC Bank")',
      params: '"term": the term asked about, as written (e.g. "P/E", "XIRR", "max pain"); "stock": company name if the user named one',
      keywords: <String>['what is ', 'what does', 'explain', 'meaning of', 'kya hota hai'],
      builder: (context, data) => ExplainCard(term: data['term'] as String?, scrip: data['scrip'] as ScripRef?),
    ),
    'rebalance': CatalogItem(
      id: 'rebalance',
      title: 'How should I rebalance?',
      description: 'how the user should rebalance: which holdings or sectors are overweight and by how much ("how should I rebalance", "what should I trim", "am I too concentrated in one stock")',
      keywords: <String>['rebalance', 'overweight', 'trim', 'concentrated'],
      builder: (context, data) => const RebalanceCard(),
    ),
    'goal': CatalogItem(
      id: 'goal',
      title: 'Plan a goal',
      description: 'a goal or SIP calculator: the monthly SIP needed for a target amount in N years, or what a monthly amount grows to ("I want 50 lakh in 10 years", "how much should I invest monthly for a car in 3 years", "what will 5000 a month become in 15 years")',
      params: '"target": rupees as a number if a target amount was said (convert lakh/crore); "years": number of years; "monthly": rupees per month if said; "rate": expected yearly return % if said; "name": the goal (car, house, retirement) if said',
      keywords: <String>['goal', 'sip calculator', 'how much should i invest', 'retire', 'corpus'],
      builder: (context, data) => GoalCard(target: data['target'] as num?, years: data['years'] as num?, monthly: data['monthly'] as num?, rate: data['rate'] as num?, name: data['name'] as String?),
    ),
    'upcoming': CatalogItem(
      id: 'upcoming',
      title: "What's coming up",
      description: 'what is coming up for the user: SIP debits, ex-dates and record dates on their stocks ("what is coming up", "anything due this month", "upcoming SIP dates", "my calendar")',
      params: '"days": number of days ahead if said (default 30)',
      keywords: <String>['coming up', 'upcoming', 'due this', 'calendar', 'this week', 'next week'],
      builder: (context, data) => UpcomingCard(days: data['days'] as num?),
    ),
    'failed_sips': CatalogItem(
      id: 'failed_sips',
      title: 'Failed SIP payments',
      description: 'SIP instalments that failed or were rejected, with a way to pay them ("did any SIP fail", "failed sips", "missed sip payment", "sip bounce")',
      keywords: <String>['failed sip', 'sip failed', 'missed sip', 'sip bounce', 'sip rejected'],
      builder: (context, data) => const FailedSipsCard(),
    ),
    // ---- Alerts: rules kept on the device and watched on the live feed; classic page for server-side ----
    'price_alert': CatalogItem(
      id: 'price_alert',
      title: 'Price alert',
      description: 'set a price alert on ONE named stock ("alert me when Yes Bank crosses 22", "tell me if HDFC Bank falls below 1850", "notify me when Infosys goes above 1500"); optionally with an order to prepare when it fires ("…and get a buy order ready for 5")',
      params: '"stock": name or symbol as written; "condition": "above" | "below"; "price": the trigger price as a number; "action": "buy" | "sell" if an order should be prepared on trigger; "qty": shares for that order if said',
      needsStock: true,
      keywords: <String>['alert me when', 'alert me if', 'notify me when', 'crosses', 'price alert'],
      builder: (context, data) => PriceAlertCard(scrip: data['scrip'] as ScripRef, condition: data['condition'] as String?, price: _num(data['price']), action: data['action'] as String?, qty: _num(data['qty'])),
    ),
    'smart_alert': CatalogItem(
      id: 'smart_alert',
      title: 'Smart alert',
      description: 'an alert on a GROUP of stocks ("alert me if any of my bank stocks falls 5% in a day", "tell me if any of my holdings rises 3%", "watch TCS and Infosys for a 2% drop"), optionally with a prepared order on one stock ("if HDFC Bank goes below 1850, get a buy order ready for 5 more")',
      params: '"group": "my holdings" | "my bank stocks" | "my IT stocks" if the user named a group; "stocks": list of stock names if the user listed them instead; "pct": the percentage move as a number; "direction": "falls" | "rises"; "order_stock": the stock for a prepared order if said; "order_price": its trigger price; "order_condition": "above" | "below"; "action": "buy" | "sell"; "qty": shares if said',
      keywords: <String>['any of my', 'falls 5', 'in a day', 'smart alert', 'get a buy order ready'],
      builder: (context, data) => SmartAlertCard(
        group: data['group'] as String?,
        scrips: (data['scrips'] as List<ScripRef>?) ?? const <ScripRef>[],
        pct: _num(data['pct']),
        direction: data['direction'] as String?,
        orderScrip: data['order_scrip'] as ScripRef?,
        orderPrice: _num(data['order_price']),
        orderCondition: data['order_condition'] as String?,
        action: data['action'] as String?,
        qty: _num(data['qty']),
      ),
    ),
    'results_alert': CatalogItem(
      id: 'results_alert',
      title: 'Results alert',
      description: 'be told or emailed when ONE named company posts its quarterly results ("email me when HDFC Bank posts results", "tell me when Infosys declares results")',
      params: '"stock": name or symbol as written; "email": true if the user asked for an email',
      needsStock: true,
      keywords: <String>['posts results', 'declares results', 'quarterly results alert', 'when results'],
      builder: (context, data) => ResultsAlertCard(scrip: data['scrip'] as ScripRef, email: data['email'] != false),
    ),
    'report_sub': CatalogItem(
      id: 'report_sub',
      title: 'Research report subscription',
      description: 'get research reports on named stocks as soon as they are out, by email or in the app ("mail me research reports on Infosys and TCS", "subscribe me to reports on Reliance")',
      params: '"stocks": list of the company names exactly as written; "email": true if the user asked for mail',
      keywords: <String>['mail me research', 'research reports on', 'subscribe', 'as soon as they'],
      builder: (context, data) => ReportSubCard(scrips: (data['scrips'] as List<ScripRef>?) ?? const <ScripRef>[], email: data['email'] != false),
    ),
    'alerts': CatalogItem(
      id: 'alerts',
      title: 'My alerts',
      description: 'the alerts and subscriptions the user has set ("my alerts", "show my alerts", "what alerts do I have", "remove my alerts")',
      views: AlertsCard.views,
      keywords: <String>['my alerts', 'show alerts', 'alerts i have'],
      builder: (context, data) => AlertsCard(view: data['view'] as String?),
    ),
    'notifications': CatalogItem(
      id: 'notifications',
      title: 'Notifications',
      description: 'the user\'s app notifications and alerts received',
      params: '"category": a category word if the user said one',
      keywords: <String>['notifications', 'alerts received', 'any updates'],
      builder: (context, data) => NotificationsCard(category: data['category'] as String?),
    ),
  };

  static List<String> get actionIds => items.keys.toList(growable: false);

  /// Whether [component] can take half the width on a phone.
  static bool halfOk(String component) => items[component]?.narrow ?? true;

  static Widget render(BuildContext context, String component, Map<String, dynamic> data) {
    final item = items[component];
    if (item == null) return const SizedBox.shrink();
    return item.builder(context, normalizeView(item, data));
  }

  /// The LLM may name a view loosely ("chart", "graph", "table"); map it onto
  /// the view names this card actually has, so the request is honoured.
  static Map<String, dynamic> normalizeView(CatalogItem item, Map<String, dynamic> data) {
    final v = (data['view'] as String?)?.toLowerCase().trim();
    if (v == null || item.views.isEmpty || item.views.contains(v)) return data;
    const trendy = <String>{'line', 'trend', 'compare', 'comparison', 'performance', 'growth'};
    const graphy = <String>{'chart', 'graph', 'bar', 'bars', 'plot', 'visual'};
    const listy = <String>{'list', 'table', 'rows', 'text'};
    String? pick;
    if (trendy.contains(v)) pick = item.views.cast<String?>().firstWhere((x) => x == 'trend', orElse: () => null);
    if (pick == null && graphy.contains(v)) pick = item.views.cast<String?>().firstWhere((x) => x == 'chart' || x == 'bars', orElse: () => null);
    if (listy.contains(v)) pick = item.views.cast<String?>().firstWhere((x) => x == 'list' || x == 'table' || x == 'tiles', orElse: () => null);
    pick ??= item.views.cast<String?>().firstWhere((x) => x!.startsWith(v) || v.startsWith(x), orElse: () => null);
    final out = Map<String, dynamic>.from(data);
    if (pick == null) out.remove('view'); else out['view'] = pick;
    return out;
  }
}
