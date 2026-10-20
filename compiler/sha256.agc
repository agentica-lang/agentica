## SHA-256 (FIPS 180-4) over bytes that arrive in pieces, for the hash of a package (docs/future/45-packages.md, 45.6).
## Written in Agentica because the language has no hash builtin yet (docs/future/20-crypto.md); it is private to the
## front end. Words are 32 bits held in an Int, so every sum and rotation is masked.

WORD = 4294967295

ROUND_CONSTANTS = [
  1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
  3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
  3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
  2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
  666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
  2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
  430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
  1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298,
]

INITIAL = [
  1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225,
]

BLOCK = 64

HEX_DIGITS = "0123456789abcdef".split("")

## The state of a hash: the eight words, the bytes of an unfinished block, and how many bytes came in.
export struct State
  words: List[Int]
  pending: List[Int]
  size: Int
end

## The state before any byte.
export def start() -> State
  return State(words: INITIAL, pending: [], size: 0)
end

## Adds bytes (each in 0 .. 255) to the hash. A block is read from `data` where it lies, so only the part that does not
## fill a block is copied.
export def update(state: State, data: List[Int]) -> State
  words = state.words
  pending = state.pending
  at = 0
  if pending.size > 0
    take = BLOCK - pending.size
    if take > data.size
      take = data.size
    end
    pending = pending.concat(data.take(take))
    at = take
    if pending.size == BLOCK
      words = compress(words, pending, 0)
      pending = []
    end
  end
  while pending.size == 0 and at + BLOCK <= data.size
    words = compress(words, data, at)
    at += BLOCK
  end
  if pending.size == 0 and at < data.size
    pending = data.drop(at)
  end
  return State(words: words, pending: pending, size: state.size + data.size)
end

## Ends the hash and gives it as 64 lowercase hex digits.
export def finish(state: State) -> String
  # The 0x80 byte, zeros up to 8 bytes short of a block, then the length in bits as 64 bits, big end first.
  zeros = (BLOCK - ((state.size + 9) % BLOCK)) % BLOCK
  padding = [128].concat(List.repeat(0, zeros))
  bits = state.size * 8
  for shift in [56, 48, 40, 32, 24, 16, 8, 0]
    padding = padding.push(bits.shift_right_unsigned(shift).bit_and(255))
  end
  digits: List[String] = []
  for word in update(state, padding).words
    for shift in [28, 24, 20, 16, 12, 8, 4, 0]
      digits = digits.push(HEX_DIGITS[word.shift_right_unsigned(shift).bit_and(15)])
    end
  end
  return digits.join("")
end

## The hash of bytes as 64 lowercase hex digits.
export def hex(data: List[Int]) -> String
  return finish(update(start(), data))
end

# One block of 64 bytes of `data` from `at`: the message schedule, then 64 rounds. The rounds are written in line
# because a call costs more than the operations of a round, and the operations are the cost of a hash. A 32-bit word x
# is doubled as x | x << 32, so that each rotation to the right is one logical shift of the double (the bits above 32
# are left in the xor of three of them and cut when the sum is, since the low 32 bits of a sum depend only on the low
# 32 bits of its terms, and no term is near 2^63). The choice and majority functions use the forms with fewer
# operations: ch = g ^ (e & (f ^ g)) and maj = (a & b) | (c & (a | b)).
def compress(state: List[Int], data: List[Int], at: Int) -> List[Int]
  w: List[Int] = []
  for t in 0...16
    base = at + t * 4
    high = data[base].shift_left(24).bit_or(data[base + 1].shift_left(16))
    w = w.push(high.bit_or(data[base + 2].shift_left(8)).bit_or(data[base + 3]))
  end
  for t in 16...64
    x = w[t - 15]
    y = w[t - 2]
    xx = x.bit_or(x.shift_left(32))
    yy = y.bit_or(y.shift_left(32))
    low = xx.shift_right_unsigned(7).bit_xor(xx.shift_right_unsigned(18)).bit_xor(x.shift_right_unsigned(3))
    top = yy.shift_right_unsigned(17).bit_xor(yy.shift_right_unsigned(19)).bit_xor(y.shift_right_unsigned(10))
    w = w.push((w[t - 16] + w[t - 7] + low + top).bit_and(WORD))
  end
  a = state[0]
  b = state[1]
  c = state[2]
  d = state[3]
  e = state[4]
  f = state[5]
  g = state[6]
  h = state[7]
  for t in 0...64
    ee = e.bit_or(e.shift_left(32))
    big_e = ee.shift_right_unsigned(6).bit_xor(ee.shift_right_unsigned(11)).bit_xor(ee.shift_right_unsigned(25))
    choose = g.bit_xor(e.bit_and(f.bit_xor(g)))
    first = h + big_e + choose + ROUND_CONSTANTS[t] + w[t]
    aa = a.bit_or(a.shift_left(32))
    big_a = aa.shift_right_unsigned(2).bit_xor(aa.shift_right_unsigned(13)).bit_xor(aa.shift_right_unsigned(22))
    majority = a.bit_and(b).bit_or(c.bit_and(a.bit_or(b)))
    h = g
    g = f
    f = e
    e = (d + first).bit_and(WORD)
    d = c
    c = b
    b = a
    a = (first + big_a + majority).bit_and(WORD)
  end
  mixed = [a, b, c, d, e, f, g, h]
  out: List[Int] = []
  for i in 0...8
    out = out.push((state[i] + mixed[i]).bit_and(WORD))
  end
  return out
end
