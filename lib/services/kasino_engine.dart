import '../models/playing_card.dart';
import '../models/player.dart';
import '../models/game_state.dart';
import '../models/build.dart';

/// Core game engine implementing South African Casino rules.
///
/// Key SA rules implemented:
/// 1. 40-card deck (A-10, no pictures)
/// 2. Deal varies by player count (2p: 10+10, 3p: 13+1, 4p: 10)
/// 3. Capture piles face-up, build order preserved, capturing card on top
/// 4. Top card of opponent's capture pile can be stolen for builds
/// 5. Stealing requires simultaneously playing a card from hand
/// 6. Can't drift if you own a build (except second deal in 2p)
/// 7. Last capturer takes remaining table cards
/// 8. Scoring: most cards (2pts), 5+ spades (1pt), spy two (1pt),
///    big ten (2pts), each ace (1pt)
class KasinoEngine {
  static const _maxActionLog = 50;

  /// Derive a deterministic build ID from the cards it contains.
  /// Stateless — no counter needed, safe for server/client sharing.
  static String _buildId(List<List<PlayingCard>> cardGroups) {
    final ids = cardGroups.expand((g) => g).map((c) => c.id).toList()..sort();
    return 'build_${ids.join('_')}';
  }

  /// Append an action to the log, capping at [_maxActionLog] entries.
  static List<GameAction> _appendAction(
      List<GameAction> log, GameAction action) {
    if (log.length >= _maxActionLog) {
      return [...log.skip(log.length - _maxActionLog + 1), action];
    }
    return [...log, action];
  }

  // ===================================================
  //  GAME INITIALIZATION
  // ===================================================

  /// Start a new game with proper dealing based on player count
  GameState initializeGame({
    required String gameId,
    required GameMode mode,
    required List<Player> players,
  }) {
    final playerCount = players.length;
    assert(playerCount >= 2 && playerCount <= 4);

    final deck = Deck.createShuffled();
    var tableCards = <PlayingCard>[];
    var drawPile = <PlayingCard>[];
    final dealtPlayers = <Player>[];

    switch (playerCount) {
      case 2:
        // 10 cards each, no table cards, remaining 20 for second deal
        dealtPlayers.add(players[0].copyWith(hand: deck.sublist(0, 10)));
        dealtPlayers.add(players[1].copyWith(hand: deck.sublist(10, 20)));
        drawPile = deck.sublist(20); // 20 cards for second deal
        break;

      case 3:
        // 13 cards each + 1 on table
        dealtPlayers.add(players[0].copyWith(hand: deck.sublist(0, 13)));
        dealtPlayers.add(players[1].copyWith(hand: deck.sublist(13, 26)));
        dealtPlayers.add(players[2].copyWith(hand: deck.sublist(26, 39)));
        tableCards = [deck[39]]; // 1 card face up
        break;

      case 4:
        // 10 cards each, no table cards
        dealtPlayers.add(players[0].copyWith(hand: deck.sublist(0, 10)));
        dealtPlayers.add(players[1].copyWith(hand: deck.sublist(10, 20)));
        dealtPlayers.add(players[2].copyWith(hand: deck.sublist(20, 30)));
        dealtPlayers.add(players[3].copyWith(hand: deck.sublist(30, 40)));
        break;
    }

    // Initialize match scores if not set
    final matchScores = <String, int>{};
    for (final p in dealtPlayers) {
      matchScores[p.id] = 0;
    }

    return GameState(
      gameId: gameId,
      mode: mode,
      phase: GamePhase.playing,
      playerCount: playerCount,
      players: dealtPlayers,
      currentPlayerIndex: 0, // First player starts
      tableCards: tableCards,
      builds: const [],
      drawPile: drawPile,
      lastCapturePlayerIndex: -1,
      matchScores: matchScores,
    );
  }

  // ===================================================
  //  CAPTURE LOGIC
  // ===================================================

  /// Find all possible captures for a given card from hand.
  ///
  /// SA Rule: When you play a card, you MUST capture ALL matching singles,
  /// ALL matching builds, AND all valid non-overlapping combinations.
  /// The only choice arises when combinations overlap (share table cards).
  List<CaptureOption> findCaptures(GameState state, PlayingCard handCard) {
    final options = <CaptureOption>[];
    final targetValue = handCard.captureValue;

    // 1. Find matching single cards on table
    final matchingSingles =
        state.tableCards.where((c) => c.captureValue == targetValue).toList();

    // 2. Find matching builds
    final matchingBuilds =
        state.builds.where((b) => b.captureValue == targetValue).toList();

    // 3. Find combinations of table cards that sum to target
    //    (exclude singles — they're already captured individually)
    final nonSingleCards = state.tableCards
        .where((c) => c.captureValue != targetValue)
        .toList();
    final combos = _findSumCombinations(nonSingleCards, targetValue);

    // SA Rule: stealing from opponent pile is ONLY allowed during builds,
    // not during regular captures.

    if (matchingSingles.isEmpty &&
        matchingBuilds.isEmpty &&
        combos.isEmpty) {
      return options;
    }

    if (combos.isEmpty) {
      // Simple: all singles + all builds, no combos
      options.add(CaptureOption(
        handCard: handCard,
        singles: matchingSingles,
        builds: matchingBuilds,
        combinations: [],
        opponentPileCards: const [],
      ));
    } else {
      // SA Rule: must take ALL singles + ALL builds + maximum combos.
      // Find the best non-overlapping set(s) of combos.
      final comboSets = _findMaxNonOverlappingCombos(combos);

      for (final comboSet in comboSets) {
        options.add(CaptureOption(
          handCard: handCard,
          singles: matchingSingles,
          builds: matchingBuilds,
          combinations: comboSet,
          opponentPileCards: const [],
        ));
      }
    }

    return options;
  }

  /// Find all maximal non-overlapping sets of combinations.
  /// Returns a list of combo sets, each set capturing the most cards.
  List<List<List<PlayingCard>>> _findMaxNonOverlappingCombos(
      List<List<PlayingCard>> combos) {
    if (combos.isEmpty) return [];
    if (combos.length == 1) return [combos];

    // Try all subsets, keep the ones with maximum total cards
    final results = <List<List<PlayingCard>>>[];
    var maxCards = 0;

    void search(int idx, List<List<PlayingCard>> chosen, Set<String> usedIds) {
      // Calculate total cards in chosen combos
      final total = chosen.fold(0, (s, c) => s + c.length);
      if (total > maxCards) {
        maxCards = total;
        results.clear();
        results.add(List.from(chosen));
      } else if (total == maxCards && chosen.isNotEmpty) {
        results.add(List.from(chosen));
      }

      for (int i = idx; i < combos.length; i++) {
        final combo = combos[i];
        // Check if this combo overlaps with already-chosen combos
        if (combo.every((c) => !usedIds.contains(c.id))) {
          chosen.add(combo);
          final newUsed = {...usedIds, ...combo.map((c) => c.id)};
          search(i + 1, chosen, newUsed);
          chosen.removeLast();
        }
      }
    }

    search(0, [], {});
    return results.isEmpty ? [[combos.first]] : results;
  }

  /// Execute a capture action
  GameState executeCapture(
    GameState state,
    PlayingCard handCard,
    CaptureOption option,
  ) {
    final playerIdx = state.currentPlayerIndex;
    final player = state.players[playerIdx];

    // Collect cards captured from table/builds (for the action log)
    final capturedFromTable = <PlayingCard>[];

    // Add singles
    capturedFromTable.addAll(option.singles);

    // Add build cards
    for (final build in option.builds) {
      capturedFromTable.addAll(build.allCards);
    }

    // Add combination cards
    for (final combo in option.combinations) {
      capturedFromTable.addAll(combo);
    }

    // Add opponent pile top cards
    capturedFromTable.addAll(option.opponentPileCards);

    // Full pile addition: captured cards + hand card on top
    final pileCards = <PlayingCard>[...capturedFromTable, handCard];

    // Update player hand (remove played card)
    final newHand = List<PlayingCard>.from(player.hand)
      ..removeWhere((c) => c.id == handCard.id);

    // Update capture pile (build order preserved, capturing card on top)
    final newCapturePile = List<PlayingCard>.from(player.capturePile)
      ..addAll(pileCards);

    // Update table (remove captured singles and combo cards)
    final capturedIds = {
      ...option.singles.map((c) => c.id),
      ...option.combinations.expand((combo) => combo.map((c) => c.id)),
    };
    final newTableCards = state.tableCards
        .where((c) => !capturedIds.contains(c.id))
        .toList();

    // Update builds (remove captured builds)
    final capturedBuildIds = option.builds.map((b) => b.id).toSet();
    final newBuilds = state.builds
        .where((b) => !capturedBuildIds.contains(b.id))
        .toList();

    // Update opponent capture piles (remove stolen top cards)
    final stolenIds = option.opponentPileCards.map((c) => c.id).toSet();
    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIdx] = player.copyWith(
      hand: newHand,
      capturePile: newCapturePile,
    );

    // Remove stolen cards from opponent piles
    for (int i = 0; i < updatedPlayers.length; i++) {
      if (i == playerIdx) continue;
      final opPile = updatedPlayers[i].capturePile;
      if (opPile.isNotEmpty && stolenIds.contains(opPile.last.id)) {
        updatedPlayers[i] = updatedPlayers[i].copyWith(
          capturePile: opPile.sublist(0, opPile.length - 1),
        );
      }
    }

    // Log action
    final action = GameAction(
      playerId: player.id,
      type: ActionType.capture,
      cardPlayed: handCard,
      cardsCaptured: capturedFromTable,
      description:
          '${player.displayName} captured ${capturedFromTable.length} cards with ${handCard.displayName}',
      timestamp: DateTime.now(),
    );

    return state.copyWith(
      players: updatedPlayers,
      tableCards: newTableCards,
      builds: newBuilds,
      lastCapturePlayerIndex: playerIdx,
      actionLog: _appendAction(state.actionLog, action),
    );
  }

  // ===================================================
  //  BUILD LOGIC
  // ===================================================

  /// Create a new build from table cards (optionally + hand card).
  /// SA Rule: When building, you may steal an opponent's top capture card
  /// if it matches the build's declared value. A hand card must be played
  /// simultaneously when stealing.
  GameState createBuild(
    GameState state, {
    required PlayingCard? handCard, // Card from hand (optional)
    required List<PlayingCard> tableCardsForBuild, // Cards from table
    required int declaredValue, // Must have matching card in hand
    List<PlayingCard> stolenCards = const [], // Opponent's capture pile cards (cascading)
  }) {
    final playerIdx = state.currentPlayerIndex;
    final player = state.players[playerIdx];

    // SA Rule: stealing requires simultaneously playing a hand card
    if (stolenCards.isNotEmpty && handCard == null) return state;

    // SA Rule: a player can only own ONE build at a time.
    // If they already own a build of a different value, reject.
    final ownedBuild = state.builds.cast<Build?>().firstWhere(
          (b) => b!.ownerId == player.id,
          orElse: () => null,
        );
    if (ownedBuild != null && ownedBuild.captureValue != declaredValue) {
      return state; // Must capture or augment existing build first
    }

    // Validate: player must have a card matching declared value in hand
    // (and it can't be the card being played into the build)
    final hasCapture = player.hand.any((c) =>
        c.captureValue == declaredValue &&
        (handCard == null || c.id != handCard.id));
    if (!hasCapture) return state;

    // Collect all cards that form the build
    final allBuildCards = <PlayingCard>[
      ...tableCardsForBuild,
      if (handCard != null) handCard,
      ...stolenCards,
    ];

    // Partition all build cards into groups, each summing to declaredValue.
    // This handles: same-value builds (9+9), sum builds (3+6), and mixed
    // scenarios like hand 3 + stolen 6 = 9 AND stolen 3 + table 6 = 9.
    final cardGroups = _findCardPartition(allBuildCards, declaredValue);
    if (cardGroups == null) return state;

    // SA Rule: Any unselected table cards matching the declared value must
    // be auto-included in the build (e.g. building 8 from 4+4, a loose 8
    // on the table joins as a separate group).
    final selectedIds = tableCardsForBuild.map((c) => c.id).toSet();
    final autoIncluded = state.tableCards.where(
      (c) => c.captureValue == declaredValue && !selectedIds.contains(c.id),
    ).toList();
    for (final c in autoIncluded) {
      cardGroups.add([c]);
    }

    // SA Rule: same-value builds must be merged, not kept separate.
    // Check if the player already owns a build of this value.
    final existingBuild = state.builds.cast<Build?>().firstWhere(
          (b) => b!.ownerId == player.id && b.captureValue == declaredValue,
          orElse: () => null,
        );

    late final Build finalBuild;
    late final List<Build> newBuilds;

    if (existingBuild != null) {
      // Merge new groups into existing build (augment)
      finalBuild = existingBuild.copyWith(
        cardGroups: [...existingBuild.cardGroups, ...cardGroups],
      );
      newBuilds = state.builds
          .map((b) => b.id == existingBuild.id ? finalBuild : b)
          .toList();
    } else {
      // Create a fresh build
      finalBuild = Build(
        id: _buildId(cardGroups),
        ownerId: player.id,
        captureValue: declaredValue,
        cardGroups: cardGroups,
      );
      newBuilds = [...state.builds, finalBuild];
    }

    // Update hand
    final newHand = List<PlayingCard>.from(player.hand);
    if (handCard != null) {
      newHand.removeWhere((c) => c.id == handCard.id);
    }

    // Remove used table cards (selected + auto-included)
    final usedIds = selectedIds.union(autoIncluded.map((c) => c.id).toSet());
    final newTableCards =
        state.tableCards.where((c) => !usedIds.contains(c.id)).toList();

    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIdx] = player.copyWith(hand: newHand);

    // Remove stolen cards from opponent's capture pile (peel from top)
    if (stolenCards.isNotEmpty) {
      final stolenIds = stolenCards.map((c) => c.id).toSet();
      for (int i = 0; i < updatedPlayers.length; i++) {
        if (i == playerIdx) continue;
        final pile = updatedPlayers[i].capturePile;
        // Remove all stolen cards from the end of the pile
        final newPile = List<PlayingCard>.from(pile);
        newPile.removeWhere((c) => stolenIds.contains(c.id));
        if (newPile.length != pile.length) {
          updatedPlayers[i] = updatedPlayers[i].copyWith(
            capturePile: newPile,
          );
        }
      }
    }

    final actionType = stolenCards.isNotEmpty
        ? ActionType.stealAndBuild
        : existingBuild != null
            ? ActionType.buildAugment
            : ActionType.buildCreate;

    final stolenNames = stolenCards.map((c) => c.displayName).join(', ');

    return state.copyWith(
      players: updatedPlayers,
      tableCards: newTableCards,
      builds: newBuilds,
      actionLog: _appendAction(state.actionLog, GameAction(
          playerId: player.id,
          type: actionType,
          cardPlayed: handCard ?? tableCardsForBuild.first,
          cardsCaptured: stolenCards.isNotEmpty ? stolenCards : const [],
          description: stolenCards.isNotEmpty
              ? '${player.displayName} built ${finalBuild.displayString} (stole $stolenNames)'
              : '${player.displayName} built ${finalBuild.displayString}',
          timestamp: DateTime.now(),
        )),
    );
  }

  /// Augment an existing build
  GameState augmentBuild(
    GameState state, {
    required Build existingBuild,
    required List<PlayingCard> additionalCards, // From table/hand
    PlayingCard? handCard,
    PlayingCard? stolenCard, // From opponent's capture pile
  }) {
    final playerIdx = state.currentPlayerIndex;
    final player = state.players[playerIdx];

    // SA Rule: stealing from opponent pile requires simultaneous hand card play
    if (stolenCard != null && handCard == null) return state;

    // Validate: additional cards sum to the build's capture value
    final newGroupCards = <PlayingCard>[
      ...additionalCards,
      if (handCard != null) handCard,
      if (stolenCard != null) stolenCard,
    ];
    final sum = newGroupCards.fold(0, (s, c) => s + c.captureValue);
    if (sum != existingBuild.captureValue) return state;

    // Must own the build
    if (existingBuild.ownerId != player.id) return state;

    // Must still have a capture card after playing the hand card
    if (handCard != null) {
      final hasCapture = player.hand.any(
        (c) =>
            c.captureValue == existingBuild.captureValue &&
            c.id != handCard.id,
      );
      if (!hasCapture) return state;
    }

    // Create augmented build
    final newGroups = [
      ...existingBuild.cardGroups,
      newGroupCards,
    ];
    final updatedBuild = existingBuild.copyWith(cardGroups: newGroups);

    // Update hand
    final newHand = List<PlayingCard>.from(player.hand);
    if (handCard != null) {
      newHand.removeWhere((c) => c.id == handCard.id);
    }

    // Remove table cards used
    final usedTableIds = additionalCards.map((c) => c.id).toSet();
    final newTableCards =
        state.tableCards.where((c) => !usedTableIds.contains(c.id)).toList();

    // Update builds
    final newBuilds = state.builds
        .map((b) => b.id == existingBuild.id ? updatedBuild : b)
        .toList();

    // Update players
    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIdx] = player.copyWith(hand: newHand);

    // Remove stolen card from opponent pile
    if (stolenCard != null) {
      for (int i = 0; i < updatedPlayers.length; i++) {
        if (i == playerIdx) continue;
        final pile = updatedPlayers[i].capturePile;
        if (pile.isNotEmpty && pile.last.id == stolenCard.id) {
          updatedPlayers[i] = updatedPlayers[i].copyWith(
            capturePile: pile.sublist(0, pile.length - 1),
          );
        }
      }
    }

    return state.copyWith(
      players: updatedPlayers,
      tableCards: newTableCards,
      builds: newBuilds,
      actionLog: _appendAction(state.actionLog, GameAction(
          playerId: player.id,
          type: ActionType.buildAugment,
          cardPlayed: handCard ?? additionalCards.first,
          description:
              '${player.displayName} augmented build to ${updatedBuild.displayString}',
          timestamp: DateTime.now(),
        )),
    );
  }

  /// Increase an existing build's value by adding a hand card.
  /// SA Rule: Can only increase an OPPONENT's build (not your own).
  /// The build must be single-group (not augmented) and not already 10.
  /// The player who increases it becomes the new owner.
  GameState increaseBuild(
    GameState state, {
    required Build existingBuild,
    required PlayingCard handCard,
    required int newDeclaredValue,
  }) {
    final playerIdx = state.currentPlayerIndex;
    final player = state.players[playerIdx];

    // SA Rule: can only increase opponent's build, not your own
    if (existingBuild.ownerId == player.id) return state;

    // Can't increase augmented (multi-group) builds
    if (existingBuild.isAugmented) return state;

    // New value must equal build + hand card
    if (existingBuild.captureValue + handCard.captureValue != newDeclaredValue) {
      return state;
    }
    if (newDeclaredValue > 10) return state;

    // Player must have another card matching the new value
    final hasCapture = player.hand.any(
      (c) => c.captureValue == newDeclaredValue && c.id != handCard.id,
    );
    if (!hasCapture) return state;

    // Create the increased build group
    final increasedGroup = [...existingBuild.allCards, handCard];

    // Check if the player already owns another build of the new value
    // (must merge to prevent duplicate same-value builds).
    final mergeTarget = state.builds.cast<Build?>().firstWhere(
          (b) =>
              b!.id != existingBuild.id &&
              b.ownerId == player.id &&
              b.captureValue == newDeclaredValue,
          orElse: () => null,
        );

    late final List<Build> newBuilds;

    if (mergeTarget != null) {
      // Merge increased build into existing same-value build, remove old
      final mergedBuild = mergeTarget.copyWith(
        cardGroups: [...mergeTarget.cardGroups, increasedGroup],
      );
      newBuilds = state.builds
          .where((b) => b.id != existingBuild.id)
          .map((b) => b.id == mergeTarget.id ? mergedBuild : b)
          .toList();
    } else {
      // Replace existing build with new value
      final newBuild = Build(
        id: existingBuild.id,
        ownerId: player.id,
        captureValue: newDeclaredValue,
        cardGroups: [increasedGroup],
      );
      newBuilds = state.builds
          .map((b) => b.id == existingBuild.id ? newBuild : b)
          .toList();
    }

    // Remove hand card
    final newHand = List<PlayingCard>.from(player.hand)
      ..removeWhere((c) => c.id == handCard.id);

    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIdx] = player.copyWith(hand: newHand);

    return state.copyWith(
      players: updatedPlayers,
      builds: newBuilds,
      actionLog: _appendAction(state.actionLog, GameAction(
          playerId: player.id,
          type: ActionType.buildAugment,
          cardPlayed: handCard,
          description:
              '${player.displayName} increased build to $newDeclaredValue',
          timestamp: DateTime.now(),
        )),
    );
  }

  // ===================================================
  //  DRIFT (play card to table without capturing)
  // ===================================================

  /// Drift: play a card to the table without capturing
  /// SA Rule: Cannot drift if you own a build (except second deal)
  GameState drift(GameState state, PlayingCard handCard) {
    if (!state.canCurrentPlayerDrift) return state; // Blocked

    final playerIdx = state.currentPlayerIndex;
    final player = state.players[playerIdx];

    final newHand = List<PlayingCard>.from(player.hand)
      ..removeWhere((c) => c.id == handCard.id);

    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIdx] = player.copyWith(hand: newHand);

    return state.copyWith(
      players: updatedPlayers,
      tableCards: [...state.tableCards, handCard],
      actionLog: _appendAction(state.actionLog, GameAction(
          playerId: player.id,
          type: ActionType.drift,
          cardPlayed: handCard,
          description:
              '${player.displayName} drifted ${handCard.displayName}',
          timestamp: DateTime.now(),
        )),
    );
  }

  // ===================================================
  //  TURN & DEAL MANAGEMENT
  // ===================================================

  /// Advance to next player's turn
  GameState nextTurn(GameState state) {
    var newState = state.copyWith(
      currentPlayerIndex: state.nextPlayerIndex,
    );

    // Check if all hands are empty
    if (newState.allHandsEmpty) {
      if (newState.playerCount == 2 &&
          !newState.isSecondDeal &&
          newState.drawPile.isNotEmpty) {
        // Second deal for 2-player game
        newState = _dealSecondRound(newState);
      } else {
        // End of hand — score it
        newState = _endHand(newState);
      }
    }

    return newState;
  }

  /// Deal the second round of 10 cards each (2-player only)
  GameState _dealSecondRound(GameState state) {
    assert(state.playerCount == 2);
    assert(state.drawPile.length == 20);

    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[0] = updatedPlayers[0].copyWith(
      hand: state.drawPile.sublist(0, 10),
    );
    updatedPlayers[1] = updatedPlayers[1].copyWith(
      hand: state.drawPile.sublist(10, 20),
    );

    return state.copyWith(
      players: updatedPlayers,
      drawPile: [],
      isSecondDeal: true,
      phase: GamePhase.playingSecond,
      currentPlayerIndex: 0, // First player starts again
    );
  }

  /// End of hand: last capturer takes remaining table cards, then score
  GameState _endHand(GameState state) {
    var updatedPlayers = List<Player>.from(state.players);

    // Last capturer takes remaining table cards
    if (state.lastCapturePlayerIndex >= 0) {
      final lastIdx = state.lastCapturePlayerIndex;
      final remainingCards = [
        ...state.tableCards,
        ...state.builds.expand((b) => b.allCards),
      ];

      if (remainingCards.isNotEmpty) {
        updatedPlayers[lastIdx] = updatedPlayers[lastIdx].copyWith(
          capturePile: [
            ...updatedPlayers[lastIdx].capturePile,
            ...remainingCards,
          ],
        );
      }
    }

    return state.copyWith(
      players: updatedPlayers,
      tableCards: [],
      builds: [],
      phase: GamePhase.scoring,
    );
  }

  // ===================================================
  //  SCORING
  // ===================================================

  /// Calculate scores for all players after a hand
  Map<String, int> calculateScores(GameState state) {
    final scores = <String, int>{};
    final players = state.players;

    // Determine who has most cards
    int maxCards = 0;
    for (final p in players) {
      if (p.capturedCardCount > maxCards) maxCards = p.capturedCardCount;
    }
    final playersWithMostCards =
        players.where((p) => p.capturedCardCount == maxCards).toList();
    final tiedMostCards = playersWithMostCards.length > 1;

    for (final player in players) {
      scores[player.id] = player.calculateHandScore(
        hasMostCards: player.capturedCardCount == maxCards,
        tiedMostCards: tiedMostCards,
      );
    }

    return scores;
  }

  /// Apply hand scores to match totals and check for winner
  GameState applyScores(GameState state) {
    final handScores = calculateScores(state);
    final newMatchScores = Map<String, int>.from(state.matchScores);

    for (final entry in handScores.entries) {
      newMatchScores[entry.key] =
          (newMatchScores[entry.key] ?? 0) + entry.value;
    }

    // Tiebreaker: if hand scores match AND match scores match,
    // whoever has 21+ captured cards gets +1 point.
    final handValues = handScores.values.toSet();
    final matchValues = newMatchScores.values.toSet();
    if (handValues.length == 1 && matchValues.length == 1) {
      for (final player in state.players) {
        if (player.capturedCardCount >= 21) {
          newMatchScores[player.id] = (newMatchScores[player.id] ?? 0) + 1;
        }
      }
    }

    // Check if anyone reached target score
    final winners = newMatchScores.entries
        .where((e) => e.value >= state.targetScore)
        .toList();

    if (winners.isNotEmpty) {
      return state.copyWith(
        matchScores: newMatchScores,
        phase: GamePhase.gameOver,
      );
    }

    return state.copyWith(
      matchScores: newMatchScores,
      phase: GamePhase.scoring,
    );
  }

  // ===================================================
  //  UTILITY
  // ===================================================

  /// Partition cards into groups where each group sums to [target].
  /// Returns the groups, or null if no valid partition exists.
  List<List<PlayingCard>>? _findCardPartition(
    List<PlayingCard> cards,
    int target,
  ) {
    if (cards.isEmpty) return [];
    final total = cards.fold<int>(0, (s, c) => s + c.captureValue);
    if (total % target != 0) return null;
    if (cards.any((c) => c.captureValue > target)) return null;

    final numGroups = total ~/ target;
    final groups =
        List<List<PlayingCard>>.generate(numGroups, (_) => []);
    final sums = List<int>.filled(numGroups, 0);

    // Sort descending for better pruning
    final sorted = List<PlayingCard>.from(cards)
      ..sort((a, b) => b.captureValue.compareTo(a.captureValue));

    if (_partitionBacktrack(sorted, groups, sums, target, 0)) {
      return groups;
    }
    return null;
  }

  bool _partitionBacktrack(
    List<PlayingCard> cards,
    List<List<PlayingCard>> groups,
    List<int> sums,
    int target,
    int index,
  ) {
    if (index == cards.length) return true;

    final card = cards[index];
    final seen = <int>{};

    for (int i = 0; i < groups.length; i++) {
      if (sums[i] + card.captureValue > target) continue;
      // Skip duplicate group states (same sum) to avoid redundant work
      if (seen.contains(sums[i])) continue;
      seen.add(sums[i]);

      groups[i].add(card);
      sums[i] += card.captureValue;
      if (_partitionBacktrack(cards, groups, sums, target, index + 1)) {
        return true;
      }
      groups[i].removeLast();
      sums[i] -= card.captureValue;
    }

    return false;
  }

  /// Find all subsets of cards that sum to a target value.
  /// Sorted descending + suffix-sum pruning for early termination.
  List<List<PlayingCard>> _findSumCombinations(
    List<PlayingCard> cards,
    int target,
  ) {
    if (cards.isEmpty || target <= 0) return [];
    // Sort descending — larger values first prunes the search tree faster
    final sorted = List<PlayingCard>.from(cards)
      ..sort((a, b) => b.captureValue.compareTo(a.captureValue));
    // Precompute suffix sums: suffixSum[i] = sum of sorted[i..n-1]
    final n = sorted.length;
    final suffixSum = List<int>.filled(n + 1, 0);
    for (int i = n - 1; i >= 0; i--) {
      suffixSum[i] = suffixSum[i + 1] + sorted[i].captureValue;
    }
    final results = <List<PlayingCard>>[];
    _findSubsets(sorted, suffixSum, target, 0, [], results);
    // Filter out single-card matches (those are handled as singles)
    return results.where((r) => r.length >= 2).toList();
  }

  void _findSubsets(
    List<PlayingCard> cards,
    List<int> suffixSum,
    int remaining,
    int startIndex,
    List<PlayingCard> current,
    List<List<PlayingCard>> results,
  ) {
    if (remaining == 0 && current.isNotEmpty) {
      results.add(List.from(current));
      return;
    }
    if (remaining < 0 || startIndex >= cards.length) return;
    // Prune: even taking all remaining cards can't reach target
    if (suffixSum[startIndex] < remaining) return;

    for (int i = startIndex; i < cards.length; i++) {
      final val = cards[i].captureValue;
      // Skip: this card alone exceeds remaining (sorted desc -> all after are <=)
      if (val > remaining) continue;
      current.add(cards[i]);
      _findSubsets(cards, suffixSum, remaining - val, i + 1, current, results);
      current.removeLast();
    }
  }
}

/// Represents a possible capture option for the player
class CaptureOption {
  final PlayingCard handCard;
  final List<PlayingCard> singles;         // Matching single cards
  final List<Build> builds;                // Matching builds
  final List<List<PlayingCard>> combinations; // Card combos summing to value
  final List<PlayingCard> opponentPileCards;  // Stolen top cards

  const CaptureOption({
    required this.handCard,
    this.singles = const [],
    this.builds = const [],
    this.combinations = const [],
    this.opponentPileCards = const [],
  });

  /// Total cards captured (not counting the hand card)
  int get totalCaptured {
    int count = singles.length;
    count += builds.fold(0, (s, b) => s + b.cardCount);
    count += combinations.fold(0, (s, combo) => s + combo.length);
    count += opponentPileCards.length;
    return count;
  }

  /// All captured cards flattened
  List<PlayingCard> get allCapturedCards => [
        ...singles,
        ...builds.expand((b) => b.allCards),
        ...combinations.expand((combo) => combo),
        ...opponentPileCards,
      ];

  /// Description of capture
  String get description {
    final parts = <String>[];
    if (singles.isNotEmpty) {
      parts.add(singles.map((c) => c.displayName).join(', '));
    }
    if (builds.isNotEmpty) {
      parts.add('build(s) of ${builds.first.captureValue}');
    }
    if (combinations.isNotEmpty) {
      for (final combo in combinations) {
        parts.add(combo.map((c) => c.displayName).join('+'));
      }
    }
    if (opponentPileCards.isNotEmpty) {
      parts.add(
          'stole ${opponentPileCards.map((c) => c.displayName).join(', ')}');
    }
    return parts.join(' & ');
  }
}
