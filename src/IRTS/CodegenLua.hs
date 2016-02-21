module IRTS.CodegenLua(codegenLua) where

import IRTS.CodegenCommon
import IRTS.Lang
import IRTS.Simplified
import Idris.Core.TT as TT

import Data.Bits
import qualified Data.List as DL
import Data.Maybe
import Data.Char

import qualified Data.Text as T

import Language.Lua.PrettyPrinter
import Language.Lua as L

import Paths_idris_lua

-- import Text.PrettyPrint.Leijen

codegenLua :: CodeGenerator
codegenLua ci = do let out = Block (map doCodegen (simpleDecls ci) ++ [start]) Nothing
                   let decls = Block (map getFunName (simpleDecls ci)) Nothing
                   let src = decls `pasteBlocks` out
                   let code = render src
                   dir <- getDataDir
                   putStrLn dir
                   bilib <- readFile $ dir ++ "/rts/bigint.lua"
                   rtslib <- readFile $ dir ++ "/rts/rts.lua"
                   writeFile (outputFile ci) (bilib ++ rtslib ++ code)

render :: Block -> String
render s = displayS (renderPretty 0.4 150 (pprint s)) ""

start = funcall (luaName (sMN 0 "runMain")) []

variable s = PrefixExp $ PEVar $ VarName s
pfuncall f a = PrefixExp $ PEFunCall $ NormalFunCall (PEVar (VarName f)) (Args a)
funcall f a = FunCall $ NormalFunCall (PEVar (VarName f)) (Args a)
table t n = PrefixExp $ PEVar $ Select (PEVar (VarName t)) (number (n + 1))
number n = Number $ show n

luaName :: TT.Name -> String
luaName n = "idris_" ++ concatMap alphanum (showCG n)
  where alphanum x | isAlpha x || isDigit x = [x]
                   | otherwise = "_" ++ show (fromEnum x) ++ "_"

var :: TT.Name -> String
var (UN s) = T.unpack s

loc :: Int -> String
loc i = "loc" ++ show i

getFunName :: (TT.Name, SDecl) -> Stat
getFunName (n, _) = LocalAssign [luaName n] Nothing

doCodegen :: (TT.Name, SDecl) -> Stat
doCodegen (n, SFun _ args i def) = cgFun n args def

cgFun :: TT.Name -> [TT.Name] -> SExp -> Stat
cgFun n args def =
    FunAssign (FunName (luaName n) [] Nothing) (FunBody (map (loc . fst) (zip [0..] args)) False body)
            where
                doRet bs e = Block bs (Just [e])
                (locals, block) = cgBody doRet def
                meld xs (Block x e) = Block (xs++x) e
                maxArg = length args - 1
                body = (map local (DL.nub $ filter (> maxArg) locals))
                        `meld` block

--    = "function " ++ luaName n ++ "("
--                  ++ showSep "," (map (loc . fst) (zip [0..] args)) ++ ") {\n"
--                  ++ cgBody doRet def ++ "\n}\n\n"
--  where doRet :: String -> String -- Return the calculated expression
--        doRet str = "return " ++ str ++ ";"

-- cgBody converts the SExp into a chunk of php which calculates the result
-- of an expression, then runs the function on the resulting bit of code.
--
-- We do it this way because we might calculate an expression in a deeply nested
-- case statement, or inside a let, etc, so the assignment/return of the calculated
-- expression itself may happen quite deeply.
concatBody :: ([Int], Block) -> ([Int], Block) -> ([Int], Block)
concatBody (x, (Block b1 _)) (y, (Block b2 r)) = (x++y, Block (b1 ++ b2) r)

pasteBlocks :: Block -> Block -> Block
pasteBlocks (Block x1 _) (Block x2 e) = Block (x1++x2) e

local :: Int -> Stat
local n = LocalAssign [loc n] Nothing

addLocal :: Int -> ([Int], Block) -> ([Int], Block)
addLocal n (ls, b) = ((n:ls), b)

cgBody :: ([Stat] -> Exp -> Block) -> SExp -> ([Int], Block)
cgBody ret (SV (Glob n)) = ([], ret [] $ variable (luaName n))
cgBody ret (SV (Loc i)) = ([i], ret [] $ variable (loc i))
cgBody ret (SApp _ f args) = ([], ret [] $ pfuncall (luaName f)
                            (map (variable . cgVar) args))

cgBody ret (SLet (Loc i) v sc)
   = concatBody
        (addLocal i $ cgBody (\x y -> Block
                (x ++ [Assign [VarName $ loc i] [y]]) Nothing) v)
        (cgBody ret sc)
cgBody ret (SUpdate n e)
   = cgBody ret e
cgBody ret (SProj e i)
   = ([], ret [] $ table (cgVar e) i)
cgBody ret (SCon _ t n args)
   = ([], ret [] $ TableConst ((Field $ Number (show t)):(map (Field . variable . cgVar) args)))
cgBody ret (SCase _ e alts) = (concat locals, Block [If clauses Nothing] Nothing)
  where conCase (SConCase _ _ _ _ _) = True
        conCase _ = False
        scrvar = cgVar e
        scr = if any conCase alts then table scrvar 0 else variable scrvar
        (locals, clauses) = unzip $ map (cgAlt ret scrvar scr) alts
cgBody ret (SChkCase e alts)
   = ( concat locals, Block [If clauses Nothing] Nothing)
     where conCase (SConCase _ _ _ _ _) = True
           conCase _ = False
           scrvar = cgVar e
           scr = if any conCase alts then table scrvar 0 else variable scrvar
           (locals, clauses) = unzip $ map (cgAlt ret scrvar scr) alts
cgBody ret (SConst c) = ([], ret [] $ cgConst c)
cgBody ret (SOp op args) = ([], ret [] $ cgOp op (map (variable . cgVar) args))
cgBody ret SNothing = ([], ret [] $ Nil)
cgBody ret (SError x) = ([], ret [] $ String $ "error( " ++ show x ++ ")")
cgBody ret _ = ([], ret [] $ String $ "error(\"NOT IMPLEMENTED!!!!\")")

cgAlt :: ([Stat] -> Exp -> Block) -> String -> Exp -> SAlt -> ([Int], (Exp, Block))
cgAlt ret scr test (SConstCase t exp)
   = let (ls, block) = cgBody ret exp in
        (ls, (Binop L.EQ test (cgConst t), block))
cgAlt ret scr test (SDefaultCase exp) =
    let (ls, block) = cgBody ret exp in (ls, (L.Bool True, block))
cgAlt ret scr test (SConCase lv t n args exp)
    = (locals lv args ++ ls, (Binop L.EQ test (number t),
            project 1 lv args `meld` block))
   where project i v [] = []
         project i v (n : ns) = [Assign [VarName $ loc v] [table scr i]]
                            ++ project (i + 1) (v + 1) ns
         locals :: Int -> [a] -> [Int]
         locals v [] = []
         locals v (n:ns) = v:(locals (v+1) ns)
         (ls, block) = cgBody ret exp
         meld xs (Block x e) = Block (xs++x) e

cgVar :: LVar -> String
cgVar (Loc i) = loc i
cgVar (Glob n) = var n

cgConst :: Const -> Exp
cgConst (I i) = number i
cgConst (Fl f) = number f
cgConst (Ch i) = number (ord i)
cgConst (BI i) = pfuncall "bigint" [String $ show i]
cgConst (TT.Str s) = String $ show s
cgConst (B8 b) = number b
cgConst (B16 b) = number b
cgConst (B32 b) = number b
cgConst (B64 b) | b < 2^50 = pfuncall "bigint" [number b]
                | otherwise = pfuncall "bigint" [String $ show b]
cgConst TheWorld = String "0"
cgConst x | isTypeConst x = String "0"
cgConst x = error $ "Constant " ++ show x ++ " not compilable yet"

luaAbs :: Exp -> Exp
luaAbs x = pfuncall "math.abs" [x]

boolInt :: Exp -> Exp
boolInt x = pfuncall "boolint" [x]

cap :: IntTy -> Exp -> Exp
cap (ITFixed IT64) x = Binop Mod x $ pfuncall "bigint" [String $ show (2^64)]
cap (ITFixed b) x = Binop Mod x $ number (2^(nativeTyWidth b))
cap _ x = x

capa :: ArithTy -> Exp -> Exp
capa (ATInt i) x = cap i x
capa _ x = x

cgOp :: PrimFn -> [Exp] -> Exp
cgOp (LPlus t) [l, r]
     = capa t $ Binop Add l r
cgOp (LMinus t) [l, r]
     = capa t $ Binop Sub l r
cgOp (LTimes t) [l, r]
     = capa t $ Binop Mul l r
cgOp (LUDiv i) [l, r]
     = cap i $ Binop IDiv (luaAbs l) (luaAbs r)
cgOp (LSDiv (ATInt i)) [l, r]
     = cap i $ Binop IDiv l r
cgOp (LSDiv ATFloat) [l, r]
     = Binop Div l r
cgOp (LURem i) [l, r]
     = cap i $ Binop Mod (luaAbs l) (luaAbs r)
cgOp (LSRem t) [l, r]
     = capa t $ Binop Mod l r
cgOp (LAnd i) [l, r]
     = cap i $Binop BAnd l r
cgOp (LOr i) [l, r]
     = cap i $ Binop BOr l r
cgOp (LXOr i) [l, r]
     = cap i $ Binop BXor l r
cgOp (LCompl i) [b]
     = cap i $ Unop Complement b
cgOp (LSHL i) [l, r]
     = cap i $ Binop ShiftL l r
cgOp (LLSHR i) [l, r]
     = cap i $ Binop ShiftR l r
cgOp (LASHR i) [l, r]
     = cap i $ Binop ShiftR l r
cgOp (LEq _) [l, r]
     = boolInt $ Binop L.EQ l r
cgOp (LLt _) [l, r]
     = boolInt $ Binop L.LT l r
cgOp (LLe _) [l, r]
     = boolInt $ Binop LTE l r
cgOp (LGt _) [l, r]
     = boolInt $ Binop L.GT l r
cgOp (LSLt _) [l, r]
     = boolInt $ Binop L.LT l r
cgOp (LSLe _) [l, r]
     = boolInt $ Binop LTE l r
cgOp (LSGt _) [l, r]
     = boolInt $ Binop L.GT l r
cgOp (LSGe _) [l, r]
     = boolInt $ Binop GTE l r
cgOp (LSExt _ _) [x] = x
cgOp (LZExt _ _) [x] = x
cgOp (LTrunc _ i) [x] = cap i x
cgOp LStrConcat [l,r] = Binop Concat l r
cgOp LStrLt [l,r] = boolInt $ Binop L.LT l r
cgOp LStrEq [l,r] = boolInt $ Binop L.EQ l r
cgOp LStrLen [x] = pfuncall "string.len" [x]
cgOp (LIntFloat _) [x] = x
cgOp (LFloatInt _) [x] = x
cgOp (LIntStr _) [x] = pfuncall "tostring" [x]
cgOp (LStrInt ITBig) [x] = pfuncall "bigint" [x]
cgOp (LStrInt _) [x] = pfuncall "tonumber" [x]
cgOp LFloatStr [x] = pfuncall "tostring" [x]
cgOp LStrFloat [x] = pfuncall "tonumber" [x]
cgOp (LChInt _) [x] = x
cgOp (LIntCh _) [x] = x
cgOp (LBitCast _ _) [x] = x

cgOp LFExp [x] = pfuncall "math.exp" [x]
cgOp LFLog [x] = pfuncall "math.log" [x]
cgOp LFSin [x] = pfuncall "math.sin" [x]
cgOp LFCos [x] = pfuncall "math.cos" [x]
cgOp LFTan [x] = pfuncall "math.tan" [x]
cgOp LFASin [x] = pfuncall "math.asin" [x]
cgOp LFACos [x] = pfuncall "math.acos" [x]
cgOp LFATan [x] = pfuncall "math.atan" [x]
cgOp LFSqrt [x] = pfuncall "math.sqrt" [x]
cgOp LFFloor [x] = pfuncall "math.floor" [x]
cgOp LFCeil [x] = pfuncall "math.ceil" [x]
cgOp LFNegate [x] = Unop Neg x

cgOp LStrHead [x] = pfuncall "string.byte" [x, number 1]
cgOp LStrTail [x] = pfuncall "string.sub" [x, number 2]
cgOp LStrCons [l,r] = Binop Concat (pfuncall "string.char" [l]) r
cgOp LStrIndex [x, y] = pfuncall "string.byte" [pfuncall "string.sub" [x, Binop Add y (number 1), Binop Add y (number 2)], number 1]
cgOp LStrRev [x] = pfuncall "string.reverse" [x]
cgOp LStrSubstr [x, y, z] = pfuncall "string.sub" [x, Binop Add y (number 1), Binop Add z (number 1)]

cgOp LWriteStr [_,s] = pfuncall "print" [s]
cgOp LReadStr [_] = pfuncall "io.read" []

cgOp LSystemInfo [x] = pfuncall "print" [String "No!"]

-- cgOp LFork
-- cgOp LPar
-- cgOp (LExternal n)
-- cgOp LNoOp
cgOp op exps = pfuncall "print" [String $ "error(\"OPERATOR " ++ show op ++ " NOT IMPLEMENTED!!!!\")"]
   -- error("Operator " ++ show op ++ " not implemented")
