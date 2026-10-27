# Type.members lists the fields of a struct type as StructMember(name, type), in declaration order.
import {Point} from "lib/geometry"
import Geo from "lib/geometry"

type Id = Int

enum Role
  Admin
  Guest
end

struct Address
  city: String
  zip: Id
end

struct User
  id: Id
  name: String
  tags: List[String]
  scores: Map[String, Int]
  home: Address
  role: Role
  parsed: Result[Int]
  shape: Geo.Shape[String]
  members: Int
end

struct Empty
end

def show(title: String, members: List[StructMember]) -> Void
  puts(title)
  members.each do |m|
    puts("  #{m.name}: #{m.type}")
  end
end

def main() -> Void
  show("User", User.members)
  show("Address", Address.members)
  show("Point", Point.members)
  show("Geo.Point", Geo.Point.members)
  show("Empty", Empty.members)
  show("StructMember", StructMember.members)
  puts(User.members.size)
  puts(User.members.first)
  user = User(
    id: 1,
    name: "Ada",
    tags: [],
    scores: {},
    home: Address(city: "X", zip: 2),
    role: Role.Admin,
    parsed: ok(3),
    shape: Geo.Shape.Nothing,
    members: 7,
  )
  # A field called members is read from a value; Type.members is on the type.
  puts(user.members)
end
