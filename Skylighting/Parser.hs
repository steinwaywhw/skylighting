{-# LANGUAGE Arrows #-}

module Skylighting.Parser ( parseSyntaxDefinition ) where

import Safe
import Text.XML.HXT.Core
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Skylighting.Types
import Skylighting.Regex
import qualified Data.Map as Map

standardDelims :: Set.Set Char
standardDelims = Set.fromList " \n\t.():!+,-<=>%&*/;?[]^{|}~\\"

defaultKeywordAttr :: KeywordAttr
defaultKeywordAttr = KeywordAttr { keywordCaseSensitive = True
                                 , keywordDelims = standardDelims }

stripWhitespace :: String -> String
stripWhitespace = reverse . stripWhitespaceLeft . reverse . stripWhitespaceLeft
  where stripWhitespaceLeft = dropWhile isWhitespace
        isWhitespace x = x `elem` [' ', '\t', '\n']

vBool :: Bool -> String -> Bool
vBool defaultVal value = case value of
                           z | z `elem` ["true","yes","1"] -> True
                           z | z `elem` ["false","no","0"] -> False
                           _ -> defaultVal

-- | Parses a string containing a Kate XML syntax definition
-- into a 'Syntax' description.
parseSyntaxDefinition :: String -> IO Syntax
parseSyntaxDefinition xml = do
  res <- runX (application xml)
  case res of
       [s]   -> return s
       _     -> error "Could not parse xml file" -- TODO better exceptions

application :: String -> IOSArrow b Syntax
application fp
    = readDocument [withValidate no, withInputEncoding utf8] fp
      >>>
      multi (hasName "language")
      >>>
      extractSyntaxDefinition

extractSyntaxDefinition :: IOSArrow XmlTree Syntax
extractSyntaxDefinition =
  proc x -> do
     lang <- getAttrValue "name" -< x
     author <- getAttrValue "author" -< x
     version <- getAttrValue "version" -< x
     license <- getAttrValue "license" -< x
     extensions <- getAttrValue "extensions" -< x
     caseSensitive <- arr (vBool True) <<< getAttrValue "casesensitive" -< x
     contexts <- getContexts $< (getAttrValue "name") &&&
                                (arr toItemDataTable <<< getItemDatas) &&&
                                getLists &&&
                                (arr (headDef defaultKeywordAttr)
                                    <<< getKeywordAttrs) -< x
     let startingContext =
          case contexts of
               (c:_) -> c
               []    -> error "No contexts"
     returnA -< Syntax{
                  sName     = lang
                , sAuthor   = author
                , sVersion  = version
                , sLicense  = license
                , sExtensions = words $ map
                     (\c -> if c == ';'
                               then ' '
                               else c) extensions
                -- TODO case sensitive
                , sContexts = Map.fromList
                       [(cName c, c) | c <- contexts]
                , sStartingContext = startingContext
                }

toItemDataTable :: [(String,String)] -> Map.Map String TokenType
toItemDataTable = Map.fromList . map (\(s,t) -> (s, toTokenType t))

getItemDatas :: IOSArrow XmlTree [(String,String)]
getItemDatas =
  multi (hasName "itemDatas")
     >>>
     (listA $ getChildren
             >>>
             hasName "itemData"
             >>>
             getAttrValue "name" &&& getAttrValue "defStyleNum")

toTokenType :: String -> TokenType
toTokenType s =
  case s of
       "dsNormal" -> NormalTok
       "dsKeyword" -> KeywordTok
       "dsDataType" -> DataTypeTok
       "dsDecVal" -> DecValTok
       "dsBaseN" -> BaseNTok
       "dsFloat" -> FloatTok
       "dsConstant" -> ConstantTok
       "dsChar" -> CharTok
       "dsSpecialChar" -> SpecialCharTok
       "dsString" -> StringTok
       "dsVerbatimString" -> VerbatimStringTok
       "dsSpecialString" -> SpecialStringTok
       "dsImport" -> ImportTok
       "dsComment" -> CommentTok
       "dsDocumentation" -> DocumentationTok
       "dsAnnotation" -> AnnotationTok
       "dsCommentVar" -> CommentVarTok
       "dsOthers" -> OtherTok
       "dsFunction" -> FunctionTok
       "dsVariable" -> VariableTok
       "dsControlFlow" -> ControlFlowTok
       "dsOperator" -> OperatorTok
       "dsBuiltIn" -> BuiltInTok
       "dsExtension" -> ExtensionTok
       "dsPreprocessor" -> PreprocessorTok
       "dsAttribute" -> AttributeTok
       "dsRegionMarker" -> RegionMarkerTok
       "dsInformation" -> InformationTok
       "dsWarning" -> WarningTok
       "dsAlert" -> AlertTok
       "dsError" -> ErrorTok
       _ -> OtherTok -- warning?

getLists :: IOSArrow XmlTree [(String, [String])]
getLists =
  listA $ multi (hasName "list")
     >>>
     getAttrValue "name" &&& getListContents

getListContents :: IOSArrow XmlTree [String]
getListContents =
  listA $ getChildren
     >>>
     hasName "item"
     >>>
     getChildren
     >>>
     getText
     >>>
     arr stripWhitespace

getContexts ::
     (String, (Map.Map String TokenType, ([(String, [String])], KeywordAttr)))
            -> IOSArrow XmlTree [Context]
getContexts (syntaxname, (itemdatas, (lists, kwattr))) =
  listA $ multi (hasName "context")
     >>>
     proc x -> do
       name <- getAttrValue "name" -< x
       attribute <- getAttrValue "attribute" -< x
       lineEndContext <- getAttrValue "lineEndContext" -< x
       lineBeginContext <- getAttrValue "lineBeginContext" -< x
       fallthrough <- arr (vBool False) <<< getAttrValue "fallthrough" -< x
       fallthroughContext <- getAttrValue "fallthroughContext" -< x
       dynamic <- arr (vBool False) <<< getAttrValue "dynamic" -< x
       parsers <- getParsers (itemdatas, (lists, kwattr)) -< x
       returnA -< Context {
                     cName = name
                   , cSyntax = syntaxname
                   , cRules = parsers
                   , cAttribute = fromMaybe NormalTok $
                           Map.lookup attribute itemdatas
                   , cLineEndContext = parseContextSwitch lineEndContext
                   , cLineBeginContext = parseContextSwitch lineBeginContext
                   , cFallthrough = fallthrough
                   , cFallthroughContext = parseContextSwitch fallthroughContext
                   , cDynamic = dynamic
                   }

-- Note, some xml files have "\\" for a backslash,
-- others have "\".  Not sure what the rules are, but
-- this covers both bases:
readChar :: String -> Char
readChar s = case s of
                  [c] -> c
                  _   -> readDef '\xffff' $ "'" ++ s ++ "'"


getParsers :: (Map.Map String TokenType, ([(String, [String])], KeywordAttr))
            -> IOSArrow XmlTree [Rule]
getParsers (itemdatas, (lists, kwattr)) =
  listA $ getChildren
     >>>
     proc x -> do
       name <- getName -< x
       attribute <- getAttrValue "attribute" -< x
       context <- getAttrValue "context" -< x
       char0 <- arr readChar <<< getAttrValue "char" -< x
       char1 <- arr readChar <<< getAttrValue "char1" -< x
       str' <- getAttrValue "String" -< x
       insensitive <- arr (vBool False) <<< getAttrValue "insensitive" -< x
       includeAttrib <- arr (vBool False) <<< getAttrValue "includeAttrib" -< x
       lookahead <- arr (vBool False) <<< getAttrValue "lookAhead" -< x
       firstNonSpace <- arr (vBool False) <<< getAttrValue "firstNonSpace" -< x
       column' <- getAttrValue "column" -< x
       dynamic <- arr (vBool False) <<< getAttrValue "dynamic" -< x
       children <- getParsers (itemdatas, (lists, kwattr)) -< x
       let tildeRegex = name == "RegExpr" && take 1 str' == "^"
       let str = if tildeRegex then drop 1 str' else str'
       let column = if tildeRegex
                       then Just (0 :: Int)
                       else readMay column'
       let compiledRe = if dynamic
                           then Nothing
                           else Just $ compileRegex True str
       let re = RegExpr RE{ reString = str
                          , reDynamic = dynamic
                          , reCompiled = compiledRe
                          , reCaseSensitive = not insensitive }
       let (syntaxname, contextname) =
               case break (=='#') context of
                     (cont, '#':'#':lang) -> (lang, cont)
                     _ -> ("", context)
       let matcher = case name of
                          "DetectChar" -> DetectChar char0
                          "Detect2Chars" -> Detect2Chars char0 char1
                          "AnyChar" -> AnyChar str
                          "RangeDetect" -> RangeDetect char0 char1
                          "StringText" -> StringDetect str
                          "RegExpr" -> re
                          "keyword" -> Keyword kwattr $
                             fromMaybe [] (lookup str lists)
                          "Int" -> Int
                          "Float" -> Float
                          "HlCOct" -> HlCOct
                          "HlCHex" -> HlCHex
                          "HlCStringChar" -> HlCStringChar
                          "LineContinue" -> LineContinue
                          "IncludeRules" -> IncludeRules (syntaxname, contextname)
                          "DetectSpaces" -> DetectSpaces
                          "DetectIdentifier" -> DetectIdentifier
                          _ -> Unimplemented name
       let contextSwitch = if name == "IncludeRules"
                              then []
                              else parseContextSwitch context
       returnA -< Rule{ rMatcher = matcher,
                        rAttribute = fromMaybe OtherTok $
                           Map.lookup attribute itemdatas,
                        rIncludeAttribute = includeAttrib,
                        rDynamic = dynamic,
                        rChildren = children,
                        rContextSwitch = contextSwitch }

parseContextSwitch :: String -> [ContextSwitch]
parseContextSwitch [] = []
parseContextSwitch "#stay" = []
parseContextSwitch ('#':'p':'o':'p':xs) = Pop : parseContextSwitch xs
parseContextSwitch ('!':xs) = [Push ("",xs)]
parseContextSwitch xs = [Push ("",xs)]

getKeywordAttrs :: IOSArrow XmlTree [KeywordAttr]
getKeywordAttrs =
  listA $ multi $ hasName "keywords"
     >>>
     proc x -> do
       caseSensitive <- arr (vBool True) <<< getAttrValue "casesensitive" -< x
       weakDelim <- getAttrValue "weakDeliminator" -< x
       additionalDelim <- getAttrValue "additionalDeliminator" -< x
       returnA -< KeywordAttr
                         { keywordCaseSensitive = caseSensitive
                         , keywordDelims = (Set.union standardDelims
                             (Set.fromList additionalDelim)) Set.\\
                                Set.fromList weakDelim }