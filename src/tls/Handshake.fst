﻿module Handshake

open FStar.Heap
open FStar.HyperHeap
//FIXME! Don't open so much ... gets confusing. Use module abbrevs instead
open FStar.Seq
open FStar.SeqProperties // for e.g. found
open FStar.Set  

open Platform.Error
open Platform.Bytes

open TLSError
open TLSInfo
open TLSConstants
open Range
open HandshakeMessages
open HSCrypto
open StAE

//16-05-31 these opens are implementation-only; overall we should open less
open TLSExtensions 
open CoreCrypto
open HandshakeLog


module HH = FStar.HyperHeap
module MR = FStar.Monotonic.RRef
module MS = MonotoneSeq

#set-options "--lax" 

// represents the outcome of a successful handshake, 
// providing context for the derived epoch
type handshake = 
  | Fresh of sessionInfo
  | Resumed of abbrInfo * sessionInfo //changed: was hs * seq epoch (creating cycle)
// We use SessionInfo as unique session indexes.
// We tried using instead hs, but this creates circularities
// We'll probably need a global log to reason about them.
// We should probably do the same in the session store.

// extracts a transport key identifier from a handshake record
val hsId: handshake -> Tot id 
//16-05-31 TODO breaking TC in TLS; was (i:id { is_stream_ae i }) //16-05-19 focus on TLS 1.3

let hsId h = noId // Placeholder 


//<expose for TestClient>
(* Negotiation: HELLO sub-module *)
private type ri = cVerifyData * sVerifyData 
type b_log = bytes 


type eph_s = option kex_s_priv
type eph_c = list kex_s_priv
type nego = {
     n_resume: bool;
     n_client_random: TLSInfo.random;
     n_server_random: TLSInfo.random;
     n_sessionID: option sessionID;
     n_protocol_version: protocolVersion;
     n_kexAlg: TLSConstants.kexAlg;
     n_aeAlg: TLSConstants.aeAlg;
     n_sigAlg: option TLSConstants.sigAlg;
     n_cipher_suite: cipherSuite;
     n_dh_group: option namedGroup;
     n_compression: option compression;
     n_extensions: negotiatedExtensions;
     n_scsv: list scsv_suite;
}                 

type hs_id = {
     id_cert: Cert.chain;
     id_sigalg: option sigHashAlg;
}

type session = {
     session_nego: nego;
}     

    

val prepareClientHello: config -> KeySchedule.ks -> HandshakeLog.log -> option ri -> option sessionID -> ST (hs_msg * bytes)
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let prepareClientHello cfg ks log ri sido =
  let cr = KeySchedule.ks_client_random ks in
  let kp = 
     (match cfg.maxVer with
      | TLS_1p3 -> 
         let gxl = KeySchedule.ks_client_13_init_1rtt ks cfg.namedGroups in 
	 Some (ClientKeyShare gxl)
      | _ -> 
      	 let _ = KeySchedule.ks_client_init_12 ks in 
	 None) in
  let sid = (match sido with | None -> empty_bytes | Some x -> x) in
  let ci = initConnection Client cr in
  let ext = prepareExtensions cfg ci ri kp in
  let ch = 
  {ch_protocol_version = cfg.maxVer;
   ch_client_random = cr;
   ch_sessionID = sid;
   ch_cipher_suites = cfg.ciphersuites;
   ch_raw_cipher_suites = None;
   ch_compressions = [NullCompression];
   ch_extensions = Some ext;} in
  let chb = log @@ (ClientHello ch) in
  (ClientHello ch, chb)

//16-05-31 somewhat duplicating TLSConstants.geqPV
(* Is [pv1 >= pv2]? *)
val gte_pv: protocolVersion -> protocolVersion -> Tot bool
let gte_pv pv1 pv2 =
  match pv1 with
  | SSL_3p0 -> (match pv2 with | SSL_3p0 -> true | _ -> false)
  | TLS_1p0 -> (match pv2 with | SSL_3p0 | TLS_1p0 -> true | _ -> false)
  | TLS_1p1 -> (match pv2 with | SSL_3p0 | TLS_1p0 | TLS_1p1 -> true | _ -> false)
  | TLS_1p2 -> (match pv2 with | TLS_1p3 -> false | _ -> true)
  | TLS_1p3 -> true

(* Returns [c] if [c] is within the range of acceptable versions for [cfg],
 * [Error] otherwise. *)
val negotiateVersion: cfg:config -> c:protocolVersion -> Tot (result protocolVersion)
let negotiateVersion cfg c =
  if gte_pv c cfg.minVer && gte_pv cfg.maxVer c then Correct c
  else if gte_pv c cfg.maxVer then Correct cfg.maxVer
  else Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "Protocol version negotiation failed")

val negotiate:list 'a -> list 'a -> Tot (option 'a)
let negotiate l1 l2 =
  List.Tot.tryFind (fun s -> List.Tot.existsb (fun c -> c = s) l1) l2

val negotiateCipherSuite: cfg:config -> pv:protocolVersion -> c:valid_cipher_suites -> Tot (result (TLSConstants.kexAlg * option TLSConstants.sigAlg * TLSConstants.aeAlg * valid_cipher_suite))
let negotiateCipherSuite cfg pv c =
  match negotiate c cfg.ciphersuites with
  | Some(CipherSuite kex sa ae) -> Correct(kex,sa,ae,CipherSuite kex sa ae)
  | None -> Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "Cipher suite negotiation failed")

// TODO : IMPLEMENT
val getCachedSession: cfg:config -> ch:ch -> ST (option session)
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let getCachedSession cfg cg = None

val negotiateGroupKeyShare: cfg:config -> protocolVersion -> kexAlg -> exts:option (list extension) -> Tot (result (namedGroup * option bytes))
let rec negotiateGroupKeyShare cfg pv kex exts = 
    match pv,kex,exts with
    | TLS_1p3, Kex_ECDHE, Some (E_keyShare (ClientKeyShare ((gn,gxb)::_)) :: _) ->
      Correct (gn,Some gxb)
    | TLS_1p3,_, Some (h::t) -> negotiateGroupKeyShare cfg pv kex (Some t)
    | TLS_1p2, Kex_ECDHE, _ -> Correct (SEC CoreCrypto.ECC_P256, None) 
    | _ -> Error(AD_decode_error, "no supported group or key share extension found")
    

// FIXME: TLS1.3
val prepareServerHello: config -> KeySchedule.ks -> HandshakeLog.log -> option ri -> (hs_msg * bytes) -> ST (result (nego * option KeySchedule.recordInstance * (hs_msg * bytes)))
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let prepareServerHello cfg ks log ri (ClientHello ch,_) =
  match negotiateVersion cfg ch.ch_protocol_version with
    | Error(z) -> Error(z)
    | Correct(pv) ->
  match negotiateCipherSuite cfg pv ch.ch_cipher_suites with
    | Error(z) -> Error(z)
    | Correct(kex,sa,ae,cs) ->
  match negotiateGroupKeyShare cfg pv kex ch.ch_extensions with
    | Error(z) -> Error(z)
    | Correct(gn,gxo) ->
  let srand = KeySchedule.ks_server_random ks in
  let ksl = 
    (match pv,gxo with
     | TLS_1p3,Some gxb -> 
       let gyb = KeySchedule.ks_server_13_1rtt_init ks ch.ch_client_random cs gn gxb in
       (Some (ServerKeyShare (gn,gyb)))
    | _ -> None) in
  match negotiateServerExtensions pv ch.ch_extensions ch.ch_cipher_suites cfg cs ri ksl false with
    | Error(z) -> Error(z)
    | Correct(sext,next) ->
    let sid = CoreCrypto.random 32 in
    let comp = match ch.ch_compressions with
      | [] -> None
      | _ -> Some NullCompression in
    let sh = 
      {sh_protocol_version = pv;
       sh_sessionID = Some sid;
       sh_server_random = srand;
       sh_cipher_suite = cs;
       sh_compression = comp;
       sh_extensions = sext} in
    let nego = 
      {n_client_random = ch.ch_client_random;
       n_server_random = srand;
       n_sessionID = Some sid;
       n_protocol_version = pv;
       n_kexAlg = kex;
       n_sigAlg = sa;
       n_aeAlg  = ae;
       n_cipher_suite = cs;
       n_compression = comp;
       n_dh_group = Some gn;
       n_scsv = [];
       n_extensions = next;
       (* [getCachedSession] returned [None], so no session resumption *)
       n_resume = false} in
    let _ = log @@ (ClientHello ch) in
    let shb = log @@ (ServerHello sh) in
    let lb = HandshakeLog.getHash log in
    let keys = (match pv with
    	     | TLS_1p3 -> 
	       let keys = KeySchedule.ks_server_13_get_htk ks lb  in
	       Some keys
	     | _ -> None) in
    Correct (nego,keys,(ServerHello sh,shb))

(* Is this one of the special random values indicated by the RFC (6.3.1.1)? *)
val isSentinelRandomValue: protocolVersion -> protocolVersion -> TLSInfo.random -> Tot bool
let isSentinelRandomValue c_pv s_pv s_random =
  gte_pv c_pv TLS_1p3 && gte_pv TLS_1p2 s_pv && equalBytes (abytes "DOWNGRD\x01") s_random ||
  gte_pv c_pv TLS_1p2 && gte_pv TLS_1p1 s_pv && equalBytes (abytes "DOWNGRD\x00") s_random

(* If [true], then:
  - both the client and server versions are within the range specified by [cfg]
  - the server is not newer than the client
  - there is no undesired downgrade (as indicated by the special random values).
*)
val acceptableVersion: config -> ch -> protocolVersion -> TLSInfo.random -> Tot bool
let acceptableVersion cfg ch s_pv s_random =
  match negotiateVersion cfg ch.ch_protocol_version with
  | Correct c_pv -> 
    gte_pv c_pv s_pv && gte_pv s_pv cfg.minVer &&
    not (isSentinelRandomValue c_pv s_pv s_random)
  | Error _ ->
    false

(* If [true], then:
  - [s_cs] is has been offered previously;
  - [s_cs] is consistent with the [config];
  - TODO: [s_cs] is supported by the protocol version (e.g. no GCM with
    TLS<1.2).
*)
val acceptableCipherSuite: config -> ch -> protocolVersion -> valid_cipher_suite -> Tot bool
let acceptableCipherSuite cfg ch s_pv s_cs =
  // JP: I would think the first line implies the second one?
  List.Tot.existsb (fun x -> x = s_cs) ch.ch_cipher_suites &&
  List.Tot.existsb (fun x -> x = s_cs) cfg.ciphersuites &&
  not (isAnonCipherSuite s_cs) || cfg.allowAnonCipherSuite
  
val processServerHello: c:config -> KeySchedule.ks -> HandshakeLog.log -> option ri -> ch -> (hs_msg * bytes) ->
                        ST (result (nego * option KeySchedule.recordInstance))
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let processServerHello cfg ks log ri ch (ServerHello sh,_) =
  let _ = log @@ (ServerHello sh) in
  // Assuming no resumption; TODO: add it 
  if not (acceptableVersion cfg ch sh.sh_protocol_version sh.sh_server_random) then
    Error(AD_illegal_parameter, perror __SOURCE_FILE__ __LINE__ "Protocol version negotiation")
  else  if not (acceptableCipherSuite cfg ch sh.sh_protocol_version sh.sh_cipher_suite) then
    Error(AD_illegal_parameter, perror __SOURCE_FILE__ __LINE__ "Ciphersuite negotiation")
  else
  let resume = false in
  match negotiateClientExtensions sh.sh_protocol_version cfg ch.ch_extensions sh.sh_extensions sh.sh_cipher_suite ri resume with
    | Error z -> Error z
    | Correct next -> 
        match sh.sh_cipher_suite with
	| CipherSuite kex sa ae ->
        let o_nego = 
          {n_client_random = ch.ch_client_random;
           n_server_random = sh.sh_server_random;
           n_sessionID = sh.sh_sessionID;
           n_protocol_version = sh.sh_protocol_version;
           n_kexAlg = kex;
           n_aeAlg = ae;
	   n_sigAlg = sa;
           n_cipher_suite = sh.sh_cipher_suite;
	   n_dh_group = None;
           n_compression = sh.sh_compression;
	   n_scsv = [];
           n_extensions = next;
           n_resume = false } in
	   (match sh.sh_protocol_version, kex, next.ne_keyShare with
	    | TLS_1p3, Kex_DHE, Some (gn,gyb) 
	    | TLS_1p3, Kex_ECDHE, Some (gn,gyb) -> 
	      	   let lb = HandshakeLog.getHash log in
	           let keys = KeySchedule.ks_client_13_1rtt ks o_nego.n_cipher_suite (gn, gyb) lb in
	      	   Correct (o_nego,Some keys)
            | _ -> Correct (o_nego,None))
	| _ -> Error (AD_decode_error, "ServerHello CipherSuite not a real ciphersuite")


(* Handshake API: TYPES, taken from FSTI *)

type clientState = 
  | C_Idle:                  option ri -> clientState
  | C_HelloSent:        option ri -> ch -> clientState
  | C_HelloReceived:              nego -> clientState
  | C_OutCCS:                     nego -> clientState
  | C_FinishedSent: nego -> cVerifyData -> clientState
  | C_CCSReceived:  nego -> cVerifyData -> clientState
  | C_Error:                     error -> clientState

type serverState = 
  | S_Idle:                  option ri -> serverState
  | S_HelloSent :                 nego -> serverState
  | S_HelloDone :                 nego -> serverState
  | S_CCSReceived :               nego -> serverState
  | S_OutCCS:                     nego -> serverState
  | S_FinishedSent :              nego -> serverState
  | S_ResumeFinishedSent :        nego -> serverState
  | S_ZeroRTTReceived :           nego -> serverState
  | S_Error:                     error -> serverState

type role_state = 
    | C of clientState
    | S of serverState


//16-06-01 we don't need to precisely track this part of the state
//16-06-01 later, pre-allocate large-enough buffers for the connection.
//16-06-01 also revisit type of encrypted messages

type hs_msg_bufs = {
     hs_incoming_parsed : list (hs_msg * bytes); // messages parsed earlier
     hs_incoming: bytes;                         // incomplete message received earlier
     hs_outgoing: bytes;                         // messages to be sent in current epoch
}
let hs_msg_bufs_init() = {
     hs_incoming_parsed = [];
     hs_incoming = empty_bytes;
     hs_outgoing = empty_bytes;
}


//16-05-31 this type should be private to HS
//16-06-01 simplify: use a record of mutable things, subject to monotonicity and region, 
//16-06-01 rather than a mutable ref to a record
type handshake_state (r:role) =
     {
       hs_state: role_state;
       hs_nego: option nego;
       hs_log: HandshakeLog.log; // already stateful
       hs_ks: KeySchedule.ks;    // already stateful

       hs_buffers: hs_msg_bufs;

       //16-06-01 could use the StreamAE.ideal_ctr pattern; see also logIndex below.
       hs_reader: int;               
       hs_writer: int;
     }

//NS: needed this renaming trick for the .fsti
//let handshake_state r = handshake_state' r


//</expose for TestClient>

// relocate?
type fresh_subregion r0 r h0 h1 = fresh_region r h0 h1 /\ extends r r0

type epoch_region_inv (#i:id) (hs_rgn:rgn) (r:reader (peerId i)) (w:writer i) =
  disjoint hs_rgn (region w)                  /\
  parent (region w) <> FStar.HyperHeap.root    /\
  parent (region r) <> FStar.HyperHeap.root    /\
  parent hs_rgn = parent (parent (region w))  /\ //Grandparent of each writer is a sibling of the handshake
  disjoint (region w) (region r)              /\
  is_epoch_rgn (region w)                     /\ //they're all colored as epoch regions
  is_epoch_rgn (region r)                     /\
  is_epoch_rgn (parent (region w))            /\
  is_epoch_rgn (parent (region r))            /\
  is_hs_rgn hs_rgn                              //except for the hs_rgn, of course

abstract type epoch_region_inv' (#i:id) (hs_rgn:rgn) (r:reader (peerId i)) (w:writer i) =
  epoch_region_inv hs_rgn r w
  
module I = IdNonce

type epoch (hs_rgn:rgn) (n:TLSInfo.random) = 
  | Epoch: h: handshake ->
           r: reader (peerId (hsId h)) ->
           w: writer (hsId h) {epoch_region_inv' hs_rgn r w /\ I.nonce_of_id (hsId h) = n} 
	   -> epoch hs_rgn n
  // we would extend/adapt it for TLS 1.3,
  // e.g. to notify 0RTT/forwad-privacy transitions
  // for now epoch completion is a total function on handshake --- should be stateful


val getId: KeySchedule.recordInstance -> GTot id
let getId k = 
    match k with
    | KeySchedule.StAEInstance #i rd wr -> i
    | KeySchedule.StLHAEInstance #i rd wr -> i

val recordInstanceToEpoch: #hs_rgn:rgn -> #n:TLSInfo.random -> h:handshake -> ks:KeySchedule.recordInstance -> epoch hs_rgn n
let recordInstanceToEpoch #hs_rgn #n hs ri = 
    match ri with
    | KeySchedule.StAEInstance #i rd wr -> Epoch hs (StAE.Stream () rd) (StAE.Stream () wr)
    | KeySchedule.StLHAEInstance #i rd wr -> Epoch hs (StAE.StLHAE () rd) (StAE.StLHAE () wr)

(* 16-06-02 unmerged variant:
val getId: KeySchedule.recordInstance -> GTot id
let getId k = 
    match k with
    | KeySchedule.StAEInstance #i rd wr -> i
    | KeySchedule.StLHAEInstance #i rd wr -> i

val recordInstanceToEpoch: h:handshake -> ks:KeySchedule.recordInstance -> (StAE.reader (peerId (hsId h)) * StAE.writer (hsId h))
let recordInstanceToEpoch hs ri = 
    match ri with
    | KeySchedule.StAEInstance #i rd wr -> (StAE.Stream () rd),(StAE.Stream () wr)
    | KeySchedule.StLHAEInstance #i rd wr -> (StAE.StLHAE () rd),(StAE.StLHAE () wr)
*)


let id_TLS12_AES_GCM_128_SHA256  = {
    msId = noMsId;
    kdfAlg = PRF_TLS_1p2 kdf_label (HMAC CoreCrypto.SHA256);
    pv = TLS_1p2;
    aeAlg = (AEAD CoreCrypto.AES_128_GCM CoreCrypto.SHA256);
    csrConn = bytes_of_hex "";
    ext = {
      ne_extended_ms = false;
      ne_extended_padding = false;
      ne_secure_renegotiation = RI_Unsupported;
      ne_supported_groups = None;
      ne_supported_point_formats = None;
      ne_server_names = None;
      ne_signature_algorithms = None;
      ne_keyShare = None;
    };
    writer = Client
  }
     
val encryptor_TLS12_AES_GCM_128_SHA256: hs:handshake -> bytes -> bytes -> StAE.writer (hsId hs)
let encryptor_TLS12_AES_GCM_128_SHA256 hs key iv = 
  let id = hsId hs in
  let r = HyperHeap.root in
  let w: StatefulLHAE.writer id =
    let log: StatefulLHAE.st_log_t r id = ralloc r Seq.createEmpty in
    let seqn: HyperHeap.rref r seqn_t = ralloc r 0 in
    let key: AEAD_GCM.state id Writer =
      // The calls to [unsafe_coerce] are here because we're breaking
      // abstraction, as both [key] and [iv] are declared as private types.
      let key: AEAD_GCM.key id = key |> unsafe_coerce in
      let iv: AEAD_GCM.iv id = iv |> unsafe_coerce in
      let log: HyperHeap.rref r _ = ralloc r Seq.createEmpty in
      let counter = ralloc r 0 in
      AEAD_GCM.State r key iv log counter
    in
    StatefulLHAE.State r log seqn key
  in
  // StatefulLHAE.writer -> StatefulLHAE.state
  StAE.StLHAE () w

val decryptor_TLS12_AES_GCM_128_SHA256: hs:handshake -> bytes -> bytes -> StAE.reader (peerId (hsId hs))
let decryptor_TLS12_AES_GCM_128_SHA256 hs key iv = 
  let id = peerId (hsId hs) in
  let r = HyperHeap.root in
  let r: StatefulLHAE.reader id =
    let log: StatefulLHAE.st_log_t r id = ralloc r Seq.createEmpty in
    let seqn: HyperHeap.rref r seqn_t = ralloc r 0 in
    let key: AEAD_GCM.state id Reader =
      // The calls to [unsafe_coerce] are here because we're breaking
      // abstraction, as both [key] and [iv] are declared as private types.
      let key: AEAD_GCM.key id = key |> unsafe_coerce in
      let iv: AEAD_GCM.iv id = iv |> unsafe_coerce in
      let log: HyperHeap.rref r _ = ralloc r Seq.createEmpty in
      let counter = ralloc r 0 in
      AEAD_GCM.State r key iv log counter
    in
    StatefulLHAE.State r log seqn key
  in
  // StatefulLHAE.reader -> StatefulLHAE.state
  StAE.StLHAE () r

val recordKeysToEpoch: #hs_rgn:rgn -> #n:TLSInfo.random -> h:handshake -> (bytes * bytes * bytes * bytes) -> epoch hs_rgn n
let recordKeysToEpoch #hs_rgn #n h (ck,civ,sk,siv) = 
  let wr: StAE.writer (hsId h) = encryptor_TLS12_AES_GCM_128_SHA256 h ck civ in
  let rd: StAE.reader (peerId (hsId h)) = decryptor_TLS12_AES_GCM_128_SHA256 h sk siv in
  Epoch h rd wr

let reveal_epoch_region_inv_all (u:unit)
  : Lemma (forall i hs_rgn r w.{:pattern (epoch_region_inv' #i hs_rgn r w)}
	   epoch_region_inv' #i hs_rgn r w
	   <==>
   	   epoch_region_inv #i hs_rgn r w)
  = ()	   

let reveal_epoch_region_inv (#hs_rgn:rgn) (#n:TLSInfo.random) (e:epoch hs_rgn n) 
  : Lemma (let r = Epoch.r e in 
	   let w = Epoch.w e in 
	   epoch_region_inv hs_rgn r w)
  = ()

let writer_epoch (#hs_rgn:rgn) (#n:TLSInfo.random) (e:epoch hs_rgn n) 
  : Tot (w:writer (hsId (e.h)) {epoch_region_inv hs_rgn (Epoch.r e) w})
  = Epoch.w e

let reader_epoch (#hs_rgn:rgn) (#n:TLSInfo.random) (e:epoch hs_rgn n) 
  : Tot (r:reader (peerId (hsId (e.h))) {epoch_region_inv hs_rgn r (Epoch.w e)})
  = match e with | Epoch h r w -> r //16-05-20 Epoch.r e failed.

(* The footprint just includes the writer regions *)
abstract let epochs_inv (#r:rgn) (#n:TLSInfo.random) (es: seq (epoch r n)) =
  forall (i:nat { i < Seq.length es })
    (j:nat { j < Seq.length es /\ i <> j}).{:pattern (Seq.index es i); (Seq.index es j)}
    let ei = Seq.index es i in
    let ej = Seq.index es j in
    parent (region ei.w) = parent (region ej.w) /\  //they all descend from a common epochs sub-region of the connection
    disjoint (region ei.w) (region ej.w)           //each epoch writer lives in a region disjoint from the others

abstract let epochs_inv' (#r:rgn) (#n:TLSInfo.random) (es: seq (epoch r n)) = epochs_inv es

let epochs (r:rgn) (n:TLSInfo.random) = es: seq (epoch r n) { epochs_inv' es }

let reveal_epochs_inv' (u:unit)
  : Lemma (forall (r:rgn) (#n:TLSInfo.random) (es:seq (epoch r n)). {:pattern (epochs_inv' es)}
	     epochs_inv' es
	     <==>
	     epochs_inv es)
  = ()

// internal stuff: state machine, reader/writer counters, etc.
// (will take other HS fields as parameters)

type resume_id (r:role) = o:option sessionID{r=Server ==> o=None}


type hs =
  | HS: #region: rgn { is_hs_rgn region } ->
              r: role ->
         resume: resume_id r ->
            cfg: config ->
          nonce: TLSInfo.random ->  // unique for all honest instances; locally enforced; proof from global HS invariant? 
            log: MS.i_seq region (epoch region nonce) epochs_inv ->  // append-only, monotonic log of epochs
          state: rref region (handshake_state r)  ->       // opaque, subject to invariant
             hs


(* the handshake internally maintains epoch 
   indexes for the current reader and writer *)

let logT (s:hs) (h:HyperHeap.t) = MS.i_sel h s.log

let stateType (s:hs) = epochs s.region s.nonce * handshake_state (HS.r s)

let stateT (s:hs) (h:HyperHeap.t) : stateType s = (logT s h, sel h s.state)

let non_empty h s = Seq.length (logT s h) > 0

let logIndex (#t:Type) (log: seq t) = n:int { -1 <= n /\ n < Seq.length log }

let forall_epochs (hs:hs) h (p:(epoch hs.region hs.nonce -> Type)) = 
  (let es = logT hs h in
   forall (i:nat{i < Seq.length es}).{:pattern (Seq.index es i)} p (Seq.index es i))
     
(* //vs modifies clauses? *)
(* let unmodified_epochs s h0 h1 =  *)
(*   forall_epochs s h0 (fun e ->  *)
(*     let rs = regions e in  *)
(*     (forall (r:rid{Set.mem r rs}).{:pattern (Set.mem r rs)} Map.sel h0 r = Map.sel h1 r)) *)

//epochs in h1 extends epochs in h0 by one 
let fresh_epoch h0 s h1 =
  let es0 = logT s h0 in 
  let es1 = logT s h1 in 
  Seq.length es1 > 0 &&
  es0 = Seq.slice es1 0 (Seq.length es1 - 1)

let latest h (s:hs{Seq.length (logT s h) > 0}) = // accessing the latest epoch
 let es = logT s h in
 Seq.index es (Seq.length es - 1)

// separation policy: the handshake mutates its private state, 
// only depends on it, and only extends the log with fresh epochs.


// placeholder, to be implemented as a stateful property.
assume val completed: #region:rgn -> #nonce:TLSInfo.random -> epoch region nonce -> Type0

// consider adding an optional (resume: option sid) on the client side
// for now this bit is not explicitly authenticated.

// Well-formed logs are all prefixes of (Epoch; Complete)*; Error
// This crucially assumes that TLS keeps track of OutCCS and InCCSAck
// so that it knows which reader & writer to use (not always the latest ones):
// - within InCCSAck..OutCCS, we still use the older writer
// - within OutCCS..InCCSAck, we still use the older reader
// - otherwise we use the latest readers and writers

// technicality: module dependencies?
// we used to pre-declare all identifiers in TLSInfo
// we used owe could also record (fatal) errors as log terminators
 
// abstract invariant; depending only on the HS state (not the epochs state)
// no need for an epoch states invariant here: the HS never modifies them
 
assume val hs_invT : s:hs -> epochs:seq (epoch s.region s.nonce) -> handshake_state (HS.r s) -> Type0

let hs_inv (s:hs) (h: HyperHeap.t) = 
  hs_invT s (logT s h) (sel h (HS.state s))  //An abstract invariant of HS-internal state
  /\ MS.i_contains s.log h                    //Nothing deep about these next two, since they can always 
  /\ HyperHeap.contains_ref s.state h                 //be recovered by 'recall'; carrying them in the invariant saves the trouble


//to match the external interface
//let handshake_state (r:role) = handshake_state' r
val iT0: s:hs -> rw:rw -> st:stateType s -> Tot (logIndex (fst st))
let iT0 s rw st = -1 //TODO:Implement!
// returns the current index in the log for reading or writing, or -1 if there is none.
// depends only on the internal state of the handshake
let iT s rw h = iT0 s rw (stateT s h) 

//A framing lemma with a very trivial proof, because of the way stateT abstracts the state-dependent parts
let frame_iT_trivial  (s:hs) (rw:rw) (h0:HH.t) (h1:HH.t) 
  : Lemma (stateT s h0 = stateT s h1
           ==> iT s rw h0 = iT s rw h1) 
  = ()	                               

//Here's a framing on stateT connecting it to the region discipline
let frame_stateT  (s:hs) (rw:rw) (h0:HH.t) (h1:HH.t) (mods:Set.set rid)
  : Lemma (requires HH.modifies_just mods h0 h1
		    /\ Map.contains h0 s.region
		    /\ not (Set.mem s.region mods))
          (ensures stateT s h0 = stateT s h1)
  = ()	                               

//This is probably the framing lemma that a client of this module will want to use
let frame_iT  (s:hs) (rw:rw) (h0:HH.t) (h1:HH.t) (mods:Set.set rid)
  : Lemma (requires HH.modifies_just mods h0 h1
		    /\ Map.contains h0 s.region
		    /\ not (Set.mem s.region mods))
          (ensures stateT s h0 = stateT s h1
		   /\ iT s rw h0 = iT s rw h1)
  = frame_stateT s rw h0 h1 mods;
    frame_iT_trivial s rw h0 h1
    
// returns the epoch for reading or writing
let eT s rw (h:HyperHeap.t { iT s rw h >= 0 }) = Seq.index (logT s h) (iT s rw h)

let readerT s h = eT s Reader h 
let writerT s h = eT s Writer h

// this function increases (how to specify it once for all?)
val i: s:hs -> rw:rw -> ST int 
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> h0 = h1 /\ i = iT s rw h1))
let i s rw = Platform.Error.unexpected "i: not yet implemented" //TODO:Implement

val handshake_state_init: (cfg:TLSInfo.config) -> (r:role) -> (reg:rid) -> ST (handshake_state r)
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let handshake_state_init cfg (r:role) (reg:rid) =
   let ks, nonce = KeySchedule.create #reg r in
   {hs_nego = None;
    hs_log = HandshakeLog.create #reg;
    hs_ks  = ks;
    hs_reader = -1;
    hs_writer = -1;
    hs_buffers = hs_msg_bufs_init();
    hs_state =
        (match r with
    	| Client -> C (C_Idle None)
    	| Server -> S (S_Idle None)) }

// payload of a handshake fragment, to be made opaque eventually
type message (i:id) = (| rg: frange i & rbytes rg |)
let out_msg i rg b : message i= (|rg, b|)

// What the HS asks the record layer to do, in that order.
type outgoing (i:id) (* initial index *) = 
  | Outgoing: 
      send_first: option (message i) -> // HS fragment to be sent;  (with current id)
      send_ccs  : bool               -> // CCS fragment to be sent; (with current id)
      next_keys : bool               -> // the writer index increases;
      complete  : bool               -> // the handshake is complete!
      outgoing i 
  | OutError: error -> outgoing i       // usage? in case something goes wrong when preparing messages. 

let out_next_keys (#i:id) (r:outgoing i) = is_Outgoing r && Outgoing.next_keys r
let out_complete (#i:id) (r:outgoing i)  = is_Outgoing r && Outgoing.complete r

type incoming = 
  // the fragment is accepted, and...
  | InAck: 
      next_keys : bool -> // the reader index increases;
      complete  : bool -> // the handshake is complete!
      incoming

  | InQuery: Cert.chain -> bool -> incoming // could be part of InAck if no explicit user auth
  | InError: error -> incoming // how underspecified should it be?

let in_next_keys (r:incoming) = is_InAck r && InAck.next_keys r
let in_complete (r:incoming)  = is_InAck r && InAck.complete r


(* Handshake API: INTERNAL Callbacks, hidden from API *)

val client_send_client_hello: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_send_client_hello (HS #r0 r res cfg id lgref hsref) = 
  match (!hsref).hs_state with
  | C(C_Idle ri) -> 
    let (ClientHello ch,chb) = prepareClientHello cfg (!hsref).hs_ks (!hsref).hs_log ri None in
    hsref := {!hsref with 
            hs_buffers = {(!hsref).hs_buffers with hs_outgoing = chb};
	    hs_state = C(C_HelloSent ri ch)}
  	  
  
val client_handle_server_hello: hs -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_handle_server_hello (HS #r0 r res cfg id lgref hsref) msgs =
  match (!hsref).hs_state, msgs with
  | C(C_HelloSent ri ch),[(ServerHello(sh),l)] ->
   (match (processServerHello cfg (!hsref).hs_ks (!hsref).hs_log ri ch (ServerHello sh,l)) with
    | Error z -> InError z
    | Correct (n,k) -> 
      hsref := {!hsref with
	       hs_nego = Some n;
	       hs_state = C(C_HelloReceived n)};
      InAck false false)


let optHashAlg_prime_is_optHashAlg: result hashAlg' -> Tot (result hashAlg) =
  function
  | Error z -> Error z
  | Correct h -> Correct h

let sigHashAlg_is_tuple_sig_hash: sigHashAlg -> Tot (sigAlg * hashAlg) =
  function | a,b -> a,b

let rec list_sigHashAlg_is_list_tuple_sig_hash: list sigHashAlg -> Tot (list (sigAlg * hashAlg)) =
  function
  | [] -> []
  | hd::tl -> (sigHashAlg_is_tuple_sig_hash hd) :: (list_sigHashAlg_is_list_tuple_sig_hash tl)

val to_be_signed: pv:protocolVersion -> role -> csr:option bytes{is_None csr <==> pv = TLS_1p3} -> bytes -> Tot bytes
let to_be_signed pv role csr tbs =
  match pv, csr with
  | TLS_1p3, None ->
    let pad = abytes (String.make 64 (Char.char_of_int 32)) in
    let ctx =
      match role with
      | Server -> "TLS 1.3, server CertificateVerify"
      | Client -> "TLS 1.3, client CertificateVerify"
    in
    pad @| (abytes ctx) @| (abyte 0z) @| tbs
  | _, Some csr -> csr @| tbs

val sigHashAlg_of_ske: bytes -> Tot (option (sigHashAlg * bytes))
let sigHashAlg_of_ske signature =
  if length signature > 4 then
   let h, sa, sigv = split2 signature 1 1 in
   match vlsplit 2 sigv with
   | Correct (sigv, eof) ->
     begin
     match length eof, parseSigAlg sa, optHashAlg_prime_is_optHashAlg (parseHashAlg h) with
     | 0, Correct sa, Correct (Hash h) -> Some ((sa,Hash h), sigv)
     | _, _, _ -> None
     end
   | Error _ -> None
  else None


val processServerHelloDone: cfg:config -> nego:nego -> ks:KeySchedule.ks -> log:HandshakeLog.log ->
    			    list (hs_msg*bytes) -> list (hs_msg * bytes) -> ST (result (list (hs_msg * bytes)))
  (requires (fun h -> nego.n_protocol_version <> TLS_1p3))
  (ensures (fun h0 i h1 -> True))
let processServerHelloDone cfg n ks log msgs opt_msgs =
  match msgs with
  | [(Certificate(c),_); (ServerKeyExchange(ske),_); (ServerHelloDone,_)]
    when (n.n_protocol_version <> TLS_1p3 && is_Some n.n_sigAlg &&
      (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) ->
     if (not cfg.check_peer_certificate) || Cert.validate_chain c.crt_chain true cfg.peer_name cfg.ca_file then
       let ske_tbs = kex_s_to_bytes ske.ske_kex_s in
       let ske_sig = ske.ske_sig in
       let Some cs_sigalg = n.n_sigAlg in
       let sigalgs = n.n_extensions.ne_signature_algorithms in
       begin
       match sigHashAlg_of_ske ske_sig with
       | Some ((sa,h),sigv) ->
         let algs: list sigHashAlg =
           match sigalgs with
           | Some l -> l
           | None -> [(cs_sigalg, Hash CoreCrypto.SHA1)]
         in
         if List.Tot.existsb (fun (xs,xh) -> (xs = sa && xh = h))
	      algs then
           begin
	   let a = Signature.Use (fun _ -> True) sa [h] false false in
           let csr = (n.n_client_random @| n.n_server_random) in
           let ems = n.n_extensions.ne_extended_ms in
           let tbs = to_be_signed n.n_protocol_version Server (Some csr) ske_tbs in
           match Signature.get_chain_public_key #a c.crt_chain with
           | Some pk ->
	     let valid = Signature.verify #a h pk tbs sigv in
	     //let _ = IO.debug_print_string("tbs = " ^ (Platform.Bytes.print_bytes tbs) ^ "\n") in
	     let _ = IO.debug_print_string("Signature validation status = " ^ (if valid then "OK" else "FAIL") ^ "\n") in
	     if valid then
	       begin
               match ske.ske_kex_s with
               | KEX_S_DHE gy ->
                 let gx = KeySchedule.ks_client_12_full_dh ks n.n_server_random n.n_protocol_version n.n_cipher_suite n.n_extensions.ne_extended_ms gy in
                 let cke = {cke_kex_c = kex_c_of_dh_key gx} in
                   begin
	           match opt_msgs with
                   | [] ->
	             let _ = log @@ Certificate(c) in
	             let _ = log @@ ServerKeyExchange(ske) in
	             let _ = log @@ ServerHelloDone in
	             let b = log @@ ClientKeyExchange cke in
	             let lb = HandshakeLog.getBytes log in
	             if ems then KeySchedule.ks_client_12_set_session_hash ks lb;
	             Correct [(ClientKeyExchange cke,b)]
                   | [(CertificateRequest(cr),_)] ->
		     begin
                     let cc = {crt_chain = []} in // TODO
	             let _ = log @@ Certificate(c) in
	             let _ = log @@ ServerKeyExchange(ske) in
	             let _ = log @@ CertificateRequest(cr) in
		     let _ = log @@ ServerHelloDone in
		     let b1 = log @@ Certificate(cc) in
		     let b2 = log @@ ClientKeyExchange cke in
		     let lb = HandshakeLog.getBytes log in
		     if ems then KeySchedule.ks_client_12_set_session_hash ks lb;
      		     Correct [(Certificate cc,b1); (ClientKeyExchange cke,b2)]
		     end
		   | _ ->
		     Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "only support ECDHE/DHE SKE")
	           end
	       | _ -> Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "only support ECDHE/DHE SKE")
               end
             // Signature verification failed
             else Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "failed to check SKE signature")
	     // Algorithm negotiation failed
	   | None -> Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "failed to get public key from chain")
	   end
         // Certificate validation failed
         else Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "Signature algorithm negotiation failed")
       | None -> Error (AD_decode_error, perror __SOURCE_FILE__ __LINE__ "Failed to parse SKE message")
       end
     else Error (AD_certificate_unknown_fatal, perror __SOURCE_FILE__ __LINE__ "Certificate validation failure")
  | _ -> Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "Unexpected message")


val client_handle_server_hello_done: hs -> list (hs_msg * bytes) -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_handle_server_hello_done (HS #r0 r res cfg id lgref hsref) msgs opt_msgs =
  match (!hsref).hs_state with
  | C(C_HelloReceived n) when 
     (n.n_protocol_version <> TLS_1p3 && is_Some n.n_sigAlg &&
      (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) -> 
     (match processServerHelloDone cfg n (!hsref).hs_ks (!hsref).hs_log msgs opt_msgs with
      | Correct [(ClientKeyExchange(cke),b1)] ->
             hsref := {!hsref with 
                hs_buffers = {(!hsref).hs_buffers with hs_outgoing = b1};
                hs_state = C(C_OutCCS n)};
              InAck false false
      | Correct [(ClientKeyExchange(cke),b1);(Certificate(cc),b2)] ->
             hsref := {!hsref with 
                hs_buffers = {(!hsref).hs_buffers with hs_outgoing = b1 @| b2};
                hs_state = C(C_OutCCS n)};
              InAck false false
      | Error (x,y) -> InError(x,y))
   | _ -> InError (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "unexpected state")

val prepareClientFinished: KeySchedule.ks -> HandshakeLog.log -> ST (hs_msg * bytes)
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let prepareClientFinished ks log = 
    let lb = HandshakeLog.getBytes log in
    let fin = {fin_vd = KeySchedule.ks_client_12_client_verify_data ks lb} in
    let finb = log @@ (Finished fin) in
    (Finished fin, finb)

val client_send_client_finished: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_send_client_finished (HS #r0 r res cfg id lgref hsref) =
  let hs = !hsref in
  match hs.hs_state with
  | C(C_OutCCS n) ->
     let (Finished fin,finb) = prepareClientFinished (!hsref).hs_ks (!hsref).hs_log in
     hsref := {!hsref with 
            hs_buffers = {(!hsref).hs_buffers with hs_outgoing = finb};
	    hs_state = C(C_FinishedSent n fin.fin_vd)}
  
  
val client_handle_server_ccs: hs -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_handle_server_ccs (HS #r0 r res cfg id lgref hsref) msgs =
  match (!hsref).hs_state, msgs with
  | C(C_FinishedSent n vd),[(SessionTicket(stick),l)] ->
      let _ = (!hsref).hs_log @@ SessionTicket(stick) in
      hsref := {!hsref with
	       hs_state = C(C_CCSReceived n vd)};
      InAck false false

val processServerFinished: KeySchedule.ks -> HandshakeLog.log -> (hs_msg * bytes) -> ST (result bytes)
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let processServerFinished ks log (m,l) =
   match m with
   | Finished(f) ->
     let lb = HandshakeLog.getBytes log in
     let svd = KeySchedule.ks_client_12_server_verify_data ks lb in
     if (equalBytes svd f.fin_vd) then 
     	let _ = log @@ (Finished(f)) in
	Correct svd
     else Error (AD_decode_error, "Finished MAC did not verify")
   | _ -> Error (AD_decode_error, "Unexpected state")

val client_handle_server_finished: hs -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_handle_server_finished (HS #r0 r res cfg id lgref hsref) msgs =
  match (!hsref).hs_state, msgs with
  | C(C_CCSReceived n vd), [(Finished(f),l)] ->
   (match processServerFinished (!hsref).hs_ks (!hsref).hs_log (Finished f,l) with
    | Error z -> InError z
    | Correct svd -> 
       hsref := {!hsref with
  		 hs_state = C(C_Idle (Some (vd,svd)))};
       InAck false false)
    

val processServerFinished_13: cfg:config -> n:nego -> ks:KeySchedule.ks -> log:HandshakeLog.log ->
    			      list (hs_msg*bytes) -> ST (result (list (hs_msg * bytes) * bytes * KeySchedule.recordInstance))
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let processServerFinished_13 cfg n ks log msgs =
   let rem,creq = 
     match msgs with
     | (EncryptedExtensions ee,_) :: (CertificateRequest cr,_) :: rem ->         
       let _ = log @@ EncryptedExtensions(ee) in 
       let _ = log @@ CertificateRequest(cr) in 
       rem,true
     | (EncryptedExtensions ee,_) :: rem ->         
       let _ = log @@ EncryptedExtensions(ee) in 
       rem,false in
    match rem with
    | [(Certificate c,_); (CertificateVerify cv,_); (Finished f,_)]
     when (is_Some n.n_sigAlg && (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) ->
     if (not cfg.check_peer_certificate) || Cert.validate_chain c.crt_chain true cfg.peer_name cfg.ca_file then
       let _ = log @@ Certificate(c) in
       let lb = HandshakeLog.getHash log in
       let Some cs_sigalg = n.n_sigAlg in
       let Some algs = n.n_extensions.ne_signature_algorithms in
       //let _ = IO.debug_print_string("cv_sig = " ^ (Platform.Bytes.print_bytes cv.cv_sig) ^ "\n") in
       begin
       match sigHashAlg_of_ske cv.cv_sig with
       | Some ((sa,h), sigv) ->
         if List.Tot.existsb (fun (xs,xh) -> (xs = sa && xh = h))
             (list_sigHashAlg_is_list_tuple_sig_hash algs) then
           begin
           let a = Signature.Use (fun _ -> True) sa [h] false false in
           let tbs = to_be_signed n.n_protocol_version Server None lb in
           match Signature.get_chain_public_key #a c.crt_chain with
           | Some pk ->
             let valid = Signature.verify h pk tbs sigv in
             let _ = IO.debug_print_string("Signature validation status = " ^ (if valid then "OK" else "FAIL") ^ "\n") in
             if valid then
               let _ = log @@ CertificateVerify(cv) in
               let lb = HandshakeLog.getHash log in
               let svd = KeySchedule.ks_client_13_1rtt_server_finished ks lb in
               if (equalBytes svd f.fin_vd) then
		 let _ = log @@ (Finished(f)) in
        	 let lb = HandshakeLog.getHash log in
        	 let (cvd,keys) = KeySchedule.ks_client_13_1rtt_client_finished ks lb in
        	 let cfin = {fin_vd = cvd} in
        	 if creq then
        	   let cc = {crt_chain = []} in
        	   let ccb = log @@ Certificate(cc) in
        	   let finb = log @@ Finished(cfin) in
        	   Correct ([(Certificate(cc),ccb);(Finished(cfin),finb)],svd,keys)
        	 else
        	   let finb = log @@ Finished(cfin) in
        	   Correct ([(Finished(cfin),finb)],svd,keys)
               else Error (AD_decode_error, "Finished MAC did not verify")
             else Error (AD_decode_error, "Certificate signature did not verify")
	   | None -> Error (AD_decode_error, "Certificate was not valid")
	   end
         else Error (AD_handshake_failure, "Signature algorithm negotiation failed")
       | None -> Error (AD_decode_error, "Failed to parse message")
       end
     else Error (AD_decode_error, "Certificate was not valid")
   | _ -> Error (AD_decode_error, "Unexpected state")

val client_handle_server_finished_13: hs -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_handle_server_finished_13 (HS #r0 r res cfg id lgref hsref) msgs =
  match (!hsref).hs_state with
  | C(C_CCSReceived n vd) ->
   (match processServerFinished_13 cfg n (!hsref).hs_ks (!hsref).hs_log msgs with
    | Error z -> InError z
    | Correct ([(Finished(f),fb)],svd,keys) -> 
       hsref := {!hsref with
                 hs_buffers = {(!hsref).hs_buffers with hs_outgoing = fb};
  		 hs_state = C(C_Idle (Some (vd,svd)))};
       InAck false false
    | Correct ([(Certificate c,cb);(Finished f,fb)],svd,keys) -> 
       hsref := {!hsref with
                 hs_buffers = {(!hsref).hs_buffers with hs_outgoing = cb @| fb};
  		 hs_state = C(C_Idle (Some (vd,svd)))};
       InAck false false)
    



val server_handle_client_hello: hs -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_handle_client_hello (HS #r0 r res cfg id lgref hsref) msgs =
  match (!hsref).hs_state, msgs with
  | S(S_Idle ri),[(ClientHello(ch),l)] ->
    (match (prepareServerHello cfg (!hsref).hs_ks (!hsref).hs_log ri (ClientHello ch,l)) with
     | Error z -> InError z
     | Correct (n,keys,(sh,shb)) ->
       hsref := {!hsref with
               hs_buffers = {(!hsref).hs_buffers with hs_outgoing = shb};
	       hs_nego = Some n;
	       hs_state = S(S_HelloSent n)};
       InAck false false)
    

let prepareServerHelloDone cfg n ks log = 
    if (n.n_protocol_version <> TLS_1p3 && is_Some n.n_sigAlg &&
       (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) 
    then 
    match Cert.lookup_chain cfg.cert_chain_file with
    | Correct chain ->
      let c = {crt_chain = chain} in
      let cb = log @@ Certificate(c) in
      let cr = n.n_client_random in
      let ems = n.n_extensions.ne_extended_ms in
      let pv = n.n_protocol_version in 
      let cs = n.n_cipher_suite in
      let Some gn = n.n_dh_group in
      let gy = KeySchedule.ks_server_12_init_dh ks cr pv cs ems gn in

      let kex_s = KEX_S_DHE gy in
      let sv = kex_s_to_bytes kex_s in
      let csr = n.n_client_random @| n.n_server_random in

      // Signature agility (following the broken rules of 7.4.1.4.1. in RFC5246)
      let Some sa = n.n_sigAlg in
      let sigalgs = n.n_extensions.ne_signature_algorithms in
      let algs =
	match sigalgs with
	| Some l -> l
	| None -> [(sa,Hash CoreCrypto.SHA1)]
      in
      let algs = List.Tot.filter (fun (s,_) -> s = sa) algs in
      let sa, ha =
	match algs with
	| sha::_ -> sha
	| [] -> (sa, Hash CoreCrypto.SHA1)
      in
      let hab, sab = hashAlgBytes ha, sigAlgBytes sa in
      let a = Signature.Use (fun _ -> True) sa [ha] false false in
      let tbs = to_be_signed n.n_protocol_version Server (Some csr) sv in
      begin
      match Signature.lookup_key #a cfg.private_key_file with
      | Some csk ->
	let sigv = Signature.sign ha csk tbs in
        if length sigv >= 2 && length sigv < 65536 then
	  begin
	  lemma_repr_bytes_values (length sigv);
	  let signature = (hab @| sab @| (vlbytes 2 sigv)) in
	  let ske = {ske_kex_s = kex_s; ske_sig = signature} in
          let skeb = log @@ ServerKeyExchange(ske) in
          let shdb = log @@ ServerHelloDone in
	  Correct [(Certificate(c),cb);(ServerKeyExchange(ske),skeb);(ServerHelloDone,shdb)]
	  end
	else
	  Error (AD_decode_error, perror __SOURCE_FILE__ __LINE__ "signature length out of range")
      | None -> Error (AD_internal_error, perror __SOURCE_FILE__ __LINE__ "could not load siginig key")
      end
    | Error z -> Error z
    else 
       Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "should not call this function in TLS 1.3")

 

val server_send_server_hello_done: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_send_server_hello_done (HS #r0 r res cfg id lgref hsref) =
  match (!hsref).hs_state with
  | S(S_HelloSent n) 
    when (n.n_protocol_version <> TLS_1p3 &&
	 (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) ->
    (match prepareServerHelloDone cfg n (!hsref).hs_ks (!hsref).hs_log with
     | Correct ([(Certificate(c),cb);(ServerKeyExchange(ske),skeb);(ServerHelloDone,shdb)]) ->    
         let nl = cb @| skeb @| shdb in
	    hsref := {!hsref with
		 hs_buffers = {(!hsref).hs_buffers with hs_outgoing = nl};
		 hs_state = S(S_HelloDone n)}
      | Error e -> 
	  hsref := {!hsref with hs_state = S(S_Error e)})

let processClientCCS n ks log msgs opt_msgs = 
    let rem = 
    match opt_msgs with
    | [(Certificate c,_)] ->
      let _ = log @@ Certificate(c) in
      Correct msgs
    | [] -> Correct msgs 
    | _ -> Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "Expected Certificate only before CKE") in
    match rem with
    | Correct [(ClientKeyExchange cke,_)] ->
      let ems = n.n_extensions.ne_extended_ms in
      let _ = log @@ ClientKeyExchange(cke) in
      let lb = HandshakeLog.getBytes log in
      (match cke.cke_kex_c with 
       | KEX_C_DHE b 
       | KEX_C_ECDHE b -> 
             (KeySchedule.ks_server_12_cke_dh ks b lb;
	      Correct ())
       | _ -> Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "Expected DHE/ECDHE CKE"))
    | Error z -> Error z

val server_handle_client_ccs: hs -> list (hs_msg * bytes) -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))

let server_handle_client_ccs (HS #r0 r res cfg id lgref hsref) msgs opt_msgs = 
  match (!hsref).hs_state with
  | S(S_HelloDone n) when
     (n.n_protocol_version <> TLS_1p3 && 
      (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) ->
     (match processClientCCS n (!hsref).hs_ks (!hsref).hs_log msgs opt_msgs with
      | Correct () ->       
        (hsref := {!hsref with
	       hs_state = S(S_CCSReceived n)};
         InAck false false)
      | Error z -> InError z)
  

let processClientFinished n ks log msgs =   
    match msgs with
    | [(Finished f,_)] ->
      let lb = HandshakeLog.getBytes log in
      let cvd = KeySchedule.ks_server_12_client_verify_data ks lb in
      let _ = log @@ Finished(f) in
      let lb = HandshakeLog.getBytes log in
      let svd = KeySchedule.ks_server_12_server_verify_data ks lb in
      let fin = Finished ({fin_vd = svd}) in
      let finb = log @@ fin in
      Correct [(fin,finb)]
   | _ -> Error (AD_unexpected_message, perror __SOURCE_FILE__ __LINE__ "ClientFinished expected")

val server_handle_client_finished: hs -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))

let server_handle_client_finished (HS #r0 r res cfg id lgref hsref) msgs =
  match (!hsref).hs_state with
  | S(S_CCSReceived n) -> 
    match processClientFinished n (!hsref).hs_ks (!hsref).hs_log msgs with
    | Correct [(Finished(f),finb)] -> 
        (hsref := {!hsref with
	       	   hs_buffers = {(!hsref).hs_buffers with hs_outgoing = finb};
	           hs_state = S(S_OutCCS n)};
         InAck false false)
    | Error e -> InError e

val server_send_server_finished: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_send_server_finished (HS #r0 r res cfg id lgref hsref) =
  match (!hsref).hs_state with
  | S(S_OutCCS n) -> 
    hsref := {!hsref with
	       hs_state = S(S_FinishedSent n)}




let prepareServerFinished_13 cfg n ks log = 
    if (n.n_protocol_version = TLS_1p3 && is_Some n.n_sigAlg &&
       (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE))
    then 
    let ee = {ee_extensions = []} in
    let eeb = log @@ EncryptedExtensions(ee) in
    match Cert.lookup_chain cfg.cert_chain_file with
    | Correct chain ->
      let c = {crt_chain = chain} in
      let cb = log @@ Certificate(c) in
      let cr = n.n_client_random in
      let ems = n.n_extensions.ne_extended_ms in
      let pv = n.n_protocol_version in 
      let cs = n.n_cipher_suite in

      let sv = HandshakeLog.getBytes(log) in
      let finv = HandshakeLog.getHash(log) in

      // Signature agility (following the broken rules of 7.4.1.4.1. in RFC5246)
      let Some sa = n.n_sigAlg in
      let algs =
	match n.n_extensions.ne_signature_algorithms with
        | Some l -> l
        | None -> [sa,Hash CoreCrypto.SHA256]
      in
      let algs = List.Tot.filter (fun (s,_) -> s = sa) algs in
      let sa,ha =
	match algs with
	| ha::_ -> ha
	| [] -> (sa, Hash CoreCrypto.SHA256)
      in
      let hab, sab = hashAlgBytes ha, sigAlgBytes sa in
      let a = Signature.Use (fun _ -> True) sa [ha] false false in
      begin
      match Signature.lookup_key #a cfg.private_key_file with
      | Some csk ->
        let tbs = to_be_signed pv Server None sv in
        let sigv = Signature.sign ha csk tbs in
	let signature = (hab @| sab @| (vlbytes 2 sigv)) in
        let scv = {cv_sig = signature} in
        let scvb = log @@ CertificateVerify(scv) in
	let svd = KeySchedule.ks_server_13_server_finished ks finv in
	let fin = {fin_vd = svd} in
	let finb = log @@ Finished(fin) in
	Correct [(EncryptedExtensions(ee),eeb);(Certificate(c),cb);(CertificateVerify(scv),scvb);(Finished(fin),finb)]
      | None -> Error (AD_internal_error, perror __SOURCE_FILE__ __LINE__ "could not load signing key")
      end
    | Error z -> Error z
    else 
       Error (AD_handshake_failure, perror __SOURCE_FILE__ __LINE__ "should not call this function in TLS < 1.3")

val server_send_server_finished_13: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_send_server_finished_13 (HS #r0 r res cfg id lgref hsref) =
  match (!hsref).hs_state with
  | S(S_HelloSent n) 
    when (n.n_protocol_version = TLS_1p3 &&
	 (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)) ->
    (match prepareServerFinished_13 cfg n (!hsref).hs_ks (!hsref).hs_log with
     | Correct ([(EncryptedExtensions(ee),eeb);(Certificate(c),cb);(CertificateVerify(scv),scvb);(Finished(f),sfinb)]) ->    
            let nl = eeb @| cb @| scvb @| sfinb in
	    hsref := {!hsref with
		 hs_buffers = {(!hsref).hs_buffers with hs_outgoing = nl};
		 hs_state = S(S_FinishedSent n)}
     | Error e -> 
	  hsref := {!hsref with hs_state = S(S_Error e)})


val processClientFinished_13: KeySchedule.ks -> HandshakeLog.log -> list (hs_msg * bytes) -> list (hs_msg * bytes) ->
    			      ST (result (bytes * KeySchedule.recordInstance))
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let processClientFinished_13 ks log msgs opt_msgs =
   let rem = 
   match opt_msgs with
   | [(Certificate c,_)] ->
     let _ = log @@ Certificate(c) in
     Correct msgs
   | [] -> Correct msgs 
   | _ -> Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "Expected Certificate only before CKE") in
   match rem with
   | Correct ([(Finished(f),finb)]) ->
     let lb = HandshakeLog.getHash log in
     let (cvd,keys) = KeySchedule.ks_server_13_client_finished ks lb in
     if (equalBytes cvd f.fin_vd) then 
     	let _ = log @@ (Finished(f)) in
	Correct (cvd,keys)
     else Error (AD_decode_error, "Finished MAC did not verify")
   | _ -> Error (AD_decode_error, "Unexpected state")


val server_handle_client_finished_13: hs -> list (hs_msg * bytes) -> list (hs_msg * bytes) -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_handle_client_finished_13 (HS #r0 r res cfg id lgref hsref) msgs opt_msgs =
  match (!hsref).hs_state with
  | S(S_FinishedSent n) -> 
    (match processClientFinished_13 (!hsref).hs_ks (!hsref).hs_log msgs opt_msgs with
     | Correct svd ->
       (hsref := {!hsref with
  	           hs_state = S(S_Idle None)};
        InAck false false)
     | Error z -> InError z)


(* TODO: resumption *)
assume val server_send_server_finished_res: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))




(* Handshake API: PUBLIC Functions, taken from FSTI *)

// returns the protocol version negotiated so far
// (used for formatting outgoing packets, but not trusted)
val version: s:hs -> ST protocolVersion
  (requires (hs_inv s))
  (ensures (fun h0 pv h1 -> h0 = h1))
let version (HS r res cfg id l st) =
    match (!st).hs_nego with
    | Some n -> n.n_protocol_version
    | None -> cfg.minVer

// JP: the outside has been checked against the fsti which had another
// definition (at the bottom of this file)
val iT_old:  s:hs -> rw:rw -> ST int
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let iT_old (HS r res cfg id l st) rw =
  match rw with 
  | Reader -> (!st).hs_reader
  | Writer -> (!st).hs_writer


(*** Control Interface ***)

// Create instance for a fresh connection, with optional resumption for clients
val init: r0:rid -> r: role -> cfg:config -> resume: resume_id r -> 
  ST hs
  (requires (fun h -> True))
  (ensures (fun h0 s h1 ->
    modifies Set.empty h0 h1 /\
    fresh_subregion r0 (HS.region s) h0 h1 /\
    hs_inv s h1 /\
    HS.r s = r /\
    HS.resume s = resume /\
    HS.cfg s = cfg /\
    logT s h1 = Seq.createEmpty ))
let init r0 r cfg res = 
    let id = Nonce.mkHelloRandom r r0 in //NS: should this really be Client?
    let lgref = MS.alloc_mref_seq r0 Seq.createEmpty in
    let hs = handshake_state_init cfg r r0 in
    let hsref = ralloc r0 hs in
    HS #r0 r res cfg id lgref hsref

let mods s h0 h1 = 
  HyperHeap.modifies_one s.region h0 h1
  
let modifies_internal h0 s h1 =
    hs_inv s h1 /\
    mods s h0 h1 /\ 
    modifies_rref s.region !{as_ref s.state} h0 h1

// Idle client starts a full handshake on the current connection
val rehandshake: s:hs -> config -> ST bool
  (requires (fun h -> hs_inv s h /\ HS.r s = Client))
  (ensures (fun h0 _ h1 -> modifies_internal h0 s h1))
let rehandshake s c = Platform.Error.unexpected "rehandshake: not yet implemented"

// Idle client starts an abbreviated handshake resuming the current session
val rekey: s:hs -> config -> ST bool
  (requires (fun h -> hs_inv s h /\ HS.r s = Client))
  (ensures (fun h0 _ h1 -> modifies_internal h0 s h1))
let rekey s c = Platform.Error.unexpected "rekey: not yet implemented"

// (Idle) Server requests an handshake
val request: s:hs -> config -> ST bool
  (requires (fun h -> hs_inv s h /\ HS.r s = Server))
  (ensures (fun h0 _ h1 -> modifies_internal h0 s h1))
let request s c = Platform.Error.unexpected "request: not yet implemented"

val invalidateSession: s:hs -> ST unit
  (requires (hs_inv s))
  (ensures (fun h0 _ h1 -> modifies_internal h0 s h1)) // underspecified
let invalidateSession hs = Platform.Error.unexpected "invalidateSession: not yet implemented"


(*** Outgoing (main) ***)

//val next_fragment: see .fsti
let next_fragment_ensures (#i:id) (s:hs) h0 (result:outgoing i) h1 = 
    let es = logT s h0 in
    let w0 = iT s Writer h0 in
    let w1 = iT s Writer h1 in
    let r0 = iT s Reader h0 in
    let r1 = iT s Reader h1 in
    hs_inv s h1 /\
    mods s h0 h1 /\
    r1 == r0 /\
//  w1 == (match result with | Outgoing _ _ true _ -> w0 + 1 | _ -> w0 ) /\
    w1 == (if out_next_keys result then  w0 + 1 else w0 ) /\
    (b2t (out_complete result) ==> w1 >= 0 /\ r1 = w1 /\ iT s Writer h1 >= 0 /\ completed (eT s Writer h1)) 

val next_fragment: i:id -> s:hs -> ST (outgoing i)
  (requires (fun h0 -> 
    let es = logT s h0 in
    let j = iT s Writer h0 in 
    hs_inv s h0 /\
    (if j = -1 then i = noId else let e = Seq.index es j in i = hsId e.h)   
  ))
  (ensures (next_fragment_ensures s))
let rec next_fragment i hs = 
    let (HS #r0 r res cfg id lgref hsref) = hs in
    let pv,kex,res = 
      (match (!hsref).hs_nego with 
       | None -> None, None, None
       | Some n -> Some n.n_protocol_version, Some n.n_kexAlg, Some n.n_resume) in
    let b = (!hsref).hs_buffers.hs_outgoing in
    //16-06-01 TODO: handle fragmentation; return fragment + flags set in some cases
    let l = length b in
    if (l > 0) then (
       hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_outgoing = empty_bytes}};
       Outgoing (Some (out_msg i (l,l) b)) false false false)
    else 
      (match (!hsref).hs_state with 
       | C (C_Error e) -> OutError e
       | S (S_Error e) -> OutError e
       | C (C_Idle ri) -> (client_send_client_hello hs; next_fragment i hs)
       | C (C_OutCCS n) -> (client_send_client_finished hs; Outgoing None true true false)
       | S (S_HelloSent n) when (is_Some pv && pv <> Some TLS_1p3 && res = Some false) -> server_send_server_hello_done hs; next_fragment i hs
       | S (S_HelloSent n) when (is_Some pv && pv <> Some TLS_1p3 && res = Some true) -> server_send_server_finished_res hs; next_fragment i hs
       | S (S_HelloSent n) when (is_Some pv && pv = Some TLS_1p3) -> server_send_server_finished_13 hs; next_fragment i hs
       | S (S_OutCCS n) -> server_send_server_finished hs; Outgoing None true true false)


(*** Incoming (main) ***)

val parseHandshakeMessages : option protocolVersion -> option kexAlg -> buf:bytes -> Tot  (result (rem:bytes * list (hs_msg * bytes)))
let rec parseHandshakeMessages pv kex buf =
    match parseMessage buf with
    | Error z -> Error z
    | Correct(None) -> Correct (buf,[])
    | Correct(Some (|rem,hstype,pl,to_log|)) ->   
      (match parseHandshakeMessage pv kex hstype pl with
       | Error z -> Error z 
       | Correct hsm -> 
             (match parseHandshakeMessages pv kex rem with
       	     | Error z -> Error z
       	     | Correct (r,hsl) -> Correct(r,(hsm,to_log)::hsl)))


let recv_ensures (s:hs) (h0:HyperHeap.t) (result:incoming) (h1:HyperHeap.t) = 
    let w0 = iT s Writer h0 in
    let w1 = iT s Writer h1 in
    let r0 = iT s Reader h0 in
    let r1 = iT s Reader h1 in
    hs_inv s h1 /\
    mods s h0 h1 /\
    w1 == w0 /\
    r1 == (if in_next_keys result then r0 + 1 else r0) /\
    (b2t (in_complete result) ==> r1 >= 0 /\ r1 = w1 /\ iT s Reader h1 >= 0 /\ completed (eT s Reader h1))

//16-06-01 handshake state-machine transitions; could separate between C and S.
val recv_fragment: s:hs -> #i:id -> message i -> ST incoming
  (requires (hs_inv s))
  (ensures (recv_ensures s))
let recv_fragment hs #i f = 
    let (| rg,rb |) = f in
    let (HS #r0 r res cfg id lgref hsref) = hs in
    let b = (!hsref).hs_buffers.hs_incoming in
    let b = b @| rb in
    let pv,kex,res = 
      (match (!hsref).hs_nego with 
       | None -> None, None, None
       | Some n -> Some n.n_protocol_version, Some n.n_kexAlg, Some n.n_resume) in
    match parseHandshakeMessages pv kex b with
    | Error z -> InError z
    | Correct(r,hsl) -> 
       hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming = r; hs_incoming_parsed = hsl}};
      (match (!hsref).hs_state,hsl with 
       | C (C_Idle ri), _ -> InError(AD_unexpected_message, "Client hasn't sent hello yet")
       | C (C_HelloSent ri ch), (ServerHello(sh),l)::hsl 
	 when (sh.sh_protocol_version <> TLS_1p3 || hsl = []) -> 
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = hsl}};
	   client_handle_server_hello hs [(ServerHello(sh),l)]
       | C (C_HelloReceived n), (Certificate(c),l)::
			          (ServerKeyExchange(ske),l')::
				  (ServerHelloDone,l'')::
				  hsl 
	 when (is_Some pv && pv <> Some TLS_1p3 && res = Some false &&
	       (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = hsl}};
			   client_handle_server_hello_done hs 
			   [(Certificate(c),l) ;
			   (ServerKeyExchange(ske),l') ;
			   (ServerHelloDone,l'')]
			   []
       | C (C_HelloReceived n), (Certificate(c),l)::
			          (ServerKeyExchange(ske),l')::
			          (CertificateRequest(cr),l'')::
				  (ServerHelloDone,l''')::
				  hsl 
	 when (is_Some pv && pv <> Some TLS_1p3 && res = Some false &&
	       (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = hsl}};
			   client_handle_server_hello_done hs 
			   [(Certificate(c),l) ;
			   (ServerKeyExchange(ske),l') ;
			   (ServerHelloDone,l''')] 
			   [(CertificateRequest(cr),l'')]
       
       | C (C_CCSReceived n cv), (Finished(f),l)::hsl 
       	 when (is_Some pv && pv <> Some TLS_1p3) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = hsl}};
			   client_handle_server_finished hs 
			   [(Finished(f),l)]

       | C (C_HelloReceived n), (EncryptedExtensions(ee),l1)::
			          (Certificate(c),l2)::
			          (CertificateVerify(cv),l3)::
				  (Finished(f),l4)::
				  [] 
	 when (is_Some pv && pv = Some TLS_1p3 && 
	       (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
			   client_handle_server_finished_13 hs 
			   [(EncryptedExtensions(ee),l1);
			   (Certificate(c),l2) ;
			   (CertificateVerify(cv),l3) ;
			   (Finished(f),l4)]
       | C (C_HelloReceived n), (EncryptedExtensions(ee),l1)::
			          (CertificateRequest(cr),ll)::
			          (Certificate(c),l2)::
			          (CertificateVerify(cv),l3)::
				  (Finished(f),l4)::
				  [] 
	 when (is_Some pv && pv = Some TLS_1p3 && 
	       (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
			   client_handle_server_finished_13 hs 
			   [(EncryptedExtensions(ee),l1);
			   (CertificateRequest(cr),ll);
			   (Certificate(c),l2) ;			   
			   (CertificateVerify(cv),l3) ;
			   (Finished(f),l4)]
       
       | S (S_Idle ri), (ClientHello(ch),l)::hsl -> 
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = hsl}};
			   server_handle_client_hello hs
			   [(ClientHello(ch),l)]
       | S (S_CCSReceived s), (Finished(f),l)::hsl 
         when (is_Some pv && pv <> Some TLS_1p3) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = hsl}};
			   server_handle_client_finished hs
			   [(Finished(f),l)]

       | S (S_FinishedSent s), (ClientKeyExchange(cke),l)::
			       (Finished(f),l')::[]  
         when (is_Some pv && pv = Some TLS_1p3) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
	   server_handle_client_finished_13 hs [(ClientKeyExchange(cke),l);(Finished(f),l')] []

       | S (S_FinishedSent s), (ClientKeyExchange(cke),l1)::
			       (Certificate(c),l2)::
			       (Finished(f),l3)::[]  
         when (is_Some pv && pv = Some TLS_1p3 && c.crt_chain = []) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
	   server_handle_client_finished_13 hs [(ClientKeyExchange(cke),l1);(Finished(f),l3)] [(Certificate(c),l2)]

       | S (S_FinishedSent s), (ClientKeyExchange(cke),l1)::
			       (Certificate(c),l2)::
			       (CertificateVerify(cv),l3)::
			       (Finished(f),l4)::[]  
         when (is_Some pv && pv = Some TLS_1p3) ->
	   hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
	   server_handle_client_finished_13 hs [(ClientKeyExchange(cke),l1);(Finished(f),l4)] [(Certificate(c),l2);(CertificateVerify(cv),l3)]

       | C (C_Error e),_ -> InError e
       | S (S_Error e),_ -> InError e
       | _ , _ -> InAck false false)
	   

val recv_ccs: s:hs -> ST incoming  // special case: CCS before 1p3; could merge with recv_fragment
  (requires (hs_inv s)) // could require pv <= 1p2
  (ensures (fun h0 result h1 ->
    recv_ensures s h0 result h1 /\
    (is_InError result \/ result = InAck true false)
    ))
let recv_ccs hs = 
    let (HS #r0 r res cfg id lgref hsref) = hs in
    let pv,kex = 
      (match (!hsref).hs_nego with 
       | None -> None, None
       | Some n -> Some n.n_protocol_version, Some n.n_kexAlg) in
    (match ((!hsref).hs_state,(!hsref).hs_buffers.hs_incoming_parsed) with 
    | C (C_FinishedSent n cv), 
      (SessionTicket(st),l)::[] ->
       hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
       client_handle_server_ccs hs 
        [(SessionTicket(st),l)]
    | S (S_HelloDone n), 
      (ClientKeyExchange(cke),l)::[] 
      when (is_Some pv && pv <> Some TLS_1p3 && 
            (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
      hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
      server_handle_client_ccs hs
      [(ClientKeyExchange(cke),l)] []
    | S (S_HelloDone n), 
      (Certificate(c),l)::
      (ClientKeyExchange(cke),l')::[] 
      when (c.crt_chain = [] && is_Some pv && pv <> Some TLS_1p3 && 
            (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
      hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
      server_handle_client_ccs hs
      [(ClientKeyExchange(cke),l')] [(Certificate(c),l)]
    | S (S_HelloDone n), 
      (Certificate(c),l)::
      (ClientKeyExchange(cke),l')::
      (CertificateVerify(cv),l'')::[]
      when (is_Some pv && pv <> Some TLS_1p3 && 
            (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
      hsref := {!hsref with hs_buffers = {(!hsref).hs_buffers with hs_incoming_parsed = []}};
      server_handle_client_ccs hs
      [(ClientKeyExchange(cke),l')] [(Certificate(c),l);(CertificateVerify(cv),l'')]
    | C (C_Error e),_ -> InError e
    | S (S_Error e),_ -> InError e
    | _,_ -> InError(AD_unexpected_message, "ClientCCS received at wrong time"))


val authorize: s:hs -> Cert.chain -> ST incoming // special case: explicit authorize (needed?)
  (requires (hs_inv s))
  (ensures (fun h0 result h1 ->
    (is_InAck result \/ is_InError result) /\ recv_ensures s h0 result h1 ))
let authorize s ch = Platform.Error.unexpected "authorize: not yet implemented"
