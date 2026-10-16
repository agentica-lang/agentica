def main() -> Void
  groups = [[1, 2], [3]]
  groups.each_with_index do |group, index|
    puts("group #{index}")
    puts(group.each_slice(index))
  end
end
