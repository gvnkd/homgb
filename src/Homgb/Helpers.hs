{-# LANGUAGE OverloadedStrings #-}

module Homgb.Helpers
  ( -- list / string utils
    orElse
  , replace
  , split
  , splitOn
  , trim
  , trimFront
  , trimBack
  , isPrefix
  , removeOuterLetters
  , atMay
    -- tag / markup handling
  , removeAllTags
  , markupify
  , filterTags
  , getImgTagAttrs
  , parseHtmlEntities
  ) where

import qualified Data.Text as Text
import Data.List (uncons)
import Text.HTML.TagSoup (Tag(..), renderTags
                         , canonicalizeTags, parseTags, isTagCloseName)

orElse :: Maybe a -> Maybe a -> Maybe a
x `orElse` y = case x of
                 Just _  -> x
                 Nothing -> y

replace :: Eq a => [a] -> [a] -> [a] -> [a]
replace a b c = replace' c a b

replace' :: Eq a => [a] -> [a] -> [a] -> [a]
replace' [] _ _ = []
replace' s find repl
  | take (length find) s == find =
      repl ++ (replace' (drop (length find) s) find repl)
  | otherwise =
      maybe [] (\(c,cs) -> c : replace' cs find repl) (uncons s)

-- | Split a string at ":" (quote-aware, as used by deadd's config rules)
split :: String -> [String]
split ('"':':':'"':ds) = "" : split ds
split (a:[]) = [[a]]
split (a:bs) = maybe [[a]] (\(x,xs) -> (a:x):xs) (uncons (split bs))
split [] = []

splitOn :: Char -> String -> [String]
splitOn c s = case rest of
                []       -> [chunk]
                _:rest'  -> chunk : splitOn c rest'
  where (chunk, rest) = break (==c) s

trimFront :: String -> String
trimFront (' ':ss) = trimFront ss
trimFront ss = ss

trimBack :: String -> String
trimBack = reverse . trimFront . reverse

trim :: String -> String
trim = trimBack . trimFront

isPrefix :: String -> String -> Bool
isPrefix (a:pf) (b:s) = a == b && isPrefix pf s
isPrefix [] _ = True
isPrefix _ _ = False

removeOuterLetters :: String -> String
removeOuterLetters [] = []
removeOuterLetters [_x] = []
removeOuterLetters (_:xs) = init xs

atMay :: [a] -> Int -> Maybe a
atMay ls i = if length ls > i then
  Just $ ls !! i else Nothing

removeAllTags :: Text.Text -> Text.Text
removeAllTags = renderTags . (filterTags []) . canonicalizeTags . parseTags

-- The following tags should be supported:
-- <b> ... </b>              Bold
-- <i> ... </i>              Italic
-- <u> ... </u>              Underline
-- <a href="..."> ... </a>   Hyperlink
markupify :: Text.Text -> Text.Text
markupify = renderTags . (filterTags ["b", "i", "u", "a"])
  . canonicalizeTags . parseTags

filterTags :: [Text.Text] -> [Tag Text.Text] -> [Tag Text.Text]
filterTags _ [] = []
filterTags supportedTags (tag : rest) = case tag of
  TagText _        -> keep
  TagOpen "img" _  -> process "img" skip
  TagOpen name _   ->
    let conversion = if isSupported name then enclose name else strip
    in process name conversion
  _                -> next
  where
    isSupported name = elem name supportedTags

    keep = tag : next
    next = filterTags supportedTags rest

    skip _ = []
    strip  = filterTags supportedTags
    enclose name i = tag : (filterTags supportedTags i) ++ [TagClose name]

    process name conversion =
      let
        (inner, endTagRest) = break (isTagCloseName name) rest
      in (conversion inner) ++ (filterTags supportedTags endTagRest)

getImgTagAttrs :: Text.Text -> [(Text.Text, Text.Text)]
getImgTagAttrs text = getImg $ canonicalizeTags $ parseTags text
  where
    getImg [] = []
    getImg (tag : rest) = case tag of
      TagOpen "img" attr  -> attr
      _                   -> getImg rest

-- | Parses HTML entities in the given string and replaces them with their
-- representative characters. Only operates on entities in the ASCII range
-- (numeric) plus a small set of named entities. Hand-rolled scanner, no
-- regex dependency. See <https://dev.w3.org/html5/html-author/charref>
parseHtmlEntities :: String -> String
parseHtmlEntities [] = []
parseHtmlEntities ('&':rest) = case rest of
  ('#':numRest) ->
    let (ds, after) = span (`elem` ("0123456789"::String)) numRest
        valid = length ds >= 2 && length ds <= 3
        code = if valid then read ds else -1
    in if valid && take 1 after == ";" && 32 <= code && code <= 126
         then toEnum code : parseHtmlEntities (drop 1 after)
         else '&' : parseHtmlEntities rest
  _ ->
    let (name, after) = span (`elem` namedChars) rest
        repl = lookup name namedEntities
    in case (repl, after) of
         (Just r, (';':cs)) -> r : parseHtmlEntities cs
         _                  -> '&' : parseHtmlEntities rest
  where
    namedChars = ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9']
    namedEntities =
      [ ("quot", '"'), ("apos", '\''), ("grave", '`'), ("amp", '&')
      , ("tilde", '~'), ("lt", '<'), ("gt", '>') ]
parseHtmlEntities (c:cs) = c : parseHtmlEntities cs

