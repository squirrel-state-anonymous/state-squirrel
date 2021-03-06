(*******************************************************************************

Generic 2xKEM - key exchange from Key encapsulation Mechanism (KEM)


[A] Boyd, Colin and Cliff, Yvonne and Nieto, Juan M. Gonzalez and Paterson, Kenneth G. One-round key exchange in the standard model.

# On KEMs

The protocol uses KEMS. In the paper, they are id based, which we abstract here.

The KEM are usally described with
(ek,dk) <- Keygen(r) returns an encryption key ek and a decryption key ek
(k,ct) <- Encap(r,ek) returns a session key k and its cyphertext ct
k <- Decap(ct,dk) returns k.

We abstract this with, pk, encap and decap function symbols, where
 * dk is a name, ek = pk(dk)
 * k is a name, ct=encap(k,r,pk(dk)).
 * decap(encap(k,r,pk(dk)),dk) = k

# Protocol parameters

A KEMs Pk Encap DeCap

PRFs : Exct and Expd

Two parties I (initiator) and R (responder)

shared key skex for Exct

Public identities I and R
Static keys for party X := skX
Public keys for party X : pkX = pk(skX)


# Protocol description

I:
new kI;
ctI := Encap(kI, rI  ,pk(skR))
I --(I,ctI)-> R

R:
new kR;
ctR := Encap(kR, rR , pk(skI))
I <--(R,ctR)-- R


I:
kR := Decap(ctR,dkI)

R:
kI := Decap(ctI,dkI)

Boths:
kI2 := Exct(kI,skex)
kR2 := Exct(kR,skex)


s := (I,ctI,R,ctR)
KIR := expd(s,kI2) XOR expd(s,kR2)


# High level intuitions

kI is a fresh key, generated by I and sent to R via Encap using the longterm public key of R
kR is a fresh key, generated by R and sent to I via Encap using the longterm public key of I

*******************************************************************************)

hash exct

hash expd

(* public random key for exct *)

name skex : message

(* KEM *)

aenc encap,decap,pk

(* long term key of I *)

name skI : message

(* long term key of R *)
name skR : message

(* session randomess of I *)
name kI : index->message
name rI : index->message

(* session randomess of R *)
name kR : index->message
name rR : index->message


(* ideal keys *)
name ikIR : index -> index ->message

channel cI
channel cR.

process Initiator(i:index) =
 let ctI = encap(kI(i), rI(i) ,pk(skR)) in
 out(cI, ctI ); (*we omit the public parameters in the output *)

 in(cR,ctR);

 (* first key derivation *)
 let dkR = decap(ctR,skI) in

 (* common derivations *)
 let kI2 = exct(kI(i),skex) in
 let kR2 = exct(dkR,skex) in
 let s = <pk(skI),<ctI,<pk(skR),ctR>>> in
 let kIR = expd(s,kI2) XOR expd(s,kR2) in

 (* outputting the key should be real or random when the partner is honnest *)
 out(cI, try find j such that dkR = kR(j) in  diff(ikIR(i,j), kIR) else kIR).


process Responder(j:index) =
   in(cI, ctI);

   let ctR = encap(kR(j), rR(j), pk(skI)) in (* we hardcode the public key of I here, we need to add in parallel the responder that wants to talk to anybody *)
   out(cR,ctR);

   (* first key derivation *)
   let dkI = decap(ctI,skR) in

 (* common derivations *)
 let kI2 = exct(dkI,skex) in
 let kR2 = exct(kR(j),skex) in
 let s = <pk(skI),<ctI,<pk(skR),ctR>>> in
 let kIR = expd(s,kI2) XOR expd(s,kR2) in

 (* outputting the key should be real or random when the partner is honnest *)
 out(cR, try find i such that dkI = kI(i) in  diff(ikIR(i,j), kIR) else kIR).


system out(cI,skex); ((!_j R: Responder(j)) | (!_i I: Initiator(i))).

equiv main.
Proof.
 enrich skex; enrich pk(skI); enrich pk(skR).
induction t.
  expandall.
  by fa 3.

  (* first output of R *)
  expandall.
  fa 3.
  fa 4.
  fa 4.
  cca1 4.

  equivalent len(kR(j)), len(skex).
  namelength kR(j), skex.
  case j0=j.


  assert happens(R1(j)).
  by depends R(j), R1(j).

 (* diff output  of R *)
 admit.


 (* first output of I *)
  expandall.
  fa 3.
  fa 4.
  fa 4.
  cca1 4.

  equivalent len(kI(i)), len(skex).
  namelength kI(i), skex.
  case i0=i.


  assert happens(I1(i)).
  by depends I(i), I1(i).

 (* diff output of I *)

 admit.

Qed.
