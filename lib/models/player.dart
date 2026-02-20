import 'package:equatable/equatable.dart';
import 'playing_card.dart';

/// A Kasino player
class Player extends Equatable {
  final String id;
  final String displayName;
  final String avatarUrl;
  final bool isAI;

  // In-game state
  final List<PlayingCard> hand;
  final List<PlayingCard> capturePile; // Face up, top card exposed
  final int? handSize; // Set in client views where hand cards are stripped

  /// Actual card count — uses handSize (from server) if hand is stripped.
  int get visibleHandCount => handSize ?? hand.length;

  // Profile stats
  final int wins;
  final int losses;
  final int gamesPlayed;
  final int totalPoints;
  final int trophies;
  final int level;

  Player({
    required this.id,
    required this.displayName,
    this.avatarUrl = '',
    this.isAI = false,
    this.hand = const [],
    this.capturePile = const [],
    this.handSize,
    this.wins = 0,
    this.losses = 0,
    this.gamesPlayed = 0,
    this.totalPoints = 0,
    this.trophies = 0,
    this.level = 1,
  });

  /// Top card of capture pile (available to be stolen by opponents)
  PlayingCard? get topCaptureCard =>
      capturePile.isNotEmpty ? capturePile.last : null;

  /// Number of cards captured
  int get capturedCardCount => capturePile.length;

  /// Number of spades captured (cached)
  late final int spadesCount =
      capturePile.where((c) => c.isSpade).length;

  /// Spades scoring: 5 spades = 1pt, 6+ spades = 2pts
  int get spadesScore {
    if (spadesCount >= 6) return 2;
    if (spadesCount >= 5) return 1;
    return 0;
  }

  /// Has the spy two (2S)? (cached)
  late final bool hasSpyTwo = capturePile.any((c) => c.isSpyTwo);

  /// Has the big ten (10D)? (cached)
  late final bool hasBigTen = capturePile.any((c) => c.isBigTen);

  /// Count of aces captured (cached)
  late final int aceCount = capturePile.where((c) => c.isAce).length;

  /// Calculate score for this hand
  /// NOTE: "most cards" is calculated externally (need comparison)
  int calculateHandScore({
    required bool hasMostCards,
    required bool tiedMostCards,
  }) {
    int score = 0;

    // Most cards: 2 points (1 if tied)
    if (hasMostCards) {
      score += tiedMostCards ? 1 : 2;
    }

    // Spades: 5 = 1pt, 6+ = 2pts
    score += spadesScore;

    // Spy two (2S): 1 point
    if (hasSpyTwo) score += 1;

    // Big ten (10D): 2 points
    if (hasBigTen) score += 2;

    // Aces: 1 point each
    score += aceCount;

    return score;
  }

  /// Whether this player has a card of a given rank in hand
  bool hasRankInHand(int rank) => hand.any((c) => c.rank == rank);

  /// Win rate percentage
  double get winRate =>
      gamesPlayed > 0 ? (wins / gamesPlayed) * 100 : 0.0;

  Player copyWith({
    String? id,
    String? displayName,
    String? avatarUrl,
    bool? isAI,
    List<PlayingCard>? hand,
    List<PlayingCard>? capturePile,
    int? handSize,
    int? wins,
    int? losses,
    int? gamesPlayed,
    int? totalPoints,
    int? trophies,
    int? level,
  }) {
    return Player(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isAI: isAI ?? this.isAI,
      hand: hand ?? this.hand,
      capturePile: capturePile ?? this.capturePile,
      handSize: handSize ?? this.handSize,
      wins: wins ?? this.wins,
      losses: losses ?? this.losses,
      gamesPlayed: gamesPlayed ?? this.gamesPlayed,
      totalPoints: totalPoints ?? this.totalPoints,
      trophies: trophies ?? this.trophies,
      level: level ?? this.level,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'isAI': isAI,
        'hand': hand.map((c) => c.toJson()).toList(),
        'capturePile': capturePile.map((c) => c.toJson()).toList(),
        if (handSize != null) 'handSize': handSize,
        'wins': wins,
        'losses': losses,
        'gamesPlayed': gamesPlayed,
        'totalPoints': totalPoints,
        'trophies': trophies,
        'level': level,
      };

  factory Player.fromJson(Map<String, dynamic> json) {
    return Player(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String? ?? '',
      isAI: json['isAI'] as bool? ?? false,
      hand: (json['hand'] as List?)
              ?.map(
                  (c) => PlayingCard.fromJson(c as Map<String, dynamic>))
              .toList() ??
          const [],
      capturePile: (json['capturePile'] as List?)
              ?.map(
                  (c) => PlayingCard.fromJson(c as Map<String, dynamic>))
              .toList() ??
          const [],
      handSize: json['handSize'] as int?,
      wins: json['wins'] as int? ?? 0,
      losses: json['losses'] as int? ?? 0,
      gamesPlayed: json['gamesPlayed'] as int? ?? 0,
      totalPoints: json['totalPoints'] as int? ?? 0,
      trophies: json['trophies'] as int? ?? 0,
      level: json['level'] as int? ?? 1,
    );
  }

  @override
  List<Object?> get props => [id, displayName];
}
