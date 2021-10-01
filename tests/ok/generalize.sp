set autoIntro=false.

abstract a : message
abstract b : message
abstract c : message
abstract d : message
abstract e : message

abstract ok : index   -> message
abstract f  : message -> message
channel ch

system A: !_i in(ch,x);out(ch,<ok(i),x>).

abstract even : message -> boolean.

(*------------------------------------------------------------------*)
(* reach *)

goal _ :
 (forall (x,y : message), x = a || y = b) =>
 (forall (y,x : message), x = a || y = b).
Proof.
  intro Ass y x.
  generalize x y.
  assumption.
Qed.

goal _ :
 (forall (u,v : message), u = a || v = b) =>
 (forall (y,x : message), x = a || y = b).
Proof.
  intro Ass y x.
  generalize x y as u v.
  assumption.
Qed.

goal _ :
 (forall (x,y : message), x = a || y = b) =>
 (forall (y,x : message), f(x) = a || f(y) = b).
Proof.
  intro Ass y x.
  generalize (f(x)) (f(y)) as x y.
  assumption.
Qed.

goal _ (z : message) :
 (forall (x,z:message), (forall (y:message), y = z) => even(x)) =>
 (forall (y : message), y = z) =>
 (forall (x : message), even(x)).
Proof.
  intro Hyp Ass x.
  generalize dependent x z as x z. 
  assumption.
Qed.
