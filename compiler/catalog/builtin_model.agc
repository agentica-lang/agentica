## The data types of the builtin catalog. The rows themselves are builtins_data.agc, edited by hand.

import Types from "../syntax/types"

## The special checking rule of a builtin, the `rule` field of a catalog row. Plain is no rule: the arguments are
## checked against the parameters. The other variants name a special rule of the checker in CamelCase (a task spawn is
## TaskSpawn); a test compares the two lists. Prelude is a function written in Agentica in stdlib/prelude/ (its
## PreludeRow says which): the arguments are matched against the type variables of the row.
export enum Rule
  Plain
  AtsCall
  AtsNew
  ChannelNew
  ChannelRecv
  ChannelSend
  ChannelTarget
  CodecDecode
  CodecEncode
  Error
  Identity
  JsonCodec
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
  NativeCallback
  NativeClose
  NativeClosed
  NativeMemoryBlock
  NativeStruct
  Ok
  OkVoid
  OptionalNone
  OptionalSome
  Prelude
  ProfileMeasure
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
  TaskTarget
  TestEq
  TestResult
end

## The default value of a builtin parameter, a constant the call site can build with no code of its own (the same
## constants as the default of a user function, and an empty Bytes). Absent is no default. Whole, Real, Text and Flag
## are the literals of those types, Nothing is nil, EmptyBytes is `"".bytes`, and Variant holds "Enum.Variant" of a
## builtin enum whose variant has no payload.
export enum Default
  Absent
  Whole(Int)
  Real(Float)
  Text(String)
  Flag(Bool)
  Nothing
  EmptyList
  EmptyMap
  EmptyBytes
  Variant(String)
end

## A name with a type: a parameter of a builtin, or a field of a struct. Only a parameter of a builtin has a default;
## the lowering of a call that leaves out the trailing arguments with a default puts the default in their place, so the
## VM always gets every argument.
export struct Named
  name: String
  type: Types.Type
  default: Default = Default.Absent
end

## One builtin. A name may have alternatives: other forms with a different number of parameters (ok(), Task.await with
## a timeout, Map.get with a default). A Plain or Prelude builtin with no alternative may instead give a default to its
## last parameters, as a user function does (builtins.agc `default_problem` lists the rules). implementation is the
## name of the VM builtin; effects are the capabilities it needs (stdout, network, ...).
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

## A type variable of a prelude function that only some types may take: the key of `group_by` is an Int or a String.
## what is how the message names the value ("a key"). The variables of a row that has no Limit take any type.
export struct Limit
  variable: String
  allowed: List[Types.Type]
  what: String
end

## What the checker and the lowering need to know about a prelude function besides its catalog row (the row of the
## same name). module is the stem of the prelude file with the body (stdlib/prelude/list.agc is "list"). The body is a
## function of that file: bodies maps the word of the type that selector (a limited variable) is bound to, such as
## "Int", to the function; a function that serves every allowed type has selector "" and the one entry "".
export struct PreludeRow
  name: String
  module: String
  limits: List[Limit]
  selector: String
  bodies: Map[String, String]
end
