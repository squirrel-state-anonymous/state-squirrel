(*******************************************************************************
RUNNING EXAMPLE

This protocol is a variant of the OSK protocol described in:
M. Ohkubo, K. Suzuki, S. Kinoshita et al.,
“Cryptographic approach to “privacy-friendly” tags,”
RFID privacy workshop, vol. 82. Cambridge, USA, 2003.

Each tag is associated to a mutable state sT initialized with s0.
Readers have access to a database containing an entry sR for each authorized
tag.

         sT := H(sT,k)
T -> R : G(sT,k')

         input x; sR := H(sR,k) if x = G(H(sR,k),k') with sR in DB
R -> T : ok

COMMENTS
- In this model we only consider tags (no hash oracles, no readers)
  the goal is to illustrate a realistic use of `apply ~inductive`
  on a minimal example.

*******************************************************************************)

set autoIntro = false.

hash H
hash G
name k : message
name k' : message

name s0  : index -> message
name s0b : index -> message     (* renamed identities *)

mutable sT(i:index) : message = diff(s0(i),s0b(i))

abstract ok : message
channel cT

process tag(i:index) =
  sT(i):=H(sT(i),k);
  out(cT,G(sT(i),k'))

system !_i !_j T: tag(i).

set showStrengthenedHyp=true.

(* AXIOMS *)

(* Uniqueness of states:
   it is easily proved in other similar examples, we leave it out here. *)
axiom h_unique (i,i',j,j':index):
  sT(i)@T(i,j) = sT(i')@T(i',j') => (i = i' && j = j').

(* Indistinguishability between the sequences of initial states,
   before and after renaming. This is essentially an instance of the
   "fresh" tactic, but to do it within the tool we miss an induction
   principle over sequences. *)
global axiom fresh_names :
  equiv(seq(i:index->diff(s0(i),s0b(i)))).

global goal fresh_names_k :
  equiv(k, seq(i:index->diff(s0(i),s0b(i)))).
Proof.
  fresh 0. apply fresh_names.
Qed.

(* PROOFS *)

(* Observational equivalence with seeds and k as extra data:
   the proof would be the same without the extra data (except for the easy base case)
   which does not depend on t. *)
global goal equiv_with_seed (t : timestamp):
  [happens(t)] ->
  equiv(frame@t, k, seq(i:index->diff(s0(i),s0b(i)))).
Proof.
  intro Hap.
  induction t.

  fresh 1.
  expand frame; apply fresh_names.

  expandall. fa 0. fa 1. fa 1.
  prf 1; yesif 1.
    split; 1: auto.
    intro i0 j0 H Heq. use h_unique with i0, i, j0, j; 2: auto.
    destruct H0; auto.
  fresh 1.
  apply IH.
Qed.

(* With apply ~inductive we easily obtain all the past values of sT
   from the seeds and k. *)
global goal equiv_with_states_inductive (t : timestamp):
  [happens(t)] ->
  equiv(frame@t, k, seq(i:index,t':timestamp -> if t'<=t then sT(i)@t')).
Proof.
  intro Hap.
  apply ~inductive equiv_with_seed t; assumption.
Qed.

(* We now illustrate how the proof could go without the use of
   `apply ~inductive`. *)

(* We need some basic utilities. *)
include Basic.

goal neq_leq_lemma (t,t':timestamp): ((not(t=t')) && t<=t') = (t<=pred(t')).
Proof.
 rewrite eq_iff. 
 by case t.
Qed.

global goal equiv_with_states_manual (t : timestamp):
  [happens(t)] ->
  equiv(frame@t, k, seq(i:index,t':timestamp -> if t'<=t then sT(i)@t')).
Proof.
  intro Hap.
  induction t.

  (* The base case requires rewriting inside the sequence. *)
  equivalent seq(i:index,t':timestamp -> if t'<=init then sT(i)@t'),
             seq(i:index,t':timestamp -> if t'<=init then diff(s0(i),s0b(i))).
    by fa; fa.
  expand frame; apply fresh_names_k.

  expandall.
  fa 0. fa 1. fa 1.
  (* Get rid of item 1 using PRF, as before. *)
  prf 1; yesif 1.
    split; 1: auto.
    intro i0 j0 H Heq. use h_unique with i0, i, j0, j; 2: auto.
    destruct H0; auto.
  fresh 1.
  (* We now have to work on our sequence to remove the last element.
     This is done using splitseq to single out some elements,
     and then perform some rewriting inside the sequences. *)
  splitseq 2: (fun (i0:index,t':timestamp) -> t'=T(i,j)).
  rewrite !if_then_then.
  rewrite neq_leq_lemma in 3.
  (* We still can't conclude by IH. The sequence in position 2 is bi-deducible
     but to show it one needs to do a case analysis on i=i0 since the value
     of sT(i0)@T(i,j) depends on it. *)
  checkfail apply IH exn ApplyMatchFailure.
  splitseq 2: (fun (i0:index,t':timestamp) -> i0=i).
  rewrite !if_then_then.
  (* More rewriting inside sequences. *)
  equivalent
    seq(i0:index,t':timestamp-> if i0=i && (t'=T(i,j) && t'<=T(i,j)) then sT(i0)@t'),
    seq(i0:index,t':timestamp-> if i0=i && (t'=T(i,j) && t'<=T(i,j)) then H(sT(i0)@pred(t'),k));
  1: by fa; fa.
  equivalent
    seq(i0:index,t':timestamp-> if not(i0=i) && (t'=T(i,j) && t'<=T(i,j)) then sT(i0)@t'),
    seq(i0:index,t':timestamp-> if not(i0=i) && (t'=T(i,j) && t'<=T(i,j)) then sT(i0)@pred(t')).
    fa. fa; try auto. intro [H1 [H2 H3]]. rewrite H2. expand sT.
    by noif.
  (* At this point our automatic bi-deduction checker cannot verify that
     items 2 and 3 are bi-deducible. Its implementation could be improved
     to complete this tedious proof. *)
  admit.
Qed.
