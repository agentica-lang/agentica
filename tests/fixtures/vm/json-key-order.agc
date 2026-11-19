# Every JSON object keeps its key order (#1760): struct fields, map insertion order, parsed text order.
struct Bond
  name: String
  coupon: Float
  amount: Int
end

def main() -> Void
  bond = Bond(name: "b1", coupon: 2.5, amount: 100)
  puts(JSON.encode(bond))
  puts(JSON.from(bond))
  puts(JSON.from([bond, bond]))
  puts(JSON.encode({"zeta": 1, "alpha": 2}))
  puts(JSON.object({"zeta": JSON.from(1), "alpha": JSON.from(2)}))
  parsed = JSON.parse("{\"z\": 1, \"a\": {\"y\": 2, \"b\": 3}, \"z\": 4}").unwrap!
  puts(parsed)
  puts(JSON.get(parsed, "z").unwrap!)
  case JSON.node(parsed)
    JSON.Node.Object(members) -> puts(members.keys)
    _ -> puts("not an object")
  end
  decoded = JSON.decode("{\"z\": 1, \"m\": 2, \"a\": 3}", Map[String, Int]).unwrap!
  puts(decoded.keys)
  other = JSON.parse("{\"a\": {\"b\": 3, \"y\": 2}, \"z\": 4}").unwrap!
  puts(Test.eq(parsed, other).ok?)
end
