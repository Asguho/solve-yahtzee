#!/usr/bin/env python3
"""Build Roc and compare its public CLI with an independent ordered-dice oracle.

The reference retains actual upper subtotals and pays the bonus at game end.
It enumerates ordered rerolls, rather than using Roc's partial-hand lattice.
No third-party Python dependencies. All build artifacts go under /var/tmp.
"""

from collections import Counter
import argparse
import csv
from functools import cache
from itertools import combinations, combinations_with_replacement, product
from math import isclose
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parent
ROC = ["mise", "exec", "--", "roc"]
CATEGORIES = (
    "ones", "twos", "threes", "fours", "fives", "sixes", "pair", "two-pairs",
    "three-kind", "four-kind", "small-straight", "large-straight", "full-house",
    "chance", "yatzy",
)


def score(category, dice):
    counts = Counter(dice)
    if category in CATEGORIES[:6]:
        face = CATEGORIES.index(category) + 1
        return face * counts[face]
    if category in ("pair", "three-kind", "four-kind"):
        size = {"pair": 2, "three-kind": 3, "four-kind": 4}[category]
        return max((size * v for v, n in counts.items() if n >= size), default=0)
    if category == "two-pairs":
        pairs = [v for v, n in counts.items() if n >= 2]
        return 2 * sum(pairs) if len(pairs) == 2 else 0
    if category == "small-straight":
        return 15 if set(dice) == {1, 2, 3, 4, 5} else 0
    if category == "large-straight":
        return 20 if set(dice) == {2, 3, 4, 5, 6} else 0
    if category == "full-house":
        return sum(dice) if sorted(counts.values()) == [2, 3] else 0
    if category == "chance":
        return sum(dice)
    if category == "yatzy":
        return 50 if len(counts) == 1 else 0
    raise AssertionError(category)


@cache
def keeps(dice):
    return tuple(sorted({held for n in range(6) for held in combinations(dice, n)}))


@cache
def outcomes(number):
    # Deliberately keep ordered outcomes: (1, 2) and (2, 1) each get a vote.
    return tuple(product(range(1, 7), repeat=number))


def reference(open_categories, subtotal):
    @cache
    def start(open_, upper):
        return fill(open_, upper, (), 2) if open_ else (50.0 if upper >= 63 else 0.0)

    def stop(open_, upper, dice, category):
        points = score(category, dice)
        next_upper = upper + points if category in CATEGORIES[:6] else upper
        return points + start(tuple(c for c in open_ if c != category), next_upper)

    @cache
    def value(open_, upper, dice, rerolls):
        best = max(stop(open_, upper, dice, category) for category in open_)
        if rerolls:
            best = max(best, *(fill(open_, upper, held, rerolls - 1) for held in keeps(dice)))
        return best

    @cache
    def fill(open_, upper, held, remaining):
        rolls = outcomes(5 - len(held))
        return sum(value(open_, upper, tuple(sorted(held + roll)), remaining) for roll in rolls) / len(rolls)

    # Previously earned bonus is excluded from the solver's additional score.
    paid_bonus = 50 if subtotal >= 63 else 0
    return start, stop, value, fill, paid_bonus


def close(actual, expected):
    assert isclose(actual, expected, rel_tol=1e-10, abs_tol=1e-8), (actual, expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", action="store_true", help="also rerun the complete starting-position regression")
    options = parser.parse_args()
    version = re.search(r'^"github:roc-lang/nightlies"\s*=\s*"([^"]+)"$',
                        (ROOT / "mise.toml").read_text(), re.MULTILINE)[1]
    actual_version = subprocess.check_output([*ROC, "--version"], cwd=ROOT, text=True)
    assert version in actual_version, actual_version
    assert f'roc: "{version}"' in (ROOT / "main.roc").read_text()
    for command in (
        [*ROC, "fmt", "--check", "."],
        [*ROC, "check", "main.roc"],
        [*ROC, "test", "main.roc"],
    ):
        subprocess.run(command, cwd=ROOT, check=True)

    with TemporaryDirectory(prefix="yatzy-verify-", dir="/var/tmp") as directory:
        binary = str(Path(directory) / "yatzy")
        subprocess.run([*ROC, "build", "--opt=speed", f"--output={binary}", "main.roc"], cwd=ROOT, check=True)

        def run(*args):
            return subprocess.check_output([binary, *map(str, args)], text=True, timeout=60).strip()

        def number(output):
            return float(re.search(r"expected-additional-score=([^ ]+)", output)[1])

        rolls = (
            (1, 2, 3, 4, 5), (2, 3, 4, 5, 6), (6, 6, 6, 4, 4),
            (6, 6, 6, 6, 6), (4, 4, 4, 4, 1), (1, 2, 3, 5, 6),
        )
        for category, dice in product(CATEGORIES, rolls):
            assert run("score", category, ",".join(map(str, dice))) == f"score={score(category, dice)}"

        # Every single-category endgame exercises all initial rolls, all keeps,
        # and both rerolls. Two-category cases also check continuation and bonus.
        cases = [((category,), 0) for category in CATEGORIES]
        cases += [(("sixes",), 39), (("sixes",), 57), (("sixes",), 63),
                  (("sixes", "chance"), 57), (("pair", "yatzy"), 0),
                  (("ones", "twos"), 60)]
        for open_, upper in cases:
            start, _, _, _, paid = reference(open_, upper)
            close(number(run("solve", ",".join(open_), upper)), start(open_, upper) - paid)

        # Ideal first scores include their effect on future bonus probability.
        for open_, upper in ((("sixes", "chance"), 57), (("fives", "chance"), 43), (("pair", "yatzy"), 0)):
            start, _, _, _, paid = reference(open_, upper)
            rows = list(csv.DictReader(run("rank", ",".join(open_), upper).splitlines(), delimiter="\t"))
            assert {row["category"] for row in rows} == set(open_)
            actual_values = []
            for row in rows:
                category = row["category"]
                maximum = max(score(category, dice) for dice in combinations_with_replacement(range(1, 7), 5))
                assert int(row["ideal_score"]) == maximum
                next_upper = upper + maximum if category in CATEGORIES[:6] else upper
                expected = maximum + start(tuple(c for c in open_ if c != category), next_upper) - paid
                actual = float(row["expected_score_including_future_and_bonus"])
                close(actual, expected)
                actual_values.append(actual)
            assert actual_values == sorted(actual_values, reverse=True)

        advice_cases = (
            (("sixes",), 63, (1, 2, 3, 6, 6), 1),
            (("sixes",), 57, (1, 2, 3, 4, 6), 0),
            (("small-straight",), 0, (1, 2, 3, 4, 6), 2),
            (("yatzy",), 0, (2, 2, 2, 5, 5), 2),
            (("sixes", "chance"), 57, (1, 2, 3, 6, 6), 1),
        )
        for open_, upper, dice, rerolls in advice_cases:
            _, stop, value, fill, paid = reference(open_, upper)
            output = run("advise", ",".join(open_), upper, ",".join(map(str, dice)), rerolls)
            target = value(open_, upper, tuple(sorted(dice)), rerolls) - paid
            close(number(output), target)
            action = output.split(" expected-additional-score=")[0]
            if action.startswith("score "):
                category = action.removeprefix("score ")
                assert category in open_
                action_value = stop(open_, upper, dice, category)
            else:
                assert rerolls > 0
                held = () if action == "reroll all" else tuple(map(int, action.removeprefix("keep ").split(",")))
                assert not (Counter(held) - Counter(dice))
                action_value = fill(open_, upper, held, rerolls - 1)
            close(action_value - paid, target)

        close(number(run("solve", "chance", 63)), 70 / 3)
        close(number(run("solve", "sixes", 63)), 455 / 36)
        close(number(run("solve", "-", 0)), 0)
        for args in (
            ("score", "chance", "0,1,2,3,4"), ("score", "chance", "1,2,3,4"),
            ("score", "unknown", "1,2,3,4,5"), ("solve", "sixes", "106"),
            ("advise", "sixes", "0", "1,2,3,4,5", "3"),
            ("advise", "-", "0", "1,2,3,4,5", "1"),
        ):
            result = subprocess.run([binary, *args], capture_output=True, timeout=60)
            assert result.returncode != 0, args

        if options.full:
            # Regression from the completed Roc solve; the independent oracle
            # above validates endgames, not this whole-game golden result.
            output = subprocess.check_output([binary, "solve"], text=True)
            close(number(output), 248.4399893778553)
            print(f"Full-game regression: {output.strip()}")

    print(f"Verified {len(CATEGORIES) * len(rolls)} scores, {len(cases)} exhaustive endgames, {len(advice_cases)} optimal actions, ideal-score rankings, and CLI validation.")


if __name__ == "__main__":
    main()
