# A struct with private fields, built and changed only by the functions of its module block, while the rest of the
# file passes it around, stores it, sends it over a channel, compares it and prints it with every field.
module Account
  struct Wallet
    owner: String

    private

    cents: Int
    log: List[String] = []
  end

  def open(owner: String) -> Wallet = Wallet(owner: owner, cents: 0)

  def deposit(wallet: Wallet, cents: Int) -> Wallet
    wallet.with(cents: wallet.cents + cents, log: wallet.log.push("+#{cents}"))
  end

  def balance(wallet: Wallet) -> Int = wallet.cents

  def to_json(wallet: Wallet) -> String = JSON.encode(wallet)
end

def main() -> Void
  ana = Account.open("ana") |> Account.deposit(150) |> Account.deposit(25)
  bob = Account.deposit(Account.open("bob"), 7).with(owner: "rob")
  wallets = [ana, bob]
  by_owner = {ana.owner: ana, bob.owner: bob}
  channel: Channel[Account.Wallet] = Channel.new(2)
  channel.send(ana, 1000).unwrap!
  back = channel.recv(1000).unwrap!
  puts("#{back.owner} #{Account.balance(back)} #{back == ana} #{wallets[1] == ana} #{by_owner["rob"].owner}")
  puts(ana.inspect)
  puts("#{bob}")
  puts(Account.to_json(bob))
end
