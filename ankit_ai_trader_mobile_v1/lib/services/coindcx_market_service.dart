import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../models/trading_models.dart';
import 'persistence_db.dart';

class MarketScannerThresholdConfig {
  final double maxSpreadBps;
  final double minVolume24hQuote;
  final double maxSingleTradeRiskUsdt;
  final double availableCapitalUsdt;
  final Map<String, double> minVolumeByQuoteCurrency;

  const MarketScannerThresholdConfig({
    this.maxSpreadBps = 35.0,
    this.minVolume24hQuote = 10000.0,
    this.maxSingleTradeRiskUsdt = 1.0,
    this.availableCapitalUsdt = 100.0,
    this.minVolumeByQuoteCurrency = const {
      'USDT': 10000.0,
      'INR': 500000.0,
      'BTC': 0.25,
      'ETH': 5.0,
    },
  });

  double? minVolumeForQuote(String quoteCurrency) {
    final upper = quoteCurrency.trim().toUpperCase();
    if (minVolumeByQuoteCurrency.containsKey(upper)) {
      return minVolumeByQuoteCurrency[upper];
    }
    return null;
  }
}

class MarketCatalogueSnapshot {
  final List<CoinDcxMarketRecord> allMarkets;
  final int? lastSuccessfulRefreshMs;
  final bool isUsingCachedCatalogue;
  final bool isCatalogueFresh;

  const MarketCatalogueSnapshot({
    required this.allMarkets,
    this.lastSuccessfulRefreshMs,
    this.isUsingCachedCatalogue = false,
    this.isCatalogueFresh = false,
  });

  int get totalDiscoveredCount => allMarkets.length;

  int get activeMarketsCount =>
      allMarkets.where((m) => m.isActiveStatus).length;

  int get inactiveMarketsCount =>
      allMarkets.where((m) => !m.isActiveStatus).length;

  int get eligibleMarketsCount =>
      allMarkets.where((m) => m.isEligibleForPaperTrading).length;

  int get newlyListedCount =>
      allMarkets.where((m) => m.isNewlyListed).length;

  Map<String, int> get countsByQuoteCurrency {
    final map = <String, int>{};
    for (final m in allMarkets) {
      final q = m.quoteCurrency.isEmpty ? 'OTHER' : m.quoteCurrency;
      map[q] = (map[q] ?? 0) + 1;
    }
    return map;
  }

  List<CoinDcxMarketRecord> filterMarkets({
    String searchQuery = '',
    String quoteCurrencyFilter = 'ALL',
  }) {
    final qSearch = searchQuery.trim().toUpperCase();
    final qFilter = quoteCurrencyFilter.trim().toUpperCase();
    return allMarkets.where((m) {
      if (qFilter != 'ALL') {
        if (qFilter == 'OTHER') {
          if (['USDT', 'INR', 'BTC', 'ETH']
              .contains(m.quoteCurrency.toUpperCase())) {
            return false;
          }
        } else if (m.quoteCurrency.toUpperCase() != qFilter) {
          return false;
        }
      }
      if (qSearch.isNotEmpty) {
        final matchSym = m.symbol.toUpperCase().contains(qSearch);
        final matchPair = m.pair.toUpperCase().contains(qSearch);
        final matchCoindcx = m.coindcxName.toUpperCase().contains(qSearch);
        final matchBase =
            m.targetCurrencyShortName.toUpperCase().contains(qSearch);
        final matchQuote =
            m.baseCurrencyShortName.toUpperCase().contains(qSearch);
        if (!matchSym &&
            !matchPair &&
            !matchCoindcx &&
            !matchBase &&
            !matchQuote) {
          return false;
        }
      }
      return true;
    }).toList();
  }
}

class CoinDcxMarketService {
  static const String activeMarketsUrl =
      'https://api.coindcx.com/exchange/v1/markets';
  static const String marketsDetailsUrl =
      'https://api.coindcx.com/exchange/v1/markets_details';
  static const String tickerUrl = 'https://api.coindcx.com/exchange/ticker';
  static const String candlesBaseUrl =
      'https://public.coindcx.com/market_data/candles';

  final http.Client _httpClient;
  final PersistenceDatabase? persistence;
  final MarketScannerThresholdConfig thresholdConfig;
  final int requestTimeoutMs;
  final int maxRetries;

  final StreamController<Map<String, LiveMarketTicker>> _tickerStreamCtrl =
      StreamController<Map<String, LiveMarketTicker>>.broadcast();

  Set<String> _previouslySeenPairs = {};
  bool _hasCompletedInitialDiscovery = false;
  MarketCatalogueSnapshot _latestCatalogue =
      const MarketCatalogueSnapshot(allMarkets: []);
  int _rateLimitBackoffUntilMs = 0;
  int _consecutive429Count = 0;

  CoinDcxMarketService({
    http.Client? httpClient,
    this.persistence,
    this.thresholdConfig = const MarketScannerThresholdConfig(),
    this.requestTimeoutMs = 8000,
    this.maxRetries = 2,
  }) : _httpClient = httpClient ?? http.Client();

  Stream<Map<String, LiveMarketTicker>> get tickerStream =>
      _tickerStreamCtrl.stream;

  MarketCatalogueSnapshot get latestCatalogue => _latestCatalogue;

  static Set<String> parseActiveMarketsResponse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return {};
    return decoded
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  static double? _parseSafeDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) {
      final d = v.toDouble();
      return (d.isNaN || d.isInfinite) ? null : d;
    }
    if (v is String) {
      final s = v.trim();
      if (s.isEmpty) return null;
      final d = double.tryParse(s);
      if (d == null || d.isNaN || d.isInfinite) return null;
      return d;
    }
    return null;
  }

  static int? _parseSafeInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static Map<String, LiveMarketTicker> parseAllTickersResponse(
    String body, {
    required int receivedAtMs,
  }) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return {};
    final result = <String, LiveMarketTicker>{};

    for (final raw in decoded) {
      if (raw is! Map) continue;
      final marketName = (raw['market']?.toString() ?? '').trim();
      if (marketName.isEmpty || marketName.toUpperCase() == 'FSNINR') continue;

      final lastPrice = _parseSafeDouble(raw['last_price']);
      final bid = _parseSafeDouble(raw['bid']);
      final ask = _parseSafeDouble(raw['ask']);
      final high = _parseSafeDouble(raw['high']) ?? lastPrice;
      final low = _parseSafeDouble(raw['low']) ?? lastPrice;
      final vol = _parseSafeDouble(raw['volume']) ?? 0.0;
      final chg = _parseSafeDouble(raw['change_24_hour']) ?? 0.0;
      final rawTs = _parseSafeInt(raw['timestamp']);

      if (lastPrice == null ||
          lastPrice <= 0 ||
          bid == null ||
          bid <= 0 ||
          ask == null ||
          ask <= 0 ||
          ask < bid ||
          vol < 0) {
        continue;
      }

      final tsMs = rawTs != null && rawTs > 0
          ? (rawTs < 10000000000 ? rawTs * 1000 : rawTs)
          : receivedAtMs;

      final ticker = LiveMarketTicker(
        symbol: marketName,
        lastPrice: lastPrice,
        bid: bid,
        ask: ask,
        high24h: high ?? lastPrice,
        low24h: low ?? lastPrice,
        volume24h: vol,
        change24hPct: chg,
        timestampMs: tsMs,
      );

      result[marketName] = ticker;
      result[marketName.toUpperCase()] = ticker;
      if (marketName == 'BTCUSDT') {
        result['B-BTC_USDT'] = ticker;
      } else if (marketName == 'ETHUSDT') {
        result['B-ETH_USDT'] = ticker;
      }
    }
    return result;
  }

  static LiveMarketTicker? matchTickerForMarket({
    required String symbol,
    required String coindcxName,
    required String pair,
    required Map<String, LiveMarketTicker> tickersByKey,
  }) {
    for (final candidate in [
      symbol,
      coindcxName,
      pair,
      symbol.toUpperCase(),
      coindcxName.toUpperCase(),
      pair.toUpperCase(),
    ]) {
      if (candidate.isNotEmpty && tickersByKey.containsKey(candidate)) {
        return tickersByKey[candidate];
      }
    }
    if (pair.contains('-') && pair.contains('_')) {
      final afterDash = pair.split('-').last;
      final collapsed = afterDash.replaceAll('_', '');
      if (tickersByKey.containsKey(collapsed)) {
        return tickersByKey[collapsed];
      }
      if (tickersByKey.containsKey(afterDash)) {
        return tickersByKey[afterDash];
      }
    }
    return null;
  }

  static ({MarketEligibilityStatus status, String reason}) evaluateEligibility({
    required CoinDcxMarketRecord record,
    required MarketScannerThresholdConfig config,
    required int nowMs,
  }) {
    if (!record.hasValidSpecifications) {
      return (
        status: MarketEligibilityStatus.invalidMarketSpecifications,
        reason: 'Missing or invalid exchange market specifications',
      );
    }
    if (!record.isActiveStatus) {
      return (
        status: MarketEligibilityStatus.inactive,
        reason: 'Market is ${record.status} or absent from active markets list',
      );
    }
    final ticker = record.latestTicker;
    if (ticker == null || !ticker.isFresh(nowMs, maxAgeMs: 300000)) {
      return (
        status: MarketEligibilityStatus.dataUnavailable,
        reason: 'Live ticker data unavailable or stale',
      );
    }
    if (ticker.spreadBps > config.maxSpreadBps) {
      return (
        status: MarketEligibilityStatus.excessiveSpread,
        reason:
            'Spread ${ticker.spreadBps.toStringAsFixed(1)} bps > max ${config.maxSpreadBps.toStringAsFixed(1)} bps',
      );
    }

    final minVolForQuote = config.minVolumeForQuote(record.quoteCurrency);
    if (minVolForQuote == null) {
      return (
        status: MarketEligibilityStatus.pendingThresholdConfiguration,
        reason:
            'Quote currency ${record.quoteCurrency} pending liquidity threshold configuration',
      );
    }
    if (ticker.volume24h < minVolForQuote) {
      return (
        status: MarketEligibilityStatus.insufficientLiquidity,
        reason:
            '24h volume ${ticker.volume24h.toStringAsFixed(2)} < min ${minVolForQuote.toStringAsFixed(2)} ${record.quoteCurrency}',
      );
    }

    // Check minimum order size vs $100 account / $1 risk rules
    final price = ticker.ask > 0 ? ticker.ask : ticker.lastPrice;
    final minQtyForNotional =
        price > 0 ? (record.minNotional / price) : record.minQuantity;
    final rawMinNeeded = math.max(record.minQuantity, minQtyForNotional);
    final ceiledSteps = record.step > 0
        ? ((rawMinNeeded / record.step) - 1e-9).ceilToDouble()
        : 1.0;
    final minFeasibleQty = record.step > 0
        ? math.max(record.minQuantity, ceiledSteps * record.step)
        : rawMinNeeded;
    final minFeasibleNotional = minFeasibleQty * price;

    if (minFeasibleNotional > config.availableCapitalUsdt * 0.95) {
      return (
        status: MarketEligibilityStatus.belowMinimumOrderRequirements,
        reason:
            'Min feasible order notional (${minFeasibleNotional.toStringAsFixed(2)}) exceeds available paper capital',
      );
    }

    // Check if even at a standard 2% stop distance, minFeasibleQty exceeds maxSingleTradeRiskUsdt ($1.00)
    final estimatedMinStopRisk = minFeasibleNotional * 0.02;
    if (estimatedMinStopRisk > config.maxSingleTradeRiskUsdt * 1.35 &&
        record.quoteCurrency.toUpperCase() == 'USDT') {
      return (
        status: MarketEligibilityStatus.rejectedByRiskControls,
        reason:
            'Min order notional \$${minFeasibleNotional.toStringAsFixed(2)} requires >\$${config.maxSingleTradeRiskUsdt.toStringAsFixed(2)} risk at 2% stop distance',
      );
    }

    return (
      status: MarketEligibilityStatus.eligibleForPaperTrading,
      reason:
          'Eligible: Active, Spread ${ticker.spreadBps.toStringAsFixed(1)} bps, Vol ${ticker.volume24h.toStringAsFixed(0)} ${record.quoteCurrency}',
    );
  }

  static List<CoinDcxMarketRecord> buildCompleteCatalogue({
    required Set<String> activeSymbols,
    required String marketsDetailsBody,
    required Map<String, LiveMarketTicker> tickersByKey,
    required int nowMs,
    Set<String> previouslySeenPairs = const {},
    bool isFirstDiscoveryRun = true,
    MarketScannerThresholdConfig thresholdConfig =
        const MarketScannerThresholdConfig(),
  }) {
    final decoded = jsonDecode(marketsDetailsBody);
    if (decoded is! List) return const [];

    final byPair = <String, CoinDcxMarketRecord>{};
    final processedSymbols = <String>{};

    for (final raw in decoded) {
      if (raw is! Map) continue;
      final coindcxName = (raw['coindcx_name']?.toString() ?? '').trim();
      final symbol = (raw['symbol']?.toString() ?? coindcxName).trim();
      final pair = (raw['pair']?.toString() ?? '').trim();
      final ecode = (raw['ecode']?.toString() ?? '').trim();
      final baseShort =
          (raw['base_currency_short_name']?.toString() ?? '').trim();
      final targetShort =
          (raw['target_currency_short_name']?.toString() ?? '').trim();
      final baseName = (raw['base_currency_name']?.toString() ?? '').trim();
      final targetName = (raw['target_currency_name']?.toString() ?? '').trim();
      final status = (raw['status']?.toString() ?? 'inactive').trim();

      final basePrec = _parseSafeInt(raw['base_currency_precision']) ?? -1;
      final targetPrec = _parseSafeInt(raw['target_currency_precision']) ?? -1;
      final minQty = _parseSafeDouble(raw['min_quantity']) ?? -1.0;
      final maxQty = _parseSafeDouble(raw['max_quantity']) ?? -1.0;
      final maxQtyMkt =
          _parseSafeDouble(raw['max_quantity_market']) ?? maxQty;
      final step = _parseSafeDouble(raw['step']) ?? -1.0;
      final minNotional = _parseSafeDouble(raw['min_notional']) ?? -1.0;
      final minPrice = _parseSafeDouble(raw['min_price']) ?? 0.0;
      final maxPrice = _parseSafeDouble(raw['max_price']) ?? 0.0;

      final orderTypes = <String>[];
      if (raw['order_types'] is List) {
        for (final o in (raw['order_types'] as List)) {
          final s = o?.toString().trim() ?? '';
          if (s.isNotEmpty) orderTypes.add(s);
        }
      }

      final canonicalKey = pair.isNotEmpty ? pair : symbol;
      if (canonicalKey.isEmpty) continue;

      final inActiveList = activeSymbols.isEmpty ||
          activeSymbols.contains(symbol) ||
          activeSymbols.contains(coindcxName) ||
          activeSymbols.contains(pair);

      final matchedTicker = matchTickerForMarket(
        symbol: symbol,
        coindcxName: coindcxName,
        pair: pair,
        tickersByKey: tickersByKey,
      );

      final isNewlyListed = !isFirstDiscoveryRun &&
          previouslySeenPairs.isNotEmpty &&
          !previouslySeenPairs.contains(canonicalKey);

      final draft = CoinDcxMarketRecord(
        coindcxName: coindcxName,
        symbol: symbol,
        pair: pair,
        ecode: ecode,
        baseCurrencyShortName: baseShort,
        targetCurrencyShortName: targetShort,
        baseCurrencyName: baseName,
        targetCurrencyName: targetName,
        status: status,
        baseCurrencyPrecision: basePrec,
        targetCurrencyPrecision: targetPrec,
        minQuantity: minQty,
        maxQuantity: maxQty,
        maxQuantityMarket: maxQtyMkt,
        step: step,
        minNotional: minNotional,
        minPrice: minPrice,
        maxPrice: maxPrice,
        orderTypes: orderTypes,
        latestTicker: matchedTicker,
        latestDataTimestampMs: matchedTicker?.timestampMs,
        lastMetadataRefreshMs: nowMs,
        isNewlyListed: isNewlyListed,
        isInActiveMarketsList: inActiveList,
      );

      final elig = evaluateEligibility(
        record: draft,
        config: thresholdConfig,
        nowMs: nowMs,
      );

      final finalized = draft.copyWith(
        eligibilityStatus: elig.status,
        eligibilityReason: elig.reason,
      );

      // Deduplicate by canonical pair, preferring active/eligible record
      if (!byPair.containsKey(canonicalKey) ||
          (!byPair[canonicalKey]!.isActiveStatus && finalized.isActiveStatus)) {
        byPair[canonicalKey] = finalized;
      }
      if (symbol.isNotEmpty) processedSymbols.add(symbol);
      if (coindcxName.isNotEmpty) processedSymbols.add(coindcxName);
    }

    // Any symbol in activeSymbols missing from markets_details must NOT have exchange identifiers guessed!
    for (final actSym in activeSymbols) {
      if (!processedSymbols.contains(actSym) && !byPair.containsKey(actSym)) {
        byPair[actSym] = CoinDcxMarketRecord(
          coindcxName: actSym,
          symbol: actSym,
          pair: '', // Do not guess pair or ecode!
          ecode: '',
          baseCurrencyShortName: '',
          targetCurrencyShortName: '',
          status: 'active',
          baseCurrencyPrecision: 0,
          targetCurrencyPrecision: 0,
          minQuantity: 0.0,
          maxQuantity: 0.0,
          maxQuantityMarket: 0.0,
          step: 0.0,
          minNotional: 0.0,
          minPrice: 0.0,
          maxPrice: 0.0,
          orderTypes: const [],
          lastMetadataRefreshMs: nowMs,
          isInActiveMarketsList: true,
          eligibilityStatus:
              MarketEligibilityStatus.invalidMarketSpecifications,
          eligibilityReason:
              'Symbol $actSym present in /exchange/v1/markets but missing from /exchange/v1/markets_details',
        );
      }
    }

    final list = byPair.values.toList()
      ..sort((a, b) => a.symbol.compareTo(b.symbol));
    return list;
  }

  Future<http.Response?> _getWithRetry(String url, {required int nowMs}) async {
    if (nowMs < _rateLimitBackoffUntilMs) {
      return null;
    }
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final resp = await _httpClient
            .get(Uri.parse(url))
            .timeout(Duration(milliseconds: requestTimeoutMs));
        if (resp.statusCode == 200) {
          _consecutive429Count = 0;
          _rateLimitBackoffUntilMs = 0;
          return resp;
        }
        if (resp.statusCode == 429) {
          _consecutive429Count++;
          final backoffMs = math.min(60000, 2000 * (1 << _consecutive429Count));
          _rateLimitBackoffUntilMs = nowMs + backoffMs;
          return null;
        }
      } catch (_) {
        if (attempt == maxRetries) return null;
      }
    }
    return null;
  }

  Future<MarketCatalogueSnapshot> refreshMarketCatalogue({
    bool force = false,
    int? nowMs,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final activeResp = await _getWithRetry(activeMarketsUrl, nowMs: now);
    final detailsResp = await _getWithRetry(marketsDetailsUrl, nowMs: now);
    final tickerResp = await _getWithRetry(tickerUrl, nowMs: now);

    if (activeResp != null && detailsResp != null) {
      try {
        final activeSet = parseActiveMarketsResponse(activeResp.body);
        final tickers = tickerResp != null
            ? parseAllTickersResponse(tickerResp.body, receivedAtMs: now)
            : <String, LiveMarketTicker>{};

        final built = buildCompleteCatalogue(
          activeSymbols: activeSet,
          marketsDetailsBody: detailsResp.body,
          tickersByKey: tickers,
          nowMs: now,
          previouslySeenPairs: _previouslySeenPairs,
          isFirstDiscoveryRun: !_hasCompletedInitialDiscovery,
          thresholdConfig: thresholdConfig,
        );

        if (built.isNotEmpty) {
          // Mark any previously seen pair that disappeared from built as inactive
          final currentKeys = built
              .map((m) => m.pair.isNotEmpty ? m.pair : m.symbol)
              .toSet();
          for (final prev in _latestCatalogue.allMarkets) {
            final k = prev.pair.isNotEmpty ? prev.pair : prev.symbol;
            if (k.isNotEmpty && !currentKeys.contains(k)) {
              built.add(
                prev.copyWith(
                  status: 'inactive',
                  isInActiveMarketsList: false,
                  eligibilityStatus: MarketEligibilityStatus.inactive,
                  eligibilityReason: 'Market delisted or removed from active catalogue',
                ),
              );
            }
          }

          _previouslySeenPairs = built
              .where((m) => m.isActiveStatus)
              .map((m) => m.pair.isNotEmpty ? m.pair : m.symbol)
              .toSet();
          _hasCompletedInitialDiscovery = true;

          _latestCatalogue = MarketCatalogueSnapshot(
            allMarkets: built,
            lastSuccessfulRefreshMs: now,
            isUsingCachedCatalogue: false,
            isCatalogueFresh: true,
          );

          if (persistence != null) {
            await persistence!.saveDiscoveredMarkets(
              built,
              refreshedAtMs: now,
            );
          }
          return _latestCatalogue;
        }
      } catch (_) {}
    }

    // Fallback to cached catalogue in SQLite or memory (never marked fresh!)
    if (persistence != null) {
      final cached = await persistence!.loadDiscoveredMarkets();
      final lastMs = await persistence!.getLastMarketCatalogueRefreshMs();
      if (cached.isNotEmpty) {
        _latestCatalogue = MarketCatalogueSnapshot(
          allMarkets: cached,
          lastSuccessfulRefreshMs: lastMs,
          isUsingCachedCatalogue: true,
          isCatalogueFresh: false,
        );
        return _latestCatalogue;
      }
    }

    if (_latestCatalogue.allMarkets.isNotEmpty) {
      _latestCatalogue = MarketCatalogueSnapshot(
        allMarkets: _latestCatalogue.allMarkets,
        lastSuccessfulRefreshMs: _latestCatalogue.lastSuccessfulRefreshMs,
        isUsingCachedCatalogue: true,
        isCatalogueFresh: false,
      );
    }
    return _latestCatalogue;
  }

  Future<Map<String, LiveMarketTicker>> fetchLiveTickers({int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final resp = await _getWithRetry(tickerUrl, nowMs: now);
    if (resp == null) return const {};
    try {
      final parsed = parseAllTickersResponse(resp.body, receivedAtMs: now);
      if (parsed.isNotEmpty && !_tickerStreamCtrl.isClosed) {
        _tickerStreamCtrl.add(parsed);
      }
      return parsed;
    } catch (_) {
      return const {};
    }
  }

  Future<List<Candle>> fetchClosedCandles({
    required String pair,
    required String interval,
    required int nowMs,
    int limit = 120,
  }) async {
    final url = '$candlesBaseUrl?pair=${Uri.encodeComponent(pair)}&interval=${Uri.encodeComponent(interval)}&limit=$limit';
    final resp = await _getWithRetry(url, nowMs: nowMs);
    if (resp == null) return const [];
    return parseClosedCandlesResponse(
      resp.body,
      interval: interval,
      nowMs: nowMs,
    );
  }

  static int _intervalDurationMs(String interval) {
    switch (interval) {
      case '1m':
        return 60 * 1000;
      case '5m':
        return 5 * 60 * 1000;
      case '15m':
        return 15 * 60 * 1000;
      case '1h':
        return 60 * 60 * 1000;
      case '4h':
        return 4 * 60 * 60 * 1000;
      case '1d':
        return 24 * 60 * 60 * 1000;
      default:
        return 15 * 60 * 1000;
    }
  }

  static List<Candle> parseClosedCandlesResponse(
    String body, {
    required String interval,
    required int nowMs,
  }) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final durMs = _intervalDurationMs(interval);
    final candles = <Candle>[];

    for (final item in decoded) {
      if (item is! Map) continue;
      final open = _parseSafeDouble(item['open']);
      final high = _parseSafeDouble(item['high']);
      final low = _parseSafeDouble(item['low']);
      final close = _parseSafeDouble(item['close']);
      final vol = _parseSafeDouble(item['volume']) ?? 0.0;
      final rawTime = _parseSafeInt(item['time']);
      if (open == null ||
          high == null ||
          low == null ||
          close == null ||
          rawTime == null) {
        continue;
      }
      final openMs = (rawTime < 10000000000 && rawTime * 1000 <= nowMs + 86400000) ? rawTime * 1000 : rawTime;
      final closeMs = openMs + durMs;
      final c = Candle(
        openTimeMs: openMs,
        closeTimeMs: closeMs,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: vol,
      );
      if (c.isClosedAt(nowMs)) {
        candles.add(c);
      }
    }
    candles.sort((a, b) => a.openTimeMs.compareTo(b.openTimeMs));
    return candles;
  }

  void dispose() {
    if (!_tickerStreamCtrl.isClosed) {
      _tickerStreamCtrl.close();
    }
  }
}
