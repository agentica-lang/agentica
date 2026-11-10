## The JSON form of `Analysis.native_modules` (#1156): `{version, command, file, blocks}`. A block is `{library, span,
## api, functions, resources, types}`; a span is `{file, range}` with the `file` the answer is for, a doc is null when
## there is none, and a type is a string as the table of the module spells it.

import Model from "../analysis/model"
import DocJson from "../docs/doc_json"

## The object of the answer.
export def json(found: Model.NativeModules) -> Json
  blocks = found.blocks.map do |block: Model.NativeBlock| block_json(found.file, block) end
  JSON.object({
    "version": JSON.from(found.version),
    "command": JSON.from("native-modules"),
    "file": JSON.from(found.file),
    "blocks": JSON.array(blocks),
  })
end

# `api` is `{major, minor}`, the least version of the C API that has what the block declares.
def block_json(file: String, block: Model.NativeBlock) -> Json
  functions = block.functions.map do |function: Model.NativeFunction| function_json(file, function) end
  resources = block.resources.map do |resource: Model.NativeResource| resource_json(file, resource) end
  types = block.types.map do |type: Model.NativeType| type_json(type) end
  JSON.object({
    "library": JSON.from(block.library),
    "span": DocJson.span_json(file, block.range),
    "api": JSON.object({"major": JSON.from(block.api_major), "minor": JSON.from(block.api_minor)}),
    "functions": JSON.array(functions),
    "resources": JSON.array(resources),
    "types": JSON.array(types),
  })
end

def function_json(file: String, function: Model.NativeFunction) -> Json
  parameters = function.parameters.map do |parameter: Model.NativeParameter|
    JSON.object({"name": JSON.from(parameter.name), "type": JSON.from(parameter.type)})
  end

  JSON.object({
    "name": JSON.from(function.name),
    "mode": JSON.from(function.mode),
    "exported": JSON.from(function.exported),
    "doc": DocJson.text_json(function.doc),
    "span": DocJson.span_json(file, function.range),
    "name_span": DocJson.span_json(file, function.name_range),
    "parameters": JSON.array(parameters),
    "result": JSON.from(function.result),
    "signature": JSON.from(function.signature),
    "types_in": JSON.array(function.types_in.map do |name: String| JSON.from(name) end),
    "types_out": JSON.array(function.types_out.map do |name: String| JSON.from(name) end),
  })
end

def resource_json(file: String, resource: Model.NativeResource) -> Json
  JSON.object({
    "name": JSON.from(resource.name),
    "exported": JSON.from(resource.exported),
    "doc": DocJson.text_json(resource.doc),
    "span": DocJson.span_json(file, resource.range),
    "name_span": DocJson.span_json(file, resource.name_range),
  })
end

# `members` are the fields of a struct or the variants of an enum, each with its `types`: the type of a field, or the
# payload of a variant.
def type_json(type: Model.NativeType) -> Json
  members = type.members.map do |member: Model.NativeMember|
    JSON.object({
      "name": JSON.from(member.name),
      "types": JSON.array(member.types.map do |text: String| JSON.from(text) end),
    })
  end

  JSON.object({
    "kind": JSON.from(type.kind),
    "name": JSON.from(type.name),
    "shape": JSON.from(type.shape),
    "members": JSON.array(members),
  })
end
