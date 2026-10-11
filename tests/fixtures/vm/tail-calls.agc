enum Step
  Up(Int)
  Down(Int)
  Stop
end

def count_down(n: Int, acc: Int) -> Int
  if n == 0
    return acc
  elsif n % 2 == 0
    return count_down(n - 1, acc + 2)
  else
    return count_down(n - 1, acc + 1)
  end
end

def is_even(n: Int) -> Bool
  if n == 0
    return true
  end
  return is_odd(n - 1)
end

def is_odd(n: Int) -> Bool
  if n == 0
    return false
  end
  return is_even(n - 1)
end

def walk(s: Step, total: Int) -> Int
  case s
    Step.Up(k) -> return walk(Step.Down(k), total + k)
    Step.Down(k) ->
      if k > 0
        return walk(Step.Down(k - 1), total + 1)
      end
      return walk(Step.Stop, total)
    Step.Stop -> return total
  end
end

def first_big(xs: List[Int], limit: Int) -> Int
  for x in xs
    if x > limit
      return twice(x)
    end
  end
  while true
    return twice(limit)
  end
  return 0
end

def twice(n: Int) -> Int
  return n * 2
end

def sum_to(n: Int) -> Int
  if n == 0
    return 0
  end
  return n + sum_to(n - 1)
end

def wide(k: Int) -> Int
  items = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59,
    60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99,
    100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119,
    120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139,
    140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179,
    180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199,
    200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219,
    220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259,
    260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279,
    280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299
  ]
  return items[k]
end

def pick(k: Int) -> Int
  return wide(k)
end

def swap_args(a: Int, b: Int, depth: Int) -> String
  if depth == 0
    return "#{a} #{b}"
  end
  return swap_args(b, a, depth - 1)
end

def shout(text: String) -> Void
  puts(text)
  return
end

def relay(text: String) -> Void
  return shout(text)
end

def main() -> Void
  puts(count_down(9000, 0))
  puts(is_even(9001))
  puts(is_odd(7))
  puts(walk(Step.Up(5), 0))
  puts(first_big([1, 5, 9, 12], 8))
  puts(first_big([1, 2], 8))
  puts(sum_to(100) + twice(3))
  puts(pick(299))
  puts(swap_args(1, 2, 5))
  relay("done")
  return relay("again")
end
