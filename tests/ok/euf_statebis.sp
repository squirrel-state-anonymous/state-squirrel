set autoIntro=false.

mutable s : message = empty
hash h
name k : message
system s := s.

goal _ (tau:timestamp) : happens(tau) => output@tau <> h(zero,k).
Proof.
  intro Hap Heq.
  euf Heq.
Qed.
