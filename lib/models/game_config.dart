import 'game_state.dart';
import '../services/kasino_ai.dart';

/// Configuration for starting a new game.
class GameConfig {
  final int playerCount;
  final GameMode mode;
  final AIDifficulty aiDifficulty;
  final int targetScore;

  const GameConfig({
    this.playerCount = 2,
    this.mode = GameMode.singlePlayer,
    this.aiDifficulty = AIDifficulty.medium,
    this.targetScore = 11,
  });

  Map<String, dynamic> toJson() => {
        'playerCount': playerCount,
        'mode': mode.name,
        'aiDifficulty': aiDifficulty.name,
        'targetScore': targetScore,
      };

  factory GameConfig.fromJson(Map<String, dynamic> json) {
    return GameConfig(
      playerCount: json['playerCount'] as int? ?? 2,
      mode: GameMode.values.byName(json['mode'] as String? ?? 'singlePlayer'),
      aiDifficulty: AIDifficulty.values
          .byName(json['aiDifficulty'] as String? ?? 'medium'),
      targetScore: json['targetScore'] as int? ?? 11,
    );
  }
}
