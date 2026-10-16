## The VM IR that lowering gives as data. The
## bytecode writer of step 6 reads it.
##
## A function body is a flat list of instructions. A label is an Instr with the op "label" and one argument (the label
## id). The ops are the names of the bytecode instructions (`add-i`, `jump-if-false`, ...). Arguments are registers,
## label ids, function, struct, variant and global indexes, counts and builtin arities, in the order the lowering gives
## them; `const` takes its value in imm and `call-builtin` its name in name. `struct-with` takes dst, window and
## struct, then the positions of the changed fields.

import Source from "source"
import Types from "types"

## The value of a `const` instruction. Void and Nil are the values of those types.
export enum Imm
  Void
  Nil
  Bool(Bool)
  Int(Int)
  Float(Float)
  Text(String)
end

## One instruction, or a label. file is the index in Program.sources of the file the spans are in: a Span has no file
## in compiler/, and the spans of one instruction are always in one file.
export struct Instr
  op: String
  args: List[Int]
  imm: Imm
  name: String
  file: Int
  spans: List[Source.Span]
end

## One function of the table: a declared function, a kept constant, `<start>` or a block. The span is the one of the
## declaration (the program's for `<start>`), in the file at index file.
export struct Function
  name: String
  params: Int
  captures: Int
  slots: Int
  body: List[Instr]
  file: Int
  span: Source.Span
end

## A struct of the table. decodable says that JSON.decode may build it, and types then lists its field types in field
## order.
export struct StructDef
  name: String
  fields: List[String]
  decodable: Bool
  types: List[Types.Type]
end

## One variant of an enum, with the number of its payload items.
export struct VariantDef
  name: String
  size: Int
end

## An enum of the table. The variants of all enums are numbered one after the other in table order.
export struct EnumDef
  name: String
  variants: List[VariantDef]
end

## A source file of the program, in the order the spans refer to it: the canonical path (std/NAME.agc for a standard
## module) and the text.
export struct SourceFile
  file: String
  text: String
end

## The lowered program. globals is the number of slots of the module constants. entry is the index in functions of the
## function the VM starts: `main`, or `<start>` when globals is above zero. The span is the root file's.
export struct Program
  sources: List[SourceFile]
  structs: List[StructDef]
  enums: List[EnumDef]
  functions: List[Function]
  entry: Int
  globals: Int
  span: Source.Span
end

## The instruction with no immediate and no builtin name.
export def instr(op: String, args: List[Int], file: Int, spans: List[Source.Span]) -> Instr
  return Instr(op: op, args: args, imm: Imm.Void, name: "", file: file, spans: spans)
end

## The label with that id.
export def label(id: Int, file: Int) -> Instr
  return Instr(op: "label", args: [id], imm: Imm.Void, name: "", file: file, spans: [])
end
