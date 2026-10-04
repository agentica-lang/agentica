def save_number(args: List[String]) -> Void
  BDD.set("number", Result.unwrap!(JSON.parse(args[0])))
end

def expect_number(args: List[String]) -> Void
  actual = Result.unwrap!(JSON.int(Result.unwrap!(BDD.get("number"))))
  BDD.assert(actual == String.to_int!(args[0]), "wrong scenario value")
end

def expect_fresh(args: List[String]) -> Void
  BDD.assert(not Result.ok?(BDD.get("number")), "state leaked between scenarios")
end

def save_record(args: List[String]) -> Void
  BDD.set("number", Result.unwrap!(JSON.get(Result.unwrap!(JSON.parse(BDD.doc_string())), "value")))
end

def check_table(args: List[String]) -> Void
  rows = BDD.table()
  BDD.assert(rows[1][0] == "a|b" and rows[1][1] == "7", "incorrect table argument")
end

def fail(args: List[String]) -> Void
  BDD.assert(false, "intentional failure")
end

def noop(args: List[String]) -> Void
end

def crash(args: List[String]) -> Void
  invalid = 1 / 0
end

def exit_early(args: List[String]) -> Void
  System.exit(0)
end

def loop(args: List[String]) -> Void
  while true
  end
end

def assert_capture(args: List[String]) -> Void
  BDD.assert(args[0] == "hello \"world\"", "quoted string was not decoded")
end

def main() -> Void
  BDD.step("I remember {int}", &save_number)
  BDD.step("the remembered number is {int}", &expect_number)
  BDD.step("scenario state is empty", &expect_fresh)
  BDD.step("I submit a record:", &save_record)
  BDD.step("the table is valid:", &check_table)
  BDD.step("an assertion fails", &fail)
  BDD.step("nothing is checked", &noop)
  BDD.step("execution crashes", &crash)
  BDD.step("execution exits", &exit_early)
  BDD.step("execution loops", &loop)
  BDD.step("the message is {string}", &assert_capture)
end
