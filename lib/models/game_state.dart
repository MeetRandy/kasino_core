import 'package:equatable/equatable.dart';
import 'playing_card.dart';
import 'player.dart';
import 'build.dart';

/// Game phase tracking
enum GamePhase {
  dealing,        // Cards being dealt
  playing,        // Active play
  secondDeal,     // 2-player: second deal of 10 cards
  playingSecond,  // 2-player: playing second deal (drifting allowed)
  scoring,        // Calculating scores
  gameOver,       // Hand complete, showing results
}

/// Types of actions a player can take
enum ActionType {
  capture,          // Play card to capture from table
  buildCreate,      // Create a new build
  buildAugment,     // Add to existing build
  drift,            // Play card to table without capturing
  stealAndBuild,    // Steal from opponent pile + play from hand to build
}

/// Game mode
enum GameMode {
  singlePlayer,     // vs AI
  multiplayer,      // Online PvP
  practice,         // No stakes
}

/// Record of a game action for replay/logging
class GameAction extends Equatable {
  final String playerId;
  final ActionType type;
  final PlayingCard cardPlayed;
  final List<PlayingCard> cardsCaptured;
  final String description;
  final DateTime timestamp;

  const GameAction({
    required this.playerId,
    required this.type,
    required this.cardPlayed,
    this.cardsCaptured = const [],
    required this.description,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'type': type.name,
        'cardPlayed': cardPlayed.toJson(),
        'cardsCaptured': cardsCaptured.map((c) => c.toJson()).toList(),
        'description': description,
        'timestamp': timestamp.toIso8601String(),
      };

  factory GameAction.fromJson(Map<String, dynamic> json) {
    return GameAction(
      playerId: json['playerId'] as String,
      type: ActionType.values.byName(json['type'] as String),
      cardPlayed:
          PlayingCard.fromJson(json['cardPlayed'] as Map<String, dynamic>),
      cardsCaptured: (json['cardsCaptured'] as List?)
              ?.map(
                  (c) => PlayingCard.fromJson(c as Map<String, dynamic>))
              .toList() ??
          const [],
      description: json['description'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  @override
  List<Object?> get props => [playerId, type, timestamp];
}

/// Complete game state for SA Kasino
///
/// SA Casino Rules Summary:
/// - 40 cards (A-10, no pictures)
/// - 2 players: 10 cards each, second deal of 10
/// - 3 players: 13 each + 1 on table
/// - 4 players: 10 each, no table cards
/// - Capture pile face-up, top card exposed
/// - Captured cards in build order, capturing card on top
/// - Cannot drift if you own a build
/// - Steal from opponent pile only with simultaneous hand card play
/// - Second deal (2-player): drifting always allowed
class GameState extends Equatable {
  final String gameId;
  final GameMode mode;
  final GamePhase phase;
  final int playerCount;

  // Players
  final List<Player> players;
  final int currentPlayerIndex;

  // Table state
  final List<PlayingCard> tableCards;   // Loose cards on the table
  final List<Build> builds;             // Active builds on the table
  final List<PlayingCard> drawPile;     // Remaining cards to deal (2-player)

  // Tracking
  final int lastCapturePlayerIndex;     // Who captured last (gets remaining cards)
  final List<GameAction> actionLog;
  final bool isSecondDeal;              // 2-player: are we in the second deal?

  // Match scoring (can play multiple hands)
  final Map<String, int> matchScores;   // playerId -> cumulative score
  final int targetScore;                // First to this score wins match (default 11)
  final int handNumber;

  const GameState({
    required this.gameId,
    required this.mode,
    this.phase = GamePhase.dealing,
    required this.playerCount,
    required this.players,
    this.currentPlayerIndex = 0,
    this.tableCards = const [],
    this.builds = const [],
    this.drawPile = const [],
    this.lastCapturePlayerIndex = -1,
    this.actionLog = const [],
    this.isSecondDeal = false,
    this.matchScores = const {},
    this.targetScore = 11,
    this.handNumber = 1,
  });

  /// Current player
  Player get currentPlayer => players[currentPlayerIndex];

  /// Whether the current player owns any builds
  bool get currentPlayerOwnsBuild =>
      builds.any((b) => b.ownerId == currentPlayer.id);

  /// Whether drifting is allowed for the current player
  /// SA Rules: Can't drift if you own a build (except during second deal)
  bool get canCurrentPlayerDrift {
    if (isSecondDeal) return true; // Second deal: always allowed
    return !currentPlayerOwnsBuild;
  }

  /// All cards currently in play on the table (loose + in builds)
  List<PlayingCard> get allTableCards {
    final buildCards = builds.expand((b) => b.allCards).toList();
    return [...tableCards, ...buildCards];
  }

  /// Check if all players have empty hands (need new deal or scoring)
  bool get allHandsEmpty => players.every((p) => p.hand.isEmpty);

  /// Get a player by ID
  Player getPlayer(String id) => players.firstWhere((p) => p.id == id);

  /// Get opponent(s) of a player
  List<Player> getOpponents(String playerId) =>
      players.where((p) => p.id != playerId).toList();

  /// Next player index (wraps around)
  int get nextPlayerIndex => (currentPlayerIndex + 1) % playerCount;

  GameState copyWith({
    String? gameId,
    GameMode? mode,
    GamePhase? phase,
    int? playerCount,
    List<Player>? players,
    int? currentPlayerIndex,
    List<PlayingCard>? tableCards,
    List<Build>? builds,
    List<PlayingCard>? drawPile,
    int? lastCapturePlayerIndex,
    List<GameAction>? actionLog,
    bool? isSecondDeal,
    Map<String, int>? matchScores,
    int? targetScore,
    int? handNumber,
  }) {
    return GameState(
      gameId: gameId ?? this.gameId,
      mode: mode ?? this.mode,
      phase: phase ?? this.phase,
      playerCount: playerCount ?? this.playerCount,
      players: players ?? this.players,
      currentPlayerIndex: currentPlayerIndex ?? this.currentPlayerIndex,
      tableCards: tableCards ?? this.tableCards,
      builds: builds ?? this.builds,
      drawPile: drawPile ?? this.drawPile,
      lastCapturePlayerIndex:
          lastCapturePlayerIndex ?? this.lastCapturePlayerIndex,
      actionLog: actionLog ?? this.actionLog,
      isSecondDeal: isSecondDeal ?? this.isSecondDeal,
      matchScores: matchScores ?? this.matchScores,
      targetScore: targetScore ?? this.targetScore,
      handNumber: handNumber ?? this.handNumber,
    );
  }

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'mode': mode.name,
        'phase': phase.name,
        'playerCount': playerCount,
        'players': players.map((p) => p.toJson()).toList(),
        'currentPlayerIndex': currentPlayerIndex,
        'tableCards': tableCards.map((c) => c.toJson()).toList(),
        'builds': builds.map((b) => b.toJson()).toList(),
        'drawPile': drawPile.map((c) => c.toJson()).toList(),
        'lastCapturePlayerIndex': lastCapturePlayerIndex,
        'actionLog': actionLog.map((a) => a.toJson()).toList(),
        'isSecondDeal': isSecondDeal,
        'matchScores': matchScores,
        'targetScore': targetScore,
        'handNumber': handNumber,
      };

  factory GameState.fromJson(Map<String, dynamic> json) {
    return GameState(
      gameId: json['gameId'] as String,
      mode: GameMode.values.byName(json['mode'] as String),
      phase: GamePhase.values.byName(json['phase'] as String),
      playerCount: json['playerCount'] as int,
      players: (json['players'] as List)
          .map((p) => Player.fromJson(p as Map<String, dynamic>))
          .toList(),
      currentPlayerIndex: json['currentPlayerIndex'] as int,
      tableCards: (json['tableCards'] as List)
          .map((c) => PlayingCard.fromJson(c as Map<String, dynamic>))
          .toList(),
      builds: (json['builds'] as List)
          .map((b) => Build.fromJson(b as Map<String, dynamic>))
          .toList(),
      drawPile: (json['drawPile'] as List)
          .map((c) => PlayingCard.fromJson(c as Map<String, dynamic>))
          .toList(),
      lastCapturePlayerIndex: json['lastCapturePlayerIndex'] as int,
      actionLog: (json['actionLog'] as List)
          .map((a) => GameAction.fromJson(a as Map<String, dynamic>))
          .toList(),
      isSecondDeal: json['isSecondDeal'] as bool,
      matchScores: Map<String, int>.from(json['matchScores'] as Map),
      targetScore: json['targetScore'] as int,
      handNumber: json['handNumber'] as int,
    );
  }

  /// Create a client-safe view — strips opponent hand cards (replaced with
  /// empty hands). Server sends this, never the full state.
  GameState toClientView(String playerId) {
    return copyWith(
      players: players.map((p) {
        if (p.id == playerId) return p; // own hand is visible
        return p.copyWith(hand: const [], handSize: p.hand.length);
      }).toList(),
      drawPile: const [], // clients never see the draw pile
    );
  }

  @override
  List<Object?> get props => [
        gameId,
        phase,
        currentPlayerIndex,
        tableCards,
        builds,
        players,
      ];
}
