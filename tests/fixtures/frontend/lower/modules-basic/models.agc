struct User
  name: String
  age: Int
end

enum Status
  Active
  Gone
end

def describe(user: User) -> String
  return user.name + ":" + user.age.to_s
end

def names(xs: List[String]) -> List[String]
  return xs.map do |x| x.upcase end
end
