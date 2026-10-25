# Danish five-dice Yatzy

Research date: 2026-10-25. Project baseline: **free-choice Danish Yatzy, fixed 50-point Yatzy**, using Danspil's Danish rules. Edge-case conventions below are the solver's explicit choices.

## Publisher rules

Five dice; up to three rolls per turn. Choose which dice to reroll and stop early if desired. Choose a scorecard category freely; each category is used once. Highest total wins. [Tactic, Danish rules, PDF p. 1](https://www.tactic.net/site/rules/DK/02029.pdf).

Fill one category after every turn, including a zero if necessary. Finish when all categories are filled: 15 turns per player, inferred from the category list. [Tactic, Danish section, PDF p. 2](https://www.tactic.net/site/rules/NO/56307.pdf#page=2).

Score only the dice belonging to the combination, except Chance, which sums all five. Straights require all five consecutive values. The table gives the mathematical scoring interpretation; multiplicity edge cases are qualified below. [Tactic, Danish section, PDF p. 2](https://www.tactic.net/site/rules/NO/56307.pdf#page=2).

Let `n(v)` count dice showing `v`; `S` is the sum of all five dice.

| Category | Score when eligible | Maximum |
| --- | --- | ---: |
| Enere / ones | `n(1)` | 5 |
| Toere / twos | `2*n(2)` | 10 |
| Treere / threes | `3*n(3)` | 15 |
| Firere / fours | `4*n(4)` | 20 |
| Femmere / fives | `5*n(5)` | 25 |
| Seksere / sixes | `6*n(6)` | 30 |
| Et par / one pair | `2*v` | 12 |
| To par / two pairs | `2*a + 2*b` | 22 |
| Tre ens / three of a kind | `3*v` | 18 |
| Fire ens / four of a kind | `4*v` | 24 |
| Lille straight / small straight | `1,2,3,4,5`: 15 | 15 |
| Stor straight / large straight | `2,3,4,5,6`: 20 | 20 |
| Hus / full house | `3*a + 2*b` | 28 |
| Chance | `S` | 30 |
| Yatzy | Five identical dice: 50 | 50 |

Category maxima and examples: [Danspil, Danish section, PDF p. 4](https://danspil.dk/wp-content/uploads/2018/01/14036_regler_LR.pdf#page=4). An upper-section subtotal of **at least 63** earns **50 bonus points**; otherwise zero. This is a subtotal threshold, not a requirement to score three of each face. [Tactic, Danish section, PDF p. 2](https://www.tactic.net/site/rules/NO/56307.pdf#page=2). The published maximum total is **374**. Yatzy is always 50, independent of face value. [Danspil, PDF p. 4](https://danspil.dk/wp-content/uploads/2018/01/14036_regler_LR.pdf#page=4).

## Explicit solver conventions

The short rulebooks leave some cases unstated. Implemented interpretations:

- Dice are fair, independent six-sided dice. Every turn starts by rolling all five.
- Each reroll may select any subset, including previously kept dice. Keeping does not lock a die for the rest of the turn.
- Pair, three-of-a-kind and four-of-a-kind require **at least** 2, 3 and 4 matching dice respectively. Score only that many dice; use the highest eligible face. Thus `6,6,6,6,6` scores 12 as a pair, 18 as three of a kind, or 24 as four of a kind.
- Two pairs require **different faces** `a != b`, with `n(a) >= 2` and `n(b) >= 2`. A full house qualifies for two pairs; four or five identical dice do not.
- Full house requires **exactly** a `3+2` split between different faces. Five identical dice do not qualify. The published maxima of 22 for two pairs and 28 for full house support distinct faces: allowing one face in both groups would permit 24 and 30.
- Any unused category can be selected. It scores zero if ineligible. Chance may be chosen even when another category also fits. Publisher wording presents Chance as a fallback, without clearly resolving whether that is a restriction or advice.
- No joker substitutions or extra rewards for repeated Yatzys. The consulted rulebooks do not specify them. Once the Yatzy category is filled, later five-of-a-kind rolls can only score through other unused categories.

These choices are part of the solver specification, not claims that every Danish household uses identical rules. In particular, the rulebooks do not explicitly adjudicate larger matching groups used as smaller combinations or previously kept dice being rerolled.

## Source discrepancy

[Tactic's older Danish rules, PDF p. 1](https://www.tactic.net/site/rules/DK/02029.pdf) describe Yatzy as “50 ekstra bonus point”, which could suggest adding the dice total. The same sheet lists a 374 maximum, consistent with fixed 50. Prefer Danspil's explicit fixed-50 example and [Tactic's other Danish rulebook, PDF p. 2](https://www.tactic.net/site/rules/NO/56307.pdf#page=2), which also gives 50. Do not silently import a 35-point upper bonus, fixed 25-point full house, four-die small straight, or repeat-Yatzy bonuses from another ruleset.
