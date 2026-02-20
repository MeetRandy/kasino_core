import 'package:equatable/equatable.dart';

/// The four standard suits
enum Suit {
  spades,
  hearts,
  diamonds,
  clubs;

  String get symbol {
    switch (this) {
      case Suit.spades:
        return '\u2660';
      case Suit.hearts:
        return '\u2665';
      case Suit.diamonds:
        return '\u2666';
      case Suit.clubs:
        return '\u2663';
    }
  }

  bool get isRed => this == Suit.hearts || this == Suit.diamonds;
}

/// A single playing card in the SA Casino 40-card deck.
/// No picture cards — Ace through 10 only.
/// Ace = 1 for capture purposes.
class PlayingCard extends Equatable {
  final int rank; // 1 (Ace) through 10
  final Suit suit;
  final String id; // Unique ID for tracking in game state

  const PlayingCard({
    required this.rank,
    required this.suit,
    required this.id,
  });

  /// Display label: A, 2-10
  String get label {
    if (rank == 1) return 'A';
    return '$rank';
  }

  /// Full display name
  String get displayName => '$label${suit.symbol}';

  /// Capture value — in SA Casino, Ace = 1
  int get captureValue => rank;

  /// Is this a scoring card?
  bool get isSpyTwo => rank == 2 && suit == Suit.spades;
  bool get isBigTen => rank == 10 && suit == Suit.diamonds;
  bool get isAce => rank == 1;
  bool get isSpade => suit == Suit.spades;

  /// Points this card is worth when scoring
  int get scoringValue {
    int points = 0;
    if (isSpyTwo) points += 1;
    if (isBigTen) points += 2;
    if (isAce) points += 1;
    return points;
  }

  PlayingCard copyWith({String? id}) {
    return PlayingCard(rank: rank, suit: suit, id: id ?? this.id);
  }

  Map<String, dynamic> toJson() => {
        'rank': rank,
        'suit': suit.name,
        'id': id,
      };

  factory PlayingCard.fromJson(Map<String, dynamic> json) {
    return PlayingCard(
      rank: json['rank'] as int,
      suit: Suit.values.byName(json['suit'] as String),
      id: json['id'] as String,
    );
  }

  @override
  String toString() => displayName;

  @override
  List<Object?> get props => [rank, suit, id];
}

/// The SA Casino 40-card deck: Ace-10 in all four suits
class Deck {
  Deck._();

  /// Generate a fresh 40-card deck
  static List<PlayingCard> create() {
    final cards = <PlayingCard>[];
    int cardIndex = 0;

    for (final suit in Suit.values) {
      for (int rank = 1; rank <= 10; rank++) {
        cards.add(PlayingCard(
          rank: rank,
          suit: suit,
          id: 'card_${cardIndex++}',
        ));
      }
    }

    return cards;
  }

  /// Create and shuffle
  static List<PlayingCard> createShuffled() {
    final cards = create();
    cards.shuffle();
    return cards;
  }
}
