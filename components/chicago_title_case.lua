-- Legacy-compatible, side-effect-free Chicago title case conversion.
-- The old Python converter recognizes ASCII words (with ASCII/curly apostrophes
-- and hyphenated parts). Keep non-word bytes, punctuation and whitespace intact.
local M = {}

local lowerWords = {}
for word in ("a an and as at but by down for from in into like near nor n of off on onto or out over per past the than to till unto up via with"):gmatch("%S+") do
  lowerWords[word] = true
end

local acronyms = {}
for word in ("ai api ceo dna faq html ios ml phd qa rna usa uk url ux"):gmatch("%S+") do
  acronyms[word] = true
end

local curlyApostrophe = "’"
local boundaries = { ":", ".", "!", "?", "。", "！", "？", "—", "–" }

local function asciiLetter(byte)
  return byte ~= nil and ((byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122))
end

-- Returns the last byte in the Python WORD_RE match starting at pos.
local function wordEnd(text, pos)
  local cursor = pos
  while asciiLetter(text:byte(cursor)) do cursor = cursor + 1 end
  while true do
    local separatorLength
    local separator = text:sub(cursor, cursor)
    if separator == "'" or separator == "-" then
      separatorLength = 1
    elseif text:sub(cursor, cursor + #curlyApostrophe - 1) == curlyApostrophe then
      separatorLength = #curlyApostrophe
    end
    if not separatorLength or not asciiLetter(text:byte(cursor + separatorLength)) then break end
    cursor = cursor + separatorLength
    while asciiLetter(text:byte(cursor)) do cursor = cursor + 1 end
  end
  return cursor - 1
end

local function capitalizeWord(word)
  if word:find("[A-Za-z]") and word:upper() == word then return word end
  local converted, cursor = {}, 1
  while cursor <= #word do
    local asciiQuote = word:find("'", cursor, true)
    local curlyQuote = word:find(curlyApostrophe, cursor, true)
    local quote = asciiQuote
    if curlyQuote and (not quote or curlyQuote < quote) then quote = curlyQuote end
    local piece = word:sub(cursor, quote and quote - 1 or #word)
    if piece ~= "" then converted[#converted + 1] = piece:sub(1, 1):upper() .. piece:sub(2):lower() end
    if not quote then break end
    local delimiter = word:sub(quote, quote + #curlyApostrophe - 1) == curlyApostrophe and curlyApostrophe or "'"
    converted[#converted + 1] = delimiter
    cursor = quote + #delimiter
  end
  return table.concat(converted)
end

local wordForm
wordForm = function(word, major)
  if word:find("-", 1, true) then
    local converted, cursor, first = {}, 1, true
    while true do
      local hyphen = word:find("-", cursor, true)
      local part = word:sub(cursor, hyphen and hyphen - 1 or #word)
      local previous = #converted >= 2 and (converted[#converted - 1] .. converted[#converted]) or ""
      local musicalModifier = not first
        and previous:match("^[A-Ga-g]%-$") ~= nil
        and (part:lower() == "sharp" or part:lower() == "flat" or part:lower() == "natural")
      if musicalModifier then
        converted[#converted + 1] = part:lower()
      else
        converted[#converted + 1] = wordForm(part, first and major or not lowerWords[part:lower()])
      end
      if not hyphen then break end
      converted[#converted + 1] = "-"
      cursor, first = hyphen + 1, false
    end
    return table.concat(converted)
  end
  local lower = word:lower()
  if acronyms[lower] then return lower:upper() end
  if major then return capitalizeWord(word) end
  return lower
end

local function hasBoundary(between)
  for _, delimiter in ipairs(boundaries) do
    if between:find(delimiter, 1, true) then return true end
  end
  return false
end

local function convertLine(line)
  local matches, cursor = {}, 1
  while cursor <= #line do
    if asciiLetter(line:byte(cursor)) then
      local last = wordEnd(line, cursor)
      matches[#matches + 1] = { first = cursor, last = last, word = line:sub(cursor, last) }
      cursor = last + 1
    else
      cursor = cursor + 1
    end
  end
  if #matches == 0 then return line end

  local segmentStarts, segmentEnds = { [1] = true }, { [#matches] = true }
  for index = 1, #matches - 1 do
    if hasBoundary(line:sub(matches[index].last + 1, matches[index + 1].first - 1)) then
      segmentEnds[index] = true
      segmentStarts[index + 1] = true
    end
  end

  local output, copiedTo = {}, 1
  for index, match in ipairs(matches) do
    output[#output + 1] = line:sub(copiedTo, match.first - 1)
    local major = segmentStarts[index] or segmentEnds[index] or not lowerWords[match.word:lower()]
    output[#output + 1] = wordForm(match.word, major)
    copiedTo = match.last + 1
  end
  output[#output + 1] = line:sub(copiedTo)
  return table.concat(output)
end

function M.convert(text)
  assert(type(text) == "string", "text must be a string")
  local lines, cursor = {}, 1
  while true do
    local newline = text:find("\n", cursor, true)
    if not newline then
      lines[#lines + 1] = convertLine(text:sub(cursor))
      break
    end
    lines[#lines + 1] = convertLine(text:sub(cursor, newline - 1))
    cursor = newline + 1
  end
  return table.concat(lines, "\n")
end

return M
