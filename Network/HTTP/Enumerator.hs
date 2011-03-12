{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
-- | This module contains everything you need to initiate HTTP connections.  If
-- you want a simple interface based on URLs, you can use 'simpleHttp'. If you
-- want raw power, 'http' is the underlying workhorse of this package. Some
-- examples:
--
-- > -- Just download an HTML document and print it.
-- > import Network.HTTP.Enumerator
-- > import qualified Data.ByteString.Lazy as L
-- >
-- > main = simpleHttp "http://www.haskell.org/" >>= L.putStr
--
-- This example uses interleaved IO to write the response body to a file in
-- constant memory space. By using 'httpRedirect', it will automatically
-- follow 3xx redirects.
--
-- > import Data.Enumerator
-- > import Data.Enumerator.Binary
-- > import Network.HTTP.Enumerator
-- > import System.IO
-- > 
-- > main :: IO ()
-- > main = withFile "google.html" WriteMode $ \handle -> do
-- >     request <- parseUrl "http://google.com/"
-- >     run_ $ httpRedirect request (\_ _ -> iterHandle handle)
--
-- The following headers are automatically set by this module, and should not
-- be added to 'requestHeaders':
--
-- * Content-Length
--
-- * Host
--
-- * Accept-Encoding (not currently set, but client usage of this variable /will/ cause breakage).
--
-- Any network code on Windows requires some initialization, and the network
-- library provides withSocketsDo to perform it. Therefore, proper usage of
-- this library will always involve calling that function at some point.  The
-- best approach is to simply call them at the beginning of your main function,
-- such as:
--
-- > import Network.HTTP.Enumerator
-- > import qualified Data.ByteString.Lazy as L
-- > import Network (withSocketsDo)
-- >
-- > main = withSocketsDo
-- >      $ simpleHttp "http://www.haskell.org/" >>= L.putStr
module Network.HTTP.Enumerator
    ( -- * Perform a request
      simpleHttp
    , httpLbs
    , httpLbsRedirect
    , http
    , httpRedirect
    , redirectIter
      -- * Datatypes
    , Request (..)
    , RequestBody (..)
    , Response (..)
      -- * Manager
    , Manager
    , newManager
    , closeManager
    , withManager
      -- * Utility functions
    , parseUrl
    , lbsIter
      -- * Request bodies
    , urlEncodedBody
      -- * Exceptions
    , HttpException (..)
    ) where

import qualified Network.TLS.Client.Enumerator as TLS
import Network (connectTo, PortID (PortNumber))

import qualified Network.Socket as NS
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as S8
import Data.Enumerator
    ( Iteratee (..), Stream (..), catchError, throwError
    , yield, Step (..), Enumeratee, ($$), joinI, Enumerator, run_
    , returnI, (>==>)
    )
import qualified Data.Enumerator.List as EL
import Network.HTTP.Enumerator.HttpParser
import Control.Exception (Exception, bracket)
import Control.Arrow ((***))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Class (lift)
import Control.Failure
import Data.Typeable (Typeable)
import Data.Bits
import Codec.Binary.UTF8.String (encodeString)
import qualified Blaze.ByteString.Builder as Blaze
import Blaze.ByteString.Builder.Enumerator (builderToByteString)
import Data.Monoid (Monoid (..))
import qualified Network.HTTP.Types as W
import qualified Data.CaseInsensitive as CI
import Data.Int (Int64)
import qualified Codec.Zlib
import qualified Codec.Zlib.Enum as Z
import Control.Monad.IO.Control (MonadControlIO, liftIOOp)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.IORef as I
import Control.Applicative ((<$>))
import Data.Certificate.X509 (X509)
import qualified Data.Ascii as A

getSocket :: String -> Int -> IO NS.Socket
getSocket host' port' = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host') (Just $ show port')
    sock <- NS.socket (NS.addrFamily addr) (NS.addrSocketType addr)
                      (NS.addrProtocol addr)
    NS.connect sock (NS.addrAddress addr)
    return sock

withSocketConn :: MonadIO m
               => Manager
               -> String
               -> Int
               -> Enumerator Blaze.Builder m ()
               -> Enumerator S.ByteString m a
withSocketConn man host' port' =
    withManagedConn man (host', port', False) $
        fmap TLS.socketConn $ getSocket host' port'

withManagedConn
    :: MonadIO m
    => Manager
    -> ConnKey
    -> IO TLS.ConnInfo
    -> Enumerator Blaze.Builder m ()
    -> Enumerator S.ByteString m a
withManagedConn man key open req step = do
    ci <- liftIO $ takeInsecureSocket man key
          >>= maybe (liftIO open) return
    a <- withCI ci req step
    liftIO $ putInsecureSocket man key ci
    return a

withSslConn :: MonadIO m
            => ([X509] -> IO Bool)
            -> Manager
            -> String -- ^ host
            -> Int -- ^ port
            -> Enumerator Blaze.Builder m () -- ^ request
            -> Enumerator S.ByteString m a -- ^ response
withSslConn checkCert man host' port' =
    withManagedConn man (host', port', True) $
        (connectTo host' (PortNumber $ fromIntegral port') >>= TLS.sslClientConn checkCert)

withCI :: MonadIO m => TLS.ConnInfo -> Enumerator Blaze.Builder m () -> Enumerator S.ByteString m a
withCI ci req step0 = do
    lift $ run_ $ req $$ joinI $ builderToByteString $$ TLS.connIter ci
    a <- TLS.connEnum ci step0
    -- FIXME liftIO $ hClose handle
    return a

-- | All information on how to connect to a host and what should be sent in the
-- HTTP request.
--
-- If you simply wish to download from a URL, see 'parseUrl'.
data Request m = Request
    { method :: W.Method -- ^ HTTP request method, eg GET, POST.
    , secure :: Bool -- ^ Whether to use HTTPS (ie, SSL).
    , checkCerts :: [X509] -> IO Bool -- ^ Check if the server certificate is valid. Only relevant for HTTPS.
    , host :: A.Ascii
    , port :: Int
    , path :: A.Ascii -- ^ Everything from the host to the query string.
    , queryString :: W.Query -- ^ Automatically escaped for your convenience.
    , requestHeaders :: W.RequestHeaders
    , requestBody :: RequestBody m
    }

-- | When using the 'RequestBodyEnum' constructor and any function which calls
-- 'redirectIter', you must ensure that the 'Enumerator' can be called multiple
-- times.
data RequestBody m
    = RequestBodyLBS L.ByteString
    | RequestBodyEnum Int64 (Enumerator Blaze.Builder m ())

-- | A simple representation of the HTTP response created by 'lbsIter'.
data Response = Response
    { statusCode :: Int
    , responseHeaders :: W.ResponseHeaders
    , responseBody :: L.ByteString
    }
    deriving (Show, Read, Eq, Typeable)

enumSingle :: Monad m => a -> Enumerator a m b
enumSingle x (Continue k) = k $ Chunks [x]
enumSingle _ step = returnI step

-- | The most low-level function for initiating an HTTP request.
--
-- The second argument to this function gives a full specification on the
-- request: the host to connect to, whether to use SSL, headers, etc. Please
-- see 'Request' for full details.
--
-- The first argument specifies how the response should be handled. It's a
-- function that takes two arguments: the first is the HTTP status code of the
-- response, and the second is a list of all response headers. This module
-- exports 'lbsIter', which generates a 'Response' value.
--
-- Note that this allows you to have fully interleaved IO actions during your
-- HTTP download, making it possible to download very large responses in
-- constant memory.
http
     :: MonadIO m
     => Request m
     -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
     -> Manager
     -> Iteratee S.ByteString m a
http Request {..} bodyStep m = do
    let h' = A.toString host
    let withConn = if secure then withSslConn checkCerts else withSocketConn
    withConn m h' port requestEnum $$ go
  where
    (contentLength, bodyEnum) =
        case requestBody of
            RequestBodyLBS lbs -> (L.length lbs, enumSingle $ Blaze.fromLazyByteString lbs)
            RequestBodyEnum i enum -> (i, enum)
    hh
        | port == 80 && not secure = host
        | port == 443 && secure = host
        | otherwise = host `mappend` A.unsafeFromString (':' : show port)
    headers' = ("Host", hh)
                 : ("Content-Length", A.unsafeFromString $ show contentLength)
                 : ("Accept-Encoding", "gzip")
                 : requestHeaders
    requestHeaders' =
            Blaze.fromByteString (A.toByteString method)
            `mappend` Blaze.fromByteString " "
            `mappend`
                (case S8.uncons $ A.toByteString path of
                    Just ('/', _) -> Blaze.fromByteString $ A.toByteString path
                    _ -> Blaze.fromByteString "/"
                            `mappend` Blaze.fromByteString (A.toByteString path))
            `mappend` (if null queryString
                        then mempty
                        else A.toBuilder $ W.renderQueryBuilder True queryString)
            `mappend` Blaze.fromByteString " HTTP/1.1\r\n"
            `mappend` mconcat (flip map headers' $ \(k, v) ->
                Blaze.fromByteString (A.toByteString $ CI.original k)
                `mappend`  Blaze.fromByteString ": "
                `mappend` Blaze.fromByteString (A.toByteString v)
                `mappend` Blaze.fromByteString "\r\n")
            `mappend` Blaze.fromByteString "\r\n"
    requestEnum = enumSingle requestHeaders' >==> bodyEnum
    go = do
        ((_, sc, sm), hs) <- iterHeaders
        let s = W.Status sc $ A.unsafeFromByteString sm
        let hs' = map (CI.mk . A.unsafeFromByteString *** A.unsafeFromByteString) hs
        let mcl = lookup "content-length" hs'
        let body' x =
                if ("transfer-encoding", "chunked") `elem` hs'
                    then joinI $ chunkedEnumeratee $$ x
                    else case mcl >>= readMay . A.toString of
                        Just len -> joinI $ takeLBS len $$ x
                        Nothing -> x
        let decompress x =
                if ("content-encoding", "gzip") `elem` hs'
                    then joinI $ Z.decompress (Codec.Zlib.WindowBits 31) x
                    else returnI x
        if method == "HEAD"
            then bodyStep s hs'
            else body' $ decompress $$ bodyStep s hs'

chunkedEnumeratee :: MonadIO m => Enumeratee S.ByteString S.ByteString m a
chunkedEnumeratee k@(Continue _) = do
    len <- catchParser "Chunk header" iterChunkHeader
    if len == 0
        then return k
        else do
            k' <- takeLBS len k
            catchParser "End of chunk newline" iterNewline
            chunkedEnumeratee k'
chunkedEnumeratee step = return step

takeLBS :: MonadIO m => Int -> Enumeratee S.ByteString S.ByteString m a
takeLBS 0 step = return step
takeLBS len (Continue k) = do
    mbs <- EL.head
    case mbs of
        Nothing -> return $ Continue k
        Just bs -> do
            let (len', chunk, rest) =
                    if S.length bs > len
                        then (0, S.take len bs,
                                if S.length bs == len
                                    then Chunks []
                                    else Chunks [S.drop len bs])
                        else (len - S.length bs, bs, Chunks [])
            step' <- lift $ runIteratee $ k $ Chunks [chunk]
            if len' == 0
                then yield step' rest
                else takeLBS len' step'
takeLBS _ step = return step

encodeUrlCharPI :: Char -> String
encodeUrlCharPI '/' = "/"
encodeUrlCharPI c = encodeUrlChar c

encodeUrlChar :: Char -> String
encodeUrlChar c
    -- List of unreserved characters per RFC 3986
    -- Gleaned from http://en.wikipedia.org/wiki/Percent-encoding
    | 'A' <= c && c <= 'Z' = [c]
    | 'a' <= c && c <= 'z' = [c]
    | '0' <= c && c <= '9' = [c]
encodeUrlChar c@'-' = [c]
encodeUrlChar c@'_' = [c]
encodeUrlChar c@'.' = [c]
encodeUrlChar c@'~' = [c]
encodeUrlChar ' ' = "+"
encodeUrlChar y =
    let (a, c) = fromEnum y `divMod` 16
        b = a `mod` 16
        showHex' x
            | x < 10 = toEnum $ x + (fromEnum '0')
            | x < 16 = toEnum $ x - 10 + (fromEnum 'A')
            | otherwise = error $ "Invalid argument to showHex: " ++ show x
     in ['%', showHex' b, showHex' c]

-- | Convert a URL into a 'Request'.
--
-- This defaults some of the values in 'Request', such as setting 'method' to
-- GET and 'requestHeaders' to @[]@.
--
-- Since this function uses 'Failure', the return monad can be anything that is
-- an instance of 'Failure', such as 'IO' or 'Maybe'.
parseUrl :: Failure HttpException m => A.Ascii -> m (Request m')
parseUrl = parseUrlS . A.toString

parseUrlS :: Failure HttpException m => String -> m (Request m')
parseUrlS s@('h':'t':'t':'p':':':'/':'/':rest) = parseUrl1 s False rest
parseUrlS s@('h':'t':'t':'p':'s':':':'/':'/':rest) = parseUrl1 s True rest
parseUrlS x = failure $ InvalidUrlException x "Invalid scheme"

parseUrl1 :: Failure HttpException m
          => String -> Bool -> String -> m (Request m')
parseUrl1 full sec s =
    parseUrl2 full sec s'
  where
    s' = encodeString s

parseUrl2 :: Failure HttpException m
          => String -> Bool -> String -> m (Request m')
parseUrl2 full sec s = do
    port' <- mport
    return Request
        { host = A.unsafeFromString hostname
        , port = port'
        , secure = sec
        , checkCerts = const $ return True
        , requestHeaders = []
        , path = A.unsafeFromString
                    $ if null path'
                            then "/"
                            else concatMap encodeUrlCharPI path'
        , queryString = W.parseQuery $ S8.pack qstring
        , requestBody = RequestBodyLBS L.empty
        , method = "GET"
        }
  where
    (beforeSlash, afterSlash) = break (== '/') s
    (hostname, portStr) = break (== ':') beforeSlash
    (path', qstring') = break (== '?') afterSlash
    qstring'' = case qstring' of
                '?':x -> x
                _ -> qstring'
    qstring = takeWhile (/= '#') qstring''
    mport =
        case (portStr, sec) of
            ("", False) -> return 80
            ("", True) -> return 443
            (':':rest, _) ->
                case readMay rest of
                    Just i -> return i
                    Nothing -> failure $ InvalidUrlException full "Invalid port"
            x -> error $ "parseUrl1: this should never happen: " ++ show x

-- | Convert the HTTP response into a 'Response' value.
--
-- Even though a 'Response' contains a lazy bytestring, this function does
-- /not/ utilize lazy I/O, and therefore the entire response body will live in
-- memory. If you want constant memory usage, you'll need to write your own
-- iteratee and use 'http' or 'httpRedirect' directly.
lbsIter :: Monad m => W.Status -> W.ResponseHeaders
        -> Iteratee S.ByteString m Response
lbsIter (W.Status sc _) hs = do
    lbs <- fmap L.fromChunks EL.consume
    return $ Response sc hs lbs

-- | Download the specified 'Request', returning the results as a 'Response'.
--
-- This is a simplified version of 'http' for the common case where you simply
-- want the response data as a simple datatype. If you want more power, such as
-- interleaved actions on the response body during download, you'll need to use
-- 'http' directly. This function is defined as:
--
-- @httpLbs = http lbsIter@
--
-- Please see 'lbsIter' for more information on how the 'Response' value is
-- created.
httpLbs :: MonadIO m => Request m -> Manager -> m Response
httpLbs req = run_ . http req lbsIter

-- | Download the specified URL, following any redirects, and return the
-- response body.
--
-- This function will 'failure' an 'HttpException' for any response with a
-- non-2xx status code. It uses 'parseUrl' to parse the input. This function
-- essentially wraps 'httpLbsRedirect'.
simpleHttp :: (MonadControlIO m, Failure HttpException m) => A.Ascii -> m L.ByteString
simpleHttp url = do
    url' <- parseUrl url
    Response sc _ b <- withManager $ httpLbsRedirect url'
    if 200 <= sc && sc < 300
        then return b
        else failure $ StatusCodeException sc b

data HttpException = StatusCodeException Int L.ByteString
                   | InvalidUrlException String String
                   | TooManyRedirects
                   | HttpParserException String
    deriving (Show, Typeable)
instance Exception HttpException

-- | Same as 'http', but follows all 3xx redirect status codes that contain a
-- location header.
httpRedirect
    :: (MonadIO m, Failure HttpException m)
    => Request m
    -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
    -> Manager
    -> Iteratee S.ByteString m a
httpRedirect req bodyStep manager =
    http req (redirectIter 10 req bodyStep manager) manager

-- | Make a request automatically follow 3xx redirects.
--
-- Used internally by 'httpRedirect' and family.
redirectIter :: (MonadIO m, Failure HttpException m)
             => Int -- ^ number of redirects to attempt
             -> Request m -- ^ Original request
             -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
             -> Manager
             -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
redirectIter redirects req bodyStep manager s@(W.Status code _) hs
    | 300 <= code && code < 400 =
        case fmap A.toByteString $ lookup "location" hs of
            Just l'' -> do
                -- Prepend scheme, host and port if missing
                let l' =
                        case S8.uncons l'' of
                            Just ('/', _) -> concat
                                [ "http"
                                , if secure req then "s" else ""
                                , "://"
                                , A.toString $ host req
                                , ":"
                                , show $ port req
                                , S8.unpack l''
                                ]
                            _ -> S8.unpack l''
                l <- lift $ parseUrlS l'
                let req' = req
                        { host = host l
                        , port = port l
                        , secure = secure l
                        , path = path l
                        , queryString = queryString l
                        , method =
                            if code == 303
                                then "GET"
                                else method l
                        }
                if redirects == 0
                    then lift $ failure TooManyRedirects
                    else (http req') (redirectIter (redirects - 1) req' bodyStep manager) manager
            Nothing -> bodyStep s hs
    | otherwise = bodyStep s hs

-- | Download the specified 'Request', returning the results as a 'Response'
-- and automatically handling redirects.
--
-- This is a simplified version of 'httpRedirect' for the common case where you
-- simply want the response data as a simple datatype. If you want more power,
-- such as interleaved actions on the response body during download, you'll
-- need to use 'httpRedirect' directly. This function is defined as:
--
-- @httpLbsRedirect = httpRedirect lbsIter@
--
-- Please see 'lbsIter' for more information on how the 'Response' value is
-- created.
httpLbsRedirect :: (MonadIO m, Failure HttpException m) => Request m -> Manager -> m Response
httpLbsRedirect req = run_ . httpRedirect req lbsIter

readMay :: Read a => String -> Maybe a
readMay s = case reads s of
                [] -> Nothing
                (x, _):_ -> Just x

-- FIXME add a helper for generating POST bodies

-- | Add url-encoded paramters to the 'Request'.
--
-- This sets a new 'requestBody', adds a content-type request header and
-- changes the 'method' to POST.
urlEncodedBody :: Monad m => [(S.ByteString, S.ByteString)] -> Request m' -> Request m
urlEncodedBody headers req = req
    { requestBody = RequestBodyLBS body
    , method = "POST"
    , requestHeaders =
        (ct, "application/x-www-form-urlencoded")
      : filter (\(x, _) -> x /= ct) (requestHeaders req)
    }
  where
    ct = "Content-Type"
    body = Blaze.toLazyByteString $ body' headers
    body' [] = mempty
    body' [x] = pair x
    body' (x:xs) = pair x `mappend` Blaze.fromWord8 38 `mappend` body' xs
    pair (x, y)
        | S.null y = single x
        | otherwise =
            single x `mappend` Blaze.fromWord8 61 `mappend` single y
    single = Blaze.fromWriteList go . S.unpack
    go 32 = Blaze.writeWord8 43 -- space to plus
    go c | unreserved c = Blaze.writeWord8 c
    go c =
        let x = shiftR c 4
            y = c .&. 15
         in Blaze.writeWord8 37 `mappend` hexChar x `mappend` hexChar y
    unreserved  45 = True -- hyphen
    unreserved  46 = True -- period
    unreserved  95 = True -- underscore
    unreserved 126 = True -- tilde
    unreserved c
        | 48 <= c && c <= 57  = True -- 0 - 9
        | 65 <= c && c <= 90  = True -- A - Z
        | 97 <= c && c <= 122 = True -- A - Z
    unreserved _ = False
    hexChar c
        | c < 10 = Blaze.writeWord8 $ c + 48
        | c < 16 = Blaze.writeWord8 $ c + 55
        | otherwise = error $ "hexChar: " ++ show c

catchParser :: Monad m => String -> Iteratee a m b -> Iteratee a m b
catchParser s i = catchError i (const $ throwError $ HttpParserException s)

-- | Keeps track of open connections for keep-alive.
data Manager = Manager
    { mConns :: I.IORef (Map ConnKey TLS.ConnInfo)
    }

type ConnKey = (String, Int, Bool)

takeInsecureSocket :: Manager -> ConnKey -> IO (Maybe TLS.ConnInfo)
takeInsecureSocket man key =
    I.atomicModifyIORef (mConns man) go
  where
    go m = (Map.delete key m, Map.lookup key m)

putInsecureSocket :: Manager -> ConnKey -> TLS.ConnInfo -> IO ()
putInsecureSocket man key ci = do
    msock <- I.atomicModifyIORef (mConns man) go
    maybe (return ()) TLS.connClose msock
  where
    go m = (Map.insert key ci m, Map.lookup key m)

-- | Create a new 'Manager' with no open connection.
newManager :: IO Manager
newManager = Manager <$> I.newIORef Map.empty

-- | Close all connections in a 'Manager'. Afterwards, the 'Manager' can be
-- reused if desired.
closeManager :: Manager -> IO ()
closeManager (Manager i) = do
    m <- I.atomicModifyIORef i $ \x -> (Map.empty, x)
    mapM_ TLS.connClose $ Map.elems m

-- | Create a new 'Manager', call the supplied function and then close it.
withManager :: MonadControlIO m => (Manager -> m a) -> m a
withManager = liftIOOp $ bracket newManager closeManager
