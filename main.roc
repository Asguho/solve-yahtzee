app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-25-72704da",
}

import pf.OsStr
import pf.Stdout
import pf.Stderr
import Solver
import Yatzy

usage = "Usage: yatzy solve [categories upper-subtotal]\n       yatzy advise categories upper-subtotal dice rerolls\n       yatzy score category dice\n       yatzy rank [categories upper-subtotal]\nLists are comma-separated. Categories: ones,twos,threes,fours,fives,sixes,pair,two-pairs,three-kind,four-kind,small-straight,large-straight,full-house,chance,yatzy.\nUse all or - (no categories). Dice: five values in 1..6. Rerolls: 0..2.\nSubtotal excludes the bonus. solve without arguments solves the initial state."

parseOpen = |text| {
	if text == "all" {
		return Ok(Yatzy.categories)
	}
	if text == "-" {
		return Ok([])
	}
	var $open = []
	for name in text.split_on(",") {
		$open = $open.append(Yatzy.parseCategory(name)?)
	}
	Ok($open)
}

parseState = |open, upper| Solver.state(parseOpen(open)?, U8.from_str(upper)?)

parseHand = |text| {
	var $values = []
	for value in text.split_on(",") {
		$values = $values.append(U8.from_str(value)?)
	}
	Yatzy.dice($values)
}

actionText = |action| match action {
	Score(category) => "score ${Yatzy.categoryName(category)}"
	Keep(hand) => {
		kept = Str.join_with(Yatzy.faces(hand).map(U8.to_str), ",")
		if (kept.is_empty()) "reroll all" else "keep ${kept}"
	}
}

solveText = |current| {
	answer = Solver.expected(current)
	"expected-additional-score=${answer.value.to_str()} states=${answer.states.to_str()}"
}

rankText = |current| {
	rows = Solver.rankPerfect(current).map(|row| "${Yatzy.categoryName(row.category)}\t${row.points.to_str()}\t${row.value.to_str()}")
	"category\tideal_score\texpected_score_including_future_and_bonus\n${Str.join_with(rows, "\n")}"
}

run = |args| match args {
	[] => Ok(usage)
	["--help"] => Ok(usage)
	["solve"] => Ok(solveText(Solver.initial))
	["solve", open, upper] => Ok(solveText(parseState(open, upper)?))
	["rank"] => Ok(rankText(Solver.initial))
	["rank", open, upper] => Ok(rankText(parseState(open, upper)?))
	["score", name, roll] => Ok("score=${Yatzy.score(Yatzy.parseCategory(name)?, parseHand(roll)?).to_str()}")
	["advise", open, upper, roll, remaining] => {
		answer = Solver.advise(parseState(open, upper)?, parseHand(roll)?, U8.from_str(remaining)?)?
		Ok("${actionText(answer.action)} expected-additional-score=${answer.value.to_str()} states=${answer.states.to_str()}")
	}
	_ => Err(Usage)
}

main! = |args| match run(args.map(OsStr.display)) {
	Ok(output) => Stdout.line!(output)
	Err(problem) => {
		Stderr.line!("${Str.inspect(problem)}\n${usage}")?
		Err(Exit(1))
	}
}
