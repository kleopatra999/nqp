{-# LANGUAGE GADTs, StandaloneDeriving, NoMonomorphismRestriction #-}
import Control.Monad
import qualified QAST
import Compiler.Hoopl
import Text.Groom
import qualified Data.Map as Map


type Result = Unique

data History = Unchanged QAST.Id | Replace QAST.Id

replace (Unchanged id) = Replace id
replace (Replace id) = Replace id

indent :: String -> String    
indent str = concat $ map (\line -> "  " ++ line ++ "\n") $ lines str



compileStmts :: [QAST.Node] -> SimpleUniqueMonad (Graph Insn O O, [Result])

compileStmts stmts = do
    (graphs, values) <- mapAndUnzipM compileStmt stmts
    return (catGraphs graphs, values)

compileStmt :: QAST.Node -> SimpleUniqueMonad (Graph Insn O O, Result)


compileStmt (QAST.Stmts stmts) = 
    compileStmts stmts >>= \(graph, values) ->
        if null values then do
            result <- freshUnique
            return (graph <*> (mkMiddle $ Void result), result)
        else
            return (graph, last values)


compileStmt (QAST.Op "say" args id) = do
    (graph, [value]) <- compileStmts args
    return (graph <*> (mkMiddle $ Say value (Unchanged id)), value)

compileStmt (QAST.Op "add_i" args id) = do
    result <- freshUnique
    (graph, [a, b]) <- compileStmts args
    return (graph <*> (mkMiddle $ AddI result a b (Unchanged id)), result)

compileStmt (QAST.IVal i id) = do
    result <- freshUnique
    return (mkMiddle $ IVal result i (Unchanged id), result)

compileStmt stmt = do
    result <- freshUnique
    return (mkMiddle $ Unknown (groom stmt), result)

data Insn e x where 
    Label :: Label -> Insn C O
    Branch :: Label -> Insn O C
    Unknown :: String -> Insn O O
    Say :: Result -> History -> Insn O O
    AddI :: Result -> Result -> Result -> History -> Insn O O
    IVal :: Result -> Int -> History -> Insn O O
    Void :: Result -> Insn O O
    Exit :: Insn O C

--deriving instance Show (Insn e x)

showResult :: Result -> String

showResult result = "$" ++ (show result)

assign :: Result -> String -> String
assign result rest = (showResult result) ++ " = " ++ rest

showHistory (Replace i) = " # replace " ++ (show i)
showHistory (Unchanged i) = "" -- " # unchanged " ++ (show i)

instance Show (Insn e x) where
    show (IVal result i history) = assign result $ show i ++ (showHistory history)
    show (AddI result a b history) = assign result $ (showResult a) ++ " + " ++ (showResult b) ++ (showHistory history)
    show (Void result) = assign result $ "void"
    show (Say what history) = "say " ++ (showResult what) ++ (showHistory history)
    show (Unknown string) = "unknown " ++ string
    show (Branch label) = "goto " ++ (show label)
    show (Label label) = "label " ++ (show label)
    show (Exit) = "exit"

instance HooplNode (Insn) where
    mkBranchNode = Branch
    mkLabelNode = Label

instance NonLocal (Insn) where
    successors (Branch label) = [label]
    successors (Exit) = []
    entryLabel (Label label) = label
   

prettyInsn :: Showing Insn

prettyInsn insn = show insn



compileCompUnit :: QAST.Node -> SimpleUniqueMonad (Graph Insn O O)
compileCompUnit (QAST.CompUnit [qastBlock]) = do 
    blockContents <- compileImplicitBlock qastBlock
    return blockContents --(blockContents <*> (mkLast Exit))

compileImplicitBlock :: QAST.Node -> SimpleUniqueMonad (Graph Insn O O)
compileImplicitBlock (QAST.Block nodes) = do
    (graph, values) <- compileStmts nodes
    return graph 

type ConstFact = Map.Map Result (WithTop Int)
constLattice :: DataflowLattice ConstFact
constLattice = DataflowLattice
    { fact_name = "Const result"
    , fact_bot = Map.empty
    , fact_join = joinMaps (extendJoinDomain constFactAdd)}
    where
        constFactAdd _ (OldFact old) (NewFact new)
            = if new == old then (NoChange, PElem new)
              else               (SomeChange, Top)

resultIsConst :: FwdTransfer Insn ConstFact
resultIsConst = mkFTransfer ft where
    ft :: Insn e x -> ConstFact -> Fact x ConstFact
    ft (Label _) f = f
    ft (Say _ _) f = f
    ft (Unknown _) f = f -- Unknown should make us forget everything
    ft (IVal result i _) f = Map.insert result (PElem i) f
    ft (AddI result _ _ _) f = Map.insert result Top f
    ft (Branch l) f = mapSingleton l f
--    ft (Exit) _ = mapEmpty

data Change = DeleteNode QAST.Id | ReplacementIVal QAST.Id Int
    deriving Show

changes :: Insn e x -> [Change]

changes (IVal _ i (Replace id)) = [ReplacementIVal id i]
changes _ = []



gatherChanges :: Graph Insn O O -> [Change]
gatherChanges graph = foldGraphNodes (\node thusFar -> thusFar ++ (changes node)) graph []

constProp :: FuelMonad m => FwdRewrite m Insn ConstFact

constProp = mkFRewrite3 noop1 cp noop2
    where 
       cp (AddI result a b history) f = case (lookup a f, lookup b f) of
            (Just n, Just m) -> return $ Just (mkMiddle $ IVal result (n+m) (replace history))
            _ -> return $ Nothing
       cp insn f = return $ Nothing
       noop1 insn f = return $ Nothing
       noop2 insn f = return $ Nothing
       lookup x f  = case Map.lookup x f of 
            Just (PElem x) -> Just $ x
            _ -> Nothing


constPropPass = FwdPass
    { fp_lattice = constLattice
    , fp_transfer = resultIsConst
    , fp_rewrite = constProp }


simpleRun :: SimpleFuelMonad a -> a

simpleRun = runSimpleUniqueMonad . runWithFuel infiniteFuel

main = do 
    input <- getContents
    let compUnit = ((read input) :: QAST.Node)
    putStrLn $ groom compUnit
    putStrLn "\n2 turned it into:\n"
    let graph = runSimpleUniqueMonad (compileCompUnit compUnit)

    let (optimized, _, _) = simpleRun $ analyzeAndRewriteFwdOx constPropPass graph Map.empty
    putStrLn $ showGraph prettyInsn graph

    putStrLn "\noptimized into:\n"


    putStrLn $ showGraph prettyInsn optimized

    putStrLn "\nlist of changes:\n"

    putStrLn $ "result " ++ (show $ gatherChanges optimized)