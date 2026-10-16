## The data types of the builtin catalog. The rows themselves are builtins_data.agc, edited by hand.

import Types from "types"

## The special checking rule of a builtin, the `rule` field of a catalog row. Plain is no rule: the arguments are
## checked against the parameters. The other variants name a special rule of the checker in CamelCase (a task spawn is
## TaskSpawn); a test compares the two lists.
export enum Rule
  Plain
  ChannelNew
  ChannelRecv
  ChannelSend
  ChannelTarget
  Error
  Identity
  JsonDecode
  JsonEncode
  JsonFrom
  JsonSchema
  ListAll
  ListAny
  ListAppend
  ListAt
  ListConcat
  ListCount
  ListEach
  ListFilter
  ListMap
  ListReduce
  ListRepeat
  ListReverse
  ListSet
  ListSize
  ListSort
  ListSortBy
  MapDelete
  MapGet
  MapGetDefault
  MapHas
  MapKeys
  MapPut
  MapSize
  MapValues
  Ok
  OkVoid
  ResultDefault
  ResultMessage
  ResultOk
  ResultUnwrap
  SetAdd
  SetCombine
  SetInclude
  SetNew
  SetQuery
  SetSubset
  SetToA
  Show
  TaskAwait
  TaskAwaitTimeout
  TaskMap
  TaskSpawn
  TaskSpawnOwning
  TestEq
  TestResult
end

## A name with a type: a parameter of a builtin, or a field of a struct.
export struct Named
  name: String
  type: Types.Type
end

## One builtin. A name may have alternatives: other forms with a different number of parameters (ok(), Task.await with
## a timeout, Map.get with a default). implementation is the name of the VM builtin; effects are the capabilities it
## needs (stdout, network, ...).
export struct Builtin
  name: String
  parameters: List[Named]
  result: Types.Type
  rule: Rule
  implementation: String
  effects: List[String]
  description: String
  alternatives: List[Builtin]
end

## A builtin record type, such as HttpRequest, with its fields in declaration order.
export struct Record
  name: String
  fields: List[Named]
end

## One variant of an enum and the types of its payload.
export struct Variant
  name: String
  payload: List[Types.Type]
end

## An enum with its type parameters and variants in declaration order. The builtin enums (Await, LogLevel) and, in the
## checker, the enums of the program have this shape.
export struct EnumDef
  name: String
  parameters: List[String]
  variants: List[Variant]
end
