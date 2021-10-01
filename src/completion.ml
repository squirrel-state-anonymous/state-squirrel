open Utils

module L = Location

(*------------------------------------------------------------------*)
let dbg s = 
  Printer.prt (if Config.debug_completion () then `Dbg else `Ignore) s

(*------------------------------------------------------------------*)
module Cst = struct
  type t =
    | Cflat of int
    (** Constant introduced when flattening *)

    | Csucc of t
    (** Flattening of the successor of a constant *)

    | Cgfuncst of [
        | `N of Symbols.name   Symbols.t * Type.message Type.ty
        | `F of Symbols.fname  Symbols.t
        | `A of Symbols.action Symbols.t
      ]
    (** function symbol, name or action of arity zero *)

    | Cmvar   of Vars.evar

  let cst_cpt = ref 0

  let mk_flat () =
    let () = incr cst_cpt in 
    Cflat !cst_cpt

  let hash = function
    | Cgfuncst (`N (n,_)) -> Hashtbl.hash n
    | _ as t -> Hashtbl.hash t

  let rec print ppf = function
    | Cflat i   -> Fmt.pf ppf "_%d" i
    | Csucc c   -> Fmt.pf ppf "suc(@[%a@])" print c
    | Cmvar m   -> Vars.pp_e ppf m
    | Cgfuncst (`F f) -> Symbols.pp ppf f
    | Cgfuncst (`N (n,_)) -> Symbols.pp ppf n
    | Cgfuncst (`A a) -> Symbols.pp ppf a

  (* The successor function symbol is the second smallest in the precedence
      used for the LPO (0 is the smallest element).  *)
  let rec compare c c' = match c,c' with
    | Csucc a, Csucc a' -> compare a a'
    | Csucc _, _ -> -1
    | _, Csucc _ -> 1
    | _,_ -> Stdlib.compare c c'
end

(*------------------------------------------------------------------*)
type varname = int

let sort_ts compare ts = List.sort compare ts

(* [nilpotence_norm l] normalize [l] using the nilpotence rule x + x -> 0. *)
let nilpotence_norm compare l =
  let l = sort_ts compare l in
  let rec aux = function
    | a :: b :: l' ->
      if a = b then aux l'
      else a :: (aux (b :: l'))
    | [a] -> [a]
    | [] -> [] in

  aux l

(*------------------------------------------------------------------*)
(** Generalized function symbols, for [Term.fsymb], [Term.msymb] and 
    [Symbols.action Symbols.t]. *)
type gfsymb = 
  | F of Symbols.fname  Symbols.t                        (* function symbol *)
  | M of Symbols.macro  Symbols.t * Type.message Type.ty (* macro *)
  | N of Symbols.name   Symbols.t * Type.message Type.ty (* name *)
  | A of Symbols.action Symbols.t                        (* action *)
  | GPred                                                (* predecessor *)

let hash_gfs = function
  | M (m, _) -> Hashtbl.hash m
  | N (n, _) -> Hashtbl.hash n
  | _ as f -> Hashtbl.hash f

let equal_gfs f1 f2 = match f1, f2 with
  | F f1, F f2 -> f1 = f2

  | M (m1, t1), M (m2, t2) -> 
    m1 = m2 &&
    (assert (t1 = t2); true) (* sanity check, for now *)

  | N (n1, t1), N (n2, t2) -> 
    n1 = n2 && 
    (assert (t1 = t2); true) (* sanity check, for now *)

  | A a1, A a2 -> a1 = a2

  | GPred, GPred -> true

  | _ -> false

(*------------------------------------------------------------------*)
module CTerm : sig
  type cterm = private { 
    hash : int;
    cnt  : cterm_cnt;
  }

  and cterm_cnt = private
    | Cfun of gfsymb * int * cterm list (* the integer is index arity *)
    | Ccst of Cst.t
    | Cvar of varname
    | Cxor of cterm list

  val c_equal : cterm -> cterm -> bool
  val c_hash : cterm -> int
  val c_compare : cterm -> cterm -> int

  (** Smart constructors. *)

  (** [cfun g i ts], [i] is the index arity *)
  val cfun : gfsymb -> int -> cterm list -> cterm 

  val ccst : Cst.t -> cterm
  val cvar : varname -> cterm
  val cxor : cterm list -> cterm

end = struct
  (** Terms used during the completion and normalization.
      Remark: Cxor never appears during the completion. *)
  type cterm = { 
    hash : int;
    cnt  : cterm_cnt;
  }

  and cterm_cnt = 
    | Cfun of gfsymb * int * cterm list 
    | Ccst of Cst.t
    | Cvar of varname
    | Cxor of cterm list

  (*------------------------------------------------------------------*)
  (** Hash-consing.
      In [hash] and [equal], we can assume that strit subterms
      are properly hash-consed (but not the term itself). *)
  module Ct = struct
    type t = cterm

    let hash t = match t.cnt with
      | Cxor ts -> Utils.hcombine_list (fun x -> x.hash) 0 ts
      | Cfun (f,i,ts) ->
        Utils.hcombine_list (fun x -> x.hash) 
          (Utils.hcombine i (hcombine 1 (hash_gfs f)))
          ts
      | Ccst c -> hcombine 2 (Cst.hash c)
      | Cvar v -> hcombine 3 v

    let equal t t' = match t.cnt, t'.cnt with
      | Cxor ts, Cxor ts' -> List.for_all2 (fun x y -> x.hash = y.hash) ts ts'
      | Cfun (f,i,ts), Cfun (f',i',ts') ->
        equal_gfs f f' && i = i' &&
        List.for_all2 (fun x y -> x.hash = y.hash) ts ts'
      | Ccst c, Ccst c' -> c = c'
      | Cvar v, Cvar v' -> v = v'
      | _ -> false
      
  end
  module Hct = Ephemeron.K1.Make(Ct)

  let hcons_cpt = ref 0
  let hct = Hct.create 256 

  (* Care, [make] must not be exported, and must only be called by the smart
     constructors below. *)
  let make cnt =
    let ct = { hash = !hcons_cpt ; cnt = cnt } in
    try Hct.find hct ct with
    | Not_found ->
      incr hcons_cpt;
      Hct.add hct ct ct;
      ct

  (*------------------------------------------------------------------*)
  let c_equal t t' = t.hash = t'.hash

  let c_hash t = t.hash

  let c_compare t t' = Stdlib.compare t.hash t'.hash

  (*------------------------------------------------------------------*)
  (** Smart constructors *)

  let simplify_set t = match t with
    | Cxor [] -> make (Cfun (F Symbols.fs_zero, 0, []))
    | Cxor [t] -> t
    | _ -> make t

  let ccst c = make (Ccst c)

  let cvar v = make (Cvar v)

  let rec cfun f i (ts : cterm list) : cterm = 
    if f = F Symbols.fs_succ
    then begin match List.map (fun x -> x.cnt) ts with
      | [Ccst cst] -> make (Ccst (Cst.Csucc cst))
      | _ -> assert false end
    else if f = F Symbols.fs_xor
    then cxor ts
    else if ts = []
    then 
      begin
        assert (i = 0);
        match f with
        | F f -> make (Ccst (Cgfuncst (`F f)))
        | A a -> make (Ccst (Cgfuncst (`A a)))
        | N (n,t) -> make (Ccst (Cgfuncst (`N (n,t))))
        | GPred | M _ -> assert false
      end
    else make (Cfun (f, i, ts))

  and cxor (ts : cterm list) : cterm =
    (* We group the xor *)
    let ts = List.fold_left (fun ts t -> match t.cnt with
        | Cfun (f,_,_) when f = F Symbols.fs_xor -> 
          assert false

        | Cxor ts' -> ts' @ ts
        | _ -> t :: ts) [] ts in
    (* We remove duplicate *)
    let ts = nilpotence_norm (fun x y -> Stdlib.compare x.hash y.hash) ts in
    (* We simplify in case its a singleton or empty list. *)
    simplify_set (Cxor ts)
end

open CTerm

let var_cpt = ref 0

let mk_var () =
  let () = incr var_cpt in
  cvar !var_cpt

exception Unsupported_conversion

(** Translation from [term] to [cterm] *)
let rec cterm_of_term : type a. a Term.term -> cterm = fun c ->
  let open Term in
  match c with
  | Fun ((f,is),_,terms) ->
    let is = List.map cterm_of_var is
    and terms = List.map cterm_of_term terms in
    cfun (F f) (List.length is) (is @ terms)

  | Macro (ms,l,ts) -> 
    assert (l = []); 
    let is = List.map cterm_of_var ms.s_indices in
    cfun
      (M (ms.s_symb, ms.s_typ))
      (List.length is) (is @ [cterm_of_term ts])

  | Term.Action (a,is) ->
    let is = List.map cterm_of_var is in
    cfun (A a) (List.length is) is

  | Name ns -> 
    let is = List.map cterm_of_var ns.s_indices in
    cfun (N (ns.s_symb,ns.s_typ)) (List.length is) is

  | Var m  -> ccst (Cst.Cmvar (Vars.EVar m))

  | Diff(c,d) -> cfun (F Symbols.fs_diff) 0 [cterm_of_term c; cterm_of_term d]

  | Term.Pred ts -> cfun GPred 0 [cterm_of_term ts]

  | _ -> raise Unsupported_conversion

and cterm_of_var i = ccst (Cst.Cmvar (Vars.EVar i))


(*------------------------------------------------------------------*)
let index_of_cterm i = match i.cnt with
  | Ccst (Cst.Cmvar (Vars.EVar m)) -> Vars.cast m Type.KIndex
  | _ -> assert false
    
let indices_of_cterms cis = List.map index_of_cterm cis

let term_of_cterm : type a. Symbols.table -> a Type.kind -> cterm -> a Term.term =
  fun table kind c ->  
  let rec term_of_cterm : type a. a Type.kind -> cterm -> a Term.term = 
    fun kind c -> 
      match c.cnt with 
      | Cfun (F f, ari, cterms) -> 
        let cis, cterms = List.takedrop ari cterms in
        let is = indices_of_cterms cis in
        let terms = terms_of_cterms Type.KMessage cterms in
        let t = Term.mk_fun table f is terms in
        Term.cast kind t

      | Cfun (M (m,ek), ari, cterms) -> 
        let cis, cts = List.takedrop ari cterms in
        let cts = as_seq1 cts in
        let m = Term.mk_isymb m ek (indices_of_cterms cis) in
        let tm = Term.mk_macro m [] (term_of_cterm Type.KTimestamp cts) in
        Term.cast kind tm

      | Cfun (A a, ari, is) -> 
        assert (ari = List.length is);
        let is = indices_of_cterms is in 
        Term.cast kind (Term.mk_action a is)

      | Cfun (N (n,nty), ari, is) -> 
        assert (ari = List.length is);
        let is = indices_of_cterms is in
        let ns = Term.mk_isymb n nty is in
        Term.cast kind (Term.mk_name ns)

      | Cfun (GPred, ari, ts) ->
        assert (ari = 0);
        let ts = as_seq1 ts in
        let pred_ts = Term.mk_pred (term_of_cterm Type.KTimestamp ts) in
        Term.cast kind pred_ts   

      | Ccst (Cst.Cmvar (Vars.EVar m)) -> Term.mk_var (Vars.cast m kind)

      | Ccst (Cst.Cgfuncst (`F f)) ->
        Term.cast kind (Term.mk_fun table f [] [])
          
      | Ccst (Cst.Cgfuncst (`A a)) ->
        Term.cast kind (Term.mk_action a [])
                                        
      | Ccst (Cst.Cgfuncst (`N (n,nty))) ->
        let ns = Term.mk_isymb n nty [] in
        Term.cast kind (Term.mk_name ns)

      | (Ccst (Cflat _|Csucc _)|Cvar _|Cxor _) -> assert false

  and terms_of_cterms : type a. a Type.kind -> cterm list -> a Term.term list =
    fun kind cterms -> List.map (term_of_cterm kind) cterms

  in
  term_of_cterm kind c

(*------------------------------------------------------------------*)
let pp_gsymb ppf = function
  | F x     -> Symbols.pp ppf x
  | M (x,t) -> Fmt.pf ppf "%a : %a" Symbols.pp x Type.pp t
  | A x     -> Symbols.pp ppf x
  | N (x,t) -> Symbols.pp ppf x
  | GPred   -> Fmt.pf ppf "pred"

let rec pp_cterm ppf t = match t.cnt with
  | Cvar v -> Fmt.pf ppf "v#%d" v
  | Ccst c -> Cst.print ppf c

  | Cfun (gf, _, ts) ->
    Fmt.pf ppf "%a(@[<hov 1>%a@])"
      pp_gsymb gf
      (Fmt.list ~sep:(fun ppf () -> Fmt.pf ppf ",@,") pp_cterm) ts

  | Cxor ts ->
    Fmt.pf ppf "++(@[<hov 1>%a@])"
      (Fmt.list ~sep:(fun ppf () -> Fmt.pf ppf ",@,") pp_cterm) ts

let rec is_ground_cterm t = match t.cnt with
  | Ccst _ -> true
  | Cvar _ -> false
  | Cxor ts | Cfun (_, _, ts) -> List.for_all is_ground_cterm ts

let rec no_macros t = match t.cnt with
  | Cfun (M _, _, ts) -> false

  | Ccst _ | Cvar _ -> true

  | Cfun (GPred, _, ts)
  | Cxor ts -> List.for_all no_macros ts

  | Cfun ((A _ | F _ | N _), _, ts) -> List.for_all no_macros ts

let is_cst t = match t.cnt with
  | Ccst _ -> true
  | _      -> false

let is_cfun t = match t.cnt with
  | Cfun _ -> true
  | _      -> false

let is_name t = match t.cnt with
  | Cfun (N _, _, _)
  | Ccst (Cst.Cgfuncst (`N _)) -> true
  | _ -> false

let name_ty t = match t.cnt with
  | Cfun (N (_,nty), _, _)
  | Ccst (Cst.Cgfuncst (`N (_,nty))) -> nty
  | _ -> assert false

(** [t] is a name of type \[large\]. 
    If [of_ty] is not [None], also checks that [t] has the correct type. *)
let is_lname ?of_ty table t =
  if not (is_name t) then false 
  else
    let nty = name_ty t in    
    let of_ty = odflt nty of_ty in
    Symbols.check_bty_info table nty Symbols.Ty_large &&
    nty = of_ty


let get_cst t = match t.cnt with
  | Ccst c -> c
  | _ -> assert false

let subterms l =
  let rec subs acc = function
    | [] -> acc
    | x :: l -> match x.cnt with
      | Ccst _ | Cvar _ -> subs (x :: acc) l
      | Cfun (_,_,fl) -> subs (x :: acc) (fl @ l)
      | Cxor xl -> subs (x :: acc) (xl @ l) in
  subs [] l


(* Create equational rules for some common theories. *)
module Theories = struct

  (** N-ary pair. *)
  let mk_pair arity pair projs =
    assert (arity = List.length projs);
    List.mapi (fun i proj ->
        let vars = List.init arity (fun _ -> mk_var ()) in
        (cfun proj 0 [cfun pair 0 vars], List.nth vars i)
      ) projs

  (** Asymmetric encryption.
      dec(enc(m, r, pk(k)), k) -> m *)
  let mk_aenc enc dec pk =
    let m, r, k = mk_var (), mk_var (), mk_var () in
    let t_pk = cfun pk 0 [k] in
    ( cfun dec 0 [cfun enc 0 [m; r; t_pk]; k], m )

  (** Symmetric encryption.
      dec(enc(m, r, k), k) -> m *)
  let mk_senc enc dec =
    let m, r, k = mk_var (),  mk_var (), mk_var () in
    ( cfun dec 0 [cfun enc 0 [m; r; k]; k], m )

  let t_true  = cfun (F Symbols.fs_true) 0 []
  let t_false = cfun (F Symbols.fs_false) 0 []

  (** Signature.
      mcheck(msig(m, k), pk(k)) -> true *)
  let mk_sig msig mcheck pk =
    let m, k = mk_var (), mk_var () in
    let t_pk = cfun pk 0 [k] in
    ( cfun mcheck 0 [cfun msig 0 [m; k]; t_pk], t_true )


  (** Simple And Boolean rules. *)
  let mk_simpl_and () =
    let u, v, t = mk_var (), mk_var (), mk_var () in
    [( cfun (F Symbols.fs_and) 0 [t_true; u]), u;
     ( cfun (F Symbols.fs_and) 0 [v; t_true]), v;
     ( cfun (F Symbols.fs_and) 0 [t_false; mk_var ()]), t_false;
     ( cfun (F Symbols.fs_and) 0 [mk_var (); t_false]), t_false;
     ( cfun (F Symbols.fs_and) 0 [t; t]), t] 

  (** Simple Or Boolean rules. *)
  let mk_simpl_or () =
    let u, v, t = mk_var (), mk_var (), mk_var () in
    [ ( cfun (F Symbols.fs_or) 0 [t_true; mk_var ()], t_true);
      ( cfun (F Symbols.fs_or) 0 [mk_var (); t_true], t_true);
      ( cfun (F Symbols.fs_or) 0 [t_false; u], u);
      ( cfun (F Symbols.fs_or) 0 [v; t_false], v);
      ( cfun (F Symbols.fs_or) 0 [t; t], t)] 

  (** Simple Not Boolean rules. *)
  let mk_simpl_not () =
    [( cfun (F Symbols.fs_not) 0 [t_true], t_false);
     ( cfun (F Symbols.fs_not) 0 [t_false], t_true)] 

  (* (\** Some simple IfThenElse rules. A lot of rules are missing. *\)
   * let mk_simpl_ite () =
   *   let u, v, s, b = mk_var (), mk_var (), mk_var (), mk_var () in
   *   [( cfun (F Symbols.fs_ite) 0 [t_true; u; mk_var ()], u);
   *    ( cfun (F Symbols.fs_ite) 0 [t_false; mk_var (); v], v);
   *    ( cfun (F Symbols.fs_ite) 0 [b; s; s], s)] *)
end


module Cset = struct
  module Cset = Set.Make(Cst)

  include Cset

  (* Because of the nilpotence rule for the xor, [map] can only be used on
      injective functions. To avoid mistake, I removed it. *)
  let map _ _ = assert false

  (* [of_list l] is modulo nilpotence. For example:
      [of_list [a;b;a;c] = [b;c]] *)
  let of_list l = nilpotence_norm Stdlib.compare l |> 
                  of_list

  let print ppf s =
    Fmt.pf ppf "@[<hov>%a@]"
      (Fmt.list ~sep:(fun ppf () -> Fmt.pf ppf " + ") Cst.print)
      (elements s)

  (* [max comp s] : Return the maximal element of [s], using comparison
      function [comp] *)
  let max comp s =
    let m = choose s in
    fold (fun m a -> if comp a m = 1 then a else m) s m

  (* [compare s s'] : Return true if [s] is strictly smaller than [s'],
      where [s] and [s'] are sets of constants. *)
  let rec set_compare s s' = 
    if equal s s' then 0 
    else if is_empty s' then 1
    else if is_empty s then -1
    else
      let m,m' = max Cst.compare s, max Cst.compare s' in
      if Cst.compare m m' = 0 then
        set_compare (remove m s) (remove m' s')
      else Cst.compare m m'

  let compare = set_compare
end

(* Flatten a ground term, introducing new constants and rewrite rules. *)
let rec flatten t = match t.cnt with
  | Cfun (F f, _, _) when f = Symbols.fs_succ ->
    assert false

  | Cfun (F f, _, _) when f = Symbols.fs_xor ->
    assert false

  | Cxor ts ->
    assert (List.length ts >= 2); (* From the smart constructor. *)
    let eqss, xeqss, csts = List.map flatten ts |> List.split3 in
    let a = Cst.mk_flat () in
    let new_rule = Cset.of_list (a :: csts) in

    ( List.flatten eqss,
      new_rule :: List.flatten xeqss,
      a )

  | Cfun (f, ari, ts) ->
    let eqss, xeqss, csts = List.map flatten ts |> List.split3 in
    let a = Cst.mk_flat () in

    ( (cfun f ari (List.map (fun x -> ccst x) csts), a)
      :: List.flatten eqss,
      List.flatten xeqss,
      a )

  | Ccst c -> ([], [], c)

  | Cvar _ -> assert false


(*------------------------------------------------------------------*)
(** {2 Union-find} *)

module CufTmp = Uf (Cst)

module Cuf : sig
  include module type of CufTmp
end = struct
  type t = CufTmp.t

  type v = CufTmp.v

  let extend = CufTmp.extend

  let create = CufTmp.create

  let union_count = CufTmp.union_count

  let classes = CufTmp.classes

  let print = CufTmp.print

  let find t v =
    let t = CufTmp.extend t v in
    CufTmp.find t v

  (* We always use the smallest constant of a class as its representent. *)
  let union t v v' =
    let t = CufTmp.extend (CufTmp.extend t v) v' in
    if Cst.compare v v' < 0 then CufTmp.union t v' v
    else CufTmp.union t v v'

  module Memo = CufTmp.Memo
  module Memo2 = CufTmp.Memo2
end


(*------------------------------------------------------------------*)
(** {2 Map of cterms} *)

module Mct = Map.Make (struct
    type t = cterm
    let compare t t' = Stdlib.compare t.hash t'.hash    
  end)

module Sct = Set.Make (struct
    type t = cterm
    let compare t t' = Stdlib.compare t.hash t'.hash
  end)


module Scst = Set.Make (struct
    type t = Cst.t
    let compare t t' = Stdlib.compare t t'
  end)

(*------------------------------------------------------------------*)
(** {2 State of the complation procedure} *)

type grnd_rules = Scst.t Mct.t
type e_rules = Sct.t Mct.t

(* State of the completion and normalization algorithms, which stores a
    term rewriting system:
    - id : integer unique to a run of the completion procedure.
    - uf : equalities between constants.
    - xor_rules : list of initial xor rules, normalized by uf.
                  Remark that we do not saturate this set by ACUN (this is an
                  optimisation, to have a faster saturation).
                  A set {a1,...,an} corresponds to a1 + ... + an -> 0
    - sat_xor_rules : list of saturated xor rules, to avoid re-computing it.
                      The integer counter indicates the version of [state.uf]
                      that was used when the saturated set was computed.
    - grnd_rules : grounds flat rules of the form "ground term -> constant"
    - e_rules : general rules. For the completion algorithm to succeed, these
                rules must be of a restricted form:
                - No "xor" and no "succ".
                - initially, each rule in e_rule must start by a destructor,
                  which may appear only once in e_rule. *)
type state = { id            : int;
               uf            : Cuf.t;
               xor_rules     : Cset.t list;
               sat_xor_rules : (Cset.t list * int) option;
               grnd_rules    : grnd_rules;
               e_rules       : e_rules; 
               completed     : bool }

(*------------------------------------------------------------------*)
(** {2 Pretty Printers} *)

let pp_xor_rules ppf xor_rules =
  Fmt.pf ppf "@[<v>%a@]"
    (Fmt.list
       ~sep:(fun ppf () -> Fmt.pf ppf "@;")
       (fun ppf s -> Fmt.pf ppf "%a -> 0" Cset.print s)
    ) xor_rules

let pp_sat_xor_rules ppf sat_xor_rules = match sat_xor_rules with
  | Some (sat,_) ->
    Fmt.pf ppf "@[<v>%a@]"
      (Fmt.list
         ~sep:(fun ppf () -> Fmt.pf ppf "@;")
         (fun ppf s -> Fmt.pf ppf "%a -> 0" Cset.print s)
      ) sat
  | None -> Fmt.pf ppf "Not yet saturated"
              
let pp_grnd_rules ppf (grnd_rules : Scst.t Mct.t) =
  let grnd_rules = List.fold_left (fun acc (t, s) ->
      List.fold_left
        (fun acc t' -> (t, t') :: acc)
        acc (Scst.elements s)     
    ) [] (Mct.bindings grnd_rules) in

  Fmt.pf ppf "@[<v>%a@]"
  (Fmt.list
     ~sep:(fun ppf () -> Fmt.pf ppf "@;")
     (fun ppf (t,a) -> Fmt.pf ppf "%a -> %a" pp_cterm t Cst.print a)
  ) grnd_rules

let pp_e_rules ppf (e_rules : Sct.t Mct.t) =
  let e_rules = List.fold_left (fun acc (t, s) ->
      List.fold_left
        (fun acc t' -> (t, t') :: acc)
        acc (Sct.elements s)     
    ) [] (Mct.bindings e_rules) in

  Fmt.pf ppf "@[<v>%a@]"
  (Fmt.list
     ~sep:(fun ppf () -> Fmt.pf ppf "@;")
     (fun ppf (t,s) -> Fmt.pf ppf "%a -> %a" pp_cterm t pp_cterm s)
  ) e_rules

let count_g (m : Scst.t Mct.t) = 
  Mct.fold (fun _ s c -> c + Scst.cardinal s) m 0

let count_e (m : Sct.t Mct.t) = 
  Mct.fold (fun _ s c -> c + Sct.cardinal s) m 0

let count_rules s = 
  let sat_xor_rules = fst (odflt ([],0) s.sat_xor_rules) in
  List.length (s.xor_rules) +
  List.length (sat_xor_rules) +
  count_g (s.grnd_rules) +
  count_e (s.e_rules)
  
let pp_state ppf s =
  let sat_xor_rules = fst (odflt ([],0) s.sat_xor_rules) in
  Fmt.pf ppf "@[<v 0>Completion state (%d rules in total)@;\
              @[<v 2>uf:@;%a@]@;\
              @[<v 2>xor_rules (%d rules):@;%a@]@;\
              @[<v 2>sat_xor_rules (%d rules):@;%a@]@;\
              @[<v 2>grnd_rules (%d rules):@;%a@]@;\
              @[<v 2>e_rules (%d rules):@;%a@]@;\
              ;@]%!"
    (count_rules s)
    Cuf.print s.uf
    (List.length s.xor_rules)   pp_xor_rules s.xor_rules
    (List.length sat_xor_rules) pp_sat_xor_rules s.sat_xor_rules
    (count_g s.grnd_rules)  pp_grnd_rules s.grnd_rules
    (count_e s.e_rules)     pp_e_rules s.e_rules


(*------------------------------------------------------------------*)
(** {2 Normalization} *)

let rec term_uf_normalize uf t = match t.cnt with
  | Cfun (f,ari,ts) -> cfun f ari (List.map (term_uf_normalize uf) ts)
  | Cxor ts -> cxor (List.map (term_uf_normalize uf) ts)
  | Ccst c -> ccst (Cuf.find uf c)
  | Cvar _ -> t

(** memoisation *)
let term_uf_normalize = 
  let module U = struct
    type t = cterm 
    let hash t = c_hash t
    let equal s s' = c_equal s s'
  end in 
  let module Memo = Cuf.Memo2 (U) in
  let memo = Memo.create 256 in
  fun uf v ->
    try Memo.find memo (uf,v) with
    | Not_found -> 
      let r = term_uf_normalize uf v in
      Memo.add memo (uf,v) r;
      r

let p_terms_uf_normalize uf (t,t') =
  ( term_uf_normalize uf t, term_uf_normalize uf t')

(* Remark: here, we cannot act directly on the set, as this would silently
   remove duplicates, which we need to apply the nilpotence rule. *)
let set_uf_normalize state s =
  Cset.elements s
  |> List.map (Cuf.find state.uf)
  |> Cset.of_list               (* Cset.of_list is modulo nilpotence *)

let disjoint s s' = Cset.inter s s' |> Cset.is_empty

let disjoint_union s s' =
  let u, i = Cset.union s s', Cset.inter s s' in
  Cset.diff u i

module Xor : sig
  val deduce_eqs : state -> state
end = struct

  (* Add to [xrules] the rules obtained from the critical pairs with [xr]. *)
  let add_cp xr xrules =
    List.fold_left (fun acc xr' ->
        if disjoint xr xr' then acc
        else disjoint_union xr xr' :: acc) xrules xrules

  (* - Deduce constants equalities from the xor rules.
      - Example: from
      a + b -> 0
      a + c -> 0
      we deduce that
      b + c -> 0
      - Store the result in [state.sat_xor_rules]. If no constant equalities
      have been added, we do not need to recompute the saturated set.  *)
  let deduce_eqs state =
    let already_sat = match state.sat_xor_rules with
      | None -> false
      | Some (_,cpt) -> cpt = Cuf.union_count state.uf in

    if already_sat then state
    else
      (* We get all xor rules, normalized by constant equality rules. *)
      let xrules = List.map (set_uf_normalize state) state.xor_rules in

      (* First, we saturate the xor rules. *)
      let sat_xrules =
        List.fold_left (fun acc xr -> add_cp xr acc) xrules xrules
        |> List.filter (fun x -> not @@ Cset.is_empty x) 
        |> List.sort_uniq Cset.compare in

      let state =
        { state with sat_xor_rules = Some ( sat_xrules,
                                            Cuf.union_count state.uf ) } in

      (* Then, we keep rules of the form a + b -> 0. *)
      let new_eqs =
        List.filter (fun xr -> Cset.cardinal xr = 2) sat_xrules
        |> List.map (fun xr -> match Cset.elements xr with
            | [a;b] -> (a,b)
            | _ -> assert false) in

      (* We update the union-find structure with a = b *)
      let uf =
        List.fold_left (fun uf (a,b) -> Cuf.union uf a b) state.uf new_eqs
      in
      { state with uf = uf }          

  let deduce_eqs = Prof.mk_unary "Xor.deduce_eqs" deduce_eqs
end


(*------------------------------------------------------------------*)
(** {Set of rules functions} *)

(** Add some already flattened ground rule *)
let add_rule (grules : grnd_rules) (t,a) =
  Mct.update t (fun s -> 
      let s = odflt Scst.empty s in
      Some (Scst.add a s))
    grules

let add_rules (grules : grnd_rules) l =
  List.fold_left add_rule grules l

let add_rules_set (grules : grnd_rules) t s =
  Mct.update t (fun s' -> 
      let s' = odflt Scst.empty s' in
      Some (Scst.union s s'))
    grules

(** Add some e_rule *)
let add_erule (erules : e_rules) (t,a) =
  Mct.update t (fun s -> 
      let s = odflt Sct.empty s in
      Some (Sct.add a s))
    erules

let add_erules (erules : e_rules) l =
  List.fold_left add_erule erules l

let add_erules_set (erules : e_rules) t s =
  Mct.update t (fun s' -> 
      let s' = odflt Sct.empty s' in
      Some (Sct.union s s'))
    erules

let norm_grnd_rules uf (rules : grnd_rules) =
  Mct.fold (fun t s rules ->
      add_rules_set rules (term_uf_normalize uf t) (Scst.map (Cuf.find uf) s) 
    ) rules Mct.empty 

let norm_e_rules uf (rules : e_rules) =
  Mct.fold (fun t s rules ->
      add_erules_set rules (term_uf_normalize uf t) (Sct.map (term_uf_normalize uf) s)
    ) rules Mct.empty 

let fold_grules : (cterm * Cst.t -> 'a -> 'a) -> grnd_rules -> 'a -> 'a =
  fun f grules acc ->
  Mct.fold (fun l s acc ->
      Scst.fold (fun r acc ->
          f (l,r) acc 
        ) s acc
    ) grules acc

let fold_erules : (cterm * cterm -> 'a -> 'a) -> e_rules -> 'a -> 'a =
  fun f erules acc ->
  Mct.fold (fun l s acc ->
      Sct.fold (fun r acc ->
          f (l,r) acc 
        ) s acc
    ) erules acc

let iter_grules : (cterm * Cst.t -> unit) -> grnd_rules -> unit =
  fun f grules ->
  fold_grules (fun rule () -> f rule) grules ()

let iter_erules : (cterm * cterm -> unit) -> e_rules -> unit =
  fun f erules ->
  fold_erules (fun rule () -> f rule) erules ()

let find_grules :
  (cterm * Cst.t -> bool) -> grnd_rules -> (cterm * Cst.t) option =
  fun f grules ->
  let exception Found of cterm * Cst.t in
  try
    iter_grules (fun (a,b) -> if f (a,b) then raise (Found (a,b))) grules; 
    None
  with Found (a,b) -> Some (a,b)

let find_erules :
  (cterm * cterm -> bool) -> e_rules -> (cterm * cterm) option =
  fun f erules ->
  let exception Found of cterm * cterm in
  try
    iter_erules (fun (a,b) -> if f (a,b) then raise (Found (a,b))) erules;
    None
  with Found (a,b) -> Some (a,b)

let find_map_erules : (cterm * cterm -> 'a option) -> e_rules -> 'a option =
  fun f erules ->
  let found = ref None in
  let exception Found in
  try
    iter_erules (fun (a,b) -> 
        let r = f (a,b) in
        if r <> None then 
          let () = found := r in
          raise Found
      ) erules;
    None
  with Found -> !found

(*------------------------------------------------------------------*)
module Ground : sig
  val deduce_triv_eqs : state -> state
  val deduce_eqs : state -> state
end = struct

  (* Deduce trivial constants equalities from the ground rules. *)
  let deduce_triv_eqs state =
    let r_trivial, r_other = 
      Mct.partition (fun a _ -> is_cst a) state.grnd_rules in

    fold_grules (fun (a,b) state ->
        { state with uf = Cuf.union state.uf (get_cst a) b }
      ) r_trivial { state with grnd_rules = r_other } 

  let deduce_triv_eqs = Prof.mk_unary "Ground.deduce_triv_eqs" deduce_triv_eqs
    
  (* Deduce constants equalities from the ground rules. *)
  let deduce_eqs state =
    (* We get all ground rules, normalized by constant equality rules. *)
    let grules = norm_grnd_rules state.uf state.grnd_rules in

    (* We look for critical pairs, which are necessary of the form:
       c <- t -> c'
       because the rules are flat. For each such critical pair, we add c = c'. *)
    Mct.fold (fun t s state ->
        if Scst.is_empty s then state 
        else
          let c = Scst.choose s in
          Scst.fold (fun c' state ->
              { state with uf = Cuf.union state.uf c c' }
            ) s state 
      ) grules state

  let deduce_eqs = Prof.mk_unary "Ground.deduce_eqs" deduce_eqs
end

(* Simple unification implementation *)
module Unify = struct
  type subst = cterm Mi.t

  type unif_res = Mgu of subst | No_mgu

  let empty_subst = Mi.empty

  let pp_subst fmt s =
    (Fmt.list ~sep:Fmt.comma
      (fun fmt (i,c) ->
        Fmt.pf fmt "%d -> %a" i pp_cterm c))
      fmt (Mi.bindings s)

  exception Unify_cycle

  (** [subst_apply t sigma] applies [sigma] to [t], checking for cycles. *)
  let subst_apply t sigma =
    let rec aux sigma occurs t = match t.cnt with
      | Cfun (f, ari, ts) -> cfun f ari (List.map (aux sigma occurs) ts)
      | Cxor ts -> cxor (List.map (aux sigma occurs) ts)
      | Ccst _ -> t
      | Cvar v ->
        if List.mem v occurs then raise Unify_cycle
        else if Mi.mem v sigma then
          aux sigma (v :: occurs) (Mi.find v sigma)
        else cvar v in

    try aux sigma [] t with Unify_cycle -> assert false

  let subst_apply t sigma = if Mi.is_empty sigma then t else subst_apply t sigma

  let rec unify_aux eqs sigma = match eqs with
    | [] -> Mgu sigma
    | (u,v) :: eqs' ->
      match subst_apply u sigma, subst_apply v sigma with
      | { cnt = Cfun (f,ari,ts)}, { cnt = Cfun (g,ari',ts')} ->
        if f <> g then No_mgu
        else begin
          assert (ari = ari'); 
          unify_aux ((List.combine ts ts') @ eqs') sigma
        end

      | { cnt = Cxor ts}, { cnt = Cxor ts'} ->
        unify_aux ((List.combine ts ts') @ eqs') sigma

      | { cnt = Ccst a}, { cnt = Ccst b} ->
        if a = b then unify_aux eqs' sigma else No_mgu

      | ({ cnt = Cvar x} as tx), t | t, ({ cnt = Cvar x } as tx) ->
        assert (not (Mi.mem x sigma));
        let sigma = if t = tx then sigma else Mi.add x t sigma in
        unify_aux eqs' sigma

      | _ ->  No_mgu

  let unify_normed u v = unify_aux [(u,v)] empty_subst

  (** memoisation *)
  let unify_normed = 
    let module U = struct
      type t = cterm 
      let hash t = c_hash t
      let equal t t' = c_equal t t'
    end in 
    let module Memo = Ephemeron.K2.Make (U) (U) in
    let memo = Memo.create 256 in
    fun u v ->
      try Memo.find memo (u,v) with
      | Not_found -> 
        let r = unify_normed u v in
        Memo.add memo (u,v) r;
        r

  (* We normalize by constant equality rules before unifying.
      This is *not* modulo ACUN. *)
  let unify uf u v =
    let u,v = p_terms_uf_normalize uf (u,v) in
    unify_normed u v

  (** profiling *)
  let unify = Prof.mk_ternary "Completion.unify" unify
end


module Erules : sig
  val deduce_eqs : state -> state
end = struct

  (** [add_grnd_rule state l a]: the term [l] must be ground. *)
  let add_grnd_rule state (l : cterm) (a : Cst.t) =
    let eqs, xeqs, b = flatten l in
    let grules = add_rules state.grnd_rules eqs in
        
    assert (xeqs = []);
    { state with uf = Cuf.union state.uf a b;
                 grnd_rules = grules }
        

  (** Try to superpose two rules at head position, and add a new equality to get
      local confluence if necessary. *)
  let head_superpose state (l,r) (l',r') =
    match Unify.unify state.uf l l' with
    | Unify.No_mgu -> state
    | Unify.Mgu sigma ->
      match Unify.subst_apply r sigma, Unify.subst_apply r' sigma with
      | rs, rs' when c_equal rs rs' -> state

      | { cnt = Ccst a}, { cnt = Ccst b} when a <> b ->
        { state with uf = Cuf.union state.uf a b }

      | { cnt = Ccst a}, rs
      | rs, { cnt = Ccst a} -> 
        add_grnd_rule state rs a

      (* This last case should not be possible under our restrictions on
         non-ground rules. Still, if we relaxed the restriction, we could try to
         handle the case where we get two ground terms by flattening them and
         adding them to the set of ground equalities. If one of the two terms is
         not ground, we should probably always abort. *)
      | _ -> assert false


  (** [grnd_superpose state (l,r) (t,a)]: Try all superposition of a ground rule
      [t] -> [a] into an e_rule [l] -> [r], and add new equalities to get local
      confluence if necessary. *)
  let grnd_superpose state (l,r) (t,a) =

    (* Invariant in [aux acc lst f]:
     *  - [acc] is the list of e_rules to add so far.
     *  - [lst] is a subterm of [l].
     *  - [f_cntxt] is a function building the context where [lst] appears.
          For example, we have that [f_cntxt lst = l]. *)
    let rec aux state acc lst f_cntxt = match lst.cnt with
      (* never superpose at variable position *)
      | Ccst _ | Cvar _ -> ( state, acc )
      | Cxor _ -> assert false

      | Cfun (fn, ari, ts) ->
        let state, acc = match Unify.unify state.uf lst t with
          | Unify.No_mgu -> ( state, acc )
          | Unify.Mgu sigma ->
            (* Here, we have the critical pair:
               r sigma <- l[t] sigma -> l[a] sigma *)
            let la_sigma = Unify.subst_apply (f_cntxt (ccst a)) sigma
            and r_sigma = Unify.subst_apply r sigma in

            (* No critical pair *)
            if la_sigma = r_sigma then ( state, acc )

            else match la_sigma.cnt with
              | Ccst c ->
                (* Using the subterm property, we know that if [la_sigma] is
                   ground, then so is [r_sigma] *)
                assert (is_ground_cterm r_sigma);
                ( add_grnd_rule state r_sigma c, acc)

              | _ -> ( state, (la_sigma,r_sigma) :: acc ) in

        if ts = [] then (state,acc)
        else
          (* Invariant: [(List.rev left) @ [lst'] @ right = ts] *)
          let (state, acc), _, _ =
            List.fold_left (fun ((state,acc),left,right) lst' ->
                let f_cntxt' hole =
                  f_cntxt (cfun fn ari ((List.rev left) @ [hole] @ right)) in

                let right' = if right = [] then [] else List.tl right in

                ( aux state acc lst' f_cntxt', lst' :: left, right' )
              ) ((state,acc),[],List.tl ts) ts in

          ( state, acc ) in

    aux state [] l (fun x -> x)


  let rec select_erule (r_open : e_rules) : ((cterm * cterm) * e_rules) option = 
    if Mct.is_empty r_open then None
    else 
      let t, s = Mct.choose r_open in
      if Sct.is_empty s
      then select_erule (Mct.remove t r_open)
      else
        let t' = Sct.choose s in
        let s = Sct.remove t' s in
        Some ((t,t'), Mct.add t s r_open)
          
  (** [deduce_aux state r_open r_closed]. Invariant:
      - [r_closed]: e_rules already superposed with all other rules.
      - [r_open]: e_rules to superpose. *)
  let rec deduce_aux state (r_open : e_rules) (r_closed : e_rules) : state = 
    match select_erule r_open with
    | None -> { state with e_rules = r_closed }

    | Some (rule, r_open') ->
      let state, r_open' = 
        fold_grules (fun rule' (state, r_open') ->
            let (state, new_rs) = grnd_superpose state rule rule' in
            ( state, add_erules r_open' new_rs)
          ) state.grnd_rules ( state, r_open') 
      in

      let state = fold_erules (fun rule' state ->
          head_superpose state rule rule'
        ) r_open' state
      in

      deduce_aux state r_open' (add_erule r_closed rule)
  

  (** Deduce new rules (constant, ground and erule) from the non-ground
      rules. *)
  let deduce_eqs state =
    let erules = norm_e_rules state.uf state.e_rules in
    deduce_aux state erules Mct.empty 
      
  let deduce_eqs = Prof.mk_unary "Erule.deduce_eqs" deduce_eqs
end


(*------------------------------------------------------------------*)
(** {2 Normalization} *)


(** [set_grnd_normalize state s] : Normalize [s], which is a sum of terms,
    using the xor rules in [state]. *)
let set_grnd_normalize (state : state) (s : Cset.t) : Cset.t =
  let sat_rules = match state.sat_xor_rules with
    | Some (rules,_) -> rules
    | _ -> assert false (* impossible when [state] has been completed *) in

  let rec aux s = function
    | [] -> s
    | xrule :: xrules' ->
      if disjoint s xrule then aux s xrules'
      else
        let a = Cset.inter s xrule in
        let b = Cset.diff xrule a in
        (* xrule : a + b -> 0
           s     : a + c
           if b < a, then we do:
           s = a + c ----> b + c *)
        if Cset.compare b a = -1 then aux (disjoint_union xrule s) xrules'
        else aux s xrules' in

  aux s sat_rules


(** [term_grnd_normalize state u]
    Precondition: [u] must be ground and its xor grouped. *)
let rec term_grnd_normalize (state : state) (u : cterm) : cterm = 
  match u.cnt with
  | Cvar _ -> u

  | Ccst c ->
    let ts = set_grnd_normalize state (Cset.singleton c)
             |> Cset.elements
             |> List.map (fun x -> ccst x) in

    cxor ts

  | Cxor ts ->
    (* This part is a bit messy:
       - first, we split between constants and fterms.
       - then, we normalize only the fterms, and split the result (again) into
         constants and fterms.
       - finally, we normalize the two set of constants using the xor rules. *)
    let csts0, fterms0 = List.partition is_cst ts in
    let csts1, fterms1 = List.map (term_grnd_normalize state) fterms0
                         |> nilpotence_norm c_compare
                         |> List.partition is_cst in

    (* We only have to normalize the constants in [ts], i.e. [csts0 @ csts1]. *)
    let csts_norm = List.map get_cst (csts0 @ csts1)
                    |> Cset.of_list (* Cset.of_list is modulo nilpotence *)
                    |> set_grnd_normalize state
                    |> Cset.elements
                    |> List.map (fun x -> ccst x) in

    cxor (csts_norm @ fterms1)

  | Cfun (fn, ari, ts) ->
    assert (ts <> []);
    let nts = List.map (term_grnd_normalize state) ts in
    let u' = cfun fn ari nts in

    (* TODO: storing rules by head function symbols would help here. *)
    if List.for_all (fun c -> not (is_cfun c)) nts then
      match find_grules (fun (l,_) -> c_equal l u') state.grnd_rules with 
        | Some (_,a) -> ccst a
        | None -> u'
    else u'

(** [term_e_normalize state u]
    Precondition: [u] must be ground and its xors grouped. *)
let rec term_e_normalize state u = match u.cnt with
  | Ccst _ | Cvar _ -> u

  | Cxor ts -> cxor ( List.map (term_e_normalize state) ts)

  | Cfun (fn, ari, ts) ->
    let nts = List.map (term_e_normalize state) ts in
    let u = cfun fn ari nts in

    let find_unif (l,r) =
      match Unify.unify state.uf u l with
      | Unify.No_mgu -> None
      | Unify.Mgu sigma -> Some (l, r, sigma)
    in
    
    match find_map_erules find_unif state.e_rules with
    | Some (l,r,sigma) ->
      (* assert (term_uf_normalize state.uf (Unify.subst_apply l sigma)
       *         = term_uf_normalize state.uf u); *)
      Unify.subst_apply r sigma
    | None -> u

(* [normalize_cterm state u]
    Preconditions: [u] must be ground. *)
let normalize state u =
  fpt (=) (fun x -> term_uf_normalize state.uf x
                    |> term_grnd_normalize state
                    |> term_e_normalize state) u


(* [normalize_cterm state u]
    Preconditions: [u] must be ground. *)
let normalize ?(print=false) state u =
  let u_normed = normalize state u in
  if print then dbg "%a normalized to %a" pp_cterm u pp_cterm u_normed;
  u_normed

  
let rec normalize_csts state t = match t.cnt with
  | Cfun (fn,ari,ts) -> cfun fn ari (List.map (normalize_csts state) ts)
  | Cvar _ -> t
  | Ccst _ | Cxor _ -> normalize state t


(*------------------------------------------------------------------*)
(** {2 Completion} *)

(* Finalize the completion, by normalizing all ground and erules using the xor
    rules. This handles critical pair of the form:
    (R1) : a + b + c -> 0, where a > b,c
    (R2) : f(a) -> d
    Then the critical pair:
    d <- f(a) -> f(b + c)
    is joined by replacing (R2) by:
    f(b + c) -> d *)
let finalize_completion state =
  let grnds = 
   Mct.fold (fun t s grules ->
        Mct.add (normalize_csts state t) (Scst.map (Cuf.find state.uf) s) grules
      ) state.grnd_rules Mct.empty
  in
  let erules =
    Mct.fold (fun t s erules ->
        let s = Sct.map (normalize_csts state) s in
        Mct.add (normalize_csts state t) s erules
      ) state.e_rules Mct.empty
  in

  let state = { state with
                grnd_rules = grnds;
                e_rules = erules;
                completed = true } in
  dbg "@[<v 0>Finaled state:@; %a@]" pp_state state;   
  state
  
let rec complete_state state =
  dbg "%a" pp_state state; 
  
  let cond_equal state1 state2 = 
    Cuf.union_count state1.uf = Cuf.union_count state2.uf &&
    Mct.equal Scst.equal state1.grnd_rules state2.grnd_rules &&
    Mct.equal Sct.equal state1.e_rules state2.e_rules
  in

  let s_state = state in

  let state = Ground.deduce_triv_eqs state
              |> Xor.deduce_eqs
              |> Ground.deduce_eqs
              |> Erules.deduce_eqs in

  if cond_equal s_state state 
  then state
  else complete_state state

let complete_state = Prof.mk_unary "complete_state" complete_state

let check_zero_arity table fname =
  let fty, _ = Symbols.Function.get_def fname table in
  assert (fty.Type.fty_iarr = 0)

let check_zero_arities table fnames =
  List.iter (check_zero_arity table) fnames

let dec_pk table f1 f2 =
  match Symbols.Function.get_def f1 table, Symbols.Function.get_def f2 table with
  | (_, Symbols.ADec), (_, Symbols.PublicKey) -> f1, f2
  | (_, Symbols.PublicKey), (_, Symbols.ADec) -> f2, f1
  | _ -> assert false

let sig_pk table f1 f2 =
  match Symbols.Function.get_def f1 table, Symbols.Function.get_def f2 table with
  | (_, Symbols.Sign), (_, Symbols.PublicKey) -> f1, f2
  | (_, Symbols.PublicKey), (_, Symbols.Sign) -> f2, f1
  | _ -> assert false

let is_sdec table f =
  assert (snd (Symbols.Function.get_def f table) = Symbols.SDec)

let init_erules table =
  Symbols.Function.fold (fun fname def data erules -> match def, data with
      | (_, Symbols.AEnc), Symbols.AssociatedFunctions [f1; f2] ->
        let dec, pk = dec_pk table f1 f2 in
        (* We only allow an index arity of zero for crypto primitives *)
        check_zero_arities table [fname; dec; pk];
        add_erule erules (Theories.mk_aenc (F fname) (F dec) (F pk)) 

      | (_, Symbols.SEnc), Symbols.AssociatedFunctions [sdec] ->
        is_sdec table sdec;
        (* We only allow an index arity of zero for crypto primitives *)
        check_zero_arities table [fname; sdec];
        add_erule erules (Theories.mk_senc (F fname) (F sdec)) 

      | (_, Symbols.CheckSign), Symbols.AssociatedFunctions [f1; f2] ->
        let msig, pk = sig_pk table f1 f2 in
        (* We only allow an index arity of zero for crypto primitives *)
        check_zero_arities table [fname; msig; pk];
        add_erule erules (Theories.mk_sig (F msig) (F fname) (F pk)) 

      | _ -> erules
    ) 
    (add_erules
       Mct.empty 
       (Theories.mk_pair 2 (F Symbols.fs_pair) [F Symbols.fs_fst;
                                                F Symbols.fs_snd]))
    table

let state_id = ref 0

let complete_cterms table (l : (cterm * cterm) list) : state =
  let grnd_rules, xor_rules = List.fold_left (fun (acc, xacc) (u,v) ->
      let eqs, xeqs, a = flatten u
      and  eqs', xeqs', b = flatten v in
      ( (ccst a, b) :: eqs @ eqs' @ acc, xeqs @ xeqs' @ xacc )
    ) ([], []) l in

  let grnd_rules = add_rules Mct.empty grnd_rules in

  let state = { id = (incr state_id; !state_id); 
                uf = Cuf.create [];
                grnd_rules = grnd_rules;
                xor_rules = xor_rules;
                sat_xor_rules = None;
                e_rules = init_erules table;
                completed = false  } in

  complete_state state
  |> finalize_completion

let tot = ref 0.
let cptd = ref 0

(* FIXME: memory leaks *)
module Memo = Hashtbl.Make2
    (struct 
      type t = Symbols.table
      let equal t t' = Symbols.tag t = Symbols.tag t'
      let hash t = Symbols.tag t 
    end)
    (struct 
      type t = Term.esubst list
      let equal_p (Term.ESubst (t0, t1)) (Term.ESubst (t0', t1')) = 
        Type.equal (Term.ty t0) (Term.ty t0') &&
        let t0', t1' = Term.cast (Term.kind t0) t0', 
                       Term.cast (Term.kind t0) t1' in
        t0 = t0' && t1 = t1'
      let equal l l' = 
        let l, l' = List.sort_uniq Stdlib.compare l,
                    List.sort_uniq Stdlib.compare l' in
        List.length l = List.length l' &&
        List.for_all2 equal_p l l'

      let hash_p (Term.ESubst (t0, t1)) =
        Utils.hcombine (Hashtbl.hash t0) (Hashtbl.hash t1)
      let hash l = Utils.hcombine_list hash_p 0 l
    end)

let complete table (l : Term.esubst list) 
  : state timeout_r =
  let l =
    List.fold_left
      (fun l (Term.ESubst (u,v)) ->
         try
           let cu, cv = cterm_of_term u, cterm_of_term v in

           dbg "Completion: %a = %a added as %a = %a"
             Term.pp u Term.pp v pp_cterm cu pp_cterm cv; 

           (cu, cv):: l 

         with Unsupported_conversion -> 
           dbg "Completion: %a = %a ignored (unsupported)" Term.pp u Term.pp v; 
           l)
      []
      l
  in
  Utils.timeout (Config.solver_timeout ()) (complete_cterms table) l 

(** With memoisation *)
let complete : Symbols.table -> Term.esubst list -> state Utils.timeout_r =
  let memo = Memo.create 256 in
  fun table l ->
    try Memo.find memo (table,l) with
    | Not_found -> 
      let res = complete table l in
      Memo.add memo (table,l) res;
      res
  
let print_init_trs fmt table =
  Fmt.pf fmt "@[<v 2>Rewriting rules:@;%a@]"
    pp_e_rules (init_erules table)

(*------------------------------------------------------------------*)
(** {2 Dis-equality} *)

(** Returns true if the cterm corresponds to a ground term, e.g without macros
    and vars. *)
let rec is_ground_term t = match t.cnt with
  | Cfun (M _, _, _) 
  | Ccst (Cst.Cmvar _) 
  | Cvar _ -> false

  | Ccst _ -> true

  | Cfun (GPred, _, ts)
  | Cxor ts 
  | Cfun ((A _ | F _ | N _), _, ts) -> List.for_all is_ground_term ts


let check_disequality_cterm state neqs (u,v) =
  assert (state.completed);
  (* we normalize all inequalities *)
  let neqs =
    List.map (fun (x, y) -> normalize state x, normalize state y) neqs
  in
  let u, v = normalize state u,normalize state v in
  (* if the given pair appears in the normalized disequality, we conclude *)
  List.mem (u, v) neqs
  || List.mem (v, u) neqs
  (* if the term are grounds and have different normal form, return disequal *)
  || (is_ground_term u && is_ground_term v && (u <> v))

(** [check_disequalities s neqs l] checks that all disequalities inside [l] are
    implied by inequalities inside neqs, w.r.t [s]. *)
let check_disequality state neqs (u,v) =
  try check_disequality_cterm state neqs (cterm_of_term u, cterm_of_term v)
  with
  | Unsupported_conversion -> false

let check_disequalities state neqs l =
  let neqs = List.map (fun (x, y) ->
         cterm_of_term x, cterm_of_term y) neqs in
  List.for_all (check_disequality state neqs) l

(** [check_equality_cterm state (u,v)]
     Precondition: [u] and [v] must be ground *)
let check_equality_cterm state (u,v) =
  assert (state.completed);
  normalize ~print:true state u = 
  normalize ~print:true state v

let check_equality state (Term.ESubst (u,v)) =  
  try
    let cu, cv = cterm_of_term u, cterm_of_term v in
    let bool = check_equality_cterm state (cu, cv) in

    dbg "check_equality: %a = %a as %a = %a: %a"
      Term.pp u Term.pp v pp_cterm cu pp_cterm cv Fmt.bool bool;

    bool

  with Unsupported_conversion -> 
    dbg "check_equality: %a = %a ignored (unsupported)" Term.pp u Term.pp v;
    false

let check_equalities state l = List.for_all (check_equality state) l


(*------------------------------------------------------------------*)
(** {2 Names and Constants Equalities} *)

(** [star_apply (f : 'a -> 'b list) (l : 'a list)] applies [f] to the
    first element of [l] and all the other elements of [l], and return the
    concatenation of the results of these application.
    If [l] is the list [a1],...,[an], then [star_apply f l] returns:
    [(f a1 a2) @ ... @ (f a1 an)] *)
let star_apply f = function
  | [] -> []
  | a :: l ->
    let rec star acc = function
      | [] -> acc
      | b :: rem -> star ((f a b) @ acc) rem in

    star [] l

let x_index_cnstrs state l select f_cnstr =
  List.fold_left
    (fun l t -> try cterm_of_term t :: l with Unsupported_conversion -> l)
    [] l
  |> subterms
  |> List.filter select
  |> List.sort_uniq Stdlib.compare
  |> List.map (fun x -> x, normalize state x)
  |> Utils.classes (fun (_,x) (_,y) -> x = y)
  |> List.map @@ List.map fst
  |> List.map (star_apply f_cnstr)
  |> List.flatten


(** [name_index_cnstrs state l] looks for all names that are equal w.r.t. the
    rewrite relation in [state], and add the corresponding index equalities.
    Only applies to names with \[large\] types.
    E.g., if n(i,j) and n(k,l) are equal, then i = k and j = l.*)
let name_index_cnstrs table state l =
  let n_cnstr a b = match a.cnt,b.cnt with
    | Ccst (Cst.Cgfuncst (`N n)), Ccst (Cst.Cgfuncst (`N n')) ->
      if n <> n' then [Term.mk_false] else []
      
    | Cfun (N (n,_), ari, is), Cfun (N (n',_), ari', is') ->
      assert (ari > 0 && ari' > 0);
      if n <> n' then [Term.mk_false]
      else begin
        assert (ari = ari');
        List.map2 (fun x y -> 
            Term.mk_atom `Eq 
              (Term.mk_var (index_of_cterm x))
              (Term.mk_var (index_of_cterm y))
          ) is is'
      end

    | Cfun (N (n,_), ari, _), Ccst (Cst.Cgfuncst (`N (n',_)))
    | Ccst (Cst.Cgfuncst (`N (n,_))), Cfun (N (n',_), ari, _) ->
      assert (ari <> 0 && n <> n');
      [Term.mk_false] 

    | _ -> assert false in

  x_index_cnstrs state l (is_lname table) n_cnstr


(** [name_indep_cnstrs state l] looks for all name equals to a term w.r.t. the
    rewrite relation in [state], and adds the fact that the name must be equal
    to one of the name appearing inside the term. 
    Only applies to names with \[large\] types. *)
let name_indep_cnstrs table state l =
  let n_cnstr (a : cterm) (b : cterm) = 
    if not (is_lname table a) && not (is_lname table b) then []
    else
      let name, t = if is_lname table a then a, b else b, a in
      let nty = name_ty name in

      (* We keep only the names in [t] that are of the correct type. *)
      let sub_names = subterms [t]
                      |> List.filter (is_lname ~of_ty:nty table)
                      |> List.sort_uniq Stdlib.compare
      in

      let rec mk_disjunction l =
        match l with
        | [] -> Term.mk_false
        | [p] -> 
          Term.mk_atom `Eq
            (term_of_cterm table Type.KMessage p)
            (term_of_cterm table Type.KMessage name)
        | p::q ->
          Term.mk_or
            (Term.mk_atom `Eq 
               (term_of_cterm table Type.KMessage p)
               (term_of_cterm table Type.KMessage name))
            (mk_disjunction q)
      in
      [mk_disjunction sub_names]
  in

  x_index_cnstrs state l
    (function f -> is_ground_cterm f && no_macros f)
    n_cnstr
  |>  List.filter (fun f -> not (Term.is_true f)) 
  |>  List.sort_uniq Stdlib.compare


(*------------------------------------------------------------------*)
(** {2 Tests Suites} *)

let mk_cst () = ccst (Cst.mk_flat ())

let (++) a b = cfun (F Symbols.fs_xor) 0 [a;b]

let () =
  let mk c = L.mk_loc Location._dummy c in
  Checks.add_suite "Completion" [
    ("Basic", `Quick,
     fun () ->
       let fi = Type.mk_ftype 0 [] [] Type.Message, Symbols.Abstract `Prefix in
       let table,ffs =
         Symbols.Function.declare_exact Symbols.builtins_table (mk "f") fi in
       let table,hfs =
         Symbols.Function.declare_exact table (mk "h") fi in
       let ffs,hfs = F ffs, F hfs in
       let f a b = cfun ffs 0 [a;b] in
       let h a b = cfun hfs 0 [a;b] in

       let e', e, d, c, b, a = mk_cst (), mk_cst (), mk_cst (),
                              mk_cst (), mk_cst (), mk_cst () in

       let v = ccst (Cst.Cmvar (Vars.EVar (snd (
           Vars.make `Approx Vars.empty_env (Type.Message) "v"))))
       in
       let state0 = complete_cterms table [(a,b); (b,c);
                                           (b,d); (e,e'); 
                                           (v,v)] in
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (c,e')) true;
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (c,d)) false;
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (v,d)) false;
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (a,c)) false;
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (f c d, f a b)) false;
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (f c d, f a e')) true;
       Alcotest.(check bool) "simple"
         (check_disequality_cterm state0 [] (f a a, h a a)) true;

       let state1 = complete_cterms table [(a,e'); 
                                           (a ++ b, c); 
                                           (e' ++ d, e)] in
       Alcotest.(check bool) "xor"
         (check_disequality_cterm state1 [] (b ++ c ++ d, e)) false;
       Alcotest.(check bool) "xor"
         (check_disequality_cterm state1 [] (a ++ b ++ d, e)) true;
       Alcotest.(check bool) "xor"
         (check_disequality_cterm state1 [] ( f (b ++ d) a, f (c ++ e) a)) false;
       Alcotest.(check bool) "xor"
         (check_disequality_cterm state1 [] ( f (b ++ d) a, f (a) a)) true;
    )]
