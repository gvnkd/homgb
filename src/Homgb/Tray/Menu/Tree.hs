{-# LANGUAGE OverloadedStrings #-}

-- | dbusmenu layout tree, ported from taffybar's DBusMenu.hs (GTK parts
-- dropped).
module Homgb.Tray.Menu.Tree
  ( LayoutNode(..)
  , parseLayout
  , menuItemLabel
  , menuItemVisible
  , menuItemEnabled
  , menuItemIsSeparator
  , menuItemChildrenDisplay
  , menuItemToggleState
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Int (Int32)
import DBus (Variant(..), Structure(..), fromVariant)

data LayoutNode = LayoutNode
  { lnId :: Int32
  , lnProps :: Map.Map T.Text Variant
  , lnChildren :: [LayoutNode]
  } deriving (Show)

-- | Parse the (ia{sv}av) layout structure returned by GetLayout.
parseLayout :: Variant -> Maybe LayoutNode
parseLayout v = do
  (i, props, kids) <- fromVariant v :: Maybe (Int32, Map.Map T.Text Variant, [Variant])
  children <- mapM parseLayout kids
  return $ LayoutNode i props children

prop :: T.Text -> LayoutNode -> Maybe Variant
prop name node = Map.lookup name (lnProps node)

propText :: T.Text -> LayoutNode -> Maybe T.Text
propText name node = prop name node >>= fromVariant

propBool :: T.Text -> Bool -> LayoutNode -> Bool
propBool name def node = maybe def id (prop name node >>= fromVariant)

menuItemLabel :: LayoutNode -> T.Text
menuItemLabel node = maybe "" id (propText "label" node)

menuItemVisible :: LayoutNode -> Bool
menuItemVisible = propBool "visible" True

menuItemEnabled :: LayoutNode -> Bool
menuItemEnabled = propBool "enabled" True

menuItemIsSeparator :: LayoutNode -> Bool
menuItemIsSeparator node = propText "type" node == Just "separator"

menuItemChildrenDisplay :: LayoutNode -> Maybe T.Text
menuItemChildrenDisplay = propText "children-display"

menuItemToggleState :: LayoutNode -> Maybe Int32
menuItemToggleState node = prop "toggle-state" node >>= fromVariant
