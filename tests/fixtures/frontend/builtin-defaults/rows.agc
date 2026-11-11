import Model from "../../../../compiler/catalog/builtin_model"
import Builtins from "../../../../compiler/catalog/builtins"
import Types from "../../../../compiler/syntax/types"

# Builds catalog rows by hand for the paths of builtin defaults that no real row uses yet: a last Fn parameter, an
# alternative form, a block form (File.open with a block) and one that differs from its entry, a Prelude rule, a rule
# that is neither Plain nor Prelude, a gap in the defaults, a default of the wrong type and a bad variant. Prints, for
# each row, which counts of arguments form_for takes (for 0 to 3) and which form_for_call picks with a block (b, the
# block form; p, the plain one), the fewest arguments, the arity text (and the one of a method call, which leaves out
# the receiver), the signature and the problem of the defaults.

def required(name: String, type: Types.Type) -> Model.Named
  return Model.Named(name: name, type: type)
end

def optional(name: String, type: Types.Type, default: Model.Default) -> Model.Named
  return Model.Named(name: name, type: type, default: default)
end

def row(name: String, parameters: List[Model.Named], rule: Model.Rule, others: List[Model.Builtin]) -> Model.Builtin
  return Model.Builtin(
    name: name,
    parameters: parameters,
    result: Types.Type.Void,
    rule: rule,
    implementation: name,
    effects: [],
    description: "",
    alternatives: others,
  )
end

def plain(name: String, parameters: List[Model.Named]) -> Model.Builtin
  return row(name, parameters, Model.Rule.Plain, [])
end

def takes(entry: Model.Builtin, arity: Int) -> String
  if Builtins.form_for(entry, arity).ok?
    return "y"
  end

  return "n"
end

# The form a call with a block takes: b for a form whose last parameter is an Fn, p for one without, n for none.
def with_block(entry: Model.Builtin, arity: Int) -> String
  found = Builtins.form_for_call(entry, arity, true)
  if !found.ok?
    return "n"
  end

  form = found.unwrap!
  if form.parameters.size > 0 and Types.is?(form.parameters[form.parameters.size - 1].type, "Fn")
    return "b"
  end

  return "p"
end

def show(entry: Model.Builtin) -> Void
  taken = [0, 1, 2, 3].map do |arity: Int| takes(entry, arity) end.join("")
  blocks = [0, 1, 2, 3].map do |arity: Int| with_block(entry, arity) end.join("")
  puts("#{entry.name} takes=#{taken} block=#{blocks} required=#{Builtins.required_count(entry)}")
  puts("  arity=#{Builtins.arity_text(entry, 0)} method=#{Builtins.arity_text(entry, 1)}")
  puts("  signature=#{Builtins.form_signature(entry)}")
  puts("  problem=#{Builtins.default_problem(entry)}")
end

def main() -> Void
  text = Types.Type.String
  number = Types.Type.Int
  each_line = Types.Type.Fn([Types.Type.String], Types.Type.Void)
  level = Types.Type.Enum("LogRegistry.Level", [])
  await = Types.Type.Enum("Await", [Types.Type.Int])
  x = required("x", number)
  one = optional("b", number, Model.Default.Whole(1))
  timeout = optional("timeout_ms", number, Model.Default.Whole(1000))
  info = optional("level", level, Model.Default.Variant("LogRegistry.Level.Info"))

  show(plain("Row.fn_last", [required("path", text), timeout, required("f", each_line)]))
  show(plain("Row.plain", [required("path", text), timeout]))
  show(plain("Row.none", [required("path", text)]))
  show(row("Row.alternative", [x, one], Model.Rule.Plain, [plain("Row.alternative", [x])]))
  show(row("Row.alternative_second", [x], Model.Rule.Plain, [plain("Row.alternative_second", [x, one])]))
  block = required("f", Types.Type.Fn([Types.Type.Int], Types.Type.Result(Types.Type.Var("A"))))
  block_form = row("Row.block_form", [x, one, block], Model.Rule.Prelude, [])
  show(row("Row.block", [x, one], Model.Rule.Plain, [block_form]))
  other_default = row("Row.block_other", [x, timeout, block], Model.Rule.Prelude, [])
  show(row("Row.block_other", [x, one], Model.Rule.Plain, [other_default]))
  show(row("Row.not_plain", [x, one], Model.Rule.ListMap, []))
  show(row("Row.prelude", [required("path", text), timeout], Model.Rule.Prelude, []))
  show(plain("Row.gap", [x, optional("a", number, Model.Default.Whole(1)), required("b", number)]))
  show(plain("Row.fn_not_last", [x, one, required("f", each_line), optional("c", number, Model.Default.Whole(2))]))
  show(plain("Row.wrong_type", [x, optional("b", number, Model.Default.Text("x"))]))
  show(plain("Row.wrong_list", [x, optional("a", Types.Type.Map(text, number), Model.Default.EmptyList)]))
  show(plain("Row.variant_ok", [x, info]))
  show(plain("Row.variant_missing", [x, optional("level", level, Model.Default.Variant("LogRegistry.Level.Nope"))]))
  show(plain("Row.variant_payload", [x, optional("done", await, Model.Default.Variant("Await.Done"))]))
  show(plain("Row.variant_other_enum", [x, optional("level", level, Model.Default.Variant("Await.TimedOut"))]))
  show(plain("Row.variant_unknown_enum", [x, optional("l", Types.Type.Enum("Nope", []), Model.Default.Variant("Nope.A"))]))

  every = [
    Model.Default.Absent,
    Model.Default.Whole(-6),
    Model.Default.Real(0.5),
    Model.Default.Text("a\"b"),
    Model.Default.Flag(true),
    Model.Default.Nothing,
    Model.Default.EmptyList,
    Model.Default.EmptyMap,
    Model.Default.Variant("LogRegistry.Level.Info"),
  ]
  puts(every.map do |default: Model.Default| "[#{Builtins.default_text(default)}]" end.join(" "))
end
