%
% (c) The AQUA Project, Glasgow University, 1993-1996
%
\section[SimplEnv]{Environment stuff for the simplifier}

\begin{code}
#include "HsVersions.h"

module SimplEnv (
	nullSimplEnv,
	pprSimplEnv, -- debugging only

	replaceInEnvs, nullInEnvs,

	extendTyEnv, extendTyEnvList,
	simplTy, simplTyInId,

	extendIdEnvWithAtom, extendIdEnvWithAtomList,
	extendIdEnvWithInlining,
	extendIdEnvWithClone, extendIdEnvWithClones,
	lookupId,

	extendUnfoldEnvGivenRhs,
	extendUnfoldEnvGivenFormDetails,
	extendUnfoldEnvGivenConstructor,
	lookForConstructor,
	lookupUnfolding, filterUnfoldEnvForInlines,

	getSwitchChecker, switchIsSet,

	setEnclosingCC,

	-- Types
	SwitchChecker(..),
	SimplEnv, EnclosingCcDetails(..),
	InIdEnv(..), IdVal(..), InTypeEnv(..),
	UnfoldEnv, UnfoldItem, UnfoldConApp,

	InId(..),  InBinder(..),  InBinding(..),  InType(..),
	OutId(..), OutBinder(..), OutBinding(..), OutType(..),

	InExpr(..),  InAlts(..),  InDefault(..),  InArg(..),
	OutExpr(..), OutAlts(..), OutDefault(..), OutArg(..)
    ) where

import Ubiq{-uitous-}

import SmplLoop		-- breaks the MagicUFs / SimplEnv loop

import BinderInfo	( BinderInfo{-instances-} )
import CgCompInfo	( uNFOLDING_CREATION_THRESHOLD )
import CmdLineOpts	( switchIsOn, intSwitchSet, SimplifierSwitch(..), SwitchResult )
import CoreSyn
import CoreUnfold	( UnfoldingDetails(..), mkGenForm, modifyUnfoldingDetails,
			  calcUnfoldingGuidance, UnfoldingGuidance(..),
			  mkFormSummary, FormSummary
			)
import CoreUtils	( manifestlyWHNF )
import FiniteMap	-- lots of things
import Id		( idType, getIdUnfolding, getIdStrictness,
			  applyTypeEnvToId,
			  nullIdEnv, growIdEnvList, rngIdEnv, lookupIdEnv,
			  addOneToIdEnv, modifyIdEnv,
			  IdEnv(..), IdSet(..), GenId )
import IdInfo		( bottomIsGuaranteed, StrictnessInfo )
import Literal		( isNoRepLit, Literal{-instances-} )
import Name		( isLocallyDefined )
import OccurAnal	( occurAnalyseExpr )
import Outputable	( Outputable(..){-instances-} )
import PprCore		-- various instances
import PprStyle		( PprStyle(..) )
import PprType		( GenType, GenTyVar )
import Pretty
import Type		( getAppDataTyCon, applyTypeEnvToTy )
import TyVar		( nullTyVarEnv, addOneToIdEnv, addOneToTyVarEnv,
			  growTyVarEnvList,
			  TyVarEnv(..), GenTyVar{-instance Eq-}
			)
import Unique		( Unique{-instance Outputable-} )
import UniqFM		( addToUFM_Directly, lookupUFM_Directly, ufmToList )
import UniqSet		-- lots of things
import Usage		( UVar(..), GenUsage{-instances-} )
import Util		( zipEqual, panic, assertPanic )

type TypeEnv = TyVarEnv Type
cmpType = panic "cmpType (SimplEnv)"
exprSmallEnoughToDup = panic "exprSmallEnoughToDup (SimplEnv)"
oneSafeOcc = panic "oneSafeOcc (SimplEnv)"
oneTextualOcc = panic "oneTextualOcc (SimplEnv)"
simplIdWantsToBeINLINEd = panic "simplIdWantsToBeINLINEd (SimplEnv)"
\end{code}

%************************************************************************
%*									*
\subsection[Simplify-types]{Type declarations}
%*									*
%************************************************************************


%************************************************************************
%*									*
\subsubsection{The @SimplEnv@ type}
%*									*
%************************************************************************


INVARIANT: we assume {\em no shadowing}.  (ToDo: How can we ASSERT
this? WDP 94/06) This allows us to neglect keeping everything paired
with its static environment.

The environment contains bindings for all
	{\em in-scope,}
	{\em locally-defined}
things.

For such things, any unfolding is found in the environment, not in the
Id.  Unfoldings in the Id itself are used only for imported things
(otherwise we get trouble because we have to simplify the unfoldings
inside the Ids, etc.).

\begin{code}
data SimplEnv
  = SimplEnv
	SwitchChecker

	EnclosingCcDetails -- the enclosing cost-centre (when profiling)

	InTypeEnv	-- For cloning types
			-- Domain is all in-scope type variables

	InIdEnv		-- IdEnv
			-- Domain is
			-- 	*all*
			-- 	*in-scope*,
			--	*locally-defined*
			-- 	*InIds*
			-- (Could omit the exported top-level guys,
			-- since their names mustn't change; and ditto
			-- the non-exported top-level guys which you
			-- don't want to macro-expand, since their
			-- names need not change.)
			--
			-- Starts off empty

	UnfoldEnv	-- Domain is any *OutIds*, including imports
			-- where we know something more than the
			-- interface file tells about their value (see
			-- below)

nullSimplEnv :: SwitchChecker -> SimplEnv

nullSimplEnv sw_chkr
  = SimplEnv sw_chkr NoEnclosingCcDetails nullTyVarEnv nullIdEnv null_unfold_env

pprSimplEnv (SimplEnv _ _ ty_env id_env (UFE unfold_env _ _))
  = ppAboves [
	ppStr "** Type Env ** ????????", -- ppr PprDebug ty_env,
	ppSP, ppStr "** Id Env ** ?????????",
--	ppAboves [ pp_id_entry x | x <- getIdEnvMapping id_env ],
	ppSP, ppStr "** Unfold Env **",
	ppAboves [ pp_uf_entry x | x <- rngIdEnv unfold_env ]
    ]
  where
    pp_id_entry (v, idval)
      = ppCat [ppr PprDebug v, ppStr "=>",
	       case idval of
		 InlineIt _ _ e -> ppCat [ppStr "InlineIt:", ppr PprDebug e]
		 ItsAnAtom a    -> ppCat [ppStr "Atom:", ppr PprDebug a]
	      ]

    pp_uf_entry (UnfoldItem v form encl_cc)
      = ppCat [ppr PprDebug v, ppStr "=>",
	       case form of
		 NoUnfoldingDetails -> ppStr "NoUnfoldingDetails"
		 LitForm l -> ppCat [ppStr "Lit:", ppr PprDebug l]
		 OtherLitForm ls -> ppCat [ppStr "Other lit:", ppInterleave (ppStr ", ")
						               [ppr PprDebug l | l <- ls]]
		 ConForm c a     -> ppCat [ppStr "Con:", ppr PprDebug c, ppr PprDebug a]
		 OtherConForm cs -> ppCat [ppStr "OtherCon:", ppInterleave (ppStr ", ")
							      [ppr PprDebug c | c <- cs]]
		 GenForm t w e g -> ppCat [ppStr "UF:",	ppr PprDebug t,	ppr PprDebug w,
							ppr PprDebug g, ppr PprDebug e]
		 MagicForm s _   -> ppCat [ppStr "Magic:", ppr PprDebug s]
	      ]
\end{code}

%************************************************************************
%*									*
\subsubsection{The @IdVal@ type (for the ``IdEnv'')}
%*									*
%************************************************************************

The unfoldings for imported things are mostly kept within the Id
itself; nevertheless, they {\em can} get into the @UnfoldEnv@.  For
example, suppose \tr{x} is imported, and we have
\begin{verbatim}
	case x of
	  (p,q) -> <body>
\end{verbatim}
Then within \tr{<body>}, we know that \tr{x} is a pair with components
\tr{p} and \tr{q}.

\begin{code}
type InIdEnv = IdEnv IdVal	-- Maps InIds to their value

data IdVal
  = InlineIt InIdEnv InTypeEnv InExpr
		-- No binding of the Id is left;
		-- You *have* to replace any occurences
		-- of the id with this expression.
		-- Rather like a macro, really
		-- NB: the InIdEnv/InTypeEnv is necessary to prevent
		-- name caputure. Consider:
		--	let y = ...
		--	    x = ...y...
		-- 	    y = ...
		--	in ...x...
		-- If x gets an InlineIt, we must remember
		-- the correct binding for y.

  | ItsAnAtom OutArg	-- Used either (a) to record the cloned Id
			-- or (b) if the orig defn is a let-binding, and
			-- the RHS of the let simplifies to an atom,
			-- we just bind the variable to that atom, and
			-- elide the let.
\end{code}

%************************************************************************
%*									*
\subsubsection{The @UnfoldEnv@ type}
%*									*
%************************************************************************

The @UnfoldEnv@ contains information about the value of some of the
in-scope identifiers.  It obeys the following invariant:

	If the @UnfoldEnv@ contains information, it is safe to use it!

In particular, if the @UnfoldEnv@ contains details of an unfolding of
an Id, then it's safe to use the unfolding.  If, for example, the Id
is used many times, then its unfolding won't be put in the UnfoldEnv
at all.

The @UnfoldEnv@ (used to be [WDP 94/06]) a simple association list
because (a)~it's small, and (b)~we need to search its {\em range} as
well as its domain.

\begin{code}
data UnfoldItem -- a glorified triple...
  = UnfoldItem	OutId			-- key: used in lookForConstructor
		UnfoldingDetails	-- for that Id
		EnclosingCcDetails	-- so that if we do an unfolding,
					-- we can "wrap" it in the CC
					-- that was in force.

data UnfoldConApp -- yet another glorified triple
  = UCA		OutId			-- same fields as ConForm
		[OutArg]

data UnfoldEnv	-- yup, a glorified triple...
  = UFE		(IdEnv UnfoldItem)	-- Maps an OutId => its UnfoldItem
		IdSet			-- The Ids in the domain of the env
					-- which have details (GenForm True ...)
					-- i.e., they claim they are duplicatable.
					-- These are the ones we have to worry
					-- about when adding new items to the
					-- unfold env.
		(FiniteMap UnfoldConApp OutId)
					-- Maps applications of constructors (to
					-- types & atoms) back to OutIds that are
					-- bound to them; i.e., this is a reversed
					-- mapping for (part of) the main IdEnv
					-- (1st part of UFE)

null_unfold_env = UFE nullIdEnv emptyUniqSet emptyFM
\end{code}

The @UnfoldEnv@ type.  We expect on the whole that an @UnfoldEnv@ will
be small, because it contains bindings only for those things whose
form or unfolding is known.  Basically it maps @Id@ to their
@UnfoldingDetails@ (and @EnclosingCcDetails@---boring...), but we also
need to search it associatively, to look for @Id@s which have a given
constructor form.

We implement it with @IdEnvs@, possibly overkill, but sometimes these
things silently grow quite big....  Here are some local functions used
elsewhere in the module:

\begin{code}
grow_unfold_env   :: UnfoldEnv -> OutId -> UnfoldingDetails -> EnclosingCcDetails -> UnfoldEnv
lookup_unfold_env :: UnfoldEnv -> OutId -> UnfoldingDetails
lookup_unfold_env_encl_cc
		  :: UnfoldEnv -> OutId -> EnclosingCcDetails

grow_unfold_env full_u_env id NoUnfoldingDetails _ = full_u_env

grow_unfold_env (UFE u_env interesting_ids con_apps) id
		uf_details@(GenForm True _ _ _) encl_cc
    -- Only interested in Ids which have a "dangerous" unfolding; that is
    -- one that claims to have a single occurrence.
  = UFE (addOneToIdEnv u_env id (UnfoldItem id uf_details encl_cc))
	(addOneToUniqSet interesting_ids id)
	con_apps

grow_unfold_env (UFE u_env interesting_ids con_apps) id uf_details encl_cc
  = UFE (addOneToIdEnv u_env id (UnfoldItem id uf_details encl_cc))
	interesting_ids
	new_con_apps
  where
    new_con_apps
      = case uf_details of
	  ConForm con vargs
	    -> case (lookupFM con_apps entry) of
		 Just _  -> con_apps -- unchanged; we hang onto what we have
		 Nothing -> addToFM con_apps entry id
	    where
	      entry = UCA con vargs

	  not_a_constructor -> con_apps -- unchanged

addto_unfold_env (UFE u_env interesting_ids con_apps) extra_items
  = ASSERT(not (any constructor_form_in_those extra_items))
    -- otherwise, we'd need to change con_apps
    UFE (growIdEnvList u_env extra_items) interesting_ids con_apps
  where
    constructor_form_in_those (_, UnfoldItem _ (ConForm _ _) _) = True
    constructor_form_in_those _ = False

rng_unfold_env (UFE u_env _ _) = rngIdEnv u_env

get_interesting_ids (UFE _ interesting_ids _) = interesting_ids

foldr_unfold_env fun (UFE u_env interesting_ids con_apps) stuff
  = UFE (foldr fun u_env stuff) interesting_ids con_apps

lookup_unfold_env (UFE u_env _ _) id
  = case (lookupIdEnv u_env id) of
      Nothing		       -> NoUnfoldingDetails
      Just (UnfoldItem _ uf _) -> uf

lookup_unfold_env_encl_cc (UFE u_env _ _) id
  = case (lookupIdEnv u_env id) of
      Nothing	    	    	    -> NoEnclosingCcDetails
      Just (UnfoldItem _ _ encl_cc) -> encl_cc

lookup_conapp (UFE _ _ con_apps) con args
  = lookupFM con_apps (UCA con args)

modify_unfold_env (UFE u_env interesting_ids con_apps) zapper id
  = UFE (modifyIdEnv u_env zapper id) interesting_ids con_apps

-- If the current binding claims to be a "unique" one, then
-- we modify it.
modifyItem :: Bool -> BinderInfo -> UnfoldItem -> UnfoldItem

modifyItem ok_to_dup occ_info (UnfoldItem id details enc_cc)
  = UnfoldItem id (modifyUnfoldingDetails ok_to_dup occ_info details) enc_cc
\end{code}

The main thing about @UnfoldConApp@ is that it has @Ord@ defined on
it, so we can use it for a @FiniteMap@ key.
\begin{code}
instance Eq  UnfoldConApp where
    a == b = case cmp_app a b of { EQ_ -> True;   _ -> False }
    a /= b = case cmp_app a b of { EQ_ -> False;  _ -> True  }

instance Ord UnfoldConApp where
    a <= b = case cmp_app a b of { LT_ -> True;  EQ_ -> True;  GT__ -> False }
    a <  b = case cmp_app a b of { LT_ -> True;  EQ_ -> False; GT__ -> False }
    a >= b = case cmp_app a b of { LT_ -> False; EQ_ -> True;  GT__ -> True  }
    a >  b = case cmp_app a b of { LT_ -> False; EQ_ -> False; GT__ -> True  }
    _tagCmp a b = case cmp_app a b of { LT_ -> _LT; EQ_ -> _EQ; GT__ -> _GT }

instance Ord3 UnfoldConApp where
    cmp = cmp_app

cmp_app (UCA c1 as1) (UCA c2 as2)
  = case (c1 `cmp` c2) of
      LT_ -> LT_
      GT_ -> GT_
      _   -> cmp_lists cmp_atom as1 as2
  where
    cmp_lists cmp_item []     []     = EQ_
    cmp_lists cmp_item (x:xs) []     = GT_
    cmp_lists cmp_item []     (y:ys) = LT_
    cmp_lists cmp_item (x:xs) (y:ys)
      = case cmp_item x y of { EQ_ -> cmp_lists cmp_item xs ys; other -> other }

    cmp_atom (VarArg x) (VarArg y) = x `cmp` y
    cmp_atom (VarArg _) _		 = LT_
    cmp_atom (LitArg x) (LitArg y)
      = case _tagCmp x y of { _LT -> LT_; _EQ -> EQ_; GT__ -> GT_ }
    cmp_atom (LitArg _) _		 = GT_
\end{code}

%************************************************************************
%*									*
\subsubsection{The @EnclosingCcDetails@ type}
%*									*
%************************************************************************

\begin{code}
data EnclosingCcDetails
  = NoEnclosingCcDetails
  | EnclosingCC	    CostCentre
\end{code}

%************************************************************************
%*									*
\subsubsection{The ``InXXX'' and ``OutXXX'' type synonyms}
%*									*
%************************************************************************

\begin{code}
type InId      = Id			-- Not yet cloned
type InBinder  = (InId, BinderInfo)
type InType    = Type			-- Ditto
type InBinding = SimplifiableCoreBinding
type InExpr    = SimplifiableCoreExpr
type InAlts    = SimplifiableCoreCaseAlts
type InDefault = SimplifiableCoreCaseDefault
type InArg     = SimplifiableCoreArg

type OutId	= Id			-- Cloned
type OutBinder	= Id
type OutType	= Type			-- Cloned
type OutBinding	= CoreBinding
type OutExpr	= CoreExpr
type OutAlts	= CoreCaseAlts
type OutDefault	= CoreCaseDefault
type OutArg	= CoreArg

\end{code}

\begin{code}
type SwitchChecker = SimplifierSwitch -> SwitchResult
\end{code}

%************************************************************************
%*									*
\subsection{@SimplEnv@ handling}
%*									*
%************************************************************************

%************************************************************************
%*									*
\subsubsection{Command-line switches}
%*									*
%************************************************************************

\begin{code}
getSwitchChecker :: SimplEnv -> SwitchChecker
getSwitchChecker (SimplEnv chkr _ _ _ _) = chkr

switchIsSet :: SimplEnv -> SimplifierSwitch -> Bool
switchIsSet (SimplEnv chkr _ _ _ _) switch
  = switchIsOn chkr switch
\end{code}

%************************************************************************
%*									*
\subsubsection{The ``enclosing cost-centre''}
%*									*
%************************************************************************

\begin{code}
setEnclosingCC :: SimplEnv -> EnclosingCcDetails -> SimplEnv

setEnclosingCC (SimplEnv chkr _ ty_env id_env unfold_env) encl_cc
  = SimplEnv chkr encl_cc ty_env id_env unfold_env
\end{code}

%************************************************************************
%*									*
\subsubsection{The @TypeEnv@ part}
%*									*
%************************************************************************

\begin{code}
type InTypeEnv = TypeEnv	-- Maps InTyVars to OutTypes

extendTyEnv :: SimplEnv -> TyVar -> Type -> SimplEnv
extendTyEnv (SimplEnv chkr encl_cc ty_env id_env unfold_env) tyvar ty
  = SimplEnv chkr encl_cc new_ty_env id_env unfold_env
  where
    new_ty_env = addOneToTyVarEnv ty_env tyvar ty

extendTyEnvList :: SimplEnv -> [(TyVar,Type)] -> SimplEnv
extendTyEnvList (SimplEnv chkr encl_cc ty_env id_env unfold_env) pairs
  = SimplEnv chkr encl_cc new_ty_env id_env unfold_env
  where
    new_ty_env = growTyVarEnvList ty_env pairs

simplTy     (SimplEnv _ _ ty_env _ _) ty = applyTypeEnvToTy ty_env ty
simplTyInId (SimplEnv _ _ ty_env _ _) id = applyTypeEnvToId ty_env id
\end{code}

@replaceInEnvs@ is used to install saved type and id envs
when pulling an un-simplified expression out of the environment, which
was saved with its environments.

\begin{code}
nullInEnvs = (nullTyVarEnv, nullIdEnv) :: (InTypeEnv,InIdEnv)

replaceInEnvs :: SimplEnv -> (InTypeEnv,InIdEnv) -> SimplEnv

replaceInEnvs (SimplEnv chkr encl_cc ty_env id_env unfold_env)
	      (new_ty_env, new_id_env)
  = SimplEnv chkr encl_cc new_ty_env new_id_env unfold_env
\end{code}

%************************************************************************
%*									*
\subsubsection{The ``Id env'' part}
%*									*
%************************************************************************

\begin{code}
extendIdEnvWithAtom
	:: SimplEnv
	-> InBinder -> OutArg
	-> SimplEnv

extendIdEnvWithAtom (SimplEnv chkr encl_cc ty_env id_env unfold_env) (in_id,occ_info) atom@(LitArg lit)
  = SimplEnv chkr encl_cc ty_env new_id_env unfold_env
  where
    new_id_env = addOneToIdEnv id_env in_id (ItsAnAtom atom)

extendIdEnvWithAtom (SimplEnv chkr encl_cc ty_env id_env unfold_env)
	    (in_id, occ_info) atom@(VarArg out_id)
  = SimplEnv chkr encl_cc ty_env new_id_env new_unfold_env
  where
    new_id_env = addOneToIdEnv id_env in_id (ItsAnAtom atom)

    new_unfold_env = modify_unfold_env
			unfold_env
			(modifyItem ok_to_dup occ_info)
			out_id
		-- Modify binding for in_id
		-- NO! modify out_id, because its the info on the
		-- atom that interest's us.

    ok_to_dup    = switchIsOn chkr SimplOkToDupCode

extendIdEnvWithAtomList
	:: SimplEnv
	-> [(InBinder, OutArg)]
	-> SimplEnv
extendIdEnvWithAtomList = foldr (\ (bndr,val) env -> extendIdEnvWithAtom env bndr val)

extendIdEnvWithInlining
	:: SimplEnv		-- The Env to modify
	-> SimplEnv		-- The Env to record in the inlining.  Usually the
				-- same as the previous one, except in the recursive case
	-> InBinder -> InExpr
	-> SimplEnv

extendIdEnvWithInlining (SimplEnv chkr encl_cc ty_env        id_env        unfold_env)
			~(SimplEnv _   _       inline_ty_env inline_id_env _         )
			(in_id,occ_info)
			expr
  = SimplEnv chkr encl_cc ty_env new_id_env unfold_env
  where
    new_id_env = addOneToIdEnv id_env in_id (InlineIt inline_id_env inline_ty_env expr)

extendIdEnvWithClone
	:: SimplEnv
	-> InBinder	-- Old binder; binderinfo ignored
	-> OutId	-- Its new clone, as an Id
	-> SimplEnv

extendIdEnvWithClone (SimplEnv chkr encl_cc ty_env id_env unfold_env)
	(in_id,_) out_id
  = SimplEnv chkr encl_cc ty_env new_id_env unfold_env
  where
    new_id_env = addOneToIdEnv id_env in_id (ItsAnAtom (VarArg out_id))

extendIdEnvWithClones	-- Like extendIdEnvWithClone
	:: SimplEnv
	-> [InBinder]
	-> [OutId]
	-> SimplEnv

extendIdEnvWithClones (SimplEnv chkr encl_cc ty_env id_env unfold_env)
	in_binders out_ids
  = SimplEnv chkr encl_cc ty_env new_id_env unfold_env
  where
    new_id_env = growIdEnvList id_env (in_ids `zipEqual` out_vals)
    in_ids     = [id | (id,_) <- in_binders]
    out_vals   = [ItsAnAtom (VarArg out_id) | out_id <- out_ids]

lookupId :: SimplEnv -> Id -> Maybe IdVal

lookupId (SimplEnv _ _ _ id_env _) id
#ifndef DEBUG
  = lookupIdEnv id_env id
#else
  = case (lookupIdEnv id_env id) of
      xxx@(Just _) -> xxx
      xxx	   -> --false!: ASSERT(not (isLocallyDefined id))
		      xxx
#endif
\end{code}

%************************************************************************
%*									*
\subsubsection{The @UnfoldEnv@}
%*									*
%************************************************************************

\begin{code}
extendUnfoldEnvGivenFormDetails
	:: SimplEnv
	-> OutId
	-> UnfoldingDetails
	-> SimplEnv

extendUnfoldEnvGivenFormDetails
	env@(SimplEnv chkr encl_cc ty_env id_env unfold_env)
	id details
  = case details of
      NoUnfoldingDetails -> env
      good_details	 -> SimplEnv chkr encl_cc ty_env id_env new_unfold_env
	where
	  new_unfold_env = grow_unfold_env unfold_env id good_details encl_cc

extendUnfoldEnvGivenConstructor -- specialised variant
	:: SimplEnv
	-> OutId		-- bind this to...
	-> Id -> [OutId]	-- "con <tys-to-be-invented> args"
	-> SimplEnv

extendUnfoldEnvGivenConstructor env var con args
  = let
	-- conjure up the types to which the con should be applied
	scrut_ty	= idType var
	(_, ty_args, _) = getAppDataTyCon scrut_ty
    in
    extendUnfoldEnvGivenFormDetails
      env var (ConForm con (map VarArg args))
\end{code}


@extendUnfoldEnvGivenRhs@ records in the UnfoldEnv info about the RHS
of a new binding.  There is a horrid case we have to take care about,
due to Andr\'e Santos:
@
    type Array_type b   = Array Int b;
    type Descr_type     = (Int,Int);

    tabulate      :: (Int -> x) -> Descr_type -> Array_type x;
    tabulate      f (l,u)             = listArray (l,u) [f i | i <- [l..u]];

    f_iaamain a_xs=
	let {
	    f_aareorder::(Array_type Int) -> (Array_type t1) -> Array_type t1;
	    f_aareorder a_index a_ar=
		let {
		    f_aareorder' a_i= a_ar ! (a_index ! a_i)
		 } in  tabulate f_aareorder' (bounds a_ar);
	    r_index=tabulate ((+) 1) (1,1);
	    arr    = listArray (1,1) a_xs;
	    arg    = f_aareorder r_index arr
	 } in  elems arg
@
Now, when the RHS of arg gets simplified, we inline f_aareorder to get
@
	arg  = let f_aareorder' a_i = arr ! (r_index ! a_i)
	       in tabulate f_aareorder' (bounds arr)
@
Note that r_index is not inlined, because it was bound to a_index which
occurs inside a lambda.

Alas, if elems is inlined, so that (elems arg) becomes (case arg of ...),
then arg is inlined. IF WE USE THE NEW VERSION OF arg, and re-occurrence
analyse it, we won't spot the inside-lambda property of r_index, so r_index
will get inlined inside the lambda.  AARGH.

Solution: when we occurrence-analyse the new RHS we have to go back
and modify the info recorded in the UnfoldEnv for the free vars
of the RHS.  In the example we'd go back and record that r_index is now used
inside a lambda.

\begin{code}
extendUnfoldEnvGivenRhs
	:: SimplEnv
	-> InBinder
	-> OutId	-- Note: *must* be an "out" Id (post-cloning)
	-> OutExpr	-- Its rhs (*simplified*)
	-> SimplEnv

extendUnfoldEnvGivenRhs env@(SimplEnv chkr encl_cc ty_env id_env unfold_env)
			binder@(_,occ_info) out_id rhs
  = SimplEnv chkr encl_cc ty_env id_env new_unfold_env
  where
	-- Occurrence-analyse the RHS
    (fv_occ_info, template) = occurAnalyseExpr {-test:nullIdEnv-} interesting_fvs rhs

    interesting_fvs = get_interesting_ids unfold_env

	-- Compute unfolding details
    details = case rhs of
		Var v			   -> panic "Vars already dealt with"
		Lit lit | isNoRepLit lit -> LitForm lit
			  | otherwise	   -> panic "non-noRep Lits already dealt with"

		Con con args 		   -> ConForm con args

		other -> mkGenForm ok_to_dup occ_info
				   (mkFormSummary (getIdStrictness out_id) rhs)
				   template guidance

	-- Compute resulting unfold env
    new_unfold_env = case details of
			NoUnfoldingDetails	-> unfold_env
			GenForm _ _ _ _	-> unfold_env2{-test: unfold_env1 -}
			other			-> unfold_env1

	-- Add unfolding to unfold env
    unfold_env1 = grow_unfold_env unfold_env out_id details encl_cc

	-- Modify unfoldings of free vars of rhs, based on their
	-- occurrence info in the rhs [see notes above]
    unfold_env2 = foldr_unfold_env modify unfold_env1 (ufmToList fv_occ_info)

    modify :: (Unique, BinderInfo) -> IdEnv UnfoldItem -> IdEnv UnfoldItem
    modify (u, occ_info) env
      = case (lookupUFM_Directly env u) of
	  Nothing -> env -- ToDo: can this happen?
	  Just xx -> addToUFM_Directly env u (modifyItem ok_to_dup occ_info xx)

	-- Compute unfolding guidance
    guidance = if simplIdWantsToBeINLINEd out_id env
	       then UnfoldAlways
	       else calcUnfoldingGuidance True{-sccs OK-} bOMB_OUT_SIZE rhs

    bOMB_OUT_SIZE = case (intSwitchSet chkr SimplUnfoldingCreationThreshold) of
		      Nothing -> uNFOLDING_CREATION_THRESHOLD
		      Just xx -> xx

    ok_to_dup     = switchIsOn chkr SimplOkToDupCode
			|| exprSmallEnoughToDup rhs
			-- [Andy] added, Jun 95

{- Reinstated AJG Jun 95; This is needed
    --example that does not (currently) work
    --without this extention

    --let f = g x
    --in
    --  case <exp> of
    --	   True -> h i f
    --	   False -> f
    --	==>
    --  case <exp> of
    --	   True -> h i f
    --	   False -> g x
-}
{- OLD:
   Omitted SLPJ Feb 95; should, I claim, be unnecessary
	-- is_really_small looks for things like f a b c
	-- but making sure there are not *too* many arguments.
	-- (This is brought to you by *ANDY* Magic Constants, Inc.)
    is_really_small
      = case collectArgs new_rhs of
	  (Var _, _, _, xs) -> length xs < 10
	  _ -> False
-}
\end{code}

\begin{code}
lookupUnfolding :: SimplEnv -> Id -> UnfoldingDetails

lookupUnfolding (SimplEnv _ _ _ _ unfold_env) var
  | not (isLocallyDefined var)	-- Imported, so look inside the id
  = getIdUnfolding var

  | otherwise			-- Locally defined, so look in the envt.
				-- There'll be nothing inside the Id.
  = lookup_unfold_env unfold_env var
\end{code}

We need to remove any @GenForm@ bindings from the UnfoldEnv for
the RHS of an Id which has an INLINE pragma.

\begin{code}
filterUnfoldEnvForInlines :: SimplEnv -> SimplEnv

filterUnfoldEnvForInlines env@(SimplEnv chkr encl_cc ty_env id_env unfold_env)
  = SimplEnv chkr encl_cc ty_env id_env new_unfold_env
  where
    new_unfold_env = null_unfold_env
	-- This version is really simple.  INLINEd things are going to
	-- be inlined wherever they are used, and then all the
	-- UnfoldEnv stuff will take effect.  Meanwhile, there isn't
	-- much point in doing anything to the as-yet-un-INLINEd rhs.

	-- Andy disagrees! Example:
	--	all xs = foldr (&&) True xs
	--	any p = all . map p  {-# INLINE any #-}
	--
	-- Problem: any won't get deforested, and so if it's exported and
	-- the importer doesn't use the inlining, (eg passes it as an arg)
	-- then we won't get deforestation at all.
	--
	-- So he'd like not to filter the unfold env at all.  But that's a disaster:
	-- Suppose we have:
	--
	-- let f = \pq -> BIG
	-- in
	-- let g = \y -> f y y
	--     {-# INLINE g #-}
	-- in ...g...g...g...g...g...
	--
	-- Now, if that's the ONLY occurrence of f, it will be inlined inside g,
	-- and thence copied multiple times when g is inlined.
\end{code}

======================

In @lookForConstructor@ we used (before Apr 94) to have a special case
for nullary constructors:

\begin{verbatim}
  = 	-- Don't re-use nullary constructors; it's a waste.  Consider
	-- let
	-- 	  a = leInt#! p q
	-- in
	-- case a of
	--    True  -> ...
	--    False -> False
	--
	-- Here the False in the second case will get replace by "a", hardly
	-- a good idea
    Nothing
\end{verbatim}

but now we only do constructor re-use in let-bindings the special
case isn't necessary any more.

\begin{code}
lookForConstructor (SimplEnv _ _ _ _ unfold_env) con args
  = lookup_conapp unfold_env con args
\end{code}
