{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Homgb.Config
  ( Config(..)
  , ButtonConfig(..)
  , ModificationRule(..)
  , ThemeConfig(..)
  , defaultThemeConfig
  , getConfig
  , defaultConfigText
  ) where

import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Int ( Int32 )
import qualified Data.Map as Map
import qualified Data.Yaml as Y
import Data.Yaml ((.:), (.:?), (.!=), FromJSON(..))
import Data.Aeson.Key as AesonKey

import Homgb.Helpers (orElse)

data ModificationRule = Modify
  {
    mMatch :: Map.Map String String
  , modifyTitle :: Maybe String
  , modifyBody :: Maybe String
  , modifyAppname :: Maybe String
  , modifyAppicon :: Maybe String
  , modifyTimeout :: Maybe Int32
  , modifyRight :: Maybe Int
  , modifyTop :: Maybe Int
  , modifyImage :: Maybe String
  , modifyImageSize :: Maybe Int
  , modifyTransient :: Maybe Bool
  , modifyNoClosedMsg :: Maybe Bool
  , modifyRemoveActions :: Maybe Bool
  , modifyActionIcons :: Maybe Bool
  , modifyActionCommands :: Maybe (Map.Map String String)
  , modifyActions :: Maybe [String]
  } |
  Script
  {
    mMatch :: Map.Map String String
  , mScript :: String
  }

instance FromJSON ModificationRule where
  parseJSON (Y.Object o) = do
    mScriptField <- o .:? "script"
    case mScriptField of
      Nothing -> Modify
        <$> o .: "match"
      -- modifyTitle
        <*> o .: "modify" .:. "title"
      -- modifyBody
        <*> o .: "modify" .:. "body"
      -- modifyAppname
        <*> o .: "modify" .:. "app-name"
      -- modifyAppicon
        <*> o .: "modify" .:. "app-icon"
      -- modifyTimeout
        <*> o .: "modify" .:. "timeout"
      -- modifyRight
        <*> o .: "modify" .:. "margin-right"
      -- modifyTop
        <*> o .: "modify" .:. "margin-top"
      -- modifyImage
        <*> o .: "modify" .:. "image"
      -- modifyImageSize
        <*> o .: "modify" .:. "image-size"
      -- modifyTransient
        <*> o .: "modify" .:. "transient"
      -- modifyNoClosedMsg
        <*> o .: "modify" .:. "send-noti-closed"
      -- modifyRemoveActions
        <*> o .: "modify" .:. "remove-actions"
      -- modifyActionIcons
        <*> o .: "modify" .:. "action-icons"
      -- modifyActionCommands
        <*> o .: "modify" .:. "action-commands"
      -- modifyActions
        <*> o .: "modify" .:. "actions"
      Just script'-> Script
        <$> o .: "match"
      -- mScript
        <*> return script'
  parseJSON _ = fail "Expected Object for ModificationRule"

data Config = Config
  {
  -- notification-center
    configBarHeight :: Int
  , configBottomBarHeight :: Int
  , configRightMargin :: Int
  , configWidth :: Int
  , configStartupCommand :: String
  , configNotiCenterMonitor :: Int
  , configNotiCenterFollowMouse :: Bool
  , configNotiCenterNewFirst :: Bool
  , configIgnoreTransient :: Bool
  , configMatchingRules :: [ModificationRule]
  , configActionIcons :: Bool
  , configNotiMarkup :: Bool
  , configNotiParseHtmlEntities :: Bool
  , configSendNotiClosedDbusMessage :: Bool
  , configGuessIconFromAppname :: Bool
  , configNotiCenterHideOnMouseLeave :: Bool

  -- notification-center-notification-popup
  , configNotiDefaultTimeout :: Int
  , configDistanceTop :: Int
  , configDistanceRight :: Int
  , configDistanceBetween :: Int
  , configWidthNoti :: Int
  , configNotiFollowMouse :: Bool
  , configNotiMonitor :: Int
  , configImgSize :: Int
  , configImgMarginTop :: Int
  , configImgMarginLeft :: Int
  , configImgMarginBottom :: Int
  , configImgMarginRight :: Int
  , configIconSize :: Int
  , configPopupMaxLinesInBody :: Int
  , configPopupEllipsizeBody :: Bool
  , configPopupDismissButton :: String
  , configPopupDefaultActionButton :: String
  , configPopupHideBodyIfEmpty :: Bool

  -- buttons
  , configButtonsPerRow :: Int
  , configButtonHeight :: Int
  , configButtonMargin :: Int
  , configButtons :: [ButtonConfig]

  -- tray
  , configTrayIconSize :: Int
  , configTraySpacing :: Int
  , configTrayPosition :: String
  , configTrayMonitor :: Int
  , configTrayFollowMouse :: Bool
  , configTrayBehindWindows :: Bool
    -- ^ True: tray stays behind all windows (unclickable where
    -- overlapped); False: normal panel stacking, above apps

  -- theming (raw @theme:@ section; see Homgb.Theme)
  , configTheme :: ThemeConfig

  -- bar (xmobar replacement, rendered inside the tray surface)
  , configBarWorkspaces :: Bool

  -- keyboard
  , configKbLayouts :: [String]
  , configKbIndicator :: Bool
  }

(.:.) :: FromJSON a => Y.Parser (Maybe Y.Object) -> Text.Text -> Y.Parser (Maybe a)
(.:.) po name = do
  mO <- po
  case mO of
    Nothing -> return Nothing
    (Just x) -> x .:? AesonKey.fromText name

(.!=>) :: Y.Parser (Maybe a) -> Y.Parser (Maybe a) -> Y.Parser (Maybe a)
(.!=>) a b = orElse <$> a <*> b

firstLevel :: FromJSON a => Y.Object -> Text.Text -> a -> Y.Parser a
firstLevel o firstKey alt =
  o .:? AesonKey.fromText firstKey
  .!= alt

secondLevel :: FromJSON a => Y.Object -> Text.Text -> Text.Text -> a -> Y.Parser a
secondLevel o firstKey secondKey alt =
  o .:? AesonKey.fromText firstKey .:. secondKey
  .!= alt

thirdLevel :: FromJSON a => Y.Object -> Text.Text -> Text.Text -> Text.Text -> a -> Y.Parser a
thirdLevel o firstKey secondKey thirdKey alt =
  o .:? AesonKey.fromText firstKey .:. secondKey .:. thirdKey
  .!= alt

fourthLevel :: FromJSON a => Y.Object -> Text.Text -> Text.Text -> Text.Text -> Text.Text -> a -> Y.Parser a
fourthLevel o firstKey secondKey thirdKey fourthKey alt =
  o .:? AesonKey.fromText firstKey .:. secondKey .:. thirdKey .:. fourthKey
  .!= alt

inheritingSecondLevel :: FromJSON a => Y.Object -> Text.Text -> Text.Text -> a -> Y.Parser a
inheritingSecondLevel o firstKey secondKey alt =
  o .:? AesonKey.fromText firstKey .:. secondKey
  .!=> (o .:? AesonKey.fromText secondKey)
  .!= alt

inheritingThirdLevel :: FromJSON a => Y.Object -> Text.Text -> Text.Text -> Text.Text -> a -> Y.Parser a
inheritingThirdLevel o firstKey secondKey thirdKey alt =
  o .:? AesonKey.fromText firstKey .:. secondKey .:. thirdKey
  .!=> (o .:? AesonKey.fromText secondKey .:. thirdKey)
  .!=> (o .:? AesonKey.fromText thirdKey)
  .!= alt

instance FromJSON Config where
  parseJSON (Y.Object o) =
    Config
  --configBarHeight
    <$> inheritingSecondLevel o "notification-center" "margin-top" 0
  -- configBottomBarHeight
    <*> inheritingSecondLevel o "notification-center" "margin-bottom" 0
  -- configRightMargin
    <*> inheritingSecondLevel o "notification-center" "margin-right" 0
  -- configWidth
    <*> inheritingSecondLevel o "notification-center" "width" 500
  -- configStartupCommand
    <*> firstLevel o "startup-command" ""
  -- configNotiCenterMonitor
    <*> inheritingSecondLevel o "notification-center" "monitor" 0
  -- configNotiCenterFollowMouse
    <*> inheritingSecondLevel o "notification-center" "follow-mouse" False
  -- configNotiCenterNewFirst
    <*> secondLevel o "notification-center" "new-first" True
  -- configIgnoreTransient
    <*> secondLevel o "notification-center" "ignore-transient" False
  -- configMatchingRules
    <*> secondLevel o "notification" "modifications" []
  -- configActionIcons
    <*> secondLevel o "notification" "use-action-icons" True
  -- configNotiMarkup
    <*> secondLevel o "notification" "use-markup" True
  -- configNotiParseHtmlEntities
    <*> secondLevel o "notification" "parse-html-entities" True
  -- configSendNotiClosedDbusMessage
    <*> thirdLevel o "notification" "dbus" "send-noti-closed" False
  -- configGuessIconFromAppname
    <*> inheritingThirdLevel o "notification" "app-icon" "guess-icon-from-name"
    True
  -- configNotiCenterHideOnMouseLeave
    <*> secondLevel o "notification-center" "hide-on-mouse-leave" True
  -- configNotiDefaultTimeout (deadd README documents 10000ms; the
  -- code fallback there is 1000, which makes popups vanish in a
  -- second — use the documented value)
    <*> thirdLevel o "notification" "popup" "default-timeout" 10000
  -- configDistanceTop
    <*> inheritingThirdLevel o "notification" "popup" "margin-top" 50
  -- configDistanceRight
    <*> inheritingThirdLevel o "notification" "popup" "margin-right" 50
  -- configDistanceBetween
    <*> thirdLevel o "notification" "popup" "margin-between" 20
  -- configWidthNoti
    <*> inheritingThirdLevel o "notification" "popup" "width" 300
  -- configNotiFollowMouse
    <*> inheritingThirdLevel o "notification" "popup" "follow-mouse" False
  -- configNotiMonitor
    <*> inheritingThirdLevel o "notification" "popup" "monitor" 0
  -- configImgSize
    <*> thirdLevel o "notification" "image" "size" 100
  -- configImgMarginTop
    <*> thirdLevel o "notification" "image" "margin-top" 15
  -- configImgMarginLeft
    <*> thirdLevel o "notification" "image" "margin-left" 15
  -- configImgMarginBottom
    <*> thirdLevel o "notification" "image" "margin-bottom" 15
  -- configImgMarginRight
    <*> thirdLevel o "notification" "image" "margin-right" 0
  -- configIconSize
    <*> thirdLevel o "notification" "app-icon" "icon-size" 20
  -- configPopupMaxLinesInBody
    <*> inheritingThirdLevel o "notification" "popup" "max-lines-in-body" 3
  -- configPopupEllipsizeBody
    <*> ((/= (0 :: Int)) <$>
          inheritingThirdLevel o "notification" "popup" "max-lines-in-body" 3)
  -- configPopupDismissButton
    <*> fourthLevel o "notification" "popup" "click-behavior" "dismiss" "mouse1"
  -- configPopupDefaultActionButton
    <*> fourthLevel o "notification" "popup" "click-behavior" "default-action" "mouse3"
  -- configPopupHideBodyIfEmpty
    <*> thirdLevel o "notification" "popup" "hide-body-if-empty" False
  -- configButtonsPerRow
    <*> thirdLevel o "notification-center" "buttons" "buttons-per-row" 5
  -- configButtonHeight
    <*> thirdLevel o "notification-center" "buttons" "buttons-height" 60
  -- configButtonMargin
    <*> thirdLevel o "notification-center" "buttons" "buttons-margin" 2
  -- configButtons
    <*> thirdLevel o "notification-center" "buttons" "actions" []
  -- configTrayIconSize
    <*> secondLevel o "tray" "icon-size" 22
  -- configTraySpacing
    <*> secondLevel o "tray" "spacing" 4
  -- configTrayPosition
    <*> secondLevel o "tray" "position" "top-right"
  -- configTrayMonitor
    <*> secondLevel o "tray" "monitor" 0
  -- configTrayFollowMouse
    <*> secondLevel o "tray" "follow-mouse" False
  -- configTrayBehindWindows
    <*> secondLevel o "tray" "behind-windows" False
  -- configTheme
    <*> firstLevel o "theme" defaultThemeConfig
  -- configBarWorkspaces
    <*> secondLevel o "bar" "workspaces" True
  -- configKbLayouts
    <*> secondLevel o "keyboard" "layouts" []
  -- configKbIndicator
    <*> secondLevel o "keyboard" "indicator" True
  parseJSON _ = fail "Expected Object for Config value"

data ButtonConfig = Button
  {
    configButtonLabel :: String
  , configButtonCommand :: String
  }

instance FromJSON ButtonConfig where
  parseJSON (Y.Object o) = Button
        <$> o .: "label"
        <*> o .: "command"
  parseJSON _ = fail "Expected Object for ButtonConfig"

-- | Raw @theme:@ config section. Every field optional; 'Homgb.Theme.mkTheme'
-- merges it over the built-in defaults. Kept here (not in Homgb.Theme)
-- because Config carries it and Theme imports Config.
data ThemeConfig = ThemeConfig
  { tcFontFamily :: Maybe Text.Text
  , tcFontSize :: Maybe Float
  , tcFontCyrillic :: Maybe Bool
  , tcColors :: Map.Map Text.Text Text.Text
  , tcTrayIconSize :: Maybe Int
  , tcTraySpacing :: Maybe Int
  , tcTrayPadX :: Maybe Float
  , tcTrayPadY :: Maybe Float
  , tcPopupPadX :: Maybe Float
  , tcPopupPadY :: Maybe Float
  , tcMenuPadX :: Maybe Float
  , tcMenuPadY :: Maybe Float
  }

defaultThemeConfig :: ThemeConfig
defaultThemeConfig = ThemeConfig
  { tcFontFamily = Nothing
  , tcFontSize = Nothing
  , tcFontCyrillic = Nothing
  , tcColors = Map.empty
  , tcTrayIconSize = Nothing
  , tcTraySpacing = Nothing
  , tcTrayPadX = Nothing
  , tcTrayPadY = Nothing
  , tcPopupPadX = Nothing
  , tcPopupPadY = Nothing
  , tcMenuPadX = Nothing
  , tcMenuPadY = Nothing
  }

instance FromJSON ThemeConfig where
  parseJSON (Y.Object o) = do
    font <- o .:? "font"
    (ffam, fsz, fcyr) <- case font of
      Nothing -> return (Nothing, Nothing, Nothing)
      Just (Y.Object f) ->
        (,,) <$> f .:? "family" <*> f .:? "size" <*> f .:? "cyrillic"
      Just _ -> fail "Expected Object for theme.font"
    colors <- o .:? "colors" .!= Map.empty
    sizes <- o .:? "sizes"
    (tpx, tpy, ppx, ppy, mpx, mpy) <- case sizes of
      Nothing -> return (Nothing, Nothing, Nothing, Nothing, Nothing, Nothing)
      Just (Y.Object s) -> do
        tray <- s .:? "tray"
        (tx, ty) <- case tray of
          Nothing -> return (Nothing, Nothing)
          Just (Y.Object t) -> (,) <$> t .:? "padding-x" <*> t .:? "padding-y"
          Just _ -> fail "Expected Object for theme.sizes.tray"
        popup <- s .:? "popup"
        (px, py) <- case popup of
          Nothing -> return (Nothing, Nothing)
          Just (Y.Object p) -> (,) <$> p .:? "padding-x" <*> p .:? "padding-y"
          Just _ -> fail "Expected Object for theme.sizes.popup"
        menu <- s .:? "menu"
        (mx, my) <- case menu of
          Nothing -> return (Nothing, Nothing)
          Just (Y.Object m) -> (,) <$> m .:? "padding-x" <*> m .:? "padding-y"
          Just _ -> fail "Expected Object for theme.sizes.menu"
        return (tx, ty, px, py, mx, my)
      Just _ -> fail "Expected Object for theme.sizes"
    ThemeConfig
      <$> pure ffam
      <*> pure fsz
      <*> pure fcyr
      <*> pure colors
      <*> sizeOf "tray" "icon-size"
      <*> sizeOf "tray" "spacing"
      <*> pure tpx
      <*> pure tpy
      <*> pure ppx
      <*> pure ppy
      <*> pure mpx
      <*> pure mpy
    where
      -- theme.sizes.<section>.<key>
      sizeOf section key = do
        msizes <- o .:? "sizes"
        case msizes of
          Just (Y.Object s) -> do
            msec <- s .:? AesonKey.fromText section
            case msec of
              Just (Y.Object sec) -> sec .:? AesonKey.fromText key
              _ -> return Nothing
          _ -> return Nothing
  parseJSON _ = fail "Expected Object for ThemeConfig"

getConfig :: Text.Text -> IO Config
getConfig configYml = Y.decodeThrow $ encodeUtf8 configYml

-- | Built-in configuration used when no config file is present.
-- All values fall back to the defaults in 'parseJSON' anyway; this
-- exists so users have a starting point to copy to
-- @~\/.config\/homgb\/config.yml@.
defaultConfigText :: Text.Text
defaultConfigText = Text.pack $ unlines
  [ "notification-center:"
  , "  margin-top: 0"
  , "  margin-bottom: 0"
  , "  margin-right: 0"
  , "  width: 500"
  , "  monitor: 0"
  , "  follow-mouse: false"
  , "  new-first: true"
  , "  ignore-transient: false"
  , "notification:"
  , "  use-action-icons: true"
  , "  use-markup: true"
  , "  parse-html-entities: true"
  , "  dbus:"
  , "    send-noti-closed: false"
  , "  app-icon:"
  , "    guess-icon-from-name: true"
  , "  popup:"
  , "    default-timeout: 10000"
  , "    margin-top: 50"
  , "    margin-right: 50"
  , "    margin-between: 20"
  , "    width: 300"
  , "    follow-mouse: false"
  , "    monitor: 0"
  , "    max-lines-in-body: 3"
  , "    hide-body-if-empty: false"
  , "    click-behavior:"
  , "      dismiss: mouse1"
  , "      default-action: mouse3"
  , "  image:"
  , "    size: 100"
  , "    margin-top: 15"
  , "    margin-left: 15"
  , "    margin-bottom: 15"
  , "    margin-right: 0"
  , "  modifications: []"
  , "buttons:"
  , "  buttons-per-row: 5"
  , "  buttons-height: 60"
  , "  buttons-margin: 2"
  , "  actions: []"
  , "tray:"
  , "  icon-size: 22"
  , "  spacing: 4"
  , "  position: top-right"
  , "  monitor: 0"
  , "  follow-mouse: false"
  , "  behind-windows: false"
  , "bar:"
  , "  workspaces: true"
  , "theme:"
  , "  font:"
  , "    family: \"Noto Sans\""
  , "    size: 28"
  , "    cyrillic: true"
  , "  colors:"
  , "    popup.bg: \"#212227\""
  , "    popup.bg-low: \"#1a1a1c\""
  , "    popup.bg-critical: \"#291c1c\""
  , "    popup.border: \"#40434a\""
  , "    popup.border-low: \"#333338\""
  , "    popup.border-critical: \"#cc3333\""
  , "    popup.title: \"#e6e6e6\""
  , "    popup.title-low: \"#bfbfbf\""
  , "    popup.title-critical: \"#f26666\""
  , "    menu.bg: \"#333a52\""
  , "    menu.border: \"#8c9ec7\""
  , "  sizes:"
  , "    tray:"
  , "      padding-x: 8"
  , "      padding-y: 8"
  , "    popup:"
  , "      padding-x: 8"
  , "      padding-y: 8"
  , "    menu:"
  , "      padding-x: 8"
  , "      padding-y: 8"
  , "keyboard:"
  , "  layouts: []"
  , "  indicator: true"
  ]
