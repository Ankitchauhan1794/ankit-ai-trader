import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../models/trading_models.dart';
import 'persistence_db.dart';

/// Stage 47.1 Section 7: Scanner & Eligibility Threshold Configuration.
/// Uses existing USDT scanner thresholds (25 bps max spread, 100.0 min 24h volume)
/// and explicitly reports `pendingThresholdConfiguration` for quote currencies
/// that do not yet have approved volume/risk thresholds configured.
class MarketScannerThresholdConfig {
  final double maxAllowedSpreadBps;
  final Map<String, double> minVolume24hByQuoteCurrency;
  final Set<String> riskApprovedQuoteCurrencies;
  final double maxAllowedNotionalUsdt;
  final int maxTickerAgeMs;

  const MarketScannerThresholdConfig({
    this.maxAllowedSpreadBps = 25.0,
    this.minVolume24hByQuoteCurrency = const {
      'USDT': 100.0,
    },
    this.riskApprovedQuoteCurrencies = const {
      'USDT',
    },
    this.maxAllowedNotionalUsdt = 100.0,
    this.maxTickerAgeMs = 120000,
  });
}

/// Stage 47.1 Section 4, 6, 7 & 8: Complete Market Catalogue Snapshot.
class MarketCatalogueSnapshot {
  final List<CoinDcxMarketRecord> allMarkets;
  final List<String> newlyListedPairs;
  final List<String> newlyInactivePairs;
  final int? lastSuccessfulRefreshMs;
  final bool isUsingCachedCatalogue;
  final bool isCatalogueFresh;
  final String? lastRefreshError;

  const MarketCatalogueSnapshot({
    required this.allMarkets,
    this.newlyListedPairs = const [],
    this.newlyInactivePairs = const [],
    this.lastSuccessfulRefreshMs,
    this.isUsingCachedCatalogue = false,
    this.isCatalogueFresh = false,
    this.lastRefreshError,
  });

  int get totalDiscoveredCount => allMarkets.length;
  int get activeMarketsCount =>
      allMarkets.where((m) => m.isActiveStatus).length;
  int get inactiveMarketsCount =>
      allMarkets.where((m) => !m.isActiveStatus).length;
  int get eligibleMarketsCount =>
      allMarkets.where((m) => m.isEligibleForPaperTrading).length;
  int get rejectedMarketsCount => allMarkets
      .where((m) =>
          m.eligibilityStatus !=
          MarketEligibilityStatus.eligibleForPaperTrading)
      .length;

  List<CoinDcxMarketRecord> get eligibleMarkets =>
      allMarkets.where((m) => m.isEligibleForPaperTrading).toList();

  Map<String, int> get countByQuoteCurrency {
    final counts = <String, int>{};
    for (final m in allMarkets) {
      final q = m.baseCurrencyShortName.isEmpty
          ? 'UNKNOWN'
          : m.baseCurrencyShortName;
      counts[q] = (counts[q] ?? 0) + 1;
    }
    return counts;
  }

  List<CoinDcxMarketRecord> filterMarkets({
    String searchQuery = '',
    String quoteCurrencyFilter = 'ALL',
  }) {
    final q = searchQuery.trim().toUpperCase();
    final quoteFilter = quoteCurrencyFilter.trim().toUpperCase();

    return allMarkets.where((m) {
      if (quoteFilter.isNotEmpty && quoteFilter != 'ALL') {
        if (quoteFilter == 'OTHER') {
          const mainQuotes = {'INR', 'USDT', 'BTC', 'ETH'};
          if (mainQuotes.contains(m.baseCurrencyShortName.toUpperCase())) {
            return false;
          }
        } else if (m.baseCurrencyShortName.toUpperCase() != quoteFilter) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      return m.symbol.toUpperCase().contains(q) ||
          m.coindcxName.toUpperCase().contains(q) ||
          m.pair.toUpperCase().contains(q) ||
          m.targetCurrencyShortName.toUpperCase().contains(q) ||
          m.baseCurrencyShortName.toUpperCase().contains(q);
    }).toList();
  }
}

class CoinDcxMarketService {
  static const String marketsUrl = 'https://api.coindcx.com/exchange/v1/markets';
  static const String marketsDetailsUrl =
      'https://api.coindcx.com/exchange/v1/markets_details';
  static const String tickerUrl = 'https://api.coindcx.com/exchange/ticker';
  static const String candlesUrl =
      'https://public.coindcx.com/market_data/candles';
  static const String wsUrl = 'wss://stream.coindcx.com';

  final http.Client _httpClient;
  final PersistenceDatabase? _persistence;
  final MarketScannerThresholdConfig thresholdConfig;
  final int minCatalogueRefreshIntervalMs;
  final int maxApiRetries;
  final int initialRetryBackoffMs;

  WebSocket? _ws;
  Timer? _wsReconnectTimer;
  int _wsReconnectAttempts = 0;
  bool _wsDisposed = false;

  final Map<String, LiveMarketTicker> _latestTickers = {};
  final Map<String, LiveMarketTicker> _rawTickersByMarketKey = {};
  final Map<String, CoinDcxMarketRecord> _catalogueByPair = {};
  MarketCatalogueSnapshot _latestCatalogueSnapshot =
      const MarketCatalogueSnapshot(allMarkets: []);
  Future<MarketCatalogueSnapshot>? _inFlightCatalogueRefresh;
  int? _lastSuccessfulCatalogueRefreshMs;
  int _rateLimitBackoffUntilMs = 0;

  final StreamController<Map<String, LiveMarketTicker>>
      _tickerStreamController =
      StreamController<Map<String, LiveMarketTicker>>.broadcast();

  CoinDcxMarketService({
    http.Client? httpClient,
    PersistenceDatabase? persistence,
    this.thresholdConfig = const MarketScannerThresholdConfig(),
    this.minCatalogueRefreshIntervalMs = 60000,
    this.maxApiRetries = 2,
    this.initialRetryBackoffMs = 50,
  })  : _httpClient = httpClient ?? http.Client(),
        _persistence = persistence;

  Stream<Map<String, LiveMarketTicker>> get tickerStream =>
      _tickerStreamController.stream;

  Map<String, LiveMarketTicker> get latestTickers =>
      Map.unmodifiable(_latestTickers);

  MarketCatalogueSnapshot get latestCatalogueSnapshot =>
      _latestCatalogueSnapshot;

  Map<String, CoinDcxMarketRecord> get catalogueByPair =>
      Map.unmodifiable(_catalogueByPair);

  static double? _parseFiniteDouble(dynamic value) {
    if (value == null) return null;
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value.toString().trim());
    if (parsed == null || parsed.isNaN || parsed.isInfinite) return null;
    return parsed;
  }

  static int? _parseFiniteInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) {
      if (value.isNaN || value.isInfinite) return null;
      return value.toInt();
    }
    return int.tryParse(value.toString().trim());
  }

  /// Stage 47.1 Section 3A: Parse GET https://api.coindcx.com/exchange/v1/markets
  Set<String> parseActiveMarketsResponse(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! List) {
      throw const FormatException(
        'Expected JSON array from /exchange/v1/markets',
      );
    }
    final activeSymbols = <String>{};
    for (final item in decoded) {
      if (item is String) {
        final trimmed = item.trim();
        if (trimmed.isNotEmpty) {
          activeSymbols.add(trimmed);
        }
      }
    }
    return activeSymbols;
  }

  /// Stage 47.1 Section 3C: Parse all tickers from GET https://api.coindcx.com/exchange/ticker
  Map<String, LiveMarketTicker> parseAllTickersResponse(
    String responseBody, {
    required int nowMs,
  }) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! List) return {};

    final result = <String, LiveMarketTicker>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final market = (item['market']?.toString() ?? '').trim();
      if (market.isEmpty) continue;

      final lastPrice = _parseFiniteDouble(item['last_price']) ?? 0.0;
      if (lastPrice <= 0) continue;

      final rawBid = _parseFiniteDouble(item['bid']);
      final rawAsk = _parseFiniteDouble(item['ask']);
      final bid = (rawBid != null && rawBid > 0) ? rawBid : lastPrice;
      final ask = (rawAsk != null && rawAsk > 0) ? rawAsk : lastPrice;
      if (ask < bid) continue;

      final rawHigh = _parseFiniteDouble(item['high']);
      final rawLow = _parseFiniteDouble(item['low']);
      final high24h = (rawHigh != null && rawHigh > 0) ? rawHigh : lastPrice;
      final low24h = (rawLow != null && rawLow > 0) ? rawLow : lastPrice;
      final volume24h = math.max(0.0, _parseFiniteDouble(item['volume']) ?? 0.0);
      final change24hPct = _parseFiniteDouble(item['change_24_hour']) ?? 0.0;
      final rawTs = _parseFiniteInt(item['timestamp']) ?? 0;
      final tsMs = rawTs > 0
          ? (rawTs < 10000000000 ? rawTs * 1000 : rawTs)
          : nowMs;

      result[market] = LiveMarketTicker(
        symbol: market,
        lastPrice: lastPrice,
        bid: bid,
        ask: ask,
        high24h: high24h,
        low24h: low24h,
        volume24h: volume24h,
        change24hPct: change24hPct,
        timestampMs: tsMs,
      );
    }
    return result;
  }

  /// Backward-compatible ticker parser used by existing Stage 12–46 callers & tests,
  /// plus dynamic mapping for all discovered catalogue pairs.
  Map<String, LiveMarketTicker> parseLiveTickersResponse(
    String responseBody, {
    required int nowMs,
  }) {
    final rawByMarket = parseAllTickersResponse(responseBody, nowMs: nowMs);
    if (rawByMarket.isEmpty) return {};

    _rawTickersByMarketKey
      ..clear()
      ..addAll(rawByMarket);

    final mapped = <String, LiveMarketTicker>{};

    // Map any market already known in the discovered catalogue using its exact CoinDCX identifiers
    for (final record in _catalogueByPair.values) {
      final matched = matchTickerForMarketRecord(record, rawByMarket);
      if (matched != null) {
        mapped[record.pair] = matched;
      }
    }

    // Preserve canonical B-BTC_USDT and B-ETH_USDT keys for existing callers when present in ticker payload
    final btcTicker = rawByMarket['B-BTC_USDT'] ?? rawByMarket['BTCUSDT'];
    if (btcTicker != null) {
      mapped['B-BTC_USDT'] = LiveMarketTicker(
        symbol: 'B-BTC_USDT',
        lastPrice: btcTicker.lastPrice,
        bid: btcTicker.bid,
        ask: btcTicker.ask,
        high24h: btcTicker.high24h,
        low24h: btcTicker.low24h,
        volume24h: btcTicker.volume24h,
        change24hPct: btcTicker.change24hPct,
        timestampMs: btcTicker.timestampMs,
      );
    }
    final ethTicker = rawByMarket['B-ETH_USDT'] ?? rawByMarket['ETHUSDT'];
    if (ethTicker != null) {
      mapped['B-ETH_USDT'] = LiveMarketTicker(
        symbol: 'B-ETH_USDT',
        lastPrice: ethTicker.lastPrice,
        bid: ethTicker.bid,
        ask: ethTicker.ask,
        high24h: ethTicker.high24h,
        low24h: ethTicker.low24h,
        volume24h: ethTicker.volume24h,
        change24hPct: ethTicker.change24hPct,
        timestampMs: ethTicker.timestampMs,
      );
    }

    return mapped;
  }

  /// Stage 47.1 Section 3 & 4: Match ticker to market record using ONLY exact CoinDCX identifiers
  /// (`pair`, `symbol`, `coindcx_name`) without guessing exchange codes.
  LiveMarketTicker? matchTickerForMarketRecord(
    CoinDcxMarketRecord record,
    Map<String, LiveMarketTicker> tickersByMarketKey,
  ) {
    final match = tickersByMarketKey[record.symbol] ??
        tickersByMarketKey[record.coindcxName] ??
        tickersByMarketKey[record.pair];
    if (match == null) return null;
    return LiveMarketTicker(
      symbol: record.pair.isNotEmpty ? record.pair : record.symbol,
      lastPrice: match.lastPrice,
      bid: match.bid,
      ask: match.ask,
      high24h: match.high24h,
      low24h: match.low24h,
      volume24h: match.volume24h,
      change24hPct: match.change24hPct,
      timestampMs: match.timestampMs,
    );
  }

  /// Stage 47.1 Section 7: Classify market eligibility using existing scanner/risk rules.
  ({MarketEligibilityStatus status, String reason}) classifyMarketEligibility({
    required CoinDcxMarketRecord record,
    required int nowMs,
    MarketScannerThresholdConfig? config,
  }) {
    final cfg = config ?? thresholdConfig;

    if (!record.hasValidSpecifications) {
      return (
        status: MarketEligibilityStatus.invalidMarketSpecifications,
        reason:
            'Invalid or incomplete market specifications in /exchange/v1/markets_details',
      );
    }

    if (!record.isActiveStatus) {
      return (
        status: MarketEligibilityStatus.inactive,
        reason:
            'Market status is ${record.status} (inActiveList=${record.isInActiveMarketsList})',
      );
    }

    final ticker = record.latestTicker;
    if (ticker == null ||
        ticker.lastPrice <= 0 ||
        ticker.bid <= 0 ||
        ticker.ask <= 0 ||
        ticker.ask < ticker.bid ||
        !ticker.isFresh(nowMs, maxAgeMs: cfg.maxTickerAgeMs)) {
      return (
        status: MarketEligibilityStatus.dataUnavailable,
        reason: 'Fresh live ticker bid/ask/price data is unavailable',
      );
    }

    final quote = record.baseCurrencyShortName.toUpperCase();
    final minVolThreshold = cfg.minVolume24hByQuoteCurrency[quote];
    if (minVolThreshold == null ||
        !cfg.riskApprovedQuoteCurrencies.contains(quote)) {
      return (
        status: MarketEligibilityStatus.pendingThresholdConfiguration,
        reason:
            'Pending threshold configuration for quote currency $quote (active market discovered & tracked)',
      );
    }

    final spreadBps = ticker.spreadBps;
    if (spreadBps > cfg.maxAllowedSpreadBps) {
      return (
        status: MarketEligibilityStatus.excessiveSpread,
        reason:
            'Spread ${spreadBps.toStringAsFixed(1)} bps exceeds max ${cfg.maxAllowedSpreadBps.toStringAsFixed(1)} bps',
      );
    }

    if (ticker.volume24h < minVolThreshold) {
      return (
        status: MarketEligibilityStatus.insufficientLiquidity,
        reason:
            '24h volume ${ticker.volume24h.toStringAsFixed(2)} below minimum $minVolThreshold',
      );
    }

    // Check minimum order requirements against paper account & market rules
    final minQtyNotional = record.minQuantity * ticker.ask;
    final requiredMinNotional = math.max(record.minNotional, minQtyNotional);
    final minFeasibleQty =
        record.roundQuantityToPrecision(requiredMinNotional / ticker.ask);
    final candidateQty = math.max(record.minQuantity, minFeasibleQty);
    final orderValidation = record.validateOrder(
      quantity: candidateQty,
      price: ticker.ask,
    );
    if (!orderValidation.valid) {
      return (
        status: MarketEligibilityStatus.belowMinimumOrderRequirements,
        reason:
            orderValidation.reason ?? 'Below minimum order size/notional rules',
      );
    }

    if (requiredMinNotional > cfg.maxAllowedNotionalUsdt) {
      return (
        status: MarketEligibilityStatus.rejectedByRiskControls,
        reason:
            'Minimum order notional \$${requiredMinNotional.toStringAsFixed(2)} exceeds \$${cfg.maxAllowedNotionalUsdt.toStringAsFixed(2)} risk cap',
      );
    }

    return (
      status: MarketEligibilityStatus.eligibleForPaperTrading,
      reason:
          'Eligible for paper-trading evaluation (Spread ${spreadBps.toStringAsFixed(1)} bps, Vol ${ticker.volume24h.toStringAsFixed(1)})',
    );
  }

  /// Stage 47.1 Section 3B, 4, 5 & 7: Parse and combine active markets, markets_details, and tickers
  /// into a complete normalized catalogue, detecting newly listed and newly inactive markets.
  MarketCatalogueSnapshot buildCompleteMarketCatalogue({
    required Set<String> activeMarketsFromEndpoint,
    required String marketsDetailsJson,
    required Map<String, LiveMarketTicker> tickersByMarketKey,
    required int nowMs,
    Map<String, CoinDcxMarketRecord>? previousCatalogueByPair,
  }) {
    final decodedDetails = jsonDecode(marketsDetailsJson);
    if (decodedDetails is! List) {
      throw const FormatException(
        'Expected JSON array from /exchange/v1/markets_details',
      );
    }

    final prevMap = previousCatalogueByPair ?? _catalogueByPair;
    final hadPriorCatalogue = prevMap.isNotEmpty;
    final nextByPair = <String, CoinDcxMarketRecord>{};
    final matchedSymbolsInDetails = <String>{};
    final newlyListed = <String>[];
    final newlyInactive = <String>[];

    for (final raw in decodedDetails) {
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
      final rawStatus = (raw['status']?.toString() ?? 'inactive').trim();

      final canonicalKey = pair.isNotEmpty ? pair : symbol;
      if (canonicalKey.isEmpty) continue;

      if (symbol.isNotEmpty) matchedSymbolsInDetails.add(symbol);
      if (coindcxName.isNotEmpty) matchedSymbolsInDetails.add(coindcxName);
      if (pair.isNotEmpty) matchedSymbolsInDetails.add(pair);

      final basePrec = _parseFiniteInt(raw['base_currency_precision']) ?? -1;
      final targetPrec =
          _parseFiniteInt(raw['target_currency_precision']) ?? -1;
      final minQty = _parseFiniteDouble(raw['min_quantity']) ?? -1.0;
      final maxQty = _parseFiniteDouble(raw['max_quantity']) ?? -1.0;
      final maxQtyMkt = _parseFiniteDouble(raw['max_quantity_market']) ?? 0.0;
      final minNotional = _parseFiniteDouble(raw['min_notional']) ?? -1.0;
      final minPrice = _parseFiniteDouble(raw['min_price']) ?? -1.0;
      final maxPrice = _parseFiniteDouble(raw['max_price']) ?? -1.0;
      final step = _parseFiniteDouble(raw['step']) ?? -1.0;

      final orderTypes = <String>[];
      if (raw['order_types'] is List) {
        for (final ot in raw['order_types'] as List) {
          final s = ot?.toString().trim() ?? '';
          if (s.isNotEmpty) orderTypes.add(s);
        }
      }

      // Duplicate handling: if canonicalKey already processed in this batch, skip duplicate if existing has valid specs
      final alreadyInBatch = nextByPair[canonicalKey];
      if (alreadyInBatch != null && alreadyInBatch.hasValidSpecifications) {
        continue;
      }

      final inActiveEndpoint = activeMarketsFromEndpoint.isEmpty ||
          activeMarketsFromEndpoint.contains(symbol) ||
          activeMarketsFromEndpoint.contains(coindcxName) ||
          activeMarketsFromEndpoint.contains(pair);

      final priorRecord = prevMap[canonicalKey];
      final isNew = hadPriorCatalogue &&
          rawStatus.toLowerCase() == 'active' &&
          inActiveEndpoint &&
          (priorRecord == null || !priorRecord.isActiveStatus);

      if (isNew && !newlyListed.contains(canonicalKey)) {
        newlyListed.add(canonicalKey);
      }

      final provisional = CoinDcxMarketRecord(
        coindcxName: coindcxName.isNotEmpty ? coindcxName : symbol,
        symbol: symbol.isNotEmpty ? symbol : coindcxName,
        pair: pair,
        ecode: ecode,
        baseCurrencyShortName: baseShort,
        targetCurrencyShortName: targetShort,
        baseCurrencyName: baseName,
        targetCurrencyName: targetName,
        status: rawStatus,
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
        lastMetadataRefreshMs: nowMs,
        isNewlyListed: isNew,
        isInActiveMarketsList: inActiveEndpoint,
      );

      final matchedTicker =
          matchTickerForMarketRecord(provisional, tickersByMarketKey) ??
              priorRecord?.latestTicker;

      final withTicker = provisional.copyWith(
        latestTicker: matchedTicker,
        latestDataTimestampMs: matchedTicker?.timestampMs,
      );

      final eligibility = classifyMarketEligibility(
        record: withTicker,
        nowMs: nowMs,
      );

      if (hadPriorCatalogue &&
          priorRecord != null &&
          priorRecord.isActiveStatus &&
          !withTicker.isActiveStatus) {
        newlyInactive.add(canonicalKey);
      }

      nextByPair[canonicalKey] = withTicker.copyWith(
        eligibilityStatus: eligibility.status,
        eligibilityReason: eligibility.reason,
      );
    }

    // Handle active symbols returned by /exchange/v1/markets that were missing from /exchange/v1/markets_details
    // Never guess their ecode or pair! Record them with invalidMarketSpecifications ("Missing metadata").
    for (final activeSym in activeMarketsFromEndpoint) {
      if (!matchedSymbolsInDetails.contains(activeSym) &&
          !nextByPair.containsKey(activeSym)) {
        final rawTicker = tickersByMarketKey[activeSym];
        nextByPair[activeSym] = CoinDcxMarketRecord(
          coindcxName: activeSym,
          symbol: activeSym,
          pair: '',
          ecode: '',
          baseCurrencyShortName: '',
          targetCurrencyShortName: '',
          status: 'active',
          baseCurrencyPrecision: -1,
          targetCurrencyPrecision: -1,
          minQuantity: 0.0,
          maxQuantity: 0.0,
          maxQuantityMarket: 0.0,
          step: 0.0,
          minNotional: 0.0,
          minPrice: 0.0,
          maxPrice: 0.0,
          orderTypes: const [],
          latestTicker: rawTicker,
          latestDataTimestampMs: rawTicker?.timestampMs,
          lastMetadataRefreshMs: nowMs,
          isNewlyListed: hadPriorCatalogue && !prevMap.containsKey(activeSym),
          isInActiveMarketsList: true,
          eligibilityStatus:
              MarketEligibilityStatus.invalidMarketSpecifications,
          eligibilityReason:
              'Missing metadata in /exchange/v1/markets_details; exchange identifiers not guessed',
        );
      }
    }

    // Preserve previously discovered markets that disappeared from the API response by marking them inactive
    for (final entry in prevMap.entries) {
      if (!nextByPair.containsKey(entry.key)) {
        if (entry.value.isActiveStatus) {
          newlyInactive.add(entry.key);
        }
        nextByPair[entry.key] = entry.value.copyWith(
          status: 'inactive',
          isInActiveMarketsList: false,
          isNewlyListed: false,
          lastMetadataRefreshMs: nowMs,
          eligibilityStatus: MarketEligibilityStatus.inactive,
          eligibilityReason:
              'Market delisted or absent from latest CoinDCX market catalogue',
        );
      }
    }

    final sortedMarkets = nextByPair.values.toList()
      ..sort((a, b) {
        if (a.isEligibleForPaperTrading != b.isEligibleForPaperTrading) {
          return a.isEligibleForPaperTrading ? -1 : 1;
        }
        if (a.isActiveStatus != b.isActiveStatus) {
          return a.isActiveStatus ? -1 : 1;
        }
        return a.symbol.compareTo(b.symbol);
      });

    return MarketCatalogueSnapshot(
      allMarkets: sortedMarkets,
      newlyListedPairs: newlyListed,
      newlyInactivePairs: newlyInactive,
      lastSuccessfulRefreshMs: nowMs,
      isUsingCachedCatalogue: false,
      isCatalogueFresh: true,
    );
  }

  Future<http.Response> _getWithRetryAndRateLimitGuard(
    Uri uri, {
    required int nowMs,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (nowMs < _rateLimitBackoffUntilMs) {
      throw HttpException(
        'CoinDCX rate-limit backoff active until $_rateLimitBackoffUntilMs',
        uri: uri,
      );
    }

    Object? lastError;
    for (int attempt = 0; attempt <= maxApiRetries; attempt++) {
      try {
        final response = await _httpClient.get(uri).timeout(timeout);
        if (response.statusCode == 200) {
          return response;
        }
        if (response.statusCode == 429) {
          final backoffMs = initialRetryBackoffMs * (1 << (attempt + 2));
          _rateLimitBackoffUntilMs = nowMs + backoffMs;
          lastError = HttpException('CoinDCX HTTP 429 rate limited', uri: uri);
        } else if (response.statusCode >= 500) {
          lastError = HttpException(
            'CoinDCX HTTP ${response.statusCode}',
            uri: uri,
          );
        } else {
          throw HttpException('CoinDCX HTTP ${response.statusCode}', uri: uri);
        }
      } catch (e) {
        lastError = e;
        if (e is HttpException &&
            !e.message.contains('429') &&
            !e.message.contains('50')) {
          rethrow;
        }
      }

      if (attempt < maxApiRetries) {
        final delayMs = initialRetryBackoffMs * (1 << attempt);
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
    throw lastError ?? HttpException('Request failed for $uri', uri: uri);
  }

  /// Stage 47.1 Section 4 & 6: Refresh the complete CoinDCX Spot market catalogue
  /// from `/exchange/v1/markets`, `/exchange/v1/markets_details`, and `/exchange/ticker`
  /// with non-overlapping lock, rate-limit backoff, SQLite persistence, and cached fallback.
  Future<MarketCatalogueSnapshot> refreshMarketCatalogue({
    bool force = false,
    int? nowMs,
  }) {
    if (_inFlightCatalogueRefresh != null) {
      return _inFlightCatalogueRefresh!;
    }

    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        _lastSuccessfulCatalogueRefreshMs != null &&
        (ts - _lastSuccessfulCatalogueRefreshMs!) <
            minCatalogueRefreshIntervalMs &&
        _latestCatalogueSnapshot.allMarkets.isNotEmpty &&
        !_latestCatalogueSnapshot.isUsingCachedCatalogue) {
      return Future.value(_latestCatalogueSnapshot);
    }

    final future = _executeCatalogueRefreshInternal(nowMs: ts);
    _inFlightCatalogueRefresh = future;
    return future.whenComplete(() {
      _inFlightCatalogueRefresh = null;
    });
  }

  Future<MarketCatalogueSnapshot> _executeCatalogueRefreshInternal({
    required int nowMs,
  }) async {
    try {
      // Load cached catalogue from SQLite if our in-memory catalogue is empty (e.g., on cold start)
      if (_catalogueByPair.isEmpty && _persistence != null) {
        final cached = await _persistence!.loadDiscoveredMarkets();
        for (final m in cached) {
          final key = m.pair.isNotEmpty ? m.pair : m.symbol;
          if (key.isNotEmpty) {
            _catalogueByPair[key] = m;
          }
        }
      }

      final marketsResp = await _getWithRetryAndRateLimitGuard(
        Uri.parse(marketsUrl),
        nowMs: nowMs,
      );
      final detailsResp = await _getWithRetryAndRateLimitGuard(
        Uri.parse(marketsDetailsUrl),
        nowMs: nowMs,
      );
      final tickerResp = await _getWithRetryAndRateLimitGuard(
        Uri.parse(tickerUrl),
        nowMs: nowMs,
      );

      final activeSymbols = parseActiveMarketsResponse(marketsResp.body);
      final rawTickers = parseAllTickersResponse(tickerResp.body, nowMs: nowMs);
      _rawTickersByMarketKey
        ..clear()
        ..addAll(rawTickers);

      final snapshot = buildCompleteMarketCatalogue(
        activeMarketsFromEndpoint: activeSymbols,
        marketsDetailsJson: detailsResp.body,
        tickersByMarketKey: rawTickers,
        nowMs: nowMs,
        previousCatalogueByPair: Map.from(_catalogueByPair),
      );

      _catalogueByPair
        ..clear()
        ..addEntries(
          snapshot.allMarkets.map(
            (m) => MapEntry(m.pair.isNotEmpty ? m.pair : m.symbol, m),
          ),
        );

      for (final m in snapshot.allMarkets) {
        if (m.latestTicker != null && m.pair.isNotEmpty) {
          _latestTickers[m.pair] = m.latestTicker!;
        }
      }

      // Also update B-BTC_USDT & B-ETH_USDT if present in rawTickers
      final mappedTickers = parseLiveTickersResponse(
        tickerResp.body,
        nowMs: nowMs,
      );
      _latestTickers.addAll(mappedTickers);
      if (!_tickerStreamController.isClosed && _latestTickers.isNotEmpty) {
        _tickerStreamController.add(Map.unmodifiable(_latestTickers));
      }

      _lastSuccessfulCatalogueRefreshMs = nowMs;
      _latestCatalogueSnapshot = snapshot;

      if (_persistence != null) {
        await _persistence!.saveDiscoveredMarkets(
          snapshot.allMarkets,
          refreshedAtMs: nowMs,
        );
      }
      return snapshot;
    } catch (e) {
      // Fallback to cached catalogue in SQLite or memory; NEVER treat cached data as fresh live data!
      List<CoinDcxMarketRecord> cachedList = _catalogueByPair.values.toList();
      int? lastRefresh = _lastSuccessfulCatalogueRefreshMs;
      if (cachedList.isEmpty && _persistence != null) {
        cachedList = await _persistence!.loadDiscoveredMarkets();
        lastRefresh ??= await _persistence!.getLastMarketCatalogueRefreshMs();
        for (final m in cachedList) {
          final key = m.pair.isNotEmpty ? m.pair : m.symbol;
          if (key.isNotEmpty) {
            _catalogueByPair[key] = m;
          }
        }
      }

      final fallbackSnapshot = MarketCatalogueSnapshot(
        allMarkets: cachedList,
        newlyListedPairs: const [],
        newlyInactivePairs: const [],
        lastSuccessfulRefreshMs: lastRefresh,
        isUsingCachedCatalogue: true,
        isCatalogueFresh: false,
        lastRefreshError: e.toString(),
      );
      _latestCatalogueSnapshot = fallbackSnapshot;
      return fallbackSnapshot;
    }
  }

  Map<String, double> parseLiveTickerPrices(String responseBody) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final full = parseLiveTickersResponse(responseBody, nowMs: nowMs);
    return {
      for (final e in full.entries) e.key: e.value.lastPrice,
    };
  }

  /// Stage 11 & 15: Live REST ticker polling and automatic fallback.
  /// Also updates tickers and eligibility on all discovered catalogue markets.
  Future<Map<String, LiveMarketTicker>> fetchLiveTickers({int? nowMs}) async {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final response = await _getWithRetryAndRateLimitGuard(
      Uri.parse(tickerUrl),
      nowMs: ts,
    );
    final parsed = parseLiveTickersResponse(response.body, nowMs: ts);
    if (parsed.isNotEmpty) {
      _latestTickers.addAll(parsed);
      if (_catalogueByPair.isNotEmpty) {
        final updatedMarkets = <CoinDcxMarketRecord>[];
        for (final entry in _catalogueByPair.entries) {
          final record = entry.value;
          final matched =
              matchTickerForMarketRecord(record, _rawTickersByMarketKey) ??
                  record.latestTicker;
          final withTicker = record.copyWith(
            latestTicker: matched,
            latestDataTimestampMs: matched?.timestampMs,
          );
          final elig = classifyMarketEligibility(
            record: withTicker,
            nowMs: ts,
          );
          final updated = withTicker.copyWith(
            eligibilityStatus: elig.status,
            eligibilityReason: elig.reason,
          );
          _catalogueByPair[entry.key] = updated;
          updatedMarkets.add(updated);
        }
        _latestCatalogueSnapshot = MarketCatalogueSnapshot(
          allMarkets: updatedMarkets,
          newlyListedPairs: _latestCatalogueSnapshot.newlyListedPairs,
          newlyInactivePairs: _latestCatalogueSnapshot.newlyInactivePairs,
          lastSuccessfulRefreshMs:
              _lastSuccessfulCatalogueRefreshMs ??
              _latestCatalogueSnapshot.lastSuccessfulRefreshMs,
          isUsingCachedCatalogue:
              _latestCatalogueSnapshot.isUsingCachedCatalogue,
          isCatalogueFresh: !_latestCatalogueSnapshot.isUsingCachedCatalogue,
          lastRefreshError: _latestCatalogueSnapshot.lastRefreshError,
        );
      }
      if (!_tickerStreamController.isClosed) {
        _tickerStreamController.add(Map.unmodifiable(_latestTickers));
      }
    }
    return parsed;
  }

  Future<Map<String, double>> fetchLiveTickerPrices({int? nowMs}) async {
    final tickers = await fetchLiveTickers(nowMs: nowMs);
    return {
      for (final e in tickers.entries) e.key: e.value.lastPrice,
    };
  }

  /// Stage 13: Fetch strictly closed historical candles (15m / 1h), separate from live ticker.
  Future<List<Candle>> fetchClosedCandles({
    required String pair,
    required String interval,
    required int nowMs,
    int limit = 120,
  }) async {
    final uri = Uri.parse(candlesUrl).replace(queryParameters: {
      'pair': pair,
      'interval': interval,
      'limit': '$limit',
    });
    final response = await _getWithRetryAndRateLimitGuard(
      uri,
      nowMs: nowMs,
      timeout: const Duration(seconds: 12),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw FormatException('Invalid candles response for $pair ($interval)');
    }

    final intervalMs = interval == '1h' ? 60 * 60 * 1000 : 15 * 60 * 1000;
    final candles = <Candle>[];

    for (final raw in decoded) {
      if (raw is! Map) continue;
      final openTime = (raw['time'] as num?)?.toInt() ?? 0;
      if (openTime <= 0) continue;
      final closeTime = openTime + intervalMs;
      if (closeTime > nowMs) continue;

      final open = _parseFiniteDouble(raw['open']) ?? 0.0;
      final high = _parseFiniteDouble(raw['high']) ?? 0.0;
      final low = _parseFiniteDouble(raw['low']) ?? 0.0;
      final close = _parseFiniteDouble(raw['close']) ?? 0.0;
      final volume = _parseFiniteDouble(raw['volume']) ?? 0.0;
      if (close <= 0 || high < low) continue;

      candles.add(Candle(
        openTimeMs: openTime,
        closeTimeMs: closeTime,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: volume,
      ));
    }

    candles.sort((a, b) => a.openTimeMs.compareTo(b.openTimeMs));
    return candles;
  }

  /// Stage 16: Stale-data and missing-candle gap protection.
  bool hasRecentMissingCandleGap(
    List<Candle> candles, {
    required int intervalMs,
    int recentCount = 5,
  }) {
    if (candles.length < recentCount) return true;
    final startIdx = candles.length - recentCount;
    for (int i = startIdx + 1; i < candles.length; i++) {
      final delta = candles[i].openTimeMs - candles[i - 1].openTimeMs;
      if (delta > intervalMs * 2) {
        return true;
      }
    }
    return false;
  }

  bool isDataStale({
    required List<Candle> closedCandles15m,
    required int nowMs,
    int maxCandleAgeMs = 35 * 60 * 1000,
  }) {
    if (closedCandles15m.length < 52) return true;
    final latest = closedCandles15m.last;
    if (latest.close <= 0 || latest.high < latest.low) return true;
    if ((nowMs - latest.closeTimeMs) > maxCandleAgeMs) return true;
    if (hasRecentMissingCandleGap(
      closedCandles15m,
      intervalMs: 15 * 60 * 1000,
    )) {
      return true;
    }
    return false;
  }

  /// Stage 14 & 15: WebSocket market stream with automatic reconnection & REST fallback.
  Future<void> connectWebSocketFeed() async {
    if (_wsDisposed || _ws != null) return;
    try {
      final socket =
          await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 10));
      _ws = socket;
      _wsReconnectAttempts = 0;

      final channels = _catalogueByPair.values
          .where((m) => m.isEligibleForPaperTrading && m.pair.isNotEmpty)
          .map((m) => '${m.pair}@prices')
          .toList();
      if (channels.isEmpty) {
        channels.addAll(['B-BTC_USDT@prices', 'B-ETH_USDT@prices']);
      }
      for (final ch in channels.take(20)) {
        socket.add(jsonEncode({
          'event': 'join',
          'channelName': ch,
        }));
      }

      socket.listen(
        _handleWebSocketMessage,
        onError: (_) => _scheduleWebSocketReconnect(),
        onDone: _scheduleWebSocketReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleWebSocketReconnect();
    }
  }

  void _handleWebSocketMessage(dynamic raw) {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final decoded = jsonDecode(raw.toString());
      if (decoded is! Map) return;
      final data = decoded['data'] is String
          ? jsonDecode(decoded['data'] as String)
          : decoded['data'];
      if (data is! Map) return;

      final rawSymbolOrChannel =
          (data['s'] ?? data['channel'] ?? '').toString().trim();
      String? resolvedPair;
      for (final record in _catalogueByPair.values) {
        if (rawSymbolOrChannel == record.pair ||
            rawSymbolOrChannel == record.symbol ||
            rawSymbolOrChannel == record.coindcxName ||
            rawSymbolOrChannel == '${record.pair}@prices') {
          resolvedPair = record.pair;
          break;
        }
      }
      if (resolvedPair == null) {
        if (rawSymbolOrChannel.contains('BTC')) resolvedPair = 'B-BTC_USDT';
        if (rawSymbolOrChannel.contains('ETH')) resolvedPair = 'B-ETH_USDT';
      }
      if (resolvedPair == null) return;

      final price =
          _parseFiniteDouble(data['p'] ?? data['last_price']) ?? 0.0;
      if (price <= 0) return;

      final existing = _latestTickers[resolvedPair];
      _latestTickers[resolvedPair] = LiveMarketTicker(
        symbol: resolvedPair,
        lastPrice: price,
        bid: _parseFiniteDouble(data['b']) ?? existing?.bid ?? price,
        ask: _parseFiniteDouble(data['a']) ?? existing?.ask ?? price,
        high24h: _parseFiniteDouble(data['h']) ?? existing?.high24h ?? price,
        low24h: _parseFiniteDouble(data['l']) ?? existing?.low24h ?? price,
        volume24h: _parseFiniteDouble(data['v']) ?? existing?.volume24h ?? 0.0,
        change24hPct:
            _parseFiniteDouble(data['c']) ?? existing?.change24hPct ?? 0.0,
        timestampMs: nowMs,
      );
      if (!_tickerStreamController.isClosed) {
        _tickerStreamController.add(Map.unmodifiable(_latestTickers));
      }
    } catch (_) {}
  }

  void _scheduleWebSocketReconnect() {
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
    if (_wsDisposed) return;

    _wsReconnectAttempts++;
    final delaySec = _wsReconnectAttempts <= 1
        ? 3
        : (_wsReconnectAttempts == 2
            ? 10
            : (_wsReconnectAttempts == 3 ? 20 : 30));
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(Duration(seconds: delaySec), () async {
      try {
        await fetchLiveTickers();
      } catch (_) {}
      await connectWebSocketFeed();
    });
  }

  void dispose() {
    _wsDisposed = true;
    _wsReconnectTimer?.cancel();
    try {
      _ws?.close();
    } catch (_) {}
    _tickerStreamController.close();
  }
}
