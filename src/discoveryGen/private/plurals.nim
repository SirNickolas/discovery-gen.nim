# Based on https://github.com/plurals/pluralize
import std/macros
import std/pegs
import std/strscans
from   std/strutils import split, toLowerAscii, toUpperAscii

func reversedString(s: string): string =
  result = newString s.len
  let last = s.len - 1
  for i, c in s:
    result[last - i] = c

func createCharSet(curly: NimNode): NimNode =
  bindSym"charSet".newCall curly

func createTerm(s: string): NimNode =
  if s.len == 1:
    let curly = nnkCurly.newNimNode
    for c in s:
      curly.add newLit c.toLowerAscii, newLit c.toUpperAscii
    createCharSet curly
  else:
    bindSym"termIgnoreCase".newCall newLit s.reversedString

iterator simplePatternMatchers(pattern: string): NimNode =
  var
    idx = 0
    token = ""
    curly: NimNode
    inverted = false
  if not scanp(pattern, idx,
    (* ~{'[', '(', '\\'} -> token &= $_) ^* (
      '[' -> (block:
        if token.len != 0:
          yield createTerm token
        curly = nnkCurly.newNimNode
      ),
      ?'^' -> (inverted = true),
      + ~{']', '-', '\\'} -> curly.add(newLit toLowerAscii $_, newLit toUpperAscii $_),
      ']' -> (block:
        if inverted:
          curly = quote: {'\x01' .. '\xFF'} - `curly`
          inverted = false
        yield createCharSet curly
        token.setLen 0
      ),
    ),
  ) or idx != pattern.len:
    error "invalid pattern: " & pattern

  if token.len != 0:
    yield createTerm token

macro pat(pattern: static string): Peg =
  let sequenceSym = bindSym"sequence"
  result = bindSym"/".newCall
  for alt in pattern.split '|': # Will work incorrectly if `|` is put inside a character class.
    let sub = sequenceSym.newCall
    for node in alt.simplePatternMatchers:
      sub.add node

    result.add:
      let n = sub.len
      if n == 2:
        sub[1]
      else:
        for i in 1 .. (n - 1) shr 1:
          let tmp = sub[i]
          sub[i] = sub[n - i]
          sub[n - i] = tmp
        sub

  if result.len == 2:
    result = result[1]

let rulesData = {
  pat"men": (false, "man"),

  sequence(
    ?pat"x",
    capture pat"eau",
  ): (true, ""),

  sequence(
    pat"ren",
    capture pat"child",
  ): (true, ""),

  sequence(
    pat"rson|ople",
    capture pat"pe",
  ): (true, "rson"),

  sequence(
    pat"ices",
    capture pat"matr|append",
  ): (true, "ix"),

  sequence(
    pat"ices",
    capture pat"cod|mur|sil|vert|ind",
  ): (true, "ex"),

  sequence(
    pat"ae",
    capture pat"alumn|alg|vertebr",
  ): (true, "a"),

  sequence(
    pat"a",
    capture pat do:
      "apheli|hyperbat|periheli|asyndet|noumen|phenomen|criteri|organ|prolegomen|hedr|automat"
  ): (true, "on"),

  sequence(
    pat"a",
    capture pat do:
      "agend|addend|millenni|dat|extrem|bacteri|desiderat|strat|candelabr|errat|ov|symposi" &
      "|curricul|quor"
  ): (true, "um"),

  sequence(
    pat"us|i",
    capture pat"alumn|syllab|vir|radi|nucle|fung|cact|stimul|termin|bacill|foc|uter|loc|strat",
  ): (true, "us"),

  sequence(
    pat"[ie]s",
    capture pat"test",
  ): (true, "is"),

  sequence(
    pat"s",
    capture pat"movie|twelve|abuse|e[mn]u",
  ): (true, ""),

  sequence(
    pat"s[ei]s",
    capture pat"analy|diagno|parenthe|progno|synop|the|empha|cri|ne",
  ): (true, "sis"),

  sequence(
    ?pat"es",
    capture pat"x|ch|ss|sh|zz|tto|go|cho|alias|[^aou]us|t[lm]as|gas|hero|ato|gro|[aeiou]ris",
  ): (true, ""),

  sequence(
    pat"im",
    capture pat"seraph|cherub",
  ): (true, ""),

  sequence(
    pat"ice",
    capture pat"titm|[lm]",
    !identChars,
  ): (true, "ouse"),

  sequence(
    pat"ies",
    capture pat"mon|smil",
    !identChars,
  ): (true, "ey"),

  sequence(
    pat"ies",
    capture sequence(
      pat do:
        "[ltp]|neckt|crosst|hogt|aunt|coll|faer|food|gen|goon|group|hipp|junk|vegg|porkp|charl" &
        "|calor|cut",
      !identChars,
    ) / pat"dg|ss|ois|lk|ok|wn|mb|th|ch|ec|oal|is|ck|ix|sser|ts|wb",
  ): (true, "ie"),

  pat"ies": (false, "y"),

  sequence(
    pat"ves",
    capture pat"ar|wol|[ae]l|[eo][ao]",
  ): (true, "f"),

  sequence(
    pat"ves",
    capture pat"wi|kni" / sequence(
      pat"li",
      pat"after|half|high|low|mid|non|night" / !identChars,
    ),
  ): (true, "fe"),

  capture pat"ss": (true, ""),

  pat"s": (false, ""),
}

iterator iterRules: (Peg, (bool, string)) =
  {.cast(noSideEffect).}:
    for a in rulesData:
      yield a

func singularize*(word: string): string =
  let rev = word.reversedString
  var cap: Captures
  for (pattern, repl) in iterRules():
    {.cast(tags: []).}:
      let n = rev.rawMatch(pattern, 0, cap)
    if n >= 0:
      let (hasCapture, suffix) = repl
      result = word[0 .. ^(n + 1)]
      if hasCapture:
        let (a, b) = cap.bounds 0
        result &= word[^(b + 1) .. ^(a + 1)]
      result &= suffix
      return
  word
