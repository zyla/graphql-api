{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | Literal GraphQL values.
module GraphQL.Value
  ( Value(..)
  , toObject
  , ToValue(..)
  , astToValue
  , valueToAST
  , prop_roundtripFromAST
  , prop_roundtripFromValue
  , prop_roundtripValue
  , FromValue(..)
  , Name
  , List
  , String(..)
    -- * Objects
  , Object
  , ObjectField(ObjectField)
    -- ** Constructing
  , makeObject
  , objectFromList
    -- ** Combining
  , unionObjects
    -- ** Querying
  , objectFields
  ) where

import Protolude

import qualified Data.List.NonEmpty as NonEmpty
import Data.List.NonEmpty (NonEmpty)
import Data.Aeson (ToJSON(..), (.=), pairs)
import qualified Data.Aeson as Aeson
import qualified Data.Map as Map
import Test.QuickCheck (Arbitrary(..), Gen, oneof, listOf, sized)

import GraphQL.Internal.Arbitrary (arbitraryText)
import GraphQL.Internal.AST (Name(..))
import qualified GraphQL.Internal.AST as AST
import GraphQL.Internal.OrderedMap (OrderedMap)
import qualified GraphQL.Internal.OrderedMap as OrderedMap


-- | Concrete GraphQL value. Essentially Data.GraphQL.AST.Value, but without
-- the "variable" field.
data Value
  = ValueInt Int32
  | ValueFloat Double
  | ValueBoolean Bool
  | ValueString String
  | ValueEnum Name
  | ValueList List
  | ValueObject Object
  | ValueNull
  deriving (Eq, Ord, Show)

toObject :: Value -> Maybe Object
toObject (ValueObject o) = pure o
toObject _ = empty

instance ToJSON GraphQL.Value.Value where

  toJSON (ValueInt x) = toJSON x
  toJSON (ValueFloat x) = toJSON x
  toJSON (ValueBoolean x) = toJSON x
  toJSON (ValueString x) = toJSON x
  toJSON (ValueEnum x) = toJSON x
  toJSON (ValueList x) = toJSON x
  toJSON (ValueObject x) = toJSON x
  toJSON ValueNull = Aeson.Null

instance Arbitrary Value where
  -- | Generate an arbitrary value. Uses the generator's \"size\" property to
  -- determine maximum object depth.
  arbitrary = sized genValue

-- | Generate an arbitrary scalar value.
genScalarValue :: Gen Value
genScalarValue = oneof [ ValueInt <$> arbitrary
                       , ValueFloat <$> arbitrary
                       , ValueBoolean <$> arbitrary
                       , ValueString <$> arbitrary
                       , ValueEnum <$> arbitrary
                       , pure ValueNull
                       ]

-- | Generate an arbitrary value, with objects at most @n@ levels deep.
genValue :: Int -> Gen Value
genValue n
  | n <= 0 = genScalarValue
  | otherwise = oneof [ genScalarValue
                      , ValueObject <$> genObject (n - 1)
                      , ValueList . List <$> listOf (genValue (n - 1))
                      ]

newtype String = String Text deriving (Eq, Ord, Show)

instance Arbitrary String where
  arbitrary = String <$> arbitraryText

instance ToJSON String where
  toJSON (String x) = toJSON x

newtype List = List [Value] deriving (Eq, Ord, Show)

instance Arbitrary List where
  -- TODO: GraphQL does not allow heterogeneous lists:
  -- https://facebook.github.io/graphql/#sec-Lists, so this will generate
  -- invalid lists.
  arbitrary = List <$> listOf arbitrary

makeList :: (Functor f, Foldable f, ToValue a) => f a -> List
makeList = List . Protolude.toList . map toValue


instance ToJSON List where
  toJSON (List x) = toJSON x

-- | A literal GraphQL object.
--
-- Note that https://facebook.github.io/graphql/#sec-Response calls these
-- \"Maps\", but everywhere else in the spec refers to them as objects.
newtype Object = Object (OrderedMap Name Value) deriving (Eq, Ord, Show)

objectFields :: Object -> [ObjectField]
objectFields (Object object) = map (uncurry ObjectField) (OrderedMap.toList object)

instance Arbitrary Object where
  arbitrary = sized genObject

-- | Generate an arbitrary object to the given maximum depth.
genObject :: Int -> Gen Object
genObject n = Object <$> OrderedMap.genOrderedMap arbitrary (genValue n)

data ObjectField = ObjectField Name Value deriving (Eq, Ord, Show)

instance Arbitrary ObjectField where
  arbitrary = ObjectField <$> arbitrary <*> arbitrary

makeObject :: [ObjectField] -> Maybe Object
makeObject fields = objectFromList [(name, value) | ObjectField name value <- fields]

objectFromList :: [(Name, Value)] -> Maybe Object
objectFromList xs = Object <$> OrderedMap.orderedMap xs

unionObjects :: [Object] -> Maybe Object
unionObjects objects = Object <$> OrderedMap.unions [obj | Object obj <- objects]

instance ToJSON Object where
  -- Direct encoding to preserve order of keys / values
  toJSON (Object xs) = toJSON (Map.fromList [(getNameText k, v) | (k, v) <- OrderedMap.toList xs])
  toEncoding (Object xs) = pairs (foldMap (\(k, v) -> toS (getNameText k) .= v) (OrderedMap.toList xs))

-- | Turn a Haskell value into a GraphQL value.
class ToValue a where
  toValue :: a -> Value

instance ToValue Value where
  toValue = identity

-- XXX: Should this just be for Foldable?
instance ToValue a => ToValue [a] where
  toValue = toValue . List . map toValue

instance ToValue a => ToValue (NonEmpty a) where
  toValue = toValue . makeList

instance ToValue a => ToValue (Maybe a) where
  toValue = maybe ValueNull toValue

instance ToValue Bool where
  toValue = ValueBoolean

instance ToValue Int32 where
  toValue = ValueInt

instance ToValue Double where
  toValue = ValueFloat

instance ToValue String where
  toValue = ValueString

-- XXX: Make more generic: any string-like thing rather than just Text.
instance ToValue Text where
  toValue = toValue . String

instance ToValue List where
  toValue = ValueList

instance ToValue Object where
  toValue = ValueObject

-- | @a@ can be converted from a GraphQL 'Value' to a Haskell value.
--
-- The @FromValue@ instance converts 'AST.Value' to the type expected by the
-- handler function. It is the boundary between incoming data and your custom
-- application Haskell types.
class FromValue a where
  -- | Convert an already-parsed value into a Haskell value, generally to be
  -- passed to a handler.
  fromValue :: Value -> Either Text a

instance FromValue Int32 where
  fromValue (ValueInt v) = pure v
  fromValue v = wrongType "Int" v

instance FromValue Double where
  fromValue (ValueFloat v) = pure v
  fromValue v = wrongType "Double" v

instance FromValue Bool where
  fromValue (ValueBoolean v) = pure v
  fromValue v = wrongType "Bool" v

instance FromValue Text where
  fromValue (ValueString (String v)) = pure v
  fromValue v = wrongType "String" v

instance forall v. FromValue v => FromValue [v] where
  fromValue (ValueList (List values)) = traverse (fromValue @v) values
  fromValue v = wrongType "List" v

instance forall v. FromValue v => FromValue (NonEmpty v) where
  fromValue (ValueList (List values)) =
    case NonEmpty.nonEmpty values of
      Nothing -> Left "Cannot construct NonEmpty from empty list"
      Just values' -> traverse (fromValue @v) values'
  fromValue v = wrongType "List" v

instance forall v. FromValue v => FromValue (Maybe v) where
  fromValue ValueNull = pure Nothing
  fromValue x = Just <$> fromValue @v x

-- | Anything that can be converted to a value and from a value should roundtrip.
prop_roundtripValue :: forall a. (Eq a, ToValue a, FromValue a) => a -> Bool
prop_roundtripValue x = fromValue (toValue x) == Right x

-- | Throw an error saying that @value@ does not have the @expected@ type.
wrongType :: (MonadError Text m, Show a) => Text -> a -> m b
wrongType expected value = throwError ("Wrong type, should be " <> expected <> show value)

-- | Convert an AST value into a literal value.
--
-- This is a stop-gap until we have proper conversion of user queries into
-- canonical forms.
astToValue :: AST.Value -> Maybe Value
astToValue (AST.ValueInt x) = pure $ ValueInt x
astToValue (AST.ValueFloat x) = pure $ ValueFloat x
astToValue (AST.ValueBoolean x) = pure $ ValueBoolean x
astToValue (AST.ValueString (AST.StringValue x)) = pure $ ValueString $ String x
astToValue (AST.ValueEnum x) = pure $ ValueEnum x
astToValue (AST.ValueList (AST.ListValue xs)) = ValueList . List <$> traverse astToValue xs
astToValue (AST.ValueObject (AST.ObjectValue fields)) = do
  fields' <- traverse toObjectField fields
  object <- makeObject fields'
  pure (ValueObject object)
  where
    toObjectField (AST.ObjectField name value) = ObjectField name <$> astToValue value
astToValue AST.ValueNull = pure ValueNull
astToValue (AST.ValueVariable _) = empty

-- | A value from the AST can be converted to a literal value and back, unless it's a variable.
prop_roundtripFromAST :: AST.Value -> Bool
prop_roundtripFromAST ast =
  case astToValue ast of
    Nothing -> True
    Just value -> ast == valueToAST value

-- | Convert a literal value into an AST value.
--
-- Nulls are converted into Nothing.
--
-- This function probably isn't particularly useful, but it functions as a
-- stop-gap until we have QuickCheck generators for the AST.
valueToAST :: Value -> AST.Value
valueToAST (ValueInt x) = AST.ValueInt x
valueToAST (ValueFloat x) = AST.ValueFloat x
valueToAST (ValueBoolean x) = AST.ValueBoolean x
valueToAST (ValueString (String x)) = AST.ValueString (AST.StringValue x)
valueToAST (ValueEnum x) = AST.ValueEnum x
valueToAST (ValueList (List xs)) = AST.ValueList (AST.ListValue (map valueToAST xs))
valueToAST (ValueObject (Object fields)) = AST.ValueObject (AST.ObjectValue (map toObjectField (OrderedMap.toList fields)))
  where
    toObjectField (name, value) = AST.ObjectField name (valueToAST value)
valueToAST ValueNull = AST.ValueNull

-- | A literal value can be converted to the AST and back.
prop_roundtripFromValue :: Value -> Bool
prop_roundtripFromValue value =
  case astToValue (valueToAST value) of
    Nothing -> False
    Just value' -> value == value'
