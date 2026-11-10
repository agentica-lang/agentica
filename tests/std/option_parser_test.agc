import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

def parser() -> OP.Parser
  return OP.new(
    "tool",
    "Serves a file over HTTP",
    [Arg(name: "file", help: "file to serve")],
    [
      Opt(name: "port", short: "p", kind: K.Int, default: "8080", help: "port"),
      Opt(name: "ratio", kind: K.Float, help: "scale"),
      Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
      Opt(name: "quiet", short: "q", kind: K.Flag),
      Opt(name: "label", short: "l"),
      Opt(name: "user", kind: K.String, choices: ["ana", "bob"], help: "user name"),
      Opt(name: "mode", short: "m", default: "fast", choices: ["fast", "slow"]),
      Opt(name: "jobs", kind: K.Int, min: some(1), max: some(64), help: "jobs (a few)"),
      Opt(name: "level", kind: K.Int, choices: ["1", "2"], metavar: "N"),
    ],
  )
end

# An Int argument with a min, an option with only a max and one with a negative min.
def limited() -> OP.Parser
  return OP.new(
    "tool",
    "",
    [Arg(name: "count", kind: K.Int, min: some(1))],
    [
      Opt(name: "cap", kind: K.Int, max: some(9)),
      Opt(name: "offset", kind: K.Int, min: some(-10)),
    ],
  )
end

# Float limits on an argument and on options: both ends, a max alone and a negative min.
def ranged() -> OP.Parser
  return OP.new(
    "gen",
    "",
    [Arg(name: "scale", kind: K.Float, min_float: some(0.5), max_float: some(4.0))],
    [
      Opt(name: "temp", kind: K.Float, default: "0.8", min_float: some(0.0), max_float: some(2.0)),
      Opt(name: "top-p", kind: K.Float, max_float: some(1.0)),
      Opt(name: "bias", kind: K.Float, min_float: some(-0.25)),
      Opt(name: "eps", kind: K.Float, min_float: some(1e-7), max_float: some(0.1)),
    ],
  )
end

# The limits that a help row shows, read back as numbers: "[min: 0.0, max: 2.0]" gives [0.0, 2.0].
def shown_limits(help: String, name: String) -> Result[List[Float]]
  line = try help.split("\n").find do |text| text.include?(name) end
  start = line.index_of("[min: ")
  if start.none?
    start = line.index_of("[max: ")
  end
  return error("no limits on #{line}") if start.none?
  inside = line.slice(start.unwrap! + 1, line.length - start.unwrap! - 2)
  numbers: List[Float] = []
  for part in inside.split(", ")
    numbers = numbers.push(try part.split(": ")[1].to_f)
  end
  return ok(numbers)
end

# The message names the option and says what is wrong, and the command line is the one that fails.
def fails(args: List[String], part: String) -> Result[Void]
  parsed = OP.parse(parser(), args)
  try Test.assert(!parsed.ok?, "#{args} should fail")
  try Test.assert(parsed.message.start_with?("tool: "), "#{parsed.message} starts with the program")
  try Test.assert(parsed.message.include?("Try 'tool --help'"), "#{parsed.message} has the hint")
  return Test.assert(parsed.message.include?(part), "#{parsed.message} should say #{part}")
end

def main() -> Void
  Test.run([
    Test.test("every form of an option, a flag and an argument") do
      forms = [
        ["-p", "3000", "-v", "f"],
        ["--port", "3000", "--verbose", "f"],
        ["--port=3000", "f", "-v"],
        ["-p3000", "-vq", "f"],
        ["-v", "--port", "3000", "--", "f"],
        ["-p=3000", "-v", "f"],
        ["-vp3000", "f"],
      ]

      for args in forms
        p = try OP.parse(parser(), args)
        try Test.eq(OP.string(p, "file"), "f")
        try Test.eq(OP.int(p, "port"), 3000)
        try Test.assert(OP.flag(p, "verbose"), "#{args} sets the flag")
      end
      p = try OP.parse(parser(), ["-p", "3000", "--ratio=1.5", "-vq", "--user", "ana", "-m", "slow", "--", "-x"])
      try Test.eq(OP.int(p, "port"), 3000)
      try Test.eq(OP.float(p, "ratio"), 1.5)
      try Test.eq(OP.optional_float(p, "ratio"), some(1.5))
      try Test.eq(OP.flag(p, "verbose"), true)
      try Test.eq(OP.flag(p, "quiet"), true)
      try Test.eq(OP.string(p, "user"), "ana")
      try Test.eq(OP.string(p, "mode"), "slow")
      try Test.eq(OP.string(p, "file"), "-x")
      negative = try OP.parse(parser(), ["-p", "-1", "--ratio", "-2.5", "-5"])
      try Test.eq(OP.int(negative, "port"), -1)
      try Test.eq(OP.float(negative, "ratio"), -2.5)
      try Test.eq(OP.string(negative, "file"), "-5")
      literal = try OP.parse(parser(), ["--label=--x", "f"])
      try Test.eq(OP.string(literal, "label"), "--x")
      joined = try OP.parse(parser(), ["-l--y", "f"])
      Test.eq(OP.string(joined, "label"), "--y")
    end,
    Test.test("defaults fill the options that are not given and the others are none") do
      p = try OP.parse(parser(), ["f"])
      try Test.eq(OP.int(p, "port"), 8080)
      try Test.eq(OP.optional_int(p, "port"), some(8080))
      try Test.eq(OP.string(p, "mode"), "fast")
      try Test.eq(OP.flag(p, "verbose"), false)
      try Test.eq(OP.optional_float(p, "ratio"), none)
      try Test.eq(OP.optional_string(p, "user"), none)
      again = try OP.parse(parser(), ["--port", "1", "--port", "2", "f"])
      Test.eq(OP.int(again, "port"), 2)
    end,
    Test.test("each mistake is an error that names the option") do
      try fails(["--bogus", "f"], "unknown option --bogus")
      try fails(["-x", "f"], "unknown option -x")
      try fails(["f", "--port"], "option --port needs a value")
      try fails(["f", "-p"], "option --port needs a value")
      try fails(["--port", "--verbose", "f"], "option --port needs a value")
      try fails(["--user", "-v", "f"], "option --user needs a value")
      try fails(["--port", "abc", "f"], "invalid value for --port: 'abc' is not an Int")
      try fails(["--ratio", "x", "f"], "invalid value for --ratio: 'x' is not a Float")
      try fails(["--user", "cy", "f"], "invalid value for --user: 'cy' is not one of ana, bob")
      try fails(["--verbose=1", "f"], "option --verbose does not take a value")
      try fails([], "missing argument <file>")
      try fails(["f", "g"], "unexpected argument 'g'")
      failed = OP.parse(parser(), ["--bogus"]).message
      try Test.assert(!OP.help?(failed), "an error is not a request for help")
      Test.eq(OP.message(failed), failed)
    end,
    Test.test("an Int limit refuses a value outside it and the edges are valid") do
      try fails(["--jobs", "0", "f"], "invalid value for --jobs: '0' is below the minimum 1")
      try fails(["--jobs=65", "f"], "invalid value for --jobs: '65' is above the maximum 64")
      try fails(["--jobs", "-3", "f"], "'-3' is below the minimum 1")
      for edge in [1, 64]
        p = try OP.parse(parser(), ["--jobs", "#{edge}", "f"])
        try Test.eq(OP.int(p, "jobs"), edge)
      end
      p = try OP.parse(parser(), ["--port", "-7", "f"])
      Test.eq(OP.int(p, "port"), -7)
    end,
    Test.test("limits on an argument, a max alone and a negative min") do
      refused = OP.parse(limited(), ["0"])
      try Test.assert(!refused.ok?, "0 is below the minimum of the argument")
      try Test.assert(refused.message.include?("for <count>: '0' is below the minimum 1"), refused.message)
      cap = OP.parse(limited(), ["--cap", "10", "1"])
      try Test.assert(cap.message.include?("invalid value for --cap: '10' is above the maximum 9"), cap.message)
      low = OP.parse(limited(), ["--offset", "-11", "1"])
      try Test.assert(low.message.include?("invalid value for --offset: '-11' is below the minimum -10"), low.message)
      p = try OP.parse(limited(), ["--cap", "-100", "--offset=-10", "1"])
      try Test.eq(OP.int(p, "cap"), -100)
      try Test.eq(OP.int(p, "offset"), -10)
      Test.eq(OP.int(p, "count"), 1)
    end,
    Test.test("a Float limit refuses a value outside it and the edges are valid") do
      for words in [["--temp", "2.5", "1"], ["--temp", "-1", "1"]]
        failed = OP.parse(ranged(), words)
        try Test.assert(failed.message.include?("invalid value for --temp: '#{words[1]}' is"), failed.message)
      end
      joined = OP.parse(ranged(), ["--temp=-0.1", "1"]).message
      try Test.assert(joined.include?("'-0.1' is below the minimum 0.0"), joined)
      above = OP.parse(ranged(), ["--temp", "2.5", "1"]).message
      try Test.assert(above.include?("'2.5' is above the maximum 2.0"), above)
      below = OP.parse(ranged(), ["--temp", "-1", "1"]).message
      try Test.assert(below.include?("'-1' is below the minimum 0.0"), below)
      small = OP.parse(ranged(), ["0.4"]).message
      try Test.assert(small.include?("invalid value for <scale>: '0.4' is below the minimum 0.5"), small)
      top = OP.parse(ranged(), ["--top-p", "1.0000001", "1"]).message
      try Test.assert(top.include?("'1.0000001' is above the maximum 1.0"), top)
      try Test.assert(OP.parse(ranged(), ["--bias", "-0.3", "1"]).message.include?("below the minimum -0.25"), "bias")
      try Test.assert(OP.parse(ranged(), ["--temp", "nan", "1"]).message.include?("'nan' is not a Float"), "nan")
      eps = OP.parse(ranged(), ["--eps", "0.10000001", "1"]).message
      try Test.assert(eps.include?("above the maximum 0.1"), eps)
      signed = OP.new("gen", "", [], [Opt(name: "zero", kind: K.Float, min_float: some(-0.0))])
      try Test.eq(OP.float(try OP.parse(signed, ["--zero", "0"]), "zero"), 0.0)
      words = ["0", "2.0", "-0.0", "1e-3"]
      values = [0.0, 2.0, 0.0, 0.001]
      for index in 0...words.size
        p = try OP.parse(ranged(), ["--temp", words[index], "0.5"])
        try Test.eq(OP.float(p, "temp"), values[index])
      end
      p = try OP.parse(ranged(), ["--top-p", "-5", "--bias=-0.25", "4"])
      try Test.eq(OP.optional_float(p, "top-p"), some(-5.0))
      try Test.eq(OP.float(p, "bias"), -0.25)
      try Test.eq(OP.float(p, "scale"), 4.0)
      Test.eq(OP.float(p, "temp"), 0.8)
    end,
    Test.test("a Float that is not finite is refused, with limits or without") do
      for text in ["+nan.0", "+inf.0", "-inf.0", "1e400", "-1e400"]
        limited_one = OP.parse(ranged(), ["--temp=#{text}", "1"]).message
        try Test.assert(limited_one.include?("invalid value for --temp: '#{text}' does not fit a Float"), limited_one)
        try fails(["--ratio=#{text}", "f"], "invalid value for --ratio: '#{text}' does not fit a Float")
      end
      for text in ["+nan.0", "+inf.0", "1e400"]
        try fails(["--ratio", text, "f"], "'#{text}' does not fit a Float")
      end
      Test.assert(OP.parse(ranged(), ["+inf.0"]).message.include?("for <scale>: '+inf.0' does not fit a Float"), "arg")
    end,
    Test.test("the help shows the Float limits, and they read back as the specification has them") do
      help = OP.usage(ranged())
      try Test.assert(help.include?("  <scale>            [min: 0.5, max: 4.0]"), help)
      try Test.eq(try shown_limits(help, "--temp"), [0.0, 2.0])
      try Test.eq(try shown_limits(help, "--top-p"), [1.0])
      try Test.eq(try shown_limits(help, "--bias"), [-0.25])
      try Test.eq(try shown_limits(help, "--eps"), [1e-7, 0.1])
      usage = OP.usage(parser())
      jobs = try shown_limits(usage, "--jobs")
      Test.eq(jobs, [1.0, 64.0])
    end,
    Test.test("a number too big for an Int says so, and a word is still not an Int") do
      try fails(["--port", "99999999999999999999", "f"], "for --port: '99999999999999999999' does not fit an Int")
      try fails(["--port=-99999999999999999999", "f"], "'-99999999999999999999' does not fit an Int")
      try fails(["--port", "1x", "f"], "'1x' is not an Int")
      Test.assert(!OP.parse(parser(), ["--port", "-", "f"]).ok?, "a lone minus is refused")
    end,
    Test.test("a wrong specification is an error of parse, with the option named") do
      # 1e400 is too big for a Float, so it reads as an infinity, and an infinity minus itself is NaN.
      infinite = try "1e400".to_f
      cases = [
        OP.new("tool", "", [], [Opt(name: "port", kind: K.Int, default: "x")]),
        OP.new("tool", "", [], [Opt(name: "a", short: "p"), Opt(name: "b", short: "p")]),
        OP.new("tool", "", [Arg(name: "a"), Arg(name: "a")]),
        OP.new("tool", "", [], [Opt(name: "mode", choices: ["a"], default: "b")]),
        OP.new("tool", "", [], [Opt(name: "jobs", kind: K.Int, min: some(5), max: some(4))]),
        OP.new("tool", "", [], [Opt(name: "name", min: some(1))]),
        OP.new("tool", "", [], [Opt(name: "jobs", kind: K.Int, default: "0", min: some(1))]),
        OP.new("tool", "", [Arg(name: "file", kind: K.Flag)]),
        OP.new("tool", "", [], [Opt(name: "eq", short: "=")]),
        OP.new("tool", "", [], [Opt(name: "one", short: "1")]),
        OP.new("tool", "", [], [Opt(name: "a b")]),
        OP.new("", "", [], []),
        OP.new("tool", "", [], [Opt(name: "jobs", kind: K.Int, min_float: some(1.0))]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, min: some(0))]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, min_float: some(2.0), max_float: some(1.0))]),
        OP.new("tool", "", [], [Opt(name: "name", max_float: some(1.0))]),
        OP.new("tool", "", [], [Opt(name: "quiet", kind: K.Flag, min_float: some(0.0))]),
        OP.new("tool", "", [Arg(name: "scale", kind: K.Int, max_float: some(1.0))]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, max_float: some(infinite))]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, min_float: some(infinite - infinite))]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, default: "3.0", max_float: some(2.0))]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, default: "+nan.0")]),
        OP.new("tool", "", [], [Opt(name: "temp", kind: K.Float, min: some(0), min_float: some(0.0))]),
      ]

      # What each specification above must name in its error, in the same order.
      names = [
        "--port",
        "--b",
        "<a>",
        "--mode",
        "above its max",
        "min or max",
        "--jobs",
        "<file>",
        "--eq",
        "--one",
        "a b",
        "program name",
        "--jobs has min_float or max_float but is not a Float",
        "--temp has min or max but is not an Int: a Float has min_float and max_float",
        "the min_float of --temp is above its max_float",
        "--name has min_float or max_float",
        "--quiet has min_float or max_float",
        "<scale> has min_float or max_float",
        "the min_float or max_float of --temp is not a finite number",
        "the min_float or max_float of --temp is not a finite number",
        "invalid default for --temp: '3.0' is above the maximum 2.0",
        "invalid default for --temp: '+nan.0' does not fit a Float",
        "--temp has min or max but is not an Int",
      ]

      for index in 0...cases.size
        failed = OP.parse(cases[index], [])
        try Test.assert(!failed.ok?, "the specification #{index} is refused")
        try Test.assert(failed.message.include?("invalid specification"), failed.message)
        try Test.assert(failed.message.include?(names[index]), failed.message)
      end
      Test.assert(cases.size == names.size, "every case has its name")
    end,
    Test.test("help is asked with --help or -h and holds one row per option") do
      expected = [
        "Usage: tool [options] <file>",
        "",
        "Serves a file over HTTP",
        "",
        "Arguments:",
        "  <file>                file to serve",
        "",
        "Options:",
        "  -p, --port PORT       port [default: 8080]",
        "      --ratio RATIO     scale",
        "  -v, --verbose         more output",
        "  -q, --quiet",
        "  -l, --label LABEL",
        "      --user ana|bob    user name",
        "  -m, --mode fast|slow  [default: fast]",
        "      --jobs JOBS       jobs (a few) [min: 1, max: 64]",
        "      --level N         [choices: 1, 2]",
        "  -h, --help            show this help",
      ].join("\n")

      try Test.eq(OP.usage(parser()), expected)
      for args in [["--help"], ["f", "-h"], ["-vh"]]
        help = OP.parse(parser(), args)
        try Test.assert(OP.help?(help.message), "#{args} asks for help")
        try Test.eq(OP.message(help.message), expected)
      end
      after = try OP.parse(parser(), ["--", "-h"])
      Test.eq(OP.string(after, "file"), "-h")
    end,
  ])
end
