{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE StrictData #-}

module Main
  (main)
where

import qualified BlueRipple.Model.Evangelical.Model as RM
import qualified BlueRipple.Model.Election2.DataPrep as DP
import qualified BlueRipple.Model.Election2.ModelCommon as MC
import qualified BlueRipple.Model.Election2.ModelRunner as MR
import qualified BlueRipple.Data.Small.Loaders as BRL
import qualified BlueRipple.Data.Small.DataFrames as BR

import qualified BlueRipple.Configuration as BR
import qualified BlueRipple.Data.CachingCore as BRCC
import qualified BlueRipple.Data.Types.Demographic as DT
import qualified BlueRipple.Data.Types.Geographic as GT
import qualified BlueRipple.Data.Types.Modeling as MT
import qualified BlueRipple.Data.CES as CCES
import qualified BlueRipple.Data.ACS_Tables_Loaders as BRC
import qualified BlueRipple.Data.ACS_Tables as BRC
import qualified BlueRipple.Utilities.KnitUtils as BR
import qualified BlueRipple.Tools.StateLeg.ModeledACS as BSLACS

import qualified Knit.Report as K
import qualified Knit.Effect.AtomicCache as KC
import qualified Text.Pandoc.Error as Pandoc
import qualified System.Console.CmdArgs as CmdArgs

import qualified Stan as S

import qualified Frames as F
import qualified Frames.MapReduce as FMR
import qualified Frames.Transform as FT
import qualified Frames.SimpleJoins as FJ
import qualified Frames.Constraints as FC
import qualified Frames.Streamly.TH as FS
import qualified Frames.Streamly.CSV as FCSV

import Frames.Streamly.Streaming.Streamly (StreamlyStream, Stream)

import qualified Control.Foldl as FL
import Control.Lens (view, (^.))

import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vinyl.Functor as V

import qualified Text.Printf as PF
import qualified System.Environment as Env

FS.declareColumn "WhiteVAP" ''Int
FS.declareColumn "WhiteEv" ''Int
FS.declareColumn "TSPStateId" ''Text
FS.declareColumn "Chamber" ''Text
FS.declareColumn "Pct18To24" ''Double
FS.declareColumn "Pct18To34" ''Double

templateVars ∷ Map String String
templateVars =
  M.fromList
    [ ("lang", "English")
    , ("site-title", "Blue Ripple Politics")
    , ("home-url", "https://www.blueripplepolitics.org")
    --  , ("author"   , T.unpack yamlAuthor)
    ]

pandocTemplate ∷ K.TemplatePath
pandocTemplate = K.FullySpecifiedTemplatePath "../../research/pandoc-templates/blueripple_basic.html"

dmr ::  S.DesignMatrixRow (F.Record DP.LPredictorsR)
dmr = MC.tDesignMatrixRow_d ""

--survey :: MC.TurnoutSurvey (F.Record DP.CESByCDR)
--survey = MC.CESSurvey

weightingStyle :: DP.WeightingStyle
weightingStyle = DP.DesignEffectWeights

aggregation :: MC.SurveyAggregation S.ECVec
aggregation = MC.WeightedAggregation MC.ContinuousBinomial weightingStyle

surveyPortion :: DP.SurveyPortion
surveyPortion = DP.AllSurveyed DP.Both

--alphaModel :: MC.Alphas
--alphaModel = MC.St_A_S_E_R_StR  --MC.St_A_S_E_R_AE_AR_ER_StR

type SLDKeyR = '[GT.StateAbbreviation] V.++ BRC.LDLocationR
type ModeledR = SLDKeyR V.++ '[MR.ModelCI]

main :: IO ()
main = do
  cmdLine ← CmdArgs.cmdArgsRun BR.commandLine
  pandocWriterConfig ←
    K.mkPandocWriterConfig
    pandocTemplate
    templateVars
    (BR.brWriterOptionsF . K.mindocOptionsF)
  cacheDir <- toText . fromMaybe ".kh-cache" <$> Env.lookupEnv("BR_CACHE_DIR")
  let knitConfig ∷ K.KnitConfig BRCC.SerializerC BRCC.CacheData Text =
        (K.defaultKnitConfig $ Just cacheDir)
          { K.outerLogPrefix = Just "2023-TSP"
          , K.logIf = BR.knitLogSeverity $ BR.logLevel cmdLine -- K.logDiagnostic
          , K.pandocWriterConfig = pandocWriterConfig
          , K.serializeDict = BRCC.flatSerializeDict
          , K.persistCache = KC.persistStrictByteString (\t → toString (cacheDir <> "/" <> t))
          }
  resE ← K.knitHtmls knitConfig $ do
    K.logLE K.Info $ "Command Line: " <> show cmdLine
    let postInfo = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished Nothing)
    modelWhiteEvangelicals cmdLine
--    youthPct cmdLine
--    youthPctPre cmdLine
  case resE of
    Right namedDocs →
      K.writeAllPandocResultsWithInfoAsHtml "" namedDocs
    Left err → putTextLn $ "Pandoc Error: " <> Pandoc.renderError err

youthCountFld5 :: (FC.ElemsOf rs SLDKeyR, FC.ElemsOf rs [DT.Age5C, DT.PopCount]) => FL.Fold (F.Record rs) (F.FrameRec (SLDKeyR V.++ [DT.PopCount,Pct18To24, Pct18To34]))
youthCountFld5 =
  let popFld = FL.premap (view DT.popCount) FL.sum
      under25 = (< DT.A5_25To34) . view DT.age5C
      under35 = (< DT.A5_35To44) . view DT.age5C
      innerFld :: FL.Fold (F.Record [DT.PopCount, DT.Age5C]) (F.Record [DT.PopCount, Pct18To24, Pct18To34])
      innerFld = (\x y p -> p F.&: 100 * realToFrac x / realToFrac p F.&: 100 * realToFrac y / realToFrac p F.&: V.RNil)
                 <$> FL.prefilter under25 popFld <*> FL.prefilter under35 popFld <*> popFld
  in FMR.concatFold
     $ FMR.mapReduceFold
     FMR.noUnpack
     (FMR.assignKeysAndData @SLDKeyR @[DT.PopCount, DT.Age5C])
     (FMR.foldAndAddKey innerFld)

youthCountFld6 :: (FC.ElemsOf rs SLDKeyR, FC.ElemsOf rs [DT.Age6C, DT.PopCount]) => FL.Fold (F.Record rs) (F.FrameRec (SLDKeyR V.++ [DT.PopCount,Pct18To24, Pct18To34]))
youthCountFld6 =
  let over18 = (> DT.A6_Under18) . view DT.age6C
      popFld = FL.prefilter over18 (FL.premap (view DT.popCount) FL.sum)
      under25 = (< DT.A6_25To34) . view DT.age6C
      under35 = (< DT.A6_35To44) . view DT.age6C
      innerFld :: FL.Fold (F.Record [DT.PopCount, DT.Age6C]) (F.Record [DT.PopCount, Pct18To24, Pct18To34])
      innerFld = (\x y p -> p F.&: 100 * realToFrac x / realToFrac p F.&: 100 * realToFrac y / realToFrac p F.&: V.RNil)
                 <$> FL.prefilter under25 popFld <*> FL.prefilter under35 popFld <*> popFld
  in FMR.concatFold
     $ FMR.mapReduceFold
     FMR.noUnpack
     (FMR.assignKeysAndData @SLDKeyR @[DT.PopCount, DT.Age6C])
     (FMR.foldAndAddKey innerFld)

writeYouthCount :: (K.KnitEffects r)
             => Text -> F.FrameRec [GT.DistrictName, TSPStateId, GT.StateAbbreviation, Chamber, DT.PopCount, Pct18To24, Pct18To34] -> K.Sem r ()
writeYouthCount csvName ycF = do
  let wText = FCSV.formatTextAsIs
      printNum n m = PF.printf ("%" <> show n <> "." <> show m <> "g")
      wPrintf :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wPrintf n m = FCSV.liftFieldFormatter $ toText @String . printNum n m
--      wPrint :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
--      wPrintf n m = FCSV.liftFieldFormatter $ toText @String . printNum n m
      wCI :: (V.KnownField t, V.Snd t ~ MT.ConfidenceInterval) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wCI n m = FCSV.liftFieldFormatter
                $ toText @String .
                \ci -> printNum n m (100 * MT.ciLower ci) <> ","
                       <> printNum n m (100 * MT.ciMid ci) <> ","
                       <> printNum n m (100 * MT.ciUpper ci)
      formatModeled = FCSV.quoteField FCSV.formatTextAsIs
                      V.:& FCSV.quoteField FCSV.formatTextAsIs
                      V.:& FCSV.formatTextAsIs
                      V.:& FCSV.formatTextAsIs
                      V.:& FCSV.formatWithShow
                      V.:& wPrintf 2 2
                      V.:& wPrintf 2 2
                      V.:& V.RNil
      newHeaderMap = M.fromList [("StateAbbreviation", "state_code")
                                , ("PopCount","Population (CVAP)")
                                , ("TSPStateId", "state_district_id")
                                , ("Chamber", "chamber_name")
                                , ("Pct180To24", "18 To 24 (%)")
                                , ("Pct180To24", "18 To 34 (%)")
                                ]
  K.liftKnit @IO $ FCSV.writeLines (toString $ "../../forTSP/" <> csvName <> ".csv") $ FCSV.streamSV' @_ @(StreamlyStream Stream) newHeaderMap formatModeled "," $ FCSV.foldableToStream ycF

youthPct :: (K.KnitEffects r, BRCC.CacheEffects r) => BR.CommandLine -> K.Sem r ()
youthPct cmdLine = do
  modeledACSBySLDPSData_C <- BSLACS.modeledACSBySLD BSLACS.Modeled
  acsBySLD <- DP.unPSData <$> K.ignoreCacheTime modeledACSBySLDPSData_C
  let youthPctBySLD = FL.fold youthCountFld5 acsBySLD
  writeYouthCount "youthPct_2022" $ fmap (F.rcast . addTSPId) youthPctBySLD

youthPctPre :: (K.KnitEffects r, BRCC.CacheEffects r) => BR.CommandLine -> K.Sem r ()
youthPctPre cmdLine = do
  asrBySLD <- givenASRBySLD BRC.TY2022
  let youthPctBySLD = FL.fold youthCountFld6 asrBySLD
  writeYouthCount "youthPctPre_2022" $ fmap (F.rcast . addTSPId) youthPctBySLD


modelWhiteEvangelicals :: (K.KnitEffects r, BRCC.CacheEffects r) => BR.CommandLine -> K.Sem r ()
modelWhiteEvangelicals cmdLine = do
  let psName = "GivenWWH"
      psType = RM.PSGiven "E" psName ((`elem` [DT.R5_WhiteNonHispanic, DT.R5_Hispanic]) . view DT.race5C)
      cacheStructure cy = MR.CacheStructure (Right $ "model/evangelical/stan/CES" <> show (CCES.cesYear cy)) (Right "model/evangelical")
                          psName () ()
      modelConfig am = RM.ModelConfig aggregation am (contramap F.rcast dmr)
      modeledToCSVFrame = F.toFrame . fmap (\(k, v) -> k F.<+> FT.recordSingleton @MR.ModelCI v) . M.toList . MC.unPSMap . fst
  modeledACSBySLDPSData_C <- BSLACS.modeledACSBySLD BSLACS.Modeled
--    districtPSData <- K.ignoreCacheTime modeledACSBySLDPSData_C
  let dBDInnerF :: FL.Fold (F.Record '[DT.Race5C, DT.PopCount]) (F.Record [DT.PopCount, WhiteVAP])
      dBDInnerF =
        let pop = view DT.popCount
            race = view DT.race5C
            isWhite = (== DT.R5_WhiteNonHispanic) . race
            popF = FL.premap pop FL.sum
            whiteF = FL.prefilter isWhite popF
        in (\p w -> p F.&: w F.&: V.RNil) <$> popF <*> whiteF
      dataByDistrictF = FMR.concatFold
                        $ FMR.mapReduceFold
                        FMR.noUnpack
                        (FMR.assignKeysAndData @SLDKeyR @[DT.Race5C, DT.PopCount])
                        (FMR.foldAndAddKey dBDInnerF)
  dataByDistrict <-  fmap (FL.fold dataByDistrictF . DP.unPSData) $ K.ignoreCacheTime modeledACSBySLDPSData_C

  let addDistrictData :: K.KnitEffects r
                      =>  F.FrameRec (SLDKeyR V.++ '[MR.ModelCI])
                      -> K.Sem r (F.FrameRec (SLDKeyR V.++ [MR.ModelCI, DT.PopCount, WhiteVAP, WhiteEv]))
      addDistrictData x =  do
        let (joined, missing) = FJ.leftJoinWithMissing @SLDKeyR x dataByDistrict
        when (not $ null missing) $ K.logLE K.Error $ "Missing keys in result/district data join=" <> show missing
        let addEv r = r F.<+> FT.recordSingleton @WhiteEv (round $ MT.ciMid (r ^. MR.modelCI) * realToFrac (r ^. DT.popCount))
        pure $ fmap addEv joined
--    modeledEvangelical_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) psType (modelConfig MC.St_A_S_E_R) modeledACSBySLDPSData_C
--    modeledEvangelical_AR_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) psType (modelConfig MC.St_A_S_E_R_AR) modeledACSBySLDPSData_C
--    modeledEvangelical_StA_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) psType (modelConfig MC.St_A_S_E_R_StA) modeledACSBySLDPSData_C
  modeledEvangelical22_StR_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2022 (cacheStructure CCES.CES2022) psType surveyPortion (modelConfig MC.St_A_S_E_R_StR) modeledACSBySLDPSData_C
--    modeledEvangelical20_StR_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) psType (modelConfig MC.St_A_S_E_R_StR) modeledACSBySLDPSData_C
  let compareOn f x y = compare (f x) (f y)
      compareRows x y = compareOn (view GT.stateAbbreviation) x y
                        <> compareOn (view GT.districtTypeC) x y
                        <> GT.districtNameCompare (x ^. GT.districtName) (y ^. GT.districtName)
      csvSort = F.toFrame . sortBy compareRows . FL.fold FL.list
--    modeledEvangelical <-
--    K.ignoreCacheTime modeledEvangelical_C >>= writeModeled "modeledEvangelical_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
--    K.ignoreCacheTime modeledEvangelical_AR_C >>= writeModeled "modeledEvangelical_AR_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
--    K.ignoreCacheTime modeledEvangelical_StA_C >>= writeModeled "modeledEvangelical_StA_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
  K.ignoreCacheTime modeledEvangelical22_StR_C
    >>= fmap (fmap addTSPId) . addDistrictData . csvSort . fmap F.rcast . modeledToCSVFrame
    >>= writeModeled "modeledEvangelical22_NLCD_StR_GivenWWH" . fmap F.rcast
--    K.ignoreCacheTime modeledEvangelical20_StR_C >>= writeModeled "modeledEvangelical20_StR_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
--    let modeledEvangelicalFrame = modeledToCSVFrame modeledEvangelical
--    writeModeled "modeledEvangelical_StA_GivenWWH" $ fmap F.rcast modeledEvangelicalFrame
--    K.logLE K.Info $ show $ MC.unPSMap $ fst $ modeledEvangelical

lowerHouseNameMap :: Map Text (Text, Text)
lowerHouseNameMap = M.fromList [("CA", ("Assembly", "A"))
                               ,("NJ", ("Assembly", "A"))
                               ,("NV", ("Assembly", "A"))
                               ,("NY", ("Assembly", "A"))
                               ,("NY", ("Assembly", "A"))
                               ,("WI", ("Assembly", "A"))
                               ]

upperHouseNameMap :: Map Text (Text, Text)
upperHouseNameMap = mempty

addTSPId :: FC.ElemsOf rs [GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName] => F.Record rs -> F.Record (rs V.++ '[TSPStateId, Chamber])
addTSPId r = let (tspId, chamber) = tspIds r in r F.<+> (FT.recordSingleton @TSPStateId tspId) F.<+> (FT.recordSingleton @Chamber chamber)

tspIds :: FC.ElemsOf rs [GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName] => F.Record rs -> (Text, Text)
tspIds r =
  let sa = r ^. GT.stateAbbreviation
      dt = r ^. GT.districtTypeC
      (chamber, prefix) = case dt of
        GT.StateLower -> fromMaybe ("House", "H") $ M.lookup sa lowerHouseNameMap
        GT.StateUpper -> fromMaybe ("Senate", "S") $ M.lookup sa upperHouseNameMap
      n = r ^. GT.districtName
      nameFix = fromMaybe (const $ zeroPadName 3) $ M.lookup sa nameFixMap
  in (sa <> " " <> prefix <> "D-" <> nameFix dt n, sa <> " " <> chamber)

zeroPadName :: Int -> Text -> Text
zeroPadName n t = let l = T.length t in (if l < n then T.replicate (n - l) "0" else "") <> t

writeModeled :: (K.KnitEffects r)
             => Text -> F.FrameRec [TSPStateId, GT.StateAbbreviation, Chamber, MR.ModelCI, DT.PopCount, WhiteVAP, WhiteEv] -> K.Sem r ()
writeModeled csvName modeledEv = do
  let wText = FCSV.formatTextAsIs
      printNum n m = PF.printf ("%" <> show n <> "." <> show m <> "g")
      wPrintf :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wPrintf n m = FCSV.liftFieldFormatter $ toText @String . printNum n m
--      wPrint :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
--      wPrintf n m = FCSV.liftFieldFormatter $ toText @String . printNum n m
      wCI :: (V.KnownField t, V.Snd t ~ MT.ConfidenceInterval) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wCI n m = FCSV.liftFieldFormatter
                $ toText @String .
                \ci -> printNum n m (100 * MT.ciLower ci) <> ","
                       <> printNum n m (100 * MT.ciMid ci) <> ","
                       <> printNum n m (100 * MT.ciUpper ci)
      formatModeled = FCSV.quoteField FCSV.formatTextAsIs
                      V.:& FCSV.formatTextAsIs
                      V.:& FCSV.formatTextAsIs
                      V.:& wCI 2 1
                      V.:& FCSV.formatWithShow
                      V.:& FCSV.formatWithShow
                      V.:& FCSV.formatWithShow
                      V.:& V.RNil
      newHeaderMap = M.fromList [("StateAbbreviation", "state_code")
                                , ("TSPStateId", "state_district_id")
                                , ("Chamber", "chamber_name")
                                , ("DistrictTypeC","District Type")
                                ,("DistrictName","District Name")
                                ,("ModelCI","%Ev Lo,%Ev Median,%Ev Hi")
                                ,("PopCount", "CVAP")
                                ,("WhiteEv", "White Evangelicals")
                                ,("WhiteVAP", "White Voters")
                                ]
  K.liftKnit @IO $ FCSV.writeLines (toString $ "../../forTSP/" <> csvName <> ".csv") $ FCSV.streamSV' @_ @(StreamlyStream Stream) newHeaderMap formatModeled "," $ FCSV.foldableToStream modeledEv

nameFixMap :: Map Text (GT.DistrictType -> Text -> Text)
nameFixMap = M.fromList [("NH", nhNameFix), ("VT", vtNameFix), ("MA", maNameFix)]

nhNameFix :: GT.DistrictType -> Text -> Text
nhNameFix GT.StateLower x =
  let xPrefix = T.take 2 x
      xNumText = zeroPadName 2 (T.drop 2 x)
      regions = ["BELKNAP", "CARROL", "CHESHIRE", "COOS", "GRAFTON", "HILLSBOROUGH", "MERRIMACK", "ROCKINGHAM", "STRAFFORD", "SULLIVAN"]
      regionMap = M.fromList $ zip (fmap (T.take 2) regions) regions
      fullRegion p = fromMaybe p $ M.lookup p regionMap
  in fullRegion xPrefix  <> " " <> xNumText
nhNameFix _ x = x

vtNameFix :: GT.DistrictType -> Text -> Text
vtNameFix _ n =
  let simpleRegions = ["ADDISON", "RUTLAND", "BENNINGTON", "CHITTENDEN", "CALEDONIA", "ESSEX", "WASHINGTON", "FRANKLIN", "ORLEANS", "LAMOILLE", "ORANGE"]
      regionMap = (M.fromList $ zip (fmap (T.take 3) simpleRegions) simpleRegions)
                  <> M.fromList [("0GI","GRAND ISLE"), ("GI", "GRAND ISLE"), ("WDH", "WINDHAM"), ("ESX", "ESSEX"), ("WDR", "WINDSOR"), ("WSR", "WINDSOR")]
                  <> M.fromList [("N", "North"), ("C", "CENTRAL"), ("SE", "SOUTHEAST")]
      fixOne x = fromMaybe x $ M.lookup x regionMap
      fix = T.intercalate "-" . fmap fixOne . T.splitOn "-"
  in fix n

maNameFix :: GT.DistrictType -> Text -> Text
maNameFix GT.StateUpper n =
  let maSenateNames = [("D1", "Berkshire, Hampshire, Franklin And Hampden")
                      ,("D2", "Second Hampden And Hampshire")
                      ,("D3", "Hampden")
                      ,("D4", "First Hampden And Hampshire")
                      ,("D5", "Hampshire, Franklin And Worcester")
                      ,("D6", "Worcester, Hampden, Hampshire And Middlesex")
                      ,("D7", "Worcester And Norfolk")
                      ,("D8", "Second Worcester")
                      ,("D9", "First Worcester")
                      ,("D10", "Worcester And Middlesex")
                      ,("D11", "First Middlesex")
                      ,("D12", "Middlesex And Worcester")
                      ,("D13", "Second Middlesex And Worcester")
                      ,("D14", "Norfolk, Bristol And Middlesex")
                      ,("D15", "Third Middlesex")
                      ,("D16", "Fourth Middlesex")
                      ,("D17", "First Middlesex And Norfolk")
                      ,("D18", "Norfolk And Suffolk")
                      ,("D19", "First Essex")
                      ,("D20", "Second Essex And Middlesex")
                      ,("D21", "First Middlesex")
                      ,("D22", "Second Essex")
                      ,("D23", "Fifth Middlesex")
                      ,("D24", "Third Essex")
                      ,("D25", "First Suffolk And Middlesex")
                      ,("D26", "Middlesex And Suffolk")
                      ,("D27", "Second Middlesex")
                      ,("D28", "Second Suffolk And Middlesex")
                      ,("D29", "Second Suffolk")
                      ,("D30", "First Suffolk")
                      ,("D31", "Plymouth And Norfolk")
                      ,("D32", "Norfolk And Plymouth")
                      ,("D33", "Norfolk, Bristol And Plymouth")
                      ,("D34", "Second Plymouth And Bristol")
                      ,("D35", "Bristol And Norfolk")
                      ,("D36", "First Plymouth And Bristol")
                      ,("D37", "First Bristol And Plymouth")
                      ,("D38", "Second Bristol And Plymouth")
                      ,("D39", "Plymouth And Barnstable")
                      ,("D40", "Cape And Islands")
                      ]
  in maybe n T.toUpper $ M.lookup n $ M.fromList maSenateNames
maNameFix _ x = x

{-
tsModelConfig modelId n =  DTM3.ModelConfig True (DTM3.dmr modelId n)
                           DTM3.AlphaHierNonCentered DTM3.ThetaSimple DTM3.NormalDist


modeledACSBySLD :: forall r . (K.KnitEffects r, BRCC.CacheEffects r) => BR.CommandLine -> BRC.TableYear -> K.Sem r (K.ActionWithCacheTime r (DP.PSData SLDKeyR))
modeledACSBySLD cmdLine ty = do
  let (srcWindow, cachedSrc) = ACS.acs1Yr2012_22 @r
  (jointFromMarginalPredictorCSR_ASR_C, _) <- DDP.cachedACSa5ByPUMA srcWindow cachedSrc 2022 -- most recent available
                                              >>= DMC.predictorModel3 @'[DT.CitizenC] @'[DT.Age5C] @DMC.SRCA @DMC.SR
                                              (Right "CSR_ASR_ByPUMA")
                                              (Right "model/demographic/csr_asr_PUMA")
                                              (DTM3.Model $ tsModelConfig "CSR_ASR_ByPUMA" 71) -- use model not just mean
                                              False -- not whitened
                                              Nothing Nothing Nothing . fmap (fmap F.rcast)
  (jointFromMarginalPredictorCASR_ASE_C, _) <- DDP.cachedACSa5ByPUMA srcWindow cachedSrc 2022 -- most recent available
                                               >>= DMC.predictorModel3 @[DT.CitizenC, DT.Race5C] @'[DT.Education4C] @DMC.ASCRE @DMC.AS
                                               (Right "CASR_SER_ByPUMA")
                                               (Right "model/demographic/casr_ase_PUMA")
                                               (DTM3.Model $ tsModelConfig "CASR_ASE_ByPUMA" 141) -- use model not just mean
                                               False -- not whitened
                                               Nothing Nothing Nothing . fmap (fmap F.rcast)
  (acsCASERBySLD, _products) <- BRC.censusTablesForSLDs 2024 ty
                                >>= DMC.predictedCensusCASER' DMC.stateAbbrFromFIPS
                                (DTP.viaOptimalWeights DTP.euclideanFull 1e-4)
                                (Right "model/TSP/sldDemographics")
                                jointFromMarginalPredictorCSR_ASR_C
                                jo
                                intFromMarginalPredictorCASR_ASE_C
  BRCC.retrieveOrMakeD ("model/TSP/data/sldPSData" <> BRC.yearsText 2024 ty <> ".bin") acsCASERBySLD
    $ \x -> DP.PSData . fmap F.rcast <$> (BRL.addStateAbbrUsingFIPS $ F.filterFrame ((== DT.Citizen) . view DT.citizenC) x)
-}

type ASRR = '[BR.Year, GT.StateAbbreviation] V.++ BRC.LDLocationR V.++ [DT.Age6C, DT.SexC, BRC.RaceEthnicityC, DT.PopCount]

givenASRBySLD :: (K.KnitEffects r, BRCC.CacheEffects r) => BRC.TableYear -> K.Sem r (F.FrameRec ASRR)
givenASRBySLD ty = do
  asr <- BRC.ageSexRace <$> (K.ignoreCacheTimeM $ BRC.censusTablesForSLDs 2024 ty)
  asr' <- BRL.addStateAbbrUsingFIPS asr
  pure $ fmap F.rcast asr'
