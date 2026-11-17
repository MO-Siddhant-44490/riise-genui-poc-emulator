# Query → component → API

From an observability run on the UAT emulator (16 Nov 2026). "Model selected" is the catalog
action and parameters the router returned; "API" is what the rendered card then called.

| Query | Model selected (parameters) | API called by the card |
|---|---|---|
| aaj mera portfolio kyu gira | portfolio (kind: losers, view: list) | wms/v2/api/Portfolio/Get |
| is it a good time to get into IT stocks | research_assistant (question) | research/startsession |
| which of my funds did best this month | mf_sips (view: sips) | transaction/api/MfReport/CommonApi |
| Reliance ka chart dikhao | stock (Reliance, view: chart) | wms/v2/api/Search, then live feed only |
| how has Infosys share moved, show as graph | stock (Infosys, view: chart) | Search, then live feed only |
| Tata Motors ka fundamental analysis | stock (Tata Motors, view: fundamentals) | Quote/Fundamental?sections=Ratios |
| HDFC Bank ke peers kaun hai | stock (HDFC Bank, view: peers) | StockDetail/PeerComparison |
| ICICI Bank ka 1 saal ka return | stock (ICICI Bank, view: returns) | Quote/Overview?sections=Returns |
| Infosys vs TCS kaun better | stock_compare (stocks: Infosys, TCS) | Quote/Overview (Returns) and Quote/Fundamental (Ratios) for each |
| nifty 50 ke top gainers | index (Nifty 50, view: gainers) | Quote/Index/Detail, Quote/Index/Stocks |
| sabse zyada girne wale shares | movers (kind: losers) | Markets/MarketMoversFilters, Markets/Equity |
| banknifty option chain max pain | option_chain (Bank Nifty, view: chain) | Quote/OptionChain/Dashboard, Quote/OptionChain, Explore/OptionOI |
| where is max pain on bank nifty | fno_pulse (index: Bank Nifty) | Explore/FNO, Explore/IndexView, IndexAdvice/AdminData |
| kal ke liye koi intraday idea | research_calls (trading, intraday) | cmsapi/v2/api/Research/Landing |
| available margin for trading | funds (view: breakdown) | TradingReport/MarginReport |
| kitna paisa bacha hai trading ke liye | funds (view) | User/AvailableMargin, FundTransfer/MaxFunds |
| ping me if Infosys goes under 1400 | price_alert (Infosys, below, 1400) | Search, then live feed |
| what if the market crashes 8 percent | what_if (shock: -8) | Portfolio/Get, Portfolio/Equity/Detail |
| what is my XIRR right now | pf_vs_market (benchmark: Nifty 50) | StockAnalysis and MfAnalysis BenchmarkPerformanceTrend, Quote/Index/Detail |
| 2500 a month in some flexi cap scheme | find_funds (query: flexi cap) | master/Master/GetDatabyType, GetCollection |
| give me a full picture of Maruti plus the market mood | plan: stock (Maruti) + fno_pulse (Nifty 50) | Search, Explore/FNO, Explore/IndexView |
| HDFC buy | order (HDFC, buy), by rules with no model call | Search, Quote/PlaceOrderData |
| order a pizza for me | unsupported, with a redirect reply | none |

Plain buy and sell commands skip the model and open the order ticket directly. Chart and snapshot
views rely on the live price feed, which is down on UAT, so those cards show blanks there.
