export struct User
  name: String
  age: Int
end

export enum Status
  Active
  Gone
end

export def describe(user: User) -> String
  return user.name + ":" + user.age.to_s
end

export def names(xs: List[String]) -> List[String]
  return xs.map do |x| x.upcase end
end
