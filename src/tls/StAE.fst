// Authenticated encryptions of streams of TLS fragments (from Content)
// multiplexing StatefulLHAE and StreamAE with (some) length hiding
// (for now, under-specifying ciphertexts lengths and values)
module StAE // See StAE.fsti
open FStar.HyperHeap
open Platform.Bytes
open TLSConstants
open TLSInfo

module HH   = FStar.HyperHeap
module MR   = FStar.Monotonic.RRef
module SeqP = FStar.SeqProperties
module S    = StreamAE
module MS   = MonotoneSeq
module C    = Content
#set-options "--initial_fuel 0 --max_fuel 0 --initial_ifuel 1 --max_ifuel 1"

////////////////////////////////////////////////////////////////////////////////
//Distinguishing the two multiplexing choices of StAE based on the ids
////////////////////////////////////////////////////////////////////////////////
// the first two should be concretely defined (for now in TLSInfo)
let is_stream_ae i = pv_of_id i = TLS_1p3

let is_stateful_lhae i = 
  pv_of_id i <> TLS_1p3 
  /\ is_AEAD i.aeAlg 
  /\ ~ (authId i) // NB as a temporary hack, we currently disable AuthId for TLS 1.2.
		 // so that we can experiment with TLS and StreamAE

// PLAINTEXTS are defined in Content.fragment i

// CIPHERTEXTS. 

////////////////////////////////////////////////////////////////////////////////
//Various utilities related to lengths of ciphers and fragments
////////////////////////////////////////////////////////////////////////////////
// sufficient to ensure the cipher can be processed without length errors
let validCipherLen (i:id) (l:nat) = 
  if is_stream_ae i then StreamPlain.plainLength (l - StreamAE.ltag i)
  else True //placeholder

let frag_plain_len (#i:id) (f:C.fragment i) : StreamPlain.plainLen = 
  snd (Content.rg i f) + 1

val cipherLen: i:id -> C.fragment i -> Tot (l:nat {validCipherLen i l})
let cipherLen i f = 
  if is_stream_ae i 
  then StreamAE.cipherLen i (frag_plain_len f)
  else 0 //placeholder
  
type encrypted (#i:id) (f:C.fragment i) = lbytes (cipherLen i f)
type decrypted (i:id) = b:bytes { validCipherLen i (length b) }

// CONCRETE KEY MATERIALS, for leaking & coercing.
// (each implementation splits it into encryption keys, IVs, MAC keys, etc)
let aeKeySize (i:id) = 
  if pv_of_id i = TLS_1p3 
  then CoreCrypto.aeadKeySize (StreamAE.alg i) + CoreCrypto.aeadRealIVSize (StreamAE.alg i)
  else 0 //FIXME!

type keybytes (i:id) = lbytes (aeKeySize i)

////////////////////////////////////////////////////////////////////////////////
//`state i rw`, a sum to cover StreamAE (1.3) and StatefulLHAE (1.2)
////////////////////////////////////////////////////////////////////////////////
type state (i:id) (rw:rw) = 
  | Stream: u:unit{is_stream_ae i}         -> StreamAE.state i rw -> state i rw 
  | StLHAE: u:unit{is_stateful_lhae i} -> StatefulLHAE.state i rw -> state i rw 

let stream_ae (#i:id{is_stream_ae i}) (#rw:rw) (s:state i rw) 
  : Tot (StreamAE.state i rw)
  = let Stream _ s = s in s

let st_lhae (#i:id{is_stateful_lhae i}) (#rw:rw) (s:state i rw) 
  : Tot (StatefulLHAE.state i rw)
  = let StLHAE _ s = s in s

val region: #i:id -> #rw:rw -> state i rw -> Tot rgn
let region (#i:id) (#rw:rw) (s:state i rw): Tot rgn = 
  match s with 
  | Stream u x -> StreamAE.State.region x
  | StLHAE u x -> StatefulLHAE.region x

val log_region: #i:id -> #rw:rw -> state i rw -> Tot rgn
let log_region (#i:id) (#rw:rw) (s:state i rw): Tot rgn = 
  match s with 
  | Stream _ s -> StreamAE.State.log_region s
  | StLHAE _ s -> if rw = Writer then StatefulLHAE.region s else StatefulLHAE.peer_region s //FIXME

type reader i = state i Reader
type writer i = state i Writer
// how to specify those two? Their properties are available at creation-time. 
// NS: I don't understand this comment

// our view to AE's ideal log (when idealized, ignoring ciphers) and counter
// TODO: write down their joint monotonic specification: both are monotonic, and seqn = length log when ideal

////////////////////////////////////////////////////////////////////////////////
//Logs of fragments, defined as projections on the underlying entry logs
////////////////////////////////////////////////////////////////////////////////
type frags (i:id) = Seq.seq (C.fragment i)  // TODO: consider adding constraint on terminator fragments

let ilog (#i:id) (#rw:rw) (s:state i rw{authId i}) = S.ilog (StreamAE.State.log (stream_ae s))

//A projection of fragments from StreamAE.entries
let fragments (#i:id) (#rw:rw) (s:state i rw{ authId i }) (h:HH.t) 
  : GTot (frags i)
  = match s with
    | Stream _ s -> 
      let entries = MR.m_sel h (StreamAE.ilog (StreamAE.State.log s)) in
      MS.map StreamAE.Entry.p entries

val lemma_fragments_snoc_commutes: #i:id -> w:writer i{is_stream_ae i}
    -> h0:HH.t -> h1:HH.t -> e:S.entry i
    -> Lemma (authId i
            ==>  ( let log = ilog w in
                      MR.m_sel h1 log = SeqP.snoc (MR.m_sel h0 log) e
                  ==> fragments w h1 = SeqP.snoc (fragments w h0) (StreamAE.Entry.p e)))
let lemma_fragments_snoc_commutes #i w h0 h1 e =
  if authId i
  then let log = ilog w in
       MS.map_snoc #(S.entry i) #(C.fragment i) StreamAE.Entry.p (MR.m_sel h0 log) e
  else ()
  
//A predicate stating that the fragments have fs as a prefix
let fragments_prefix (#i:id) (#rw:rw) (w:state i rw{authId i}) (fs:frags i) (h:HH.t) 
  : GTot Type0 = 
    MS.map_prefix (ilog w) StreamAE.Entry.p fs h

//In order to witness fragments_prefix s fs, we need to prove that it is stable
let fragments_prefix_stable (#i:S.id) (#rw:rw) (w:state i rw{is_stream_ae i /\ authId i}) (h:HH.t) 
  : Lemma (let fs = fragments w h in
	   MonotoneSeq.grows fs fs 
	   /\ MR.stable_on_t (ilog w) (fragments_prefix w fs))
  = let fs = fragments w h in
    MS.seq_extension_reflexive fs;
    MS.map_prefix_stable (ilog w) StreamAE.Entry.p fs

////////////////////////////////////////////////////////////////////////////////
//Projecting sequence numbers
////////////////////////////////////////////////////////////////////////////////

let seqnT (#i:id) (#rw:rw) (s:state i rw) h 
  : GTot seqn_t 
  = match s with 
    | Stream _ s -> MR.m_sel h (StreamAE.ctr (StreamAE.State.counter s))
    | StLHAE _ s -> HH.sel h (StatefulLHAE.State.seqn s)

//it's incrementable if it doesn't overflow
let incrementable (#i:id) (#rw:rw) (s:state i rw) (h:HH.t) = is_seqn (seqnT s h + 1)

// Some invariants:
// - the writer counter is the length of the log; the reader counter is lower or equal
// - gen is called at most once for each (i:id), generating distinct refs for each (i:id)
// - the log is monotonic

// We generate first the writer, then the reader (possibly several of them)


////////////////////////////////////////////////////////////////////////////////
//Framing
////////////////////////////////////////////////////////////////////////////////
val frame_fragments : #i:id -> #rw:rw -> st:state i rw -> h0:HH.t -> h1:HH.t -> s:Set.set rid 
	       -> Lemma 
    (requires HH.modifies_just s h0 h1
	      /\ Map.contains h0 (log_region st)
	      /\ not (Set.mem (log_region st) s))
    (ensures authId i ==> fragments st h0 = fragments st h1)
let frame_fragments #i #rw st h0 h1 s = ()

val frame_seqnT : #i:id -> #rw:rw -> st:state i rw -> h0:HH.t -> h1:HH.t -> s:Set.set rid 
	       -> Lemma 
    (requires HH.modifies_just s h0 h1
    	      /\ Map.contains h0 (region st)
	      /\ not (Set.mem (region st) s))
    (ensures seqnT st h0 = seqnT st h1) 
let frame_seqnT #i #rw st h0 h1 s = ()

let trigger_frame (h:HH.t) = True

let frame_f (#a:Type) (f:HH.t -> GTot a) (h0:HH.t) (s:Set.set rid) =
  forall h1.{:pattern trigger_frame h1} 
        trigger_frame h1
        /\ (HH.equal_on s h0 h1 ==> f h0 = f h1)

val frame_seqT_auto: i:id -> rw:rw -> s:state i rw -> h0:HH.t -> h1:HH.t -> 
  Lemma (requires   HH.equal_on (Set.singleton (region s)) h0 h1 
		  /\ Map.contains h0 (region s))
        (ensures seqnT s h0 = seqnT s h1)
	[SMTPat (seqnT s h0); 
	 SMTPat (seqnT s h1)]
//	 SMTPatT (trigger_frame h1)]
let frame_seqT_auto i rw s h0 h1 = ()

val frame_fragments_auto: i:id{authId i} -> rw:rw -> s:state i rw -> h0:HH.t -> h1:HH.t -> 
  Lemma (requires    HH.equal_on (Set.singleton (log_region s)) h0 h1 
		  /\ Map.contains h0 (log_region s))
        (ensures fragments s h0 = fragments s h1)
	[SMTPat (fragments s h0); 
	 SMTPat (fragments s h1)] 
	 (* SMTPatT (trigger_frame h1)] *)
let frame_fragments_auto i rw s h0 h1 = ()

////////////////////////////////////////////////////////////////////////////////
//Experimenting with reads clauses: probably unnecessary
////////////////////////////////////////////////////////////////////////////////
let reads (s:Set.set rid) (a:Type) = 
    f: (h:HH.t -> GTot a){forall h1 h2. (HH.equal_on s h1 h2 /\ Set.subset s (Map.domain h1))
				  ==> f h1 = f h2}

val fragments' : #i:id -> #rw:rw -> s:state i rw{ authId i } -> Tot (reads (Set.singleton (log_region s)) (frags i))
let fragments' #i #rw s = fragments s

////////////////////////////////////////////////////////////////////////////////
//Generation
////////////////////////////////////////////////////////////////////////////////
let genPost (#i:id) parent h0 (w:writer i) h1 = 
  let r = region w in 
  HH.modifies Set.empty h0 h1 /\
  HH.parent r = parent /\
  HH.fresh_region r h0 h1 /\
  color r = color parent /\
  seqnT w h1 = 0 /\
  (authId i ==> fragments w h1 = Seq.createEmpty) // we need to re-apply #i knowning authId

// Generate a fresh instance with index i in a fresh sub-region 
val gen: parent:rid -> i:id -> ST (writer i)
  (requires (fun h0 -> True))
  (ensures (genPost parent))
#set-options "--initial_fuel 1 --max_fuel 1 --initial_ifuel 1 --max_ifuel 1"  
let gen parent i = 
  assume (is_stream_ae i);
  Stream () (StreamAE.gen parent i)

val genReader: parent:rid -> #i:id -> w:writer i -> ST (reader i)
  (requires (fun h0 -> HyperHeap.disjoint parent (region w))) //16-04-25  we may need w.region's parent instead
  (ensures  (fun h0 (r:reader i) h1 ->
               modifies Set.empty h0 h1 /\
               log_region r = region w /\
               HH.parent (region r) = parent /\
	       color (region r) = color parent /\
               fresh_region (region r ) h0 h1 /\
               //?? op_Equality #(log_ref w.region i) w.log r.log /\
               seqnT r h1 = 0))
// encryption, recorded in the log; safe instances are idealized
let genReader parent #i w =  
  assume (is_stream_ae i);
  match w with 
  | Stream _ w -> Stream () (StreamAE.genReader parent w) 

////////////////////////////////////////////////////////////////////////////////
//Coerce & Leak
////////////////////////////////////////////////////////////////////////////////

// Coerce a writer with index i in a fresh subregion of parent
// (coerced readers can then be obtained by calling genReader)
val coerce: parent:rid -> i:id{~(authId i)} -> keybytes i -> ST (writer i)
  (requires (fun h0 -> True))
  (ensures  (genPost parent))
let coerce parent i kiv = 
   assume(is_stream_ae i); 
   let kv, iv = Platform.Bytes.split kiv (CoreCrypto.aeadKeySize (StreamAE.alg i)) in 
   Stream () (StreamAE.coerce parent i kv iv) 

val leak: #i:id{~(authId i)} -> #role:rw -> state i role -> ST (keybytes i)
  (requires (fun h0 -> True))
  (ensures  (fun h0 r h1 -> modifies Set.empty h0 h1 ))
let leak #i #role s =  
   assume (is_stream_ae i); 
   match s with 
   | Stream _ s -> let kv, iv = StreamAE.leak s in kv @| iv

////////////////////////////////////////////////////////////////////////////////
//Encryption
////////////////////////////////////////////////////////////////////////////////
#reset-options "--initial_fuel 0 --max_fuel 0 --initial_ifuel 1 --max_ifuel 1"  
val encrypt: #i:id -> e:writer i -> f:C.fragment i -> ST (encrypted f)
  (requires (fun h0 -> incrementable e h0))
  (ensures  (fun h0 c h1 ->
               modifies_one (region e) h0 h1 
	       /\ seqnT e h1 = seqnT e h0 + 1   
	       /\ frame_f (seqnT e) h1 (Set.singleton (log_region e))
	       /\ (authId i 
		  ==> fragments e h1 = SeqP.snoc (fragments e h0) f
		      /\ frame_f (fragments e) h1 (Set.singleton (log_region e))
		      /\ MR.witnessed (fragments_prefix e (fragments e h1)))))

let encrypt #i e f =
  assume (is_stream_ae i); //FIXME: Not handling TLS-1.2 yet
  match e with
  | Stream _ s -> 
    let h0 = ST.get() in
    let l = frag_plain_len f in
    let c = StreamAE.encrypt s l f in
    let h1 = ST.get() in
    lemma_fragments_snoc_commutes e h0 h1 (S.Entry l c f);
    if authId i 
    then begin 
         fragments_prefix_stable e h1;
	 MR.witness (ilog e) (fragments_prefix e (fragments e h1))
    end;
    c

////////////////////////////////////////////////////////////////////////////////
//Decryption
////////////////////////////////////////////////////////////////////////////////
// decryption, idealized as a lookup for safe instances
let fragment_at_j (#i:id) (#rw:rw) (st:state i rw{authId i}) (n:nat) (f:C.fragment i) h = 
  MS.map_has_at_index (ilog st) StreamAE.Entry.p n f h
  
let fragment_at_j_stable (#i:id) (#rw:rw) (st:state i rw{authId i}) (n:nat) (f:C.fragment i)
  : Lemma (MR.stable_on_t (ilog st) (fragment_at_j st n f))
  = MS.map_has_at_index_stable (ilog st) StreamAE.Entry.p n f

val decrypt: #i:id -> d:reader i -> c:decrypted i -> ST (option (f:C.fragment i { frag_plain_len f <= cipherLen i f}))
  (requires (fun h0 -> incrementable d h0))
  (ensures  (fun h0 res h1 ->
	      match res with
 	     | None   -> modifies Set.empty h0 h1
	     | Some f -> let j = seqnT d h0 in 
		        seqnT d h1 = j + 1 /\
                        modifies_one (region d) h0 h1 /\
			(authId i ==>
			   (let written = fragments d h0 in
  			    j < Seq.length written /\
			    f = Seq.index written j /\
			    frame_f (fragments d) h1 (Set.singleton (log_region d)) /\
			    MR.witnessed (fragment_at_j d j f)))))
let decrypt #i d c =  
   assume (is_stream_ae i);
   let h0 = ST.get () in
   match d with 
   | Stream _ s -> 
     recall_region (StreamAE.State.log_region s);
     (match StreamAE.decrypt s (StreamAE.lenCipher i c) c with 
      | None -> None
      | Some f -> 
	if authId i
	then (fragment_at_j_stable d (seqnT d h0) f;
	      MR.witness (ilog d) (fragment_at_j d (seqnT d h0) f));
	Some f) 


  


