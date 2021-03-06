{-# LANGUAGE ScopedTypeVariables #-}

-- | Library for creating Websocket servers.  Some parts cribbed from
-- Jeff Foster's blog post at
-- <http://www.fatvat.co.uk/2010/01/web-sockets-and-haskell.html>
module Network.Websocket( Config(..), WS(..),
                          startServer, send ) where

import Char (chr)
import Control.Concurrent
import Control.Exception hiding (catch)
import Control.Monad
import Data.Char (isSpace)
import Data.Maybe
import qualified Network as N
import qualified Network.Socket as NS
import Network.URI
import Network.HTTP
import System.IO
import Data.ByteString.Char8 (pack, unpack)

restrictionValid _ Nothing = True
restrictionValid r (Just rs) = elem r rs

-- | Server configuration structure
data Config = Config
  -- | The port to bind to
  { configPort :: Int

  -- | The origin URL used in the handshake
  , configOrigins :: Maybe [String]

  -- | The location URL used in the handshake. This must match
  -- the Websocket url that the browsers connect to.
  , configDomains  :: Maybe [String]

  -- | The onopen callback, called when a socket is opened
  , configOnOpen    :: WS -> IO ()

  -- | The onmessage callback, called when a message is received
  , configOnMessage :: WS -> String -> IO ()

  -- | The onclose callback, called when the connection is closed.
  , configOnClose   :: WS -> IO ()
  }

-- | Connection state structure
data WS = WS
  -- | The server's configuration
  { wsConfig :: Config

  -- | The handle of the connected socket
  , wsHandle :: Handle
  }

readFrame :: Handle -> IO String
readFrame h = readUntil h ""
  where
    readUntil h str = do
      new <- hGetChar h
      if new == chr 0
        then readUntil h ""
        else if new == chr 255
          then return str
          else readUntil h (str ++ [new])

sendFrame :: Handle -> String -> IO ()
sendFrame h s = do
  hPutChar h (chr 0)
  hPutStr h s
  hPutChar h (chr 255)
  hFlush h

-- | Send a message to the connected browser.
send ws = sendFrame (wsHandle ws)

parseRequest :: Request -> Maybe (String, String, String)
parseRequest req = do
  let getField f = fmap unpack $ lookupField f req
  upgrade  <- getField $ FkOther $ pack "Upgrade"
  origin   <- getField $ FkOther $ pack "Origin"
  host     <- getField $ FkHost
  hostURI  <- parseURI $ pack ("ws://" ++ host ++ "/")
  hostAuth <- uriAuthority hostURI
  let domain = uriRegName hostAuth
  return (upgrade, origin, domain)

doWebSocket socket f = do 
  (h :: Handle, _, _) <- N.accept socket
  forkIO $ bracket 
    (fmap (h,) $ receive h)
    (hClose . fst)
    (\(h, maybeReq) -> case maybeReq of
      Nothing -> putStrLn "Bad request received."
      Just req -> f h req)

sendHandshake h origin location = do
  hPutStr h handshake
  hFlush h
  where
    handshake =
      "HTTP/1.1 101 Web Socket Protocol Handshake\r\n\
      \Upgrade: WebSocket\r\n\
      \Connection: Upgrade\r\n\
      \WebSocket-Origin: " ++ origin ++ "\r\n\
      \WebSocket-Location: " ++ show location ++ "\r\n\
      \WebSocket-Protocol: sample\r\n\r\n"

assertM x = assert x $ return ()

accept config socket = forever $
  doWebSocket socket $
    \h -> \req -> let
      (upgrade, origin, hostDomain) =
        case parseRequest req of
          Nothing -> throw (userError "Invalid request")
          Just a -> a
      location = (reqURI req) { uriScheme = pack "ws:" }
      ws = WS { wsConfig = config, wsHandle = h } in do
      assertM $ upgrade == "WebSocket"
      assertM $ restrictionValid origin $ configOrigins config
      assertM $ restrictionValid (unpack hostDomain) $ configDomains config
      sendHandshake h origin location
      onOpen ws
      (forever $ do
        msg <- readFrame h
        onMessage ws msg) `catch` (\e -> onClose ws)
  where
    onOpen    = configOnOpen config
    onMessage = configOnMessage config
    onClose   = configOnClose config


-- | Start a websocket server
startServer config = do
  let port = N.PortNumber $ fromIntegral $ configPort config
  bracket
    (N.listenOn port)
    NS.sClose
    (accept config)
