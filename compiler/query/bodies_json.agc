## The JSON form of `Analysis.bodies` (#1159, experimental): `{version, command, file, modules, functions, prelude}`. A
## module is `{prefix, file}`. A function is `{name, linked, exported, span, name_span, generics, params, result, body,
## pure, impure}`, with a span `{file, range}`, a parameter `{name, type, range, default}` and a reason of `impure`
## `{effect, call, range, through}`. A node is `{kind, type, range, text, target, new, children, type_args, prelude}`,
## and a type `{kind, name, args}`.

import Model from "../analysis/model"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"

## The object of the answer.
def json(found: Model.Bodies) -> JSON.Value
  functions = found.functions.map(&function_json)
  JSON.object({
    "version": JSON.from(found.version),
    "command": JSON.from("bodies"),
    "file": JSON.from(found.file),
    "modules": JSON.array(
      found.modules.map do |module: Model.BodyModule|
        JSON.object({"prefix": JSON.from(module.prefix), "file": JSON.from(module.file)})
      end,
    ),
    "functions": JSON.array(functions),
    "prelude": JSON.array(found.prelude.map(&function_json)),
  })
end

private

def function_json(function: Model.Body) -> JSON.Value
  params = function.params.map do |param: Model.BodyParam|
    JSON.object({
      "name": JSON.from(param.name),
      "type": type_json(param.type),
      "range": DiagnosticJson.range(param.range),
      "default": JSON.array(param.default.map(&node_json)),
    })
  end

  JSON.object({
    "name": JSON.from(function.name),
    "linked": JSON.from(function.linked),
    "exported": JSON.from(function.exported),
    "span": DocJson.span_json(function.file, function.range),
    "name_span": DocJson.span_json(function.file, function.name_range),
    "generics": JSON.array(function.generics.map do |name: String| JSON.from(name) end),
    "params": JSON.array(params),
    "result": type_json(function.result),
    "body": JSON.array(function.body.map(&node_json)),
    "pure": JSON.from(function.pure),
    "impure": JSON.array(function.impure.map(&reason_json)),
  })
end

def reason_json(reason: Model.Reason) -> JSON.Value
  JSON.object({
    "effect": JSON.from(reason.effect),
    "call": JSON.from(reason.call),
    "range": DiagnosticJson.range(reason.range),
    "through": JSON.array(reason.through.map do |name: String| JSON.from(name) end),
  })
end

# The object of one node, with its children.
def node_json(node: Model.Node) -> JSON.Value
  JSON.object({
    "kind": JSON.from(node.kind),
    "type": type_json(node.type),
    "range": DiagnosticJson.range(node.range),
    "text": JSON.from(node.text),
    "target": JSON.from(node.target),
    "new": JSON.from(node.new),
    "children": JSON.array(node.children.map(&node_json)),
    "type_args": JSON.array(node.type_args.map(&type_json)),
    "prelude": JSON.from(node.prelude),
  })
end

def type_json(type: Model.TypeShape) -> JSON.Value
  JSON.object({
    "kind": JSON.from(type.kind),
    "name": JSON.from(type.name),
    "args": JSON.array(type.args.map(&type_json)),
  })
end
