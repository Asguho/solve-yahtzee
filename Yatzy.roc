Yatzy :: [].{
	Category : [Ones, Twos, Threes, Fours, Fives, Sixes, Pair, TwoPairs, ThreeKind, FourKind, SmallStraight, LargeStraight, FullHouse, Chance, Yatzy]
	Hand :: List(U8).{
		is_eq = |Hand.(a), Hand.(b)| a == b
	}

	categories : List(Category)
	categories = [Ones, Twos, Threes, Fours, Fives, Sixes, Pair, TwoPairs, ThreeKind, FourKind, SmallStraight, LargeStraight, FullHouse, Chance, Yatzy]

	categoryName : Category -> Str
	categoryName = |category|
		match category {
			Ones => "ones"
			Twos => "twos"
			Threes => "threes"
			Fours => "fours"
			Fives => "fives"
			Sixes => "sixes"
			Pair => "pair"
			TwoPairs => "two-pairs"
			ThreeKind => "three-kind"
			FourKind => "four-kind"
			SmallStraight => "small-straight"
			LargeStraight => "large-straight"
			FullHouse => "full-house"
			Chance => "chance"
			Yatzy => "yatzy"

		}
	bit : Category -> U32
	bit = |category|
		match category {
			Ones => 1
			Twos => 2
			Threes => 4
			Fours => 8
			Fives => 16
			Sixes => 32
			Pair => 64
			TwoPairs => 128
			ThreeKind => 256
			FourKind => 512
			SmallStraight => 1024
			LargeStraight => 2048
			FullHouse => 4096
			Chance => 8192
			Yatzy => 16384
		}
	upperFace : Category -> U8
	upperFace = |category|
		match category {
			Ones => 1
			Twos => 2
			Threes => 3
			Fours => 4
			Fives => 5
			Sixes => 6
			_ => 0
		}

	parseCategory : Str -> Try(Category, [UnknownCategory(Str)])
	parseCategory = |name| categories.find_first(|category| categoryName(category) == name).map_err(|_| UnknownCategory(name))

	# Exactly five ordinary dice at the external boundary.
	dice : List(U8) -> Try(Hand, [InvalidDice])
	dice = |values| {
		if values.len() != 5 or !values.all(|value| value >= 1 and value <= 6) {
			return Err(InvalidDice)
		}
		var $counts = List.repeat(0, 6)
		for value in values {
			index = (value - 1).to_u64()
			$counts = setCount($counts, index, countAt($counts, index) + 1)
		}
		Ok(Hand.($counts))
	}

	faces : Hand -> List(U8)
	faces = |Hand.(counts)| List.map2(counts, [1, 2, 3, 4, 5, 6], |count, face| List.repeat(face, count.to_u64())).join()

	# Descending hand size makes every extension precede its parent.
	partialHands : List(Hand)
	partialHands = [5, 4, 3, 2, 1, 0].join_map(|total| vectors(6, total).map(|counts| Hand.(counts)))

	vectors : U8, U8 -> List(List(U8))
	vectors = |slots, total| {
		if slots == 1 {
			return [[total]]
		}
		var $result = []
		for count in 0..=total {
			for tail in vectors(slots - 1, total - count) {
				$result = $result.append(tail.prepend(count))
			}
		}
		$result
	}

	keeps : Hand -> List(Hand)
	keeps = |Hand.(counts)| {
		var $prefixes = [[]]
		for count in counts {
			var $next = []
			for prefix in $prefixes {
				for n in 0..=count {
					$next = $next.append(prefix.append(n))
				}
			}
			$prefixes = $next
		}
		$prefixes.map(|counts_| Hand.(counts_))
	}

	# Internal lattice operation, called only on hands with fewer than five dice.
	addDie : Hand, U64 -> Hand
	addDie = |Hand.(counts), index| Hand.(setCount(counts, index, countAt(counts, index) + 1))

	handKey : Hand -> U32
	handKey = |Hand.(counts)| counts.fold(0, |key, count| key * 6 + count.to_u32())

	score : Category, Hand -> U8
	score = |category, Hand.(counts)| {
		pairs = List.map2(counts, [1, 2, 3, 4, 5, 6], |count, face| if (count >= 2) face else 0).keep_if(|value| value > 0)
		matching = |n| List.map2(counts, [1, 2, 3, 4, 5, 6], |count, face| if (count >= n) face else 0).fold(0, U8.max)
		sum = List.map2(counts, [1, 2, 3, 4, 5, 6], |count, face| count * face).sum()
		match category {
			Ones => countAt(counts, 0)
			Twos => 2 * countAt(counts, 1)
			Threes => 3 * countAt(counts, 2)
			Fours => 4 * countAt(counts, 3)
			Fives => 5 * countAt(counts, 4)
			Sixes => 6 * countAt(counts, 5)
			Pair => 2 * matching(2)
			TwoPairs => if pairs.len() == 2 {
				2 * pairs.sum()
			} else 0
			ThreeKind => 3 * matching(3)
			FourKind => 4 * matching(4)
			SmallStraight => if (counts == [1, 1, 1, 1, 1, 0]) 15 else 0
			LargeStraight => if (counts == [0, 1, 1, 1, 1, 1]) 20 else 0
			FullHouse => if (counts.contains(3) and counts.contains(2)) sum else 0
			Chance => sum
			Yatzy => if (counts.contains(5)) 50 else 0
		}
	}
}

countAt : List(U8), U64 -> U8
countAt = |counts, index| match counts.get(index) {
	Ok(count) => count
	Err(_) => crash "internal face index out of bounds"
}

setCount : List(U8), U64, U8 -> List(U8)
setCount = |counts, index, value| match counts.set(index, value) {
	Ok(updated) => updated
	Err(_) => crash "internal face index out of bounds"
}

expect Yatzy.dice([6, 6, 6, 4, 4]).map_ok(|hand| [Yatzy.score(FullHouse, hand), Yatzy.score(TwoPairs, hand), Yatzy.score(ThreeKind, hand)]) == Ok([26, 20, 18])
expect Yatzy.dice([6, 6, 6, 6, 6]).map_ok(|hand| Yatzy.categories.map(|category| Yatzy.score(category, hand))) == Ok([0, 0, 0, 0, 0, 30, 12, 0, 18, 24, 0, 0, 0, 30, 50])
expect Yatzy.dice([1, 2, 3, 4, 5]).map_ok(|hand| [Yatzy.score(SmallStraight, hand), Yatzy.score(LargeStraight, hand)]) == Ok([15, 0])
expect Yatzy.dice([0, 1, 2, 3, 4]) == Err(InvalidDice)
expect Yatzy.dice([1, 2, 3, 4]) == Err(InvalidDice)
