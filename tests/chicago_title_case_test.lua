-- Expected outputs are frozen from scripts-raycast/title-case-chicago.py (main@edc350b773addfa1db36d4f1e5eb840363c006fd).
-- Retain legacy behavior, including apostrophe handling and ASCII-only word matching.
package.path = "./?.lua;./?/init.lua;" .. package.path
local converter = require("components.chicago_title_case")
assert(type(converter.convert) == "function", "Chicago converter exports convert(text)")
local cases = {
  { id = "minor words", input = "the rise and fall of ai", expected = "The Rise and Fall of AI" },
  { id = "first article", input = "a guide to the api", expected = "A Guide to the API" },
  { id = "colon", input = "war and peace: the art of the deal", expected = "War and Peace: The Art of the Deal" },
  { id = "music keys uppercase", input = "F-sharp and B-flat in ai", expected = "F-sharp and B-flat in AI" },
  { id = "music keys lowercase", input = "f-sharp and b-flat in ai", expected = "F-sharp and B-flat in AI" },
  { id = "music natural", input = "f-natural and b-sharp", expected = "F-natural and B-sharp" },
  { id = "acronyms", input = "the ai and the api", expected = "The AI and the API" },
  { id = "preserve all capitals", input = "WHY AI WORKS", expected = "WHY AI WORKS" },
  { id = "ASCII apostrophe legacy", input = "it's an api", expected = "It'S an API" },
  { id = "curly apostrophe", input = "o’neill and the api", expected = "O’Neill and the API" },
  { id = "em dash", input = "a guide—an introduction to dna", expected = "A Guide—An Introduction to DNA" },
  { id = "multiple subtitle boundaries", input = "the end. a new start! the api? and the url", expected = "The End. A New Start! The API? And the URL" },
  { id = "whitespace", input = "one  two\tand   three", expected = "One  Two\tand   Three" },
  { id = "independent lines", input = "a\n\nan api\nand the end", expected = "A\n\nAn API\nAnd the End" },
  { id = "punctuation separators", input = "a/b", expected = "A/B" },
  { id = "non ASCII prefix", input = "日本語 and ai", expected = "日本語 And AI" },
  { id = "legacy ASCII word boundaries", input = "naïve and café", expected = "NaïVe and Café" },
  { id = "hyphen compound", input = "the up-to-date guide to the art", expected = "The Up-to-Date Guide to the Art" },
  { id = "mixed existing uppercase", input = "the ROCK and ROLL", expected = "The ROCK and ROLL" },
  { id = "known acronyms existing", input = "USA and UK with QA", expected = "USA and UK with QA" },
  { id = "hyphen minor suffix", input = "go-to for the people", expected = "Go-to for the People" },
  { id = "multiple apostrophes", input = "l'amour et l'amour", expected = "L'Amour Et L'Amour" },
  { id = "surrounding spaces", input = "  the book  ", expected = "  The Book  " },
  { id = "digits only", input = "123", expected = "123" },
  { id = "empty text", input = "", expected = "" },
  { id = "ios html url", input = "the ios api and the html url", expected = "The IOS API and the HTML URL" },
  { id = "en dash", input = "a guide–the end", expected = "A Guide–The End" },
  { id = "Japanese period", input = "the end。the beginning", expected = "The End。The Beginning" },
}
for _, case in ipairs(cases) do
  local actual = converter.convert(case.input)
  assert(actual == case.expected, string.format("%s: expected %q, got %q", case.id, case.expected, tostring(actual)))
  assert(converter.convert(case.input) == actual, case.id .. ": repeated conversion is deterministic")
end
print("chicago_title_case_test: ok (" .. #cases .. " cases)")
