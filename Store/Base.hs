{-# LANGUAGE Rank2Types #-}
module Store.Base where

import Control.Monad
import qualified Data.ByteString as B
import Data.Char
import qualified Data.Enumerator as E
import Data.List

data Store = Store {
    build :: String -> IO (Maybe String),
    export :: forall a. String -> E.Enumerator B.ByteString IO a,
    findRepos :: String -> IO [(String, String)],
    getRepo :: String -> IO (Maybe String),
    newRepo :: String -> IO Bool
}

parseGitReference :: String -> Maybe String
parseGitReference name = do
    hash <- stripPrefix "git/" name
    guard $ length hash == 40 && all isHexDigit hash
    return hash
