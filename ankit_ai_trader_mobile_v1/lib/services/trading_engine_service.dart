import 'package:flutter/foundation.dart';
import '../models/trading_models.dart';

class TradingEngineService extends ChangeNotifier {
  BotEngineState state = BotEngineState.stopped;
}
