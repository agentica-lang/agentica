struct User
  id: Int
  tags: List[String]
end

def main() -> Void
  User.members.each do |m|
    puts("#{m.name}: #{m.type}")
  end
end
