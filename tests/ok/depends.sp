set autoIntro=false.

channel c

system !_i in(c,x);out(c,x);in(c,x);out(c,x).

goal _ (i:index): happens(A1(i)) => A(i) < A1(i).
Proof.
  intro Hap.
  by depends A(i), A1(i).
Qed.

(* Not true if only A1(i) happens *)
goal _ (i:index): happens(A(i)) => A(i) < A1(i).
Proof.
  intro Hap.
  checkfail (try (depends A(i), A1(i)); auto) exn GoalNotClosed.
Abort.
