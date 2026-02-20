import 'dart:math';
import '../models/playing_card.dart';
import '../models/game_state.dart';
import 'kasino_engine.dart';

enum AIDifficulty {
  easy,     // Mostly random, misses combos
  medium,   // Basic capture priority
  hard,     // Optimal captures, build strategy
  expert,   // Tracks cards, maximizes scoring
}

/// AI opponent for single-player SA Casino
class KasinoAI {
  final AIDifficulty difficulty;
  final KasinoEngine _engine = KasinoEngine();
  final Random _random = Random();

  KasinoAI({this.difficulty = AIDifficulty.medium});

  /// Decide and execute the AI's turn, returning the updated state
  GameState playTurn(GameState state) {
    final aiPlayer = state.currentPlayer;

    if (aiPlayer.hand.isEmpty) return state;

    switch (difficulty) {
      case AIDifficulty.easy:
        return _playEasy(state);
      case AIDifficulty.medium:
        return _playMedium(state);
      case AIDifficulty.hard:
      case AIDifficulty.expert:
        return _playHard(state);
    }
  }

  /// Easy: random card, capture if obvious single match
  GameState _playEasy(GameState state) {
    final hand = state.currentPlayer.hand;
    final card = hand[_random.nextInt(hand.length)];

    // Try simple captures
    final options = _engine.findCaptures(state, card);
    if (options.isNotEmpty) {
      return _engine.executeCapture(state, card, options.first);
    }

    // Drift if allowed
    if (state.canCurrentPlayerDrift) {
      return _engine.drift(state, card);
    }

    // If can't drift (owns a build), try another card
    for (final altCard in hand) {
      final altOptions = _engine.findCaptures(state, altCard);
      if (altOptions.isNotEmpty) {
        return _engine.executeCapture(state, altCard, altOptions.first);
      }
    }

    // Last resort: drift with any card (shouldn't happen if rules are correct)
    return _engine.drift(state, card);
  }

  /// Medium: prioritize captures by value, prefer scoring cards
  GameState _playMedium(GameState state) {
    final hand = state.currentPlayer.hand;

    // Score each possible play
    var bestScore = -1.0;
    PlayingCard? bestCard;
    CaptureOption? bestOption;

    for (final card in hand) {
      final options = _engine.findCaptures(state, card);
      for (final option in options) {
        final score = _scoreCaptureOption(option);
        if (score > bestScore) {
          bestScore = score;
          bestCard = card;
          bestOption = option;
        }
      }
    }

    // Execute best capture if found
    if (bestCard != null && bestOption != null && bestScore > 0) {
      return _engine.executeCapture(state, bestCard, bestOption);
    }

    // Try building if no good captures
    final buildState = _tryCreateBuild(state);
    if (buildState != null) return buildState;

    // Drift with the least valuable card
    if (state.canCurrentPlayerDrift) {
      final driftCard = _leastValuableCard(hand);
      return _engine.drift(state, driftCard);
    }

    // Forced to capture with something
    for (final card in hand) {
      final options = _engine.findCaptures(state, card);
      if (options.isNotEmpty) {
        return _engine.executeCapture(state, card, options.first);
      }
    }

    return _engine.drift(state, hand.first);
  }

  /// Hard/Expert: optimal play with card tracking and build strategy
  GameState _playHard(GameState state) {
    final hand = state.currentPlayer.hand;

    // Phase 1: Find the best capture (maximize card count + scoring cards)
    var bestScore = -1.0;
    PlayingCard? bestCard;
    CaptureOption? bestOption;

    for (final card in hand) {
      final options = _engine.findCaptures(state, card);
      for (final option in options) {
        final score = _scoreCaptureFull(option, state);
        if (score > bestScore) {
          bestScore = score;
          bestCard = card;
          bestOption = option;
        }
      }
    }

    // If there's a high-value capture, take it
    if (bestCard != null && bestOption != null && bestScore >= 3.0) {
      return _engine.executeCapture(state, bestCard, bestOption);
    }

    // Phase 2: Consider building if we can set up a bigger capture
    final buildState = _tryStrategicBuild(state);
    if (buildState != null) return buildState;

    // Phase 3: Take any capture available
    if (bestCard != null && bestOption != null && bestScore > 0) {
      return _engine.executeCapture(state, bestCard, bestOption);
    }

    // Phase 4: Drift strategically
    if (state.canCurrentPlayerDrift) {
      final driftCard = _safestDrift(state);
      return _engine.drift(state, driftCard);
    }

    // Fallback
    for (final card in hand) {
      final options = _engine.findCaptures(state, card);
      if (options.isNotEmpty) {
        return _engine.executeCapture(state, card, options.first);
      }
    }

    return _engine.drift(state, hand.first);
  }

  // --- Scoring Heuristics ---

  /// Basic capture scoring
  double _scoreCaptureOption(CaptureOption option) {
    double score = option.totalCaptured.toDouble();

    // Bonus for scoring cards
    for (final card in option.allCapturedCards) {
      if (card.isSpyTwo) score += 5;
      if (card.isBigTen) score += 8;
      if (card.isAce) score += 3;
      if (card.isSpade) score += 0.5;
    }

    // Bonus for stealing from opponent pile
    score += option.opponentPileCards.length * 2;

    return score;
  }

  /// Full capture scoring (expert level)
  double _scoreCaptureFull(CaptureOption option, GameState state) {
    double score = _scoreCaptureOption(option);

    // Bonus for total card count advantage
    final myCards = state.currentPlayer.capturedCardCount + option.totalCaptured;
    final maxOpponent = state.getOpponents(state.currentPlayer.id)
        .fold(0, (max, p) => p.capturedCardCount > max ? p.capturedCardCount : max);
    if (myCards > maxOpponent) score += 3; // We're winning the card count race

    // Bonus for clearing the table
    if (option.totalCaptured == state.tableCards.length) score += 1;

    return score;
  }

  /// Find the least valuable card to drift
  PlayingCard _leastValuableCard(List<PlayingCard> hand) {
    // Prefer drifting low cards that aren't scoring cards
    final sorted = List<PlayingCard>.from(hand)
      ..sort((a, b) {
        final aValue = a.scoringValue * 10 + a.rank;
        final bValue = b.scoringValue * 10 + b.rank;
        return aValue.compareTo(bValue);
      });
    return sorted.first;
  }

  /// Choose safest card to drift (hard mode)
  PlayingCard _safestDrift(GameState state) {
    final hand = state.currentPlayer.hand;
    final tableValues = state.tableCards.map((c) => c.captureValue).toSet();

    // Avoid drifting cards that match table cards (opponent could combo)
    final safCards = hand.where((c) => !tableValues.contains(c.captureValue)).toList();

    if (safCards.isNotEmpty) {
      return _leastValuableCard(safCards);
    }

    return _leastValuableCard(hand);
  }

  /// Find stealable opponent top capture cards matching a value
  PlayingCard? _findStealableCard(GameState state, int value) {
    final opponents = state.getOpponents(state.currentPlayer.id);
    for (final opp in opponents) {
      if (opp.capturePile.isNotEmpty &&
          opp.capturePile.last.captureValue == value) {
        return opp.capturePile.last;
      }
    }
    return null;
  }

  /// Try to create a basic build (with optional steal)
  GameState? _tryCreateBuild(GameState state) {
    final hand = state.currentPlayer.hand;
    final table = state.tableCards;

    // Look for pairs of table cards that sum to a card in our hand
    for (final targetCard in hand) {
      for (int i = 0; i < table.length; i++) {
        for (int j = i + 1; j < table.length; j++) {
          if (table[i].captureValue + table[j].captureValue ==
              targetCard.captureValue) {
            final hasSecondCapture = hand
                .where((c) =>
                    c.id != targetCard.id &&
                    c.captureValue == targetCard.captureValue)
                .isNotEmpty;

            if (hasSecondCapture || hand.length > 1) {
              // Check if we can steal an opponent's top card too
              final stealable =
                  _findStealableCard(state, targetCard.captureValue);

              // Build from table cards only (no hand card used)
              return _engine.createBuild(
                state,
                handCard: null,
                tableCardsForBuild: [table[i], table[j]],
                declaredValue: targetCard.captureValue,
                stolenCards: stealable != null ? [stealable] : const [],
              );
            }
          }
        }

        // Single table card + hand card = build
        for (final playCard in hand) {
          if (playCard.id == targetCard.id) continue;
          if (table[i].captureValue + playCard.captureValue ==
              targetCard.captureValue) {
            // Check if we can steal (requires hand card, which we have)
            final stealable =
                _findStealableCard(state, targetCard.captureValue);

            return _engine.createBuild(
              state,
              handCard: playCard,
              tableCardsForBuild: [table[i]],
              declaredValue: targetCard.captureValue,
              stolenCards: stealable != null ? [stealable] : const [],
            );
          }
        }
      }
    }

    return null;
  }

  /// Strategic build creation (expert) — prefer builds that steal
  GameState? _tryStrategicBuild(GameState state) {
    final hand = state.currentPlayer.hand;
    final table = state.tableCards;

    // First: look for builds that can steal from opponent
    for (final targetCard in hand) {
      final stealable =
          _findStealableCard(state, targetCard.captureValue);
      if (stealable == null) continue;

      // Try to find table cards that build to this value
      for (int i = 0; i < table.length; i++) {
        for (int j = i + 1; j < table.length; j++) {
          if (table[i].captureValue + table[j].captureValue ==
              targetCard.captureValue) {
            return _engine.createBuild(
              state,
              handCard: null,
              tableCardsForBuild: [table[i], table[j]],
              declaredValue: targetCard.captureValue,
              stolenCards: [stealable],
            );
          }
        }

        // Hand card + single table card
        for (final playCard in hand) {
          if (playCard.id == targetCard.id) continue;
          if (table[i].captureValue + playCard.captureValue ==
              targetCard.captureValue) {
            return _engine.createBuild(
              state,
              handCard: playCard,
              tableCardsForBuild: [table[i]],
              declaredValue: targetCard.captureValue,
              stolenCards: [stealable],
            );
          }
        }
      }
    }

    // Fallback to normal build
    return _tryCreateBuild(state);
  }
}
