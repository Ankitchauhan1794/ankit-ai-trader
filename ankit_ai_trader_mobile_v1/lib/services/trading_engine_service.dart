import 'authoritative_engine.dart';
import 'coindcx_market_service.dart';
import 'persistence_db.dart';

/// Legacy compatibility wrapper around AuthoritativeTradingEngine.
class TradingEngineService {
  final AuthoritativeTradingEngine engine;

  TradingEngineService({
    CoinDcxMarketService? marketService,
    PersistenceDatabase? persistence,
  }) : engine = AuthoritativeTradingEngine(
          marketService: marketService ?? CoinDcxMarketService(),
          persistence: persistence ?? PersistenceDatabase(),
        );

  Future<bool> runTick() =>
      engine.executeAuthoritativeCycle(allowTradingExecution: true);
}
