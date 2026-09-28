{-# LANGUAGE OverloadedStrings #-}

module Homgb.Notifications.Data
  ( Urgency(..)
  , CloseType(..)
  , Notification(..)
  , Image(..)
  , parseImageString
  ) where

import qualified Data.Text as Text
import Data.Word ( Word32 )
import Data.Int ( Int32 )
import qualified Data.ByteString as BS
import qualified Data.Map as Map ( Map )
import Data.Time.Clock ( UTCTime )
import DBus ( Variant )

import qualified Data.Yaml as Y
import Data.Yaml ((.=))

data Urgency = Normal | Low | High deriving (Eq, Show)
data CloseType = Timeout | User | CloseByCall | Other deriving (Eq, Show)

instance Eq Notification where
  a == b = notiId a == notiId b

data Notification = Notification
  { notiAppName :: Text.Text -- ^ Application name
  , notiRepId :: Word32 -- ^ Replaces id
  , notiId :: Int -- ^ Id
  , notiIcon :: Image -- ^ App icon
  , notiImg :: Image -- ^ Image
  , notiImgSize :: Int -- ^ Image size
  , notiSummary :: Text.Text -- ^ Summary
  , notiBody :: Text.Text -- ^ Body
  , notiActions :: [Text.Text] -- ^ Actions
  , notiActionCommands :: [(String, String)] -- ^ Actions
  , notiActionIcons :: Bool -- ^ Use icons for action-buttons
  , notiHints :: Map.Map Text.Text Variant -- ^ Hints
  , notiUrgency :: Urgency
  , notiTimeout :: Int32 -- ^ Expires timeout (milliseconds)
  , notiTime :: Text.Text
  , notiCreatedAt :: UTCTime -- ^ When the notification was created
  , notiTransient :: Bool
  , notiSendClosedMsg :: Bool -- ^ If notiOnClosed should be ignored
  , notiOnClosed :: CloseType -> IO ()
    -- ^ Should be called when the notification is closed, either by
    --   timeout or by user
  , notiOnAction :: [(String, String)] -> String -> Maybe String -> IO ()
    -- ^ Should be called when an action is used
  , notiTop :: Maybe Int
  , notiRight :: Maybe Int
  , notiPercentage :: Maybe Double
    -- ^ The percentage that should be shown in a percentage bar
  }

instance Y.ToJSON Notification where
  toJSON n = Y.object
    [ "appname" .= notiAppName n
    , "repId" .= notiRepId n
    , "id" .= notiId n
    , "icon" .= ((show $ notiIcon n) :: String)
    , "image" .= ((show $ notiImg n) :: String)
    , "imageSize" .= notiImgSize n
    , "title" .= notiSummary n
    , "body" .= notiBody n
    , "actions" .= notiActions n
    , "actionIcons" .= notiActionIcons n
    , "timeout" .= notiTimeout n
    , "time" .= notiTime n
    , "transient" .= notiTransient n
    , "sendClosedMsg" .= notiSendClosedMsg n
    , "top" .= notiTop n
    , "right" .= notiRight n
    , "percentage" .= notiPercentage n
    ]

instance Show Notification where
  show n = foldl (++) ""
    [ "Notification { \n"
    , "  notiAppName = " ++ (Text.unpack $ notiAppName n) ++ ", \n"
    , "  notiRepId = " ++ (show $ notiRepId n) ++ ", \n"
    , "  notiId = " ++ (show $ notiId n) ++ ", \n"
    , "  notiIcon = " ++ (show $ notiIcon n) ++ ", \n"
    , "  notiImg = " ++ (show $ notiImg n) ++ ", \n"
    , "  notiImgSize = " ++ (show $ notiImgSize n) ++ ", \n"
    , "  notiSummary = " ++ (Text.unpack $ notiSummary n) ++ ", \n"
    , "  notiBody = " ++ (Text.unpack $ notiBody n) ++ ", \n"
    , "  notiActions = " ++ (show $ Text.unpack <$> notiActions n) ++ ", \n"
    , "  notiActionIcons = " ++ (show $ notiActionIcons n) ++ ", \n"
    , "  notiHints = " ++ (show $ notiHints n) ++ ", \n"
    , "  notiUrgency = " ++ (show $ notiUrgency n) ++ ", \n"
    , "  notiTimeout = " ++ (show $ notiTimeout n) ++ ", \n"
    , "  notiTime = " ++ (Text.unpack $ notiTime n) ++ ", \n"
    , "  notiTransient = " ++ (show $ notiTransient n) ++ ", \n"
    , "  notiSendClosedMsg = " ++ (show $ notiSendClosedMsg n) ++ "\n"
    , "  notiTop = " ++ (show $ notiTop n) ++ "\n"
    , "  notiRight = " ++ (show $ notiRight n) ++ "\n"
    , "  notiPercentage = " ++ (show $ notiPercentage n) ++ "\n"
    , " }\n" ]

-- | RawImg carries ARGB32 data in network byte order, as delivered over
-- DBus in the @image-data@ hint (iiibayb ⇔ (Int32, Int32, Int32, Bool,
-- Int32, Int32, ByteString)). Convert to RGBA for GL upload in Render.
data Image = RawImg
  ( Int32 -- width
  , Int32 -- height
  , Int32 -- rowstride
  , Bool -- alpha
  , Int32 -- bits per sample
  , Int32 -- channels
  , BS.ByteString -- image data
  )
  | ImagePath String
  | NamedIcon String
  | NoImage deriving (Show, Eq)

parseImageString :: Text.Text -> Image
parseImageString a = if (Text.isPrefixOf "file://" a) then
                       ImagePath $ Text.unpack$ Text.drop 6 a
                     else
                       if (Text.length a > 0) then
                         NamedIcon $ Text.unpack a
                       else
                         NoImage
 