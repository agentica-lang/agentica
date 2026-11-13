module Net
  export struct Sock
    fd: Int

    private

    key: String
  end

  export def make() -> Sock = Sock(fd: 1, key: "k")

  export def key_of(s: Sock) -> String = s.key
end

def main() -> Void
  s = Net.make()
  puts(Net.key_of(s) + s.fd.to_s)
  puts(s.key)
end
