# Danish Yatzy, solved in Roc

I watched [*I Solved Yahtzee\** by Ballpark Figures](https://www.youtube.com/watch?v=DOgb5wrb7mM),
then played with my family. Our Danish version has a **50-point upper bonus**,
**one pair**, and **two pairs**. I wanted to solve that version—and have an
excuse to play with [Roc](https://www.roc-lang.org/).

The optimal expected score is **248.439989 points**. The solver explores every
legal choice using dynamic programming and fair-dice probabilities, with
`F64` arithmetic. The objective is maximum expected score.

## Try it

Install [Mise](https://mise.jdx.dev/) and Python 3.9+ for the verification tools.
The Roc nightly and CLI platform are pinned; the first build downloads them.

```sh
mise install
mise exec -- roc build --opt=speed --output=/var/tmp/yatzy main.roc
/var/tmp/yatzy solve
# expected-additional-score=248.4399893778553 states=947711
```

For an endgame with only sixes and chance left, an upper subtotal of 57,
and two rerolls remaining:

```sh
/var/tmp/yatzy advise sixes,chance 57 6,6,1,2,3 2
```

| Command | What it does |
| --- | --- |
| `solve [categories subtotal]` | Expected additional score; no arguments starts a new game. |
| `advise categories subtotal dice rerolls` | Choose a category or dice to keep. |
| `score category dice` | Score a specific roll. |
| `rank [categories subtotal]` | Compare ideal scores now, followed by optimal normal play. |

Categories are **unused** slots. The subtotal is upper points already earned,
excluding the bonus. Dice and category lists are comma-separated; `all` means
all categories and `-` means none. Run `/var/tmp/yatzy --help` for their names.

## The small state

Between turns, the memo key is just **a 15-bit mask of unused categories and
points still needed for the bonus**. Past points are additive, so their total
can be forgotten. Pay the bonus when it is reached; bonus-earned and
bonus-impossible states then have the same continuation value. The key fits
in a `U32`.

Within a turn, only face counts and remaining rerolls matter: **252 unordered
rolls** instead of 7,776 ordered ones. A reusable lattice of **462 partial
hands** computes reroll expectations by adding one uniform die at a time.
Only turn-boundary values are memoized; dice tables are temporary workspace.
A full solve visits **947,711** such boundary states.

The implementation is in [Solver.roc](Solver.roc); scoring and dice
combinations live in [Yatzy.roc](Yatzy.roc).

## How fast?

**25.335 seconds** for a full solve on an **Apple M5, 32 GiB RAM**,
macOS 26.6.2. Median of five fresh processes; range **25.300–25.518 s**.
The solver uses one CPU core, with no saved memo between runs. Compilation is
excluded. [Method, raw runs, and profile](reports/benchmark.md).

```sh
python3 benchmark.py --runs 5 --output /var/tmp/yatzy-benchmark.json
```

## A small strategy surprise

If you could fill one category perfectly on the first turn, **five fives**
would lead to an expected final score of **266.09**, versus **254.49** for the
best full house. The fives also make the upper bonus easier to reach.

- [Ideal first score + optimal remaining game](reports/yatzy-strategic-ranking.txt)
- [Expected points when targeting one category for a fresh turn](reports/yatzy-category-ranking.txt)

Reproduce the first ranking with `/var/tmp/yatzy rank`. These are different
questions: a category's immediate value is not its value to the whole game.

## Rules and checks

The solver uses [Danspil's Danish five-dice rules](RULES.md), with explicit
choices for cases the short rulebooks leave unstated. The upper bonus is 50
at 63 points; Yatzy is a fixed 50; pairs and three/four of a kind score only
the matching dice. Full rules, publisher links, and edge cases are in
[RULES.md](RULES.md).

```sh
python3 verify.py          # scoring, exhaustive endgames, holds, bonus, rankings
python3 verify.py --full   # also check the complete starting-position result
```

The Python reference enumerates ordered dice outcomes, retains actual upper
subtotals, and pays the bonus at game end—independently of the Roc solver's
compressed state. It checks all single-category endgames and selected
multi-category endgames. The full-game value is a regression check, not a
second independent full-game proof. CI runs these checks on every push.
