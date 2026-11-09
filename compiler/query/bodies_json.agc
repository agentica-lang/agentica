## The JSON form of `Analysis.bodies` (#1159, experimental): `{version, command, file, modules, functions}`. A module
## is `{prefix, file}`. A function is `{name, linked, exported, span, name_span, generics, params, result, body}`, with
## a span `{file, range}`, and a parameter `{name, type, range, default}`. A node is `{kind, type, range, text, target,
## new, children}`, and a type `{kind, name, args}`.

import Model from "../analysis/model"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"

## The object of the answer.
export def json(found: Model.Bodies) -> Json
  functions = found.functions.map do |function: Model.Body| function_json(found.file, function) end
  return JSON.object({
    "version": JSON.from(found.version),
    "command": JSON.from("bodies"),
    "file": JSON.from(found.file),
    "modules": JSON.array(
      found.modules.map do |module: Model.BodyModule|
        JSON.object({"prefix": JSON.from(module.prefix), "file": JSON.from(module.file)})
      end,
    ),
    "functions": JSON.array(functions),
  })
end

def function_json(file: String, function: Model.Body) -> Json
  params = function.params.map do |param: Model.BodyParam|
    JSON.object({
      "name": JSON.from(param.name),
      "type": type_json(param.type),
      "range": DiagnosticJson.range(param.range),
      "default": JSON.array(param.default.map(&node_json)),
    })
  end

  return JSON.object({
    "name": JSON.from(function.name),
    "linked": JSON.from(function.linked),
    "exported": JSON.from(function.exported),
    "span": DocJson.span_json(file, function.range),
    "name_span": DocJson.span_json(file, function.name_range),
    "generics": JSON.array(function.generics.map do |name: String| JSON.from(name) end),
    "params": JSON.array(params),
    "result": type_json(function.result),
    "body": JSON.array(function.body.map(&node_json)),
  })
end

# The object of one node, with its children.
def node_json(node: Model.Node) -> Json
  return JSON.object({
    "kind": JSON.from(node.kind),
    "type": type_json(node.type),
    "range": DiagnosticJson.range(node.range),
    "text": JSON.from(node.text),
    "target": JSON.from(node.target),
    "new": JSON.from(node.new),
    "children": JSON.array(node.children.map(&node_json)),
  })
end

def type_json(type: Model.TypeShape) -> Json
  return JSON.object({
    "kind": JSON.from(type.kind),
    "name": JSON.from(type.name),
    "args": JSON.array(type.args.map(&type_json)),
  })
end
