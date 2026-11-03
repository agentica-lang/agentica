struct User
  name: String
  on_save: Fn[User, Void]
end

struct Team
  members: List[User]
end

def main() -> Void
  team = Team(members: [])
  puts(team == team)
end
