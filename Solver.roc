import Yatzy exposing [Category, Hand]

Solver :: [].{
	# Zero means no future bonus: already paid, or impossible.
	State :: { mask : U32, needed : U8 }.{
		is_eq = |State.{ mask: am, needed: an }, State.{ mask: bm, needed: bn }| am == bm and an == bn
	}
	Action : [Score(Category), Keep(Hand)]

	state : List(Category), U8 -> Try(State, [InvalidUpperSubtotal])
	state = |open, upperSubtotal| {
		if upperSubtotal > 105 {
			return Err(InvalidUpperSubtotal)
		}
		mask = open.fold(0, |acc, category| U32.bitwise_or(acc, Yatzy.bit(category)))
		needed = if (upperSubtotal >= 63) 0 else 63 - upperSubtotal
		Ok(normalize({ mask, needed }))
	}

	initial : State
	initial = State.{ mask: 32767, needed: 63 }

	expected : State -> { value : F64, states : U64 }
	expected = |current| {
		(value, memo) = boundary(kernel, current, Dict.empty())
		{ value, states: memo.len() }
	}

	# Guarantee only this turn's ideal score. All subsequent turns use fair dice
	# and optimal play, so upper-category scores also improve future bonus odds.
	rankPerfect : State -> List({ category : Category, points : U8, value : F64 })
	rankPerfect = |current| {
		State.{ mask, .. } = current
		var $memo = Dict.empty()
		var $rows = []
		for entry in kernel.outcomes {
			if isOpen(mask, entry.category) {
				points = entry.points.fold(0, U8.max)
				moved = transition(current, entry.category, points)
				(future, updated) = boundary(kernel, moved.next, $memo)
				$memo = updated
				$rows = $rows.append({ category: entry.category, points, value: moved.reward + future })
			}
		}
		$rows.sort_with(|a, b| if (a.value > b.value) Before else if (a.value < b.value) After else Same)
	}

	advise : State, Hand, U8 -> Try({ value : F64, action : Action, states : U64 }, [GameOver, InvalidRerolls])
	advise = |current, hand, rerolls| {
		State.{ mask, .. } = current
		if rerolls > 2 {
			return Err(InvalidRerolls)
		}
		if mask == 0 {
			return Err(GameOver)
		}
		base = scoring(kernel, current, Dict.empty())
		var $choice = { value: -1, action: Score(Ones) }
		for category in Yatzy.categories {
			if isOpen(mask, category) {
				moved = transition(current, category, Yatzy.score(category, hand))
				# Every successor is already in the memo, unless terminal.
				(future, _) = boundary(kernel, moved.next, base.cache)
				value = moved.reward + future
				if value > $choice.value {
					$choice = { value, action: Score(category) }
				}
			}
		}
		if rerolls > 0 {
			beforeRoll = if (rerolls == 1) base.values else improve(kernel, base.values)
			filled = complete(kernel, beforeRoll)
			for kept in Yatzy.keeps(hand) {
				value = at(filled, indexOf(kernel.indices, kept))
				if value > $choice.value {
					$choice = { value, action: Keep(kept) }
				}
			}
		}
		Ok({ value: $choice.value, action: $choice.action, states: base.cache.len() })
	}
}

Memo : Dict(U32, F64)

FullHand : { keeps : List(U64), scores : List(U8) }

Kernel : {
	full : List(FullHand),
	extensions : List(List(U64)),
	empty : U64,
	indices : Dict(U32, U64),
	outcomes : List({ category : Category, index : U64, points : List(U8) }),
}

normalize : { mask : U32, needed : U8 } -> Solver.State
normalize = |raw| {
	maximum = Yatzy.categories.keep_if(|category| isOpen(raw.mask, category)).map(|category| 5 * Yatzy.upperFace(category)).sum()
	Solver.State.{ mask: raw.mask, needed: if (raw.needed > maximum) 0 else raw.needed }
}

isOpen : U32, Category -> Bool
isOpen = |mask, category| U32.bitwise_and(mask, Yatzy.bit(category)) != 0

key : Solver.State -> U32
key = |Solver.State.{ mask, needed }| mask * 64 + needed.to_u32()

# Pay the bonus when crossing the threshold; all values exclude past points.
transition : Solver.State, Category, U8 -> { next : Solver.State, reward : F64 }
transition = |Solver.State.{ mask, needed }, category, points| {
	earned = needed > 0 and Yatzy.upperFace(category) > 0 and points >= needed
	nextNeeded = if needed == 0 or earned {
		0
	} else if Yatzy.upperFace(category) > 0 {
		needed - points
	} else needed
	next = normalize({ mask: mask - Yatzy.bit(category), needed: nextNeeded })
	{ next, reward: points.to_f64() + (if (earned) 50 else 0) }
}

at : List(a), U64 -> a
at = |list, index| match list.get(index) {
	Ok(value) => value
	Err(_) => crash "internal lattice index out of bounds"
}

setAt : List(a), U64, a -> List(a)
setAt = |list, index, value| match list.set(index, value) {
	Ok(updated) => updated
	Err(_) => crash "internal lattice index out of bounds"
}

indexOf : Dict(U32, U64), Hand -> U64
indexOf = |indices, hand| match indices.get(Yatzy.handKey(hand)) {
	Ok(index) => index
	Err(_) => crash "internal hand missing from lattice"
}

kernel : Kernel
kernel = {
	hands = Yatzy.partialHands
	indices = hands.fold_with_index(Dict.empty(), |acc, hand, index| acc.insert(Yatzy.handKey(hand), index))
	fullHands = hands.keep_if(|hand| Yatzy.faces(hand).len() == 5)
	full = fullHands.map(
		|hand| {
			keeps: Yatzy.keeps(hand).map(|kept| indexOf(indices, kept)),
			scores: Yatzy.categories.map(|category| Yatzy.score(category, hand)),
		},
	)
	extensions = hands.drop_first(fullHands.len()).map(|hand| [0, 1, 2, 3, 4, 5].map(|face| indexOf(indices, Yatzy.addDie(hand, face))))
	outcomes = Yatzy.categories.map_with_index(
		|category, index| {
			points = full.fold(Dict.empty(), |acc, roll| acc.insert(at(roll.scores, index), {})).keys().sort()
			{ category, index, points }
		},
	)
	{ full, extensions, empty: hands.len() - 1, indices, outcomes }
}

# Fill partial hands one uniform die at a time: multinomial weights arise
# naturally, without treating the 252 full hands as equally likely.
complete : Kernel, List(F64) -> List(F64)
complete = |model, values| {
	var $filled = values
	for children in model.extensions {
		mean = children.map(|child| at($filled, child)).sum() / 6
		$filled = $filled.append(mean)
	}
	$filled
}

# Keeping all five also represents stopping.
improve : Kernel, List(F64) -> List(F64)
improve = |model, values| {
	filled = complete(model, values)
	model.full.map(|roll| roll.keeps.fold(0, |best, kept| F64.max(best, at(filled, kept))))
}

scoring : Kernel, Solver.State, Memo -> { values : List(F64), cache : Memo }
scoring = |model, current, memo| {
	Solver.State.{ mask, .. } = current
	var $cache = memo
	var $payoffs = []
	# Compute each category's distinct score continuations only once. Keep the
	# memo separate from other accumulators so recursive calls can reuse it.
	for entry in model.outcomes {
		if isOpen(mask, entry.category) {
			var $payouts = List.repeat(0, 51)
			for points in entry.points {
				moved = transition(current, entry.category, points)
				(future, updated) = boundary(model, moved.next, $cache)
				$cache = updated
				$payouts = setAt($payouts, points.to_u64(), moved.reward + future)
			}
			$payoffs = $payoffs.append({ index: entry.index, values: $payouts })
		}
	}
	values = model.full.map(
		|roll| $payoffs.fold(
			0,
			|best, payoff| {
				points = at(roll.scores, payoff.index)
				F64.max(best, at(payoff.values, points.to_u64()))
			},
		),
	)
	{ values, cache: $cache }
}

boundary : Kernel, Solver.State, Memo -> (F64, Memo)
boundary = |model, current, memo| {
	Solver.State.{ mask, .. } = current
	if mask == 0 {
		return (0, memo)
	}
	stateKey = key(current)
	match memo.get(stateKey) {
		Ok(value) => (value, memo)
		Err(_) => {
			{ values, cache } = scoring(model, current, memo)
			final = complete(model, improve(model, improve(model, values)))
			value = at(final, model.empty)
			(value, cache.insert(stateKey, value))
		}
	}
}

expect Solver.state([], 0).map_ok(|current| Solver.expected(current).value.abs() < 0.00000001) == Ok(True)
expect Solver.state([Sixes], 63).map_ok(|current| (Solver.expected(current).value - 455 / 36).abs() < 0.00000001) == Ok(True)
expect Solver.state([Sixes], 0) == Solver.state([Sixes], 63)
expect {
	current = Solver.state([Sixes], 57)
	hand = Yatzy.dice([6, 1, 2, 3, 4])
	Try.map2(current, hand, |s, h| Solver.advise(s, h, 0).map_ok(|answer| (answer.value - 56).abs() < 0.00000001 and answer.action == Score(Sixes))) == Ok(Ok(True))
}
expect {
	current = Solver.state([Sixes], 63)
	hand = Yatzy.dice([6, 6, 1, 2, 3])
	Try.map2(
		current,
		hand,
		|s, h| Solver.advise(s, h, 1).map_ok(
			|answer| {
				kept = match answer.action {
					Keep(held) => Yatzy.faces(held)
					Score(_) => []
				}
				(answer.value - 15).abs() < 0.00000001 and kept == [6, 6]
			},
		),
	) == Ok(Ok(True))
}
