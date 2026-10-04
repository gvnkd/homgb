{-# LANGUAGE OverloadedStrings #-}

-- | Hand-rolled client for the com.canonical.dbusmenu interface (the
-- menu protocol spoken by StatusNotifierItems). Equivalent to
-- taffybar's TH-generated DBusMenu.Client, without TemplateHaskell or
-- the gtk+-3.0 pkg-config dependency.
module Homgb.Tray.Menu.Client
  ( getLayout
  , aboutToShow
  , sendClicked
  , registerLayoutUpdated
  ) where

import Control.Monad (void)
import Data.Word (Word32)
import Data.Int (Int32)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import DBus hiding (Variant)
import DBus.Client
import DBus.Internal.Types (Value(..), Variant(..))

menuInterface :: InterfaceName
menuInterface = interfaceName_ "com.canonical.dbusmenu"

-- | Properties fetched for every menu node. Keep small: some items
-- error out on unknown property names.
wantedProperties :: [String]
wantedProperties =
  [ "label", "enabled", "visible", "type"
  , "toggle-type", "toggle-state", "children-display", "icon-name"
  ]

menuCall :: Client -> BusName -> ObjectPath -> MemberName -> [Variant]
         -> IO (Either MethodError MethodReturn)
menuCall client name path member body =
  call client (methodCall path menuInterface member)
    { methodCallDestination = Just name
    , methodCallBody = body
    }

-- | GetLayout(parentId, recursionDepth, propertyNames)
--   -> (revision, (id, props, children)).
getLayout :: Client -> BusName -> ObjectPath -> Int32
          -> IO (Either MethodError (Word32, Variant))
getLayout client name path parentId =
  fmap parse <$> menuCall client name path (memberName_ "GetLayout")
    [ toVariant parentId
    , toVariant (-1 :: Int32)
    , toVariant wantedProperties
    ]
  where
    parse ret =
      case methodReturnBody ret of
        (revision:layout:_) ->
          ( fromMaybe' 0 (fromVariant revision)
          , layout
          )
        _ -> (0, toVariant ())
    fromMaybe' d = maybe d id

-- | AboutToShow(id) -> needUpdate. Call before opening a submenu.
aboutToShow :: Client -> BusName -> ObjectPath -> Int32 -> IO ()
aboutToShow client name path itemId = void $
  menuCall client name path (memberName_ "AboutToShow") [toVariant itemId]

-- | Event(id, "clicked", uint32 data, timestamp).
sendClicked :: Client -> BusName -> ObjectPath -> Int32 -> Word32 -> IO ()
sendClicked client name path itemId timestamp = do
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr $
      "menu Event clicked item=" ++ show itemId ++ " to "
        ++ show path
    Nothing -> return ()
  void $ menuCall client name path (memberName_ "Event")
    [ toVariant itemId
    , toVariant ("clicked" :: String)
      -- dbusmenu's signature is Event(iisvu): the data argument is a
      -- VARIANT. A bare uint32 (isuu) is silently ignored by steam.
    , Variant (ValueVariant (toVariant (0 :: Word32)))
    , toVariant timestamp
    ]

-- | Register a handler for the LayoutUpdated signal (menu structure
-- changed, refetch). Returns the registration token for removeMatch.
registerLayoutUpdated :: Client -> BusName -> ObjectPath
                      -> ((Word32, Int32) -> IO ()) -> IO SignalHandler
registerLayoutUpdated client name path handler =
  addMatch client rule $ \sig ->
    case signalBody sig of
      (revision:parent:_) ->
        case (fromVariant revision, fromVariant parent) of
          (Just r, Just p) -> handler (r, p)
          _ -> return ()
      _ -> return ()
  where
    rule = matchAny
      { matchSender = Just name
      , matchPath = Just path
      , matchInterface = Just menuInterface
      , matchMember = Just (memberName_ "LayoutUpdated")
      }
