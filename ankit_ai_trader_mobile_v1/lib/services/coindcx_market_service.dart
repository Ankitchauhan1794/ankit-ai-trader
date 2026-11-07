import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/trading_models.dart';

class CoinDcxMarketService {
  static const String tickerUrl = 'https://api.coindcx.com/exchange/ticker';
  static const String marketsDetailsUrl =
      'https://api.coindcx.com/exchange/v1/markets_details';
  static const String candlesUrl =
      'https://public.coindcx.com/market_data/candles';
  static const String wsUrl = 'wss://stream.coindcx.com';

  final http.Client _httpClient;
  WebSocket? _ws;
  Timer? _wsReconnectTimer;
  int _wsReconnectAttempts = 0;
  bool _wsDisposed = false;
  final Map<String, LiveMarketTicker> _latestTickers = {};
  final StreamController<Map<String, LiveMarketTicker>>
      _tickerStreamController =
      StreamController<Map<String, LiveMarketTicker>>.broadcast();

  CoinDcxMarketService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  Stream<Map<String, LiveMarketTicker>> get tickerStream =>
      _tickerStreamController.stream;

  Map<String, LiveMarketTicker> get latestTickers =>
      Map.unmodifiable(_latestTickers);

  /// Stage 10: Full CoinDCX REST ticker parser for BTC/USDT and ETH/USDT.
  Map<String, LiveMarketTicker> parseLiveTickersResponse(
    String responseBody, {
    required int nowMs,
  }) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! List) return {};

    final result = <String, LiveMarketTicker>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final market = item['market']?.toString() ?? '';
      String? canonicalPair;
      if (market == 'BTCUSDT' || market == 'B-BTC_USDT') {
        canonicalPair = 'B-BTC_USDT';
      } else if (market == 'ETHUSDT' || market == 'B-ETH_USDT') {
        canonicalPair = 'B-ETH_USDT';
      }
      if (canonicalPair == null) continue;

      final lastPrice = double.tryParse('${item['last_price'] ?? ''}') ?? 0.0;
      if (lastPrice <= 0) continue;

      final bid = double.tryParse('${item['bid'] ?? ''}') ?? lastPrice;
      final ask = double.tryParse('${item['ask'] ?? ''}') ?? lastPrice;
      final high24h = double.tryParse('${item['high'] ?? ''}') ?? lastPrice;
      final low24h = double.tryParse('${item['low'] ?? ''}') ?? lastPrice;
      final volume24h = double.tryParse('${item['volume'] ?? ''}') ?? 0.0;
      final change24hPct =
          double.tryParse('${item['change_24_hour'] ?? ''}') ?? 0.0;
      final rawTs = int.tryParse('${item['timestamp'] ?? ''}') ?? 0;
      final tsMs = rawTs > 0
          ? (rawTs < 10000000000 ? rawTs * 1000 : rawTs)
          : nowMs;

      result[canonicalPair] = LiveMarketTicker(
        symbol: canonicalPair,
        lastPrice: lastPrice,
        bid: bid > 0 ? bid : lastPrice,
        ask: ask > 0 ? ask : lastPrice,
        high24h: high24h > 0 ? high24h : lastPrice,
        low24h: low24h > 0 ? low24h : lastPrice,
        volume24h: volume24h,
        change24hPct: change24hPct,
        timestampMs: tsMs,
      );
    }
    return result;
  }

  Map<String, double> parseLiveTickerPrices(String responseBody) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final full = parseLiveTickersResponse(responseBody, nowMs: nowMs);
    return {
      for (final e in full.entries) e.key: e.value.lastPrice,
    };
  }

  /// Stage 11 & 15: Live REST ticker polling and automatic fallback.
  Future<Map<String, LiveMarketTicker>> fetchLiveTickers({int? nowMs}) async {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final response = await _httpClient
        .get(Uri.parse(tickerUrl))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw HttpException('CoinDCX ticker HTTP ${response.statusCode}');
    }
    final parsed = parseLiveTickersResponse(response.body, nowMs: ts);
    if (parsed.isNotEmpty) {
      _latestTickers.addAll(parsed);
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
    final response =
        await _httpClient.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw HttpException('CoinDCX candles HTTP ${response.statusCode}');
    }
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

      final open = (raw['open'] as num?)?.toDouble() ?? 0.0;
      final high = (raw['high'] as num?)?.toDouble() ?? 0.0;
      final low = (raw['low'] as num?)?.toDouble() ?? 0.0;
      final close = (raw['close'] as num?)?.toDouble() ?? 0.0;
      final volume = (raw['volume'] as num?)?.toDouble() ?? 0.0;
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

      socket.add(jsonEncode({
        'event': 'join',
        'channelName': 'B-BTC_USDT@prices',
      }));
      socket.add(jsonEncode({
        'event': 'join',
        'channelName': 'B-ETH_USDT@prices',
      }));

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

      final pair = (data['s'] ?? data['channel'] ?? '').toString();
      String? symbol;
      if (pair.contains('BTC')) symbol = 'B-BTC_USDT';
      if (pair.contains('ETH')) symbol = 'B-ETH_USDT';
      if (symbol == null) return;

      final price =
          double.tryParse('${data['p'] ?? data['last_price'] ?? ''}') ?? 0.0;
      if (price <= 0) return;

      final existing = _latestTickers[symbol];
      _latestTickers[symbol] = LiveMarketTicker(
        symbol: symbol,
        lastPrice: price,
        bid: double.tryParse('${data['b'] ?? ''}') ?? existing?.bid ?? price,
        ask: double.tryParse('${data['a'] ?? ''}') ?? existing?.ask ?? price,
        high24h:
            double.tryParse('${data['h'] ?? ''}') ?? existing?.high24h ?? price,
        low24h:
            double.tryParse('${data['l'] ?? ''}') ?? existing?.low24h ?? price,
        volume24h:
            double.tryParse('${data['v'] ?? ''}') ?? existing?.volume24h ?? 0.0,
        change24hPct: double.tryParse('${data['c'] ?? ''}') ??
            existing?.change24hPct ??
            0.0,
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
