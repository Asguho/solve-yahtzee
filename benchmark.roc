app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-25-72704da",
}

import pf.Cmd
import pf.Duration
import pf.Env
import pf.Monotonic
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import pf.System
import pf.Utc

# Claim: median wall time of five complete, optimized solves with fresh memos.
# Building and the optional profiling solve are outside the timed region.
usage = "Usage: mise exec -- roc benchmark.roc -- [--runs N] [--output FILE] [--profile FILE]\nRun from the repository root. Defaults to five fresh full solves.\nRequires macOS or Linux and /usr/bin/time; --profile requires macOS."

Destination : [None, Some(Str)]

Options : { runs : U64, output : Destination, profile : Destination }

Sample : { wall_seconds : F64, cpu_seconds : F64, score : F64, states : U64 }

parse_options : List(Str) -> Try(Options, [InvalidArguments])
parse_options = |args| parse_options_help(args, { runs: 5, output: None, profile: None })

parse_options_help = |args, options| match args {
	[] => Ok(options)
	["--runs", count, .. as rest] => {
		runs = U64.from_str(count).map_err(|_| InvalidArguments)?
		if runs == 0 {
			return Err(InvalidArguments)
		}
		parse_options_help(rest, { ..options, runs })
	}
	["--output", file, .. as rest] if !file.is_empty() => parse_options_help(rest, { ..options, output: Some(file) })
	["--profile", file, .. as rest] if !file.is_empty() => parse_options_help(rest, { ..options, profile: Some(file) })
	_ => Err(InvalidArguments)
}

# Parse and validate the child process output at the boundary. A fast failure,
# cached answer with missing work, or incorrect result must never become a sample.
parse_result : Str -> Try({ score : F64, states : U64 }, [InvalidSolverResult])
parse_result = |text| match text.trim().split_on(" ") {
	[score_field, states_field] => {
		score = match score_field.split_on("=") {
			["expected-additional-score", value] => F64.from_str(value).map_err(|_| InvalidSolverResult)?
			_ => return Err(InvalidSolverResult)
		}
		states = match states_field.split_on("=") {
			["states", value] => U64.from_str(value).map_err(|_| InvalidSolverResult)?
			_ => return Err(InvalidSolverResult)
		}
		if !(score - 248.4399893778553).abs().is_finite() or (score - 248.4399893778553).abs() > 0.00000001 or states != 947711 {
			return Err(InvalidSolverResult)
		}
		Ok({ score, states })
	}
	_ => Err(InvalidSolverResult)
}

words = |text| text.replace_each("\t", " ").replace_each("\n", " ").split_on(" ").keep_if(|word| !word.is_empty())

parse_time_line = |text, label| match words(text) {
	[name, value] if name == label => {
		number = F64.from_str(value).map_err(|_| InvalidCpuTime)?
		if !number.is_finite() or number < 0 {
			return Err(InvalidCpuTime)
		}
		Ok(number)
	}
	_ => Err(InvalidCpuTime)
}

parse_cpu : Str -> Try(F64, [InvalidCpuTime])
parse_cpu = |text| match text.trim().split_on("\n") {
	[real, user, system] => {
		_ = parse_time_line(real, "real")?
		Ok(parse_time_line(user, "user")? + parse_time_line(system, "sys")?)
	}
	_ => Err(InvalidCpuTime)
}

sort_times : List(F64) -> List(F64)
sort_times = |values| values.sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)

median : List(F64) -> F64
median = |values| {
	sorted = sort_times(values)
	middle = sorted.len() // 2
	if sorted.len().is_multiple_of(2) {
		(at(sorted, middle - 1) + at(sorted, middle)) / 2
	} else at(sorted, middle)
}

at = |list, index| match list.get(index) {
	Ok(value) => value
	Err(_) => crash "internal benchmark index out of bounds"
}

checked_solve! : Path => Try(Sample, _)
checked_solve! = |binary| {
	# /usr/bin/time provides child CPU usage; Roc's monotonic clock measures
	# elapsed time, including the small time-wrapper/process-startup overhead.
	command = Cmd.new("/usr/bin/time").args(["-p", binary.to_os_str(), "solve"]).env("LC_ALL", "C").manage_tree(True)
	start = Monotonic.now!()
	result = command.run!()?
	elapsed = start.elapsed!().to_nanos().to_f64() / 1000000000
	output = result.require_success()?
	{ score, states } = parse_result(output.stdout_utf8()?)?
	cpu = parse_cpu(output.stderr_utf8_lossy())?
	Ok({ wall_seconds: elapsed, cpu_seconds: cpu, score, states })
}

capture! = |program, args| Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str)).capture!()?.trim() |> Ok

machine! = |target| {
	arch = match target.arch() {
		Arm64 => "arm64"
		X64 => "x64"
	}
	match target.os() {
		MacOS(_) => Ok({
			os: "macOS ${capture!("sw_vers", ["-productVersion"])?}",
			architecture: arch,
			cpu: capture!("sysctl", ["-n", "machdep.cpu.brand_string"])?,
			logical_cpus: U64.from_str(capture!("sysctl", ["-n", "hw.ncpu"])?)?,
			memory_bytes: U64.from_str(capture!("sysctl", ["-n", "hw.memsize"])?)?,
		})
		Linux(_) => {
			info = Path.read_utf8!("/proc/cpuinfo")?
			model = info.split_on("\n").find_first(|line| line.starts_with("model name") or line.starts_with("Hardware")).ok_or(arch)
			cpu = model.split_on(":").last().ok_or(arch).trim()
			pages = U64.from_str(capture!("getconf", ["_PHYS_PAGES"])?)?
			page_size = U64.from_str(capture!("getconf", ["PAGE_SIZE"])?)?
			Ok({ os: capture!("uname", ["-sr"])?, architecture: arch, cpu, logical_cpus: U64.from_str(capture!("getconf", ["_NPROCESSORS_ONLN"])?)?, memory_bytes: pages * page_size })
		}
		Windows(_) => Err(UnsupportedOS)
	}
}

load! = |target| {
	text = match target.os() {
		MacOS(_) => capture!("sysctl", ["-n", "vm.loadavg"])?.replace_each("{", "").replace_each("}", "")
		Linux(_) => Path.read_utf8!("/proc/loadavg")?
		Windows(_) => return Err(UnsupportedOS)
	}
	var $values = []
	for word in words(text).take_first(3) {
		$values = $values.append(F64.from_str(word)?)
	}
	if $values.len() != 3 {
		return Err(InvalidLoadAverage)
	}
	Ok($values)
}

# Unix paths only: all scratch files are under /var/tmp, and output directories
# are created before starting the expensive benchmark.
prepare_output! = |file| {
	parts = file.split_on("/")
	parent = Str.join_with(parts.drop_last(1), "/")
	if !parent.is_empty() {
		Path.utf8(parent).create_all!()?
	}
	Ok(Path.utf8(file))
}

profile_child! : Cmd.Child, Str => Try({}, _)
profile_child! = |child, file| {
	Duration.millis(200).sleep!()?
	Cmd.new("sample").args(["${child.pid().to_str()}", "1", "-file", OsStr.from_str(file)]).call!()?
	output = child.wait!()?.require_success()?
	_ = parse_result(output.stdout_utf8()?)?
	if !output.stderr_bytes.is_empty() {
		return Err(UnexpectedSolverStderr)
	}
	raw = Path.utf8(file).read_utf8!()?
	graph = match raw.split_on("Call graph:\n") {
		[_, body, ..] => at(body.split_on("Binary Images:"), 0).trim()
		_ => return Err(InvalidProfile)
	}
	# Keep the call graph, not process IDs, local paths or loaded libraries.
	lines = graph.split_on("\n").map(|line| if (line.contains("Thread_")) "    main thread (sampled)" else line)
	Path.utf8(file).write_utf8!("Untimed macOS sample: 1 second, 1 ms sampling interval.\n\nCall graph:\n${Str.join_with(lines, "\n")}\n")
}

profile! = |binary, file| {
	child = Cmd.new(binary.to_os_str()).arg("solve").stdout(Capture).stderr(Capture).manage_tree(True).spawn!()?
	result = profile_child!(child, file)
	# Always close, including a failed sampler; close kills and reaps a live child.
	closed = child.close!()
	match (result, closed) {
		(Ok(_), Ok(_)) => Ok({})
		(Err(err), Ok(_)) => Err(ProfileFailed(Str.inspect(err)))
		(_, Err(err)) => Err(ProfileFailed(Str.inspect(err)))
	}
}

benchmark! = |options, target, directory| {
	match options.output {
		Some(file) => {
			_ = prepare_output!(file)?
		}
		None => {}
	}
	match options.profile {
		Some(file) => {
			_ = prepare_output!(file)?
		}
		None => {}
	}
	compiler = capture!("mise", ["exec", "--", "roc", "--version"])?
	var $hashes = Dict.empty()
	for name in ["main.roc", "Solver.roc", "Yatzy.roc", "mise.toml", "benchmark.roc"] {
		digest = Crypto.SHA256.hash(Path.utf8(name).read_bytes!()?).to_hex()
		$hashes = $hashes.insert(name, digest)
	}
	hardware = machine!(target)?
	date = Utc.now!().to_iso_8601()
	binary = directory.join("yatzy")
	Cmd.new("mise").args(["exec", "--", "roc", "build", "--opt=speed", "--debug", "--output=${binary.display()}", "main.roc"]).manage_tree(True).call!()?
	match options.profile {
		Some(file) => profile!(binary, file)?
		None => {}
	}
	load_before = load!(target)?
	var $samples = []
	for index in 0..<options.runs {
		row = checked_solve!(binary)?
		$samples = $samples.append(row)
		Stdout.line!("Run ${(index + 1).to_str()}/${options.runs.to_str()}: ${row.wall_seconds.to_str()} s; ${row.states.to_str()} states; score ${row.score.to_str()}")?
	}
	load_after = load!(target)?
	times = sort_times($samples.map(|row| row.wall_seconds))
	report = {
		date_utc: date,
		machine: hardware,
		compiler,
		build_flags: ["--opt=speed", "--debug"],
		workload: "solve: all 15 categories, upper subtotal 0; fresh process and memo every run",
		includes: "full DP computation, result printing, process and /usr/bin/time wrapper startup",
		excludes: "compilation, package downloads, optional separate profiling run",
		source_sha256: $hashes,
		samples: $samples,
		load_average_before: load_before,
		load_average_after: load_after,
		median_seconds: median(times),
		min_seconds: at(times, 0),
		max_seconds: at(times, times.len() - 1),
		median_cpu_to_wall_ratio: median($samples.map(|row| row.cpu_seconds / row.wall_seconds)),
		successful_runs: $samples.len(),
		failed_runs: 0.U64,
		profile: match options.profile {
			Some(file) => file.split_on("/").last().ok_or(file)
			None => ""
		},
	}
	match options.output {
		Some(file) => Path.utf8(file).write_utf8!("${Json.to_str_try(report)?}\n")?
		None => {}
	}
	Stdout.line!("Median ${report.median_seconds.to_str()} s; range ${report.min_seconds.to_str()}–${report.max_seconds.to_str()} s; ${report.successful_runs.to_str()} verified fresh solves.")?
	Ok({})
}

run! = |args| {
	if args == ["--help"] {
		return Stdout.line!(usage)
	}
	options = parse_options(args)?
	target = System.target!()
	match target.os() {
		Windows(_) => return Err(UnsupportedOS)
		Linux(_) if options.profile != None => return Err(ProfileRequiresMacOS)
		_ => {}
	}
	directory = Env.create_temp_dir_in!("/var/tmp", "yatzy-benchmark-")?
	result = benchmark!(options, target, directory)
	cleanup = directory.delete_all!()
	match (result, cleanup) {
		(result_, Ok(_)) => result_
		(Ok(_), Err(err)) => Err(CleanupFailed(Str.inspect(err)))
		(Err(err), Err(cleanup_err)) => Err(CleanupFailed("${Str.inspect(err)}; ${Str.inspect(cleanup_err)}"))
	}
}

main! = |args| match run!(args.map(OsStr.display)) {
	Ok(_) => Ok({})
	Err(err) => {
		Stderr.line!("${Str.inspect(err)}\n${usage}")?
		Err(Exit(1))
	}
}

expect parse_options([]) == Ok({ runs: 5, output: None, profile: None })
expect parse_options(["--runs", "0"]) == Err(InvalidArguments)
expect parse_options(["--runs"]) == Err(InvalidArguments)
expect parse_options(["--runs", "-1"]) == Err(InvalidArguments)
expect parse_options(["--unknown"]) == Err(InvalidArguments)
expect parse_options(["--output", ""]) == Err(InvalidArguments)
expect parse_options(["--runs", "2", "--output", "result.json", "--profile", "sample.txt"]) == Ok({ runs: 2, output: Some("result.json"), profile: Some("sample.txt") })
expect parse_result("expected-additional-score=248.4399893778553 states=947711\n").map_ok(|row| row.states) == Ok(947711)
expect parse_result("expected-additional-score=1 states=947711") == Err(InvalidSolverResult)
expect parse_result("expected-additional-score=248.4399893778553 states=1") == Err(InvalidSolverResult)
expect parse_result("cached expected-additional-score=248.4399893778553 states=947711") == Err(InvalidSolverResult)
expect parse_cpu("real 25.3\nuser 25.1\nsys 0.02\n").map_ok(|n| (n - 25.12).abs() < 0.00000001) == Ok(True)
expect parse_cpu("solver error\nreal 1\nuser 1\nsys 0") == Err(InvalidCpuTime)
expect parse_cpu("real 1\nuser -1\nsys 0") == Err(InvalidCpuTime)
expect parse_cpu("real 1\nuser NaN\nsys 0") == Err(InvalidCpuTime)
expect median([3, 1, 2]) == 2
expect median([8, 2, 4, 6]) == 5
