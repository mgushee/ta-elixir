-- Copyright 2014 Matt Gushee <matt@gushee.net>. See LICENSE.
-- Elixir LPeg lexer.

local l = require('lexer')
local token, word_match = l.token, l.word_match
local P, R, S = lpeg.P, lpeg.R, lpeg.S

local M = {_NAME = 'elixir'}

-- Whitespace.
local ws = token(l.WHITESPACE, l.space^1)

-- Comments.
local comment = token(l.COMMENT, '#' * l.nonnewline^0)

local delimiter_matches = {['('] = ')', ['['] = ']', ['{'] = '}'}
local literal_delimited = P(function(input, index)
  local delimiter = input:sub(index, index)
  if not delimiter:find('[%w\r\n\f\t ]') then -- only non alpha-numerics
    local match_pos, patt
    if delimiter_matches[delimiter] then
      -- Handle nested delimiter/matches in strings.
      local s, e = delimiter, delimiter_matches[delimiter]
      patt = l.delimited_range(s..e, false, false, true)
    else
      patt = l.delimited_range(delimiter)
    end
    match_pos = lpeg.match(patt, input, index)
    return match_pos or #input + 1
  end
end)

-- Strings.
local cmd_str = l.delimited_range('`')
local lit_cmd = '%x' * literal_delimited
local lit_array = '%w' * literal_delimited
local sq_str = l.delimited_range("'")
local dq_str = l.delimited_range('"')
local lit_str = '%' * S('qQ')^-1 * literal_delimited
local heredoc = '<<' * P(function(input, index)
  local s, e, indented, _, delimiter =
    input:find('(%-?)(["`]?)([%a_][%w_]*)%2[\n\r\f;]+', index)
  if s == index and delimiter then
    local end_heredoc = (#indented > 0 and '[\n\r\f]+ *' or '[\n\r\f]+')
    local _, e = input:find(end_heredoc..delimiter, e)
    return e and e + 1 or #input + 1
  end
end)
-- TODO: regex_str fails with `obj.method /patt/` syntax.
local regex_str = l.last_char_includes('!%^&*([{-=+|:;,?<>~') *
                  l.delimited_range('/', true, false) * S('iomx')^0
local lit_regex = '%r' * literal_delimited * S('iomx')^0
local string = token(l.STRING, (sq_str + dq_str + lit_str + heredoc + cmd_str +
                                lit_cmd + lit_array) * S('f')^-1) +
               token(l.REGEX, regex_str + lit_regex)

local word_char = l.alnum + S('_!?')

-- Numbers.
local dec = l.digit^1 * ('_' * l.digit^1)^0 * S('ri')^-1
local bin = '0b' * S('01')^1 * ('_' * S('01')^1)^0
local integer = S('+-')^-1 * (bin + l.hex_num + l.oct_num + dec)
-- TODO: meta, control, etc. for numeric_literal.
local numeric_literal = '?' * (l.any - l.space) * -word_char
local number = token(l.NUMBER, l.float * S('ri')^-1 + integer + numeric_literal)

-- Keywords.
local keyword = token(l.KEYWORD, word_match({
  'BEGIN', 'END', 'alias', 'and', 'begin', 'break', 'case', 'class', 'def',
  'defined?', 'do', 'else', 'elsif', 'end', 'ensure', 'false', 'for', 'if',
  'in', 'module', 'next', 'nil', 'not', 'or', 'redo', 'rescue', 'retry',
  'return', 'self', 'super', 'then', 'true', 'undef', 'unless', 'until', 'when',
  'while', 'yield', '__FILE__', '__LINE__'
}, '?!'))

-- Functions.
local func = token(l.FUNCTION, word_match({
  'at_exit', 'autoload', 'binding', 'caller', 'catch', 'chop', 'chop!', 'chomp',
  'chomp!', 'eval', 'exec', 'exit', 'exit!', 'fail', 'fork', 'format', 'gets',
  'global_variables', 'gsub', 'gsub!', 'iterator?', 'lambda', 'load',
  'local_variables', 'loop', 'open', 'p', 'print', 'printf', 'proc', 'putc',
  'puts', 'raise', 'rand', 'readline', 'readlines', 'require', 'select',
  'sleep', 'split', 'sprintf', 'srand', 'sub', 'sub!', 'syscall', 'system',
  'test', 'trace_var', 'trap', 'untrace_var'
}, '?!')) * -S('.:|')

-- Identifiers.
local word = (l.alpha + '_') * word_char^0
local identifier = token(l.IDENTIFIER, word)

-- Variables.
local global_var = '$' * (word + S('!@L+`\'=~/\\,.;<>_*"$?:') + l.digit + '-' *
                   S('0FadiIKlpvw'))
local class_var = '@@' * word
local inst_var = '@' * word
local variable = token(l.VARIABLE, global_var + class_var + inst_var)

-- Symbols.
local symbol = token('symbol', ':' * P(function(input, index)
  if input:sub(index - 2, index - 2) ~= ':' then return index end
end) * (word_char^1 + sq_str + dq_str))

-- Operators.
local operator = token(l.OPERATOR, S('!%^&*()[]{}-=+/|:;.,?<>~'))

M._rules = {
  {'whitespace', ws},
  {'keyword', keyword},
  {'function', func},
  {'identifier', identifier},
  {'comment', comment},
  {'string', string},
  {'number', number},
  {'variable', variable},
  {'symbol', symbol},
  {'operator', operator},
}

M._tokenstyles = {
  symbol = l.STYLE_CONSTANT
}

local function disambiguate(text, pos, line, s)
  return line:sub(1, s - 1):match('^%s*$') and
         not text:sub(1, pos - 1):match('\\[ \t]*\r?\n$') and 1 or 0
end

M._foldsymbols = {
  _patterns = {'%l+', '[%(%)%[%]{}]', '=begin', '=end', '#'},
  [l.KEYWORD] = {
    begin = 1, class = 1, def = 1, ['do'] = 1, ['for'] = 1, ['module'] = 1,
    case = 1,
    ['if'] = disambiguate, ['while'] = disambiguate,
    ['unless'] = disambiguate, ['until'] = disambiguate,
    ['end'] = -1
  },
  [l.OPERATOR] = {
    ['('] = 1, [')'] = -1, ['['] = 1, [']'] = -1, ['{'] = 1, ['}'] = -1
  },
  [l.COMMENT] = {
    ['=begin'] = 1, ['=end'] = -1, ['#'] = l.fold_line_comments('#')
  }
}

return M
