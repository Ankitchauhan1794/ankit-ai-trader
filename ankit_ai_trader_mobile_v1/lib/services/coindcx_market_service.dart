import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/trading_models.dart';

class CoinDcxMarketService {
  static const String marketsDetailsUrl =
      'https://api.coindcx.com/exchange/v1/markets_details';
  static const String candlesBaseUrl =
      'https://public.coindcx.com/market_data/candles';
  static const String tickerUrl = 'https://api.coindcx.com/exchange/ticker';

  final http.Client _client;
  final Map<String, MarketPairMetadata> discoveredPairs = {};

  CoinDcxMarketService({http.Client? client})
      : _client = client ?? http.Client();

  static int intervalDurationMs(String interval) {
    switch (interval) {
      case '15m':
        return 15 * 60 * 1000;
      case '1h':
        return 60 * 60 * 1000;
      default:
        return 15 * 60 * 1000;
    }
  }

  Future<Map<String, MarketPairMetadata>> discoverActiveUsdtPairs() async {
    final resp = await _client
        .get(Uri.parse(marketsDetailsUrl))
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw Exception('CoinDCX markets_details HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) {
      throw Exception('Invalid markets_details payload');
    }

    const wanted = {'BTCUSDT', 'ETHUSDT'};
    final found = <String, MarketPairMetadata>{};

    for (final item in decoded) {
      if (item is! Map) continue;
      final sym = (item['symbol'] ?? item['coindcx_name'] ?? '').toString();
      final pair = (item['pair'] ?? '').toString();
      final status = (item['status'] ?? 'active').toString();
      if (wanted.contains(sym) && status.toLowerCase() == 'active' && pair.isNotEmpty) {
        final minNotional =
            double.tryParse((item['min_notional'] ?? '1.0').toString()) ?? 1.0;
        final minQty =
            double.tryParse((item['min_quantity'] ?? '0.0001').toString()) ??
                0.0001;
        found[sym] = MarketPairMetadata(
          symbol: sym,
          pair: pair,
          status: status,
          minNotional: minNotional,
          minQuantity: minQty,
        );
      }
    }

    discoveredPairs
      ..clear()
      ..addAll(found);
    return found;
  }

  Future<List<Candle>> fetchClosedCandles({
    required String symbol,
    required String pair,
    required String interval,
    int limit = 120,
    int? nowEpochMs,
  }) async {
    final uri = Uri.parse(candlesBaseUrl).replace(queryParameters: {
      'pair': pair,
      'interval': interval,
      'limit': limit.toString(),
    });
    final resp =
        await _client.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw Exception('CoinDCX candles HTTP ${resp.statusCode} for $symbol ($interval)');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) {
      throw Exception('Invalid candles response for $symbol');
    }

    final stepMs = intervalDurationMs(interval);
    final nowMs =
        nowEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final candles = <Candle>[];

    for (final raw in decoded) {
      if (raw is! Map) continue;
      final openTime = (raw['time'] as num?)?.toInt();
      final open = double.tryParse((raw['open'] ?? '').toString());
      final high = double.tryParse((raw['high'] ?? '').toString());
      final low = double.tryParse((raw['low'] ?? '').toString());
      final close = double.tryParse((raw['close'] ?? '').toString());
      final volume = double.tryParse((raw['volume'] ?? '0').toString()) ?? 0.0;
      if (openTime == null ||
          open == null ||
          high == null ||
          low == null ||
          close == null) {
        continue;
      }
      final closeTime = openTime + stepMs;
      // Only include strictly closed candles
      if (closeTime <= nowMs) {
        candles.add(
          Candle(
            symbol: symbol,
            interval: interval,
            openTimeMs: openTime,
            closeTimeMs: closeTime,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume,
          ),
        );
      }
    }

    candles.sort((a, b) => a.openTimeMs.compareTo(b.openTimeMs));
    // Deduplicate by openTimeMs
    final deduped = <Candle>[];
    for (final c in candles) {
      if (deduped.isEmpty || deduped.last.openTimeMs != c.openTimeMs) {
        deduped.add(c);
      }
    }
    return deduped;
  }

  static Map<String, double> parseLiveTickerPrices({
    required List<dynamic> rawList,
  }) {
    final prices = <String, double>{};
    for (final item in rawList) {
      if (item is! Map) continue;
      final rawMarket = (item['market'] ?? '').toString().toUpperCase();
      String? normalized;
      if (rawMarket == 'BTCUSDT' || rawMarket == 'B-BTC_USDT') {
        normalized = 'BTCUSDT';
      } else if (rawMarket == 'ETHUSDT' || rawMarket == 'B-ETH_USDT') {
        normalized = 'ETHUSDT';
      }
      if (normalized == null) continue;
      final lp = double.tryParse((item['last_price'] ?? '').toString());
      if (lp != null && lp > 0 && lp.isFinite) {
        prices[normalized] = lp;
      }
    }
    return prices;
  }

  Future<Map<String, double>> fetchLiveTickerPrices() async {
    final resp = await _client
        .get(Uri.parse(tickerUrl))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('CoinDCX ticker HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) {
      return const {};
    }
    return parseLiveTickerPrices(rawList: decoded);
  }

  static bool isDataStale({
    required List<Candle> closedCandles,
    required String interval,
    required int nowMs,
  }) {
    if (closedCandles.isEmpty) return true;
    final stepMs = intervalDurationMs(interval);
    final ageMs = nowMs - closedCandles.last.closeTimeMs;
    return ageMs > (stepMs * 2.5);
  }

  static bool hasRecentMissingCandleGap({
    required List<Candle> closedCandles,
    required String interval,
    int recentCount = 5,
  }) {
    if (closedCandles.length < 2) return false;
    final stepMs = intervalDurationMs(interval);
    final startIdx = closedCandles.length > recentCount
        ? closedCandles.length - recentCount
        : 0;
    for (int i = startIdx + 1; i < closedCandles.length; i++) {
      final diff = closedCandles[i].openTimeMs - closedCandles[i - 1].openTimeMs;
      if (diff != stepMs) {
        return true;
      }
    }
    return false;
  }
}
