set autoIntro=false.

abstract ok : index->message
channel c

(*------------------------------------------------------------------*)
system A: !_i in(c,x);out(c,<ok(i),x>).

include Basic.

(*------------------------------------------------------------------*)
global goal _ (x : message): 
  equiv(x) -> [forall (i : index), ok(i) = x] ->
  equiv(seq(i:index -> diff(ok(i), x))).
Proof.
  intro Hx H.
  constseq 0: (fun (i:index) -> true) x. 
    assumption.
    by project. 
    assumption.
Qed.  

abstract ko : index->message.

(* sequence over a timestamp *)
global goal _ (x : message, t:timestamp, i:index): 
  equiv(x) -> [forall (i : index), ok(i) = ko(i)] ->
  equiv(seq(t':timestamp -> if t' < t then diff(ok(i), ko(i)))).
Proof.
  intro Hequiv Hi.
  constseq 0: 
    (fun (t':timestamp) -> t' < t) (ok(i)) 
    (fun (t':timestamp) -> not (t' < t)) zero.
  auto. 
  rewrite Hi.
  split => t' _.
  by rewrite if_true; project. 
  by rewrite if_false; project. 
  auto.
Qed.  
