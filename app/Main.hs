{-# LANGUAGE FlexibleContexts #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Xmobar.Main
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Jose A. Ortega Ruiz <jao@gnu.org>
-- Stability   :  unstable
-- Portability :  unportable
--
-- The main module of Xmobar, a text based status bar
--
-----------------------------------------------------------------------------

module Main ( -- * Main Stuff
              -- $main
              main
            , readConfig
            , readDefaultConfig
            ) where

import Xmobar
import Xmobar.Parsers
import Xmobar.Config
import Xmobar.XUtil

import Data.Foldable (for_)
import Data.List (intercalate)
import qualified Data.Map as Map

import Data.Version (showVersion)
import Graphics.X11.Xlib
import System.Console.GetOpt
import System.Directory (getHomeDirectory)
import System.Exit
import System.Environment
import System.FilePath ((</>))
import System.Posix.Files
import Control.Concurrent.Async (Async, cancel)
import Control.Exception (bracket)
import Control.Monad (unless)
import Text.Read (readMaybe)

import Xmobar.Signal (setupSignalHandler, withDeferSignals)

import Paths_xmobar (version)
import Configuration

-- $main

-- | The main entry point
main :: IO ()
main = withDeferSignals $ do
  initThreads
  d <- openDisplay ""
  args <- getArgs
  (o,file) <- getOpts args
  (c,defaultings) <- case file of
                       [cfgfile] -> readConfig cfgfile
                       _ -> readDefaultConfig

  unless (null defaultings) $ putStrLn $
    "Fields missing from config defaulted: " ++ intercalate "," defaultings

  conf  <- doOpts c o
  fs    <- initFont d (font conf)
  fl    <- mapM (initFont d) (additionalFonts conf)
  cls   <- mapM (parseTemplate conf) (splitTemplate conf)
  sig   <- setupSignalHandler
  bracket (mapM (mapM $ startCommand sig) cls)
          cleanupThreads
          $ \vars -> do
    (r,w) <- createWin d fs conf
    let ic = Map.empty
        to = textOffset conf
        ts = textOffsets conf ++ replicate (length fl) (-1)
    startLoop (XConf d r w (fs:fl) (to:ts) ic conf) sig vars

cleanupThreads :: [[([Async ()], a)]] -> IO ()
cleanupThreads vars =
  -- putStrLn "In cleanupThreads"
  for_ (concat vars) $ \(asyncs, _) ->
    for_ asyncs cancel

-- | Splits the template in its parts
splitTemplate :: Config -> [String]
splitTemplate conf =
  case break (==l) t of
    (le,_:re) -> case break (==r) re of
                   (ce,_:ri) -> [le, ce, ri]
                   _         -> def
    _         -> def
  where [l, r] = alignSep
                   (if length (alignSep conf) == 2 then conf else defaultConfig)
        t = template conf
        def = [t, "", ""]


-- | Reads the configuration files or quits with an error
readConfig :: FilePath -> IO (Config,[String])
readConfig f = do
  file <- io $ fileExist f
  s <- io $ if file then readFileSafe f else error $
               f ++ ": file not found!\n" ++ usage
  either (\err -> error $ f ++
                    ": configuration file contains errors at:\n" ++ show err)
         return $ parseConfig s

xdgConfigDir :: IO String
xdgConfigDir = do env <- getEnvironment
                  case lookup "XDG_CONFIG_HOME" env of
                       Just val -> return val
                       Nothing  -> fmap (</> ".config") getHomeDirectory

xmobarConfigDir :: IO FilePath
xmobarConfigDir = fmap (</> "xmobar") xdgConfigDir

getXdgConfigFile :: IO FilePath
getXdgConfigFile = fmap (</> "xmobarrc") xmobarConfigDir

-- | Read default configuration file or load the default config
readDefaultConfig :: IO (Config,[String])
readDefaultConfig = do
  xdgConfigFile <- getXdgConfigFile
  xdgConfigFileExists <- io $ fileExist xdgConfigFile
  home <- io $ getEnv "HOME"
  let defaultConfigFile = home ++ "/.xmobarrc"
  defaultConfigFileExists <- io $ fileExist defaultConfigFile
  if xdgConfigFileExists
    then readConfig xdgConfigFile
    else if defaultConfigFileExists
         then readConfig defaultConfigFile
         else return (defaultConfig,[])

data Opts = Help
          | Version
          | Font       String
          | BgColor    String
          | FgColor    String
          | Alpha      String
          | T
          | B
          | D
          | AlignSep   String
          | Commands   String
          | AddCommand String
          | SepChar    String
          | Template   String
          | OnScr      String
          | IconRoot   String
          | Position   String
          | WmClass    String
          | WmName     String
       deriving Show

options :: [OptDescr Opts]
options =
    [ Option "h?" ["help"] (NoArg Help) "This help"
    , Option "V" ["version"] (NoArg Version) "Show version information"
    , Option "f" ["font"] (ReqArg Font "font name") "The font name"
    , Option "w" ["wmclass"] (ReqArg WmClass "class") "X11 WM_CLASS property"
    , Option "n" ["wmname"] (ReqArg WmName "name") "X11 WM_NAME property"
    , Option "B" ["bgcolor"] (ReqArg BgColor "bg color" )
      "The background color. Default black"
    , Option "F" ["fgcolor"] (ReqArg FgColor "fg color")
      "The foreground color. Default grey"
    , Option "i" ["iconroot"] (ReqArg IconRoot "path")
      "Root directory for icon pattern paths. Default '.'"
    , Option "A" ["alpha"] (ReqArg Alpha "alpha")
      "The transparency: 0 is transparent, 255 is opaque. Default: 255"
    , Option "o" ["top"] (NoArg T) "Place xmobar at the top of the screen"
    , Option "b" ["bottom"] (NoArg B)
      "Place xmobar at the bottom of the screen"
    , Option "d" ["dock"] (NoArg D)
      "Don't override redirect from WM and function as a dock"
    , Option "a" ["alignsep"] (ReqArg AlignSep "alignsep")
      "Separators for left, center and right text\nalignment. Default: '}{'"
    , Option "s" ["sepchar"] (ReqArg SepChar "char")
      ("The character used to separate commands in" ++
       "\nthe output template. Default '%'")
    , Option "t" ["template"] (ReqArg Template "template")
      "The output template"
    , Option "c" ["commands"] (ReqArg Commands "commands")
      "The list of commands to be executed"
    , Option "C" ["add-command"] (ReqArg AddCommand "command")
      "Add to the list of commands to be executed"
    , Option "x" ["screen"] (ReqArg OnScr "screen")
      "On which X screen number to start"
    , Option "p" ["position"] (ReqArg Position "position")
      "Specify position of xmobar. Same syntax as in config file"
    ]

getOpts :: [String] -> IO ([Opts], [String])
getOpts argv =
    case getOpt Permute options argv of
      (o,n,[])   -> return (o,n)
      (_,_,errs) -> error (concat errs ++ usage)

usage :: String
usage = usageInfo header options ++ footer
    where header = "Usage: xmobar [OPTION...] [FILE]\nOptions:"
          footer = "\nMail bug reports and suggestions to " ++ mail ++ "\n"

info :: String
info = "xmobar " ++ showVersion version
        ++ "\n (C) 2007 - 2010 Andrea Rossato "
        ++ "\n (C) 2010 - 2018 Jose A Ortega Ruiz\n "
        ++ mail ++ "\n" ++ license

mail :: String
mail = "<mail@jao.io>"

license :: String
license = "\nThis program is distributed in the hope that it will be useful," ++
          "\nbut WITHOUT ANY WARRANTY; without even the implied warranty of" ++
          "\nMERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE." ++
          "\nSee the License for more details."

doOpts :: Config -> [Opts] -> IO Config
doOpts conf [] =
  return (conf {lowerOnStart = lowerOnStart conf && overrideRedirect conf})
doOpts conf (o:oo) =
  case o of
    Help -> putStr   usage >> exitSuccess
    Version -> putStrLn info  >> exitSuccess
    Font s -> doOpts' (conf {font = s})
    WmClass s -> doOpts' (conf {wmClass = s})
    WmName s -> doOpts' (conf {wmName = s})
    BgColor s -> doOpts' (conf {bgColor = s})
    FgColor s -> doOpts' (conf {fgColor = s})
    Alpha n -> doOpts' (conf {alpha = read n})
    T -> doOpts' (conf {position = Top})
    B -> doOpts' (conf {position = Bottom})
    D -> doOpts' (conf {overrideRedirect = False})
    AlignSep s -> doOpts' (conf {alignSep = s})
    SepChar s -> doOpts' (conf {sepChar = s})
    Template s -> doOpts' (conf {template = s})
    IconRoot s -> doOpts' (conf {iconRoot = s})
    OnScr n -> doOpts' (conf {position = OnScreen (read n) $ position conf})
    Commands s -> case readCom 'c' s of
                    Right x -> doOpts' (conf {commands = x})
                    Left e -> putStr (e ++ usage) >> exitWith (ExitFailure 1)
    AddCommand s -> case readCom 'C' s of
                      Right x -> doOpts' (conf {commands = commands conf ++ x})
                      Left e -> putStr (e ++ usage) >> exitWith (ExitFailure 1)
    Position s -> readPosition s
  where readCom c str =
          case readStr str of
            [x] -> Right x
            _  -> Left ("xmobar: cannot read list of commands " ++
                        "specified with the -" ++ c:" option\n")
        readStr str = [x | (x,t) <- reads str, ("","") <- lex t]
        doOpts' opts = doOpts opts oo
        readPosition string =
            case readMaybe string of
                Just x  -> doOpts' (conf { position = x })
                Nothing -> do
                    putStrLn "Can't parse position option, ignoring"
                    doOpts' conf