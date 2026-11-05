import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/trading_models.dart';

class CoinDcxMarketService {
  static const String tickerUrl = 'https://api.coindcx.com/exchange/ticker';
  static const String marketsDetailsUrl =
      'https://api.coindcx.com/exchange/v1/markets_details';
  static const String candlesBaseUrl =
      'https://public.coindcx.com/market_data/candles';

  final http.Client _client;
  final Duration timeout;
  final Map<String, MarketPairMetadata> _discoveredPairs = {};

  CoinDcxMarketService({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  Map<String, MarketPairMetadata> get discoveredPairs =>
      Map.unmodifiable(_discoveredPairs);

  Future<Map<String, MarketPairMetadata>> discoverActiveUsdtPairs({
    List<String> targetSymbols = const ['BTCUSDT', 'ETHUSDT'],
  }) async {
    final uri = Uri.parse(marketsDetailsUrl);
    final response = await _client.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError(
        'CoinDCX markets_details HTTP ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException('Invalid markets_details JSON format.');
    }

    for (final raw in decoded) {
      if (raw is! Map<String, dynamic>) continue;
      final symbol = (raw['symbol'] ?? raw['coindcx_name'] ?? '').toString();
      final pair = (raw['pair'] ?? '').toString();
      final status = (raw['status'] ?? '').toString().toLowerCase();
      final baseCurrency =
          (raw['base_currency_short_name'] ?? '').toString().toUpperCase();
      final targetCurrency =
          (raw['target_currency_short_name'] ?? '').toString().toUpperCase();

      if (status != 'active' || pair.isEmpty) continue;

      final normalized = symbol.toUpperCase().replaceAll('_', '');
      final matchedSymbol = targetSymbols.firstWhere(
        (target) =>
            normalized == target ||
            ('$targetCurrency$baseCurrency' == target),
        orElse: () => '',
      );
      if (matchedSymbol.isEmpty) continue;

      if (_discoveredPairs.containsKey(matchedSymbol) &&
          _discoveredPairs[matchedSymbol]!.pair.startsWith('B-') &&
          !pair.startsWith('B-')) {
        continue;
      }

      final minNotional = _toDouble(raw['min_notional']) ?? 1.0;
      final minQuantity = _toDouble(raw['min_quantity']) ?? 0.00001;
      final basePrecision =
          (raw['base_currency_precision'] as num?)?.toInt() ?? 2;
      final targetPrecision =
          (raw['target_currency_precision'] as num?)?.toInt() ?? 5;

      _discoveredPairs[matchedSymbol] = MarketPairMetadata(
        symbol: matchedSymbol,
        pair: pair,
        baseCurrency: baseCurrency,
        targetCurrency: targetCurrency,
        minNotional: minNotional,
        minQuantity: minQuantity,
        basePrecision: basePrecision,
        targetPrecision: targetPrecision,
        status: status,
      );
    }

    for (final requiredSymbol in targetSymbols) {
      if (!_discoveredPairs.containsKey(requiredSymbol)) {
        throw StateError(
          'Active pair metadata for $requiredSymbol not found in markets_details.',
        );
      }
    }

    return Map.unmodifiable(_discoveredPairs);
  }

  Future<List<Candle>> fetchClosedCandles({
    required String symbol,
    required String pair,
    required String interval,
    int limit = 150,
    int? nowEpochMs,
  }) async {
    final intervalMs = intervalDurationMs(interval);
    final nowMs = nowEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;

    final uri = Uri.parse(candlesBaseUrl).replace(
      queryParameters: {
        'pair': pair,
        'interval': interval,
        'limit': limit.toString(),
      },
    );

    final response = await _client.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError(
        'CoinDCX candles HTTP ${response.statusCode} for $symbol ($interval)',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException(
        'CoinDCX candles response must be a JSON List.',
      );
    }

    return sanitizeAndFilterClosedCandles(
      rawList: decoded,
      symbol: symbol,
      interval: interval,
      intervalMs: intervalMs,
      nowMs: nowMs,
    );
  }

  static int intervalDurationMs(String interval) {
    switch (interval) {
      case '15m':
        return 15 * 60 * 1000;
      case '1h':
        return 60 * 60 * 1000;
      default:
        throw ArgumentError('Unsupported candle interval: $interval');
    }
  }

  /// Validates OHLCV fields, rejects future timestamps (`openTimeMs > nowMs`),
  /// rejects incomplete candles (`closeTimeMs > nowMs`), deduplicates timestamps,
  /// and sorts chronologically.
  static List<Candle> sanitizeAndFilterClosedCandles({
    required List<dynamic> rawList,
    required String symbol,
    required String interval,
    required int intervalMs,
    required int nowMs,
  }) {
    final byOpenTime = <int, Candle>{};

    for (final item in rawList) {
      if (item is! Map) continue;
      final open = _toDouble(item['open']);
      final high = _toDouble(item['high']);
      final low = _toDouble(item['low']);
      final close = _toDouble(item['close']);
      final volume = _toDouble(item['volume']) ?? 0.0;
      final rawTime = _toInt(item['time']);

      if (open == null ||
          high == null ||
          low == null ||
          close == null ||
          rawTime == null) {
        continue;
      }

      final openTimeMs = rawTime < 100000000000 ? rawTime * 1000 : rawTime;
      // Reject future candles
      if (openTimeMs > nowMs) {
        continue;
      }
      final closeTimeMs = openTimeMs + intervalMs;

      final candle = Candle(
        symbol: symbol,
        interval: interval,
        openTimeMs: openTimeMs,
        closeTimeMs: closeTimeMs,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: volume,
      );

      if (!candle.isValid) continue;
      if (!candle.isClosedAt(nowMs)) continue;

      byOpenTime[openTimeMs] = candle;
    }

    final sorted = byOpenTime.values.toList()
      ..sort((a, b) => a.openTimeMs.compareTo(b.openTimeMs));
    return sorted;
  }

  static bool isDataStale({
    required List<Candle> closedCandles,
    required String interval,
    required int nowMs,
  }) {
    if (closedCandles.isEmpty) return true;
    final intervalMs = intervalDurationMs(interval);
    final latest = closedCandles.last;
    if (nowMs - latest.closeTimeMs > (intervalMs * 2.5).round()) {
      return true;
    }
    return false;
  }

  static bool hasRecentMissingCandleGap({
    required List<Candle> closedCandles,
    required String interval,
    int tailCount = 5,
  }) {
    if (closedCandles.length < 2) return true;
    final intervalMs = intervalDurationMs(interval);
    final startIdx =
        (closedCandles.length - tailCount).clamp(0, closedCandles.length - 1);
    for (int i = startIdx + 1; i < closedCandles.length; i++) {
      final delta = closedCandles[i].openTimeMs - closedCandles[i - 1].openTimeMs;
      if (delta != intervalMs) {
        return true;
      }
    }
    return false;
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }
    if (value is String) {
      final d = double.tryParse(value);
      return (d != null && d.isFinite) ? d : null;
    }
    return null;
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Fetches display-only live spot prices from `GET https://api.coindcx.com/exchange/ticker`.
  /// Verified CoinDCX response format: a JSON List of objects containing
  /// `market`, `change_24_hour`, `high`, `low`, `volume`, `last_price`, `bid`, `ask`, `timestamp`.
  /// NOTE: Strictly display-only; strategy signals and Stop-Loss/Take-Profit execution
  /// continue to use closed candles exclusively.
  Future<Map<String, double>> fetchLiveTickerPrices({
    List<String> targetSymbols = const ['BTCUSDT', 'ETHUSDT'],
  }) async {
    final uri = Uri.parse(tickerUrl);
    final response = await _client.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('CoinDCX ticker HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException(
        'CoinDCX ticker response must be a JSON List.',
      );
    }
    return parseLiveTickerPrices(
      rawList: decoded,
      targetSymbols: targetSymbols,
    );
  }

  /// Parses CoinDCX `/exchange/ticker` JSON array into a map of positive finite
  /// `last_price` values keyed by normalized symbol (e.g. `BTCUSDT`, `ETHUSDT`).
  static Map<String, double> parseLiveTickerPrices({
    required List<dynamic> rawList,
    List<String> targetSymbols = const ['BTCUSDT', 'ETHUSDT'],
  }) {
    final targets = targetSymbols.map((s) => s.toUpperCase()).toSet();
    final prices = <String, double>{};

    for (final item in rawList) {
      if (item is! Map) continue;
      final rawMarket = (item['market'] ?? '').toString().toUpperCase().trim();
      if (rawMarket.isEmpty) continue;
      final normalized =
          rawMarket.replaceAll('B-', '').replaceAll('_', '');
      if (!targets.contains(normalized)) continue;

      final price = _toDouble(item['last_price']);
      if (price != null && price > 0 && price.isFinite) {
        prices[normalized] = price;
      }
    }
    return prices;
  }
}
