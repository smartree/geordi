module Request (is_addressed_request, is_short_request, evaluator) where

import qualified EvalCxx
import qualified CxxParse as Cxx
import qualified MakeType

import Control.Exception ()
import Data.Char (isPrint, isAlpha, isDigit)
import Control.Monad.Error ()
import Text.ParserCombinators.Parsec (parse, getInput, (<|>), oneOf, lookAhead, spaces, satisfy, eof, CharParser, many1, string)
import System.Console.GetOpt (OptDescr(..), ArgDescr(..), ArgOrder(..), getOpt)

import Prelude hiding (catch, (.))
import Util

data Opt = CompileOnly | Terse | Help | Version | NoWarn | CompileFlags | MakeType deriving Eq

optsDesc :: [OptDescr Opt]
optsDesc =
  [ Option "c" ["compile-only"] (NoArg CompileOnly) undefined
  , Option "w" ["no-warn"] (NoArg NoWarn) undefined
  , Option "t" ["terse"] (NoArg Terse) undefined
  , Option "h" ["help"] (NoArg Help) undefined
  , Option "v" ["version"] (NoArg Version) undefined
  , Option "" ["show-compile-flags"] (NoArg CompileFlags) undefined
  , Option "" ["make-type"] (NoArg MakeType) undefined
  ]

wrapPrePost :: String -> String -> String
wrapPrePost t c = "GEORDI_" ++ t ++ "_PRE " ++ c ++ "\nGEORDI_" ++ t ++ "_POST"

wrapPrint, wrapStmts :: String -> String
wrapPrint = wrapPrePost "PRINT"
wrapStmts = wrapPrePost "STATEMENTS"

type Nick = String

nickP :: CharParser st Nick
nickP = many1 $ satisfy $ isAlpha .||. isDigit .||. (`elem` "[]\\`_^|}-")
  -- We don't include '{' because it messes up "geordi{...}", and no sane person would use it in a nick for a geordi bot anyway.

is_short_request :: String -> Maybe String
is_short_request txt =
  either (const Nothing) Just (parse (spaces >> lookAhead (string "{" <|> string "<<") >> getInput) "" txt)

is_addressed_request :: String -> Maybe (Nick, String)
is_addressed_request txt = either (const Nothing) Just (parse p "" txt)
  where
   p = do
    spaces
    nick <- nickP
    oneOf ":," <|> (spaces >> lookAhead (oneOf "<{-"))
    r <- getInput
    return (nick, r)

splitSemicolon :: Cxx.Code -> (Cxx.Code, Cxx.Code)
splitSemicolon (Cxx.Code []) = (Cxx.Code [], Cxx.Code [])
splitSemicolon (Cxx.Code (Cxx.Plain s : r)) | maybeLast s == Just ';' =
  (Cxx.Code [Cxx.Plain s], Cxx.Code r)
splitSemicolon (Cxx.Code (a : r)) = (Cxx.Code $ a : x, y)
  where (Cxx.Code x,y) = splitSemicolon (Cxx.Code r)

newlines ::Cxx.Code -> Cxx.Code
newlines = Cxx.map_chunks $ Cxx.map_plain $ map $ \c -> if c == '\\' then '\n' else c

data Request = EvalRequest EvalCxx.Request | ShowCompileFlags | MakeTypeReq String

parse_request :: (Functor m, Monad m) => String -> m Request
parse_request req = do
  (opts, rest) <- case getOpt RequireOrder optsDesc (words req) of
    (_, _, (err:_)) -> fail err
    (opts, non_opts, []) -> return (opts, concat $ takeBack (length non_opts) $ wordsWithWhite req)
      -- We can't use non_opts' contents, because whitespace between tokens has been lost.
  reqCode <- newlines . parseOrFail (Cxx.code << eof) rest
  let
    opt = (`elem` opts)
    pre = ["#include \"prelude.hpp\""] ++ if opt Terse then ["#include \"terse.hpp\""] else []
    also_run = opt Help || opt Version || not (opt CompileOnly)
    er code = EvalRequest $ EvalCxx.Request (unlines $ pre ++ code) also_run (opt NoWarn)
  return $ case () of
    ()| opt Help -> er [wrapPrint "help"]
    ()| opt MakeType -> MakeTypeReq rest
    ()| opt CompileFlags -> ShowCompileFlags
    ()| opt Version -> er [wrapPrint $ "\"g++ (GCC) \" << __VERSION__"]
    ()| Cxx.Code (Cxx.Curlies c : b) <- reqCode ->
      er [show (Cxx.Code b), wrapStmts (show c)]
    ()| Cxx.Code (Cxx.Plain ('<':'<':x) : y) <- reqCode ->
      let (a, b) = splitSemicolon $ Cxx.Code $ Cxx.Plain x : y in
      er [show b, wrapPrint (show a)]
    ()| otherwise -> er [show reqCode]

evaluator :: IO (String -> IO String)
evaluator = do
  (ev, compile_cfg) <- EvalCxx.evaluator
  return $ \s -> case parse_request s of
    Left e -> return e
    Right ShowCompileFlags -> return $ unwords $ EvalCxx.compileFlags compile_cfg
    Right (MakeTypeReq d) -> return $ either ("error: " ++) show $ MakeType.makeType d
    Right (EvalRequest r) -> filter (isPrint .||. (== '\n')) . show . ev r
      -- Filtering using isPrint works properly because (1) the EvalCxx evaluator returns proper Unicode Strings, not mere byte blobs; and (2) to print filtered strings we will use System.IO.UTF8's hPutStrLn which properly UTF-8-encodes the filtered String.
      -- Possible problem: terminals which have not been (properly) UTF-8 configured might interpret bytes that are part of UTF-8 encoded characters as control characters.
