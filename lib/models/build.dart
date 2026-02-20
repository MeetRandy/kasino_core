import 'package:equatable/equatable.dart';
import 'playing_card.dart';

/// Represents a build on the table — a stack of cards with a declared capture value.
///
/// SA Casino build rules:
/// - A build has a declared capture value (sum of cards in it)
/// - The build owner must have a card in hand that can capture it
/// - If you have a build, you cannot drift (must add to build or capture)
/// - Opponent can steal top of your capture pile to add to THEIR build,
///   but ONLY if they simultaneously play a card from hand
class Build extends Equatable {
  final String id;
  final String ownerId; // Player who owns this build
  final int captureValue; // The declared value of this build
  final List<List<PlayingCard>> cardGroups; // Groups of cards that each sum to captureValue

  Build({
    required this.id,
    required this.ownerId,
    required this.captureValue,
    required this.cardGroups,
  });

  /// All cards in this build flattened (cached).
  late final List<PlayingCard> allCards =
      List.unmodifiable(cardGroups.expand((group) => group));

  /// Total number of cards in the build
  late final int cardCount = allCards.length;

  /// Whether this is an augmented build (multiple groups of same value)
  bool get isAugmented => cardGroups.length > 1;

  /// Display string for the build
  String get displayString {
    final groups = cardGroups
        .map((g) => g.map((c) => c.displayName).join('+'))
        .join(' | ');
    return '[$captureValue: $groups]';
  }

  Build copyWith({
    String? id,
    String? ownerId,
    int? captureValue,
    List<List<PlayingCard>>? cardGroups,
  }) {
    return Build(
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      captureValue: captureValue ?? this.captureValue,
      cardGroups: cardGroups ?? this.cardGroups,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ownerId': ownerId,
        'captureValue': captureValue,
        'cardGroups': cardGroups
            .map((g) => g.map((c) => c.toJson()).toList())
            .toList(),
      };

  factory Build.fromJson(Map<String, dynamic> json) {
    return Build(
      id: json['id'] as String,
      ownerId: json['ownerId'] as String,
      captureValue: json['captureValue'] as int,
      cardGroups: (json['cardGroups'] as List)
          .map((g) => (g as List)
              .map((c) => PlayingCard.fromJson(c as Map<String, dynamic>))
              .toList())
          .toList(),
    );
  }

  @override
  List<Object?> get props => [id, ownerId, captureValue, cardGroups];
}
