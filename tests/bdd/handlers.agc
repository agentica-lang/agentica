import BDD from "std/bdd"

def save_number(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, "number", Result.unwrap!(JSON.parse(args[0])))
end

def expect_number(ctx: BDD.Context, args: List[String]) -> BDD.Context
  actual = Result.unwrap!(JSON.int(Result.unwrap!(BDD.get(ctx, "number"))))
  return BDD.assert(ctx, actual == String.to_int!(args[0]), "wrong scenario value")
end

def expect_fresh(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, not Result.ok?(BDD.get(ctx, "number")), "state leaked between scenarios")
end

def save_record(ctx: BDD.Context, args: List[String]) -> BDD.Context
  record = Result.unwrap!(JSON.parse(BDD.doc_string(ctx)))
  return BDD.set(ctx, "number", Result.unwrap!(JSON.get(record, "value")))
end

def check_table(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = BDD.table(ctx)
  return BDD.assert(ctx, rows[1][0] == "a|b" and rows[1][1] == "7", "incorrect table argument")
end

def fail(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, false, "intentional failure")
end

def noop(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return ctx
end

def crash(ctx: BDD.Context, args: List[String]) -> BDD.Context
  invalid = 1 / 0
  return ctx
end

def exit_early(ctx: BDD.Context, args: List[String]) -> BDD.Context
  System.exit(0)
  return ctx
end

def loop(ctx: BDD.Context, args: List[String]) -> BDD.Context
  while true
  end
  return ctx
end

def assert_capture(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, args[0] == "hello \"world\"", "quoted string was not decoded")
end

def main() -> Void
  BDD.run([
    BDD.step("I remember {int}", &save_number),
    BDD.step("the remembered number is {int}", &expect_number),
    BDD.step("scenario state is empty", &expect_fresh),
    BDD.step("I submit a record:", &save_record),
    BDD.step("the table is valid:", &check_table),
    BDD.step("an assertion fails", &fail),
    BDD.step("nothing is checked", &noop),
    BDD.step("execution crashes", &crash),
    BDD.step("execution exits", &exit_early),
    BDD.step("execution loops", &loop),
    BDD.step("the message is {string}", &assert_capture),
  ])
end
