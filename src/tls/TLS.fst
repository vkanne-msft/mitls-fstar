module TLS

open FStar.Heap
open FStar.HyperHeap
open FStar.Seq
open FStar.SeqProperties 
open FStar.Set

open Platform
open Platform.Bytes
open Platform.Error
open Platform.Tcp

open TLSError
open TLSConstants
open TLSInfo

open Range
open StAE
open Handshake
open Connection

open MonotoneSeq
open FStar.Monotonic.RRef

module HH = FStar.HyperHeap
module MR = FStar.Monotonic.RRef
module MS = MonotoneSeq

// using also DataStream, Content, Record


(*** to be relocated ***)

#set-options "--initial_ifuel 0 --max_ifuel 0 --initial_fuel 0 --max_fuel 0"

//allowing inverting optResult without having to globally increase the fuel just for this
val invertOptResult : a:Type -> b:Type -> Lemma 
  (requires True)
  (ensures (forall (x:optResult a b). is_Error x \/ is_Correct x))
  [SMTPatT (optResult a b)]
let invertOptResult a b = allow_inversion (optResult a b)

val invertOption : a:Type -> Lemma 
  (requires True)
  (ensures (forall (x:option a). is_None x \/ is_Some x))
  [SMTPatT (option a)]
let invertOption a = allow_inversion (option a)


//A wrapper around Handshake.next_fragment; using monotonicity to show that 
//the i'th epoch doesn't change

//16-05-20 move to Handshake.fsti?
val next_fragment: i:id -> s:hs -> ST (outgoing i)
  (requires (fun h0 -> 
    let es = logT s h0 in
    let j = iT s Writer h0 in 
    hs_inv s h0 /\
    (if j = -1 then i = noId else let e = Seq.index es j in i = hsId e.h)   
  ))
  (ensures (fun h0 result h1 -> 
    next_fragment_ensures s h0 result h1 /\
    (let w0 = iT s Writer h0 in   //Augmenting the post-condition of Handhshake.next_fragment 
     let es = logT s h0 in        //with this monotonicity propery
     w0 >= 0 ==> Seq.index (logT s h0) w0 = Seq.index (logT s h1) w0))) 
let next_fragment i s =  
  let h0 = ST.get() in 
  let ilog = HS.log s in 
  let w0 = Handshake.i s Writer in 
  let _  = if w0 >= 0 
	   then (MS.i_at_least_is_stable w0 (Seq.index (MS.i_sel h0 ilog) w0) ilog;
	         MR.witness ilog (MS.i_at_least w0 (Seq.index (i_sel h0 ilog) w0) ilog)) in
  let res = Handshake.next_fragment i s in
  let _ = if w0 >= 0
	  then MR.testify (MS.i_at_least w0 (Seq.index (i_sel h0 ilog) w0) ilog) in
  res

 
// temporary scaffolding
assume val frame_admit: c:connection -> h0:HyperHeap.t -> h1:HyperHeap.t -> Lemma
  (requires True)
  (ensures epochs c h0 = epochs c h1)

// too convenient; use sparingly. Should move to a library
// JP: isn't failwith sufficient enough? CF: this one works in ST. 
val unexpected: #a:Type -> v:string -> ST a
  (requires (fun h -> True))
  (ensures (fun _ _ _ -> False ))

let rec unexpected #a s = unexpected s


(*** misc ***) 

//16-05-10 TEMPORARY disable StatefulLHAE.fst to experiment with StreamAE.

let id = i:id{ is_stream_ae i }
 
let outerPV c : ST protocolVersion
  (requires (hs_inv c.hs))
  (ensures (fun h0 pv h1 -> h0 = h1)) =
  match Handshake.version c.hs with
  | TLS_1p3 -> TLS_1p0
  | pv      -> pv


(*** control API ***)

// was connect, resume, accept_connected, ...
val create: r0:c_rgn -> tcp:networkStream -> r:role -> cfg:config -> resume: resume_id r -> ST connection
  (requires (fun h -> True))
  (ensures (fun h0 c h1 ->
    modifies Set.empty h0 h1 /\
    extends c.region r0 /\ 
    fresh_region c.region h0 h1 /\
    Map.contains h1 c.region /\ //NS: may be removeable: we should get it from fresh_region
    st_inv c h1 /\
    c_role c = r /\
    c_cfg c = cfg /\
    c_resume c = resume /\
    c.tcp = tcp  /\
    (r = Server ==> resume = None) /\ //16-05-28 style: replacing a refinement under the option
    epochs c h1 = Seq.createEmpty /\ // we probably don't care---but we should say nothing written yet
    sel h1 c.state = BC 
    ))

let create parent tcp role cfg resume =
    let m = new_region parent in
    let hs = Handshake.init m role cfg resume in
    let state = ralloc m BC in
    C #m hs tcp state


//TODO upgrade commented-out types imported from TLS.fsti
// type initial (role: role) (ns:Tcp.networkStream) (c:config) (resume: option sessionID) (cn:connection) (h: HyperHeap.t) =
//     extends (c_rid cn) root /\ // we allocate a fresh, opaque region for the connection
//     c_role cn   = role /\
//     c_tcp cn    = ns /\
//     c_resume cn = resume /\
//     c_cfg cn = c /\
//     HyperHeap.sel h (C.reading cn) = Init /\ // assuming Init epoch implicitly have no data sent/received
//     HyperHeap.sel h (C.writing cn) = Init

// painful to specify?
//* should we still return ConnectionInfo ?
//* merging connect and resume with an optional sessionID
//val connect: ns:Tcp.networkStream -> c:config -> resume: option sessionID -> ST connection
//  (requires (fun h0 -> True))
//  (ensures (fun h0 cn h1 ->
//    modifies Set.empty h0 h1 /\
//    initial Client ns c resume cn h1
//    //TODO: even if the server declines, we authenticate the client's intent to resume from this sid.
//  ))
let connect m0 tcp cfg        = create m0 tcp Client cfg None
let resume  m0 tcp cfg sid    = create m0 tcp Client cfg (Some sid)
//val accept_connected: ns:Tcp.networkStream -> c:config -> ST connection
//  (requires (fun h0 -> True))
//  (ensures (fun h0 cn h1 ->
//    modifies Set.empty h0 h1 /\
//    initial Server ns c None cn h1
//  ))
let accept_connected m0 tcp cfg = create m0 tcp Server cfg None

//* do we need accept and accept_connected?
//val accept: Tcp.tcpListener -> c:config -> ST connection
//  (requires (fun h0 -> True))
//  (ensures (fun h0 cn h1 ->
//    modifies Set.empty h0 h1 /\
//    (exists ns. initial Server ns c None cn h1)
//  ))
let accept m0 listener cfg =
    let tcp = Platform.Tcp.accept listener in
    accept_connected m0 tcp cfg

//val rehandshake: cn:connection { c_role cn = Client } -> c:config -> ST unit
//  (requires (fun h0 -> True))
//  (ensures (fun h0 b h1 -> modifies Set.empty h0 h1 // no visible change in cn
//  ))
let rehandshake c ops = Handshake.rehandshake (C.hs c) ops
// the client can ask for rekeying --- no immediate effect
//val rekey: cn:connection { c_role cn = Client } -> ST unit
//  (requires (fun h0 -> True))
//  (ensures (fun h0 b h1 -> modifies Set.empty h0 h1 // no visible change in cn
//  ))
let rekey c ops       = Handshake.rekey       (C.hs c) ops
//val request: cn:connection { c_role cn = Server } -> c:config -> ST unit
//  (requires (fun h0 -> True))
//  (ensures (fun h0 b h1 -> modifies Set.empty h0 h1 // no visible change in cn
//  ))
let request c ops     = Handshake.request     (C.hs c) ops


(*** current epochs ***)

// the index of messages depends on the connection state,
// and may be different for reading and for writing.

#set-options "--initial_ifuel 0 --max_ifuel 1 --initial_fuel 0 --max_fuel 0"
//16-05-28 we need pattern matching! 

// to be replaced with check_incrementable (and pushed).
// dynamically checks for overflows
val no_seqn_overflow: c: connection -> rw:rw -> ST bool
  (requires (fun h -> st_inv c h))
  (ensures (fun h0 b h1 ->
    let es = epochs c h1 in
    let j = iT c.hs rw h1 in
    j < Seq.length es /\
    h0 == h1 /\
    (b /\ j >= 0) ==> (
    let e = Seq.index es j in
    match rw with 
    | Reader -> incrementable (reader_epoch e) h0
    | Writer -> incrementable (writer_epoch e) h0
    )))

let no_seqn_overflow c rw =
  let es = MS.i_read c.hs.log in //MR.m_read c.hs.log in
  let j = Handshake.i c.hs rw in
  if j < 0 then //16-05-28 style: ghost constraint prevents using j < 0 || ... 
    true
  else (
    let e = Seq.index es j in 
    let h = ST.get() in 
    let _ = match rw with 
    | Reader -> assume(incrementable (reader_epoch e) h)
    | Writer -> assume(incrementable (writer_epoch e) h) in
    true  )
// JP: placeholder while I fix the int64 problem
    (* 
    let n = !(seqn w) + 1 in
    if n >= 72057594037927936 && n < 18446744073709551616
    then (lemma_repr_bytes_values n; true)
    else false *)
    
#set-options "--initial_ifuel 0 --max_ifuel 0 --initial_fuel 0 --max_fuel 0"


(*** outgoing ***)

type ioresult_w =
    // public results returned by TLS.send
    | Written             // the application data was written; the connection remains writable
    | WriteClose          // a final closeNotify was written; the connection is either closed or read-only
    | WriteError: o:option alertDescription -> txt: string -> ioresult_w 
                          // The connection is gone, possibly after sending a fata alert 
//  | WritePartial of unsent_data // worth restoring?

    // transient internal results returned by auxiliary send functions
    | WrittenHS: newWriter:bool -> complete:bool -> ioresult_w // the handshake progressed
(*
//  | MustRead            // Nothing written, and the connection is busy completing a handshake
    | WriteDone           // No more data to send in the current state
    | WriteHSComplete     // The handshake is complete [while reading]
    | WriteClose           // a closeNotify was finally written.
    | WriteAgain          // sent something; there may be more to send (loop)
    | WriteAgainFinishing // outgoing epoch changed; there may be more to send to finish the handshake (loop)
    | WriteAgainClosing   // we are tearing down the connection & must still send an alert
*)

type ioresult_o = r:ioresult_w { is_Written r \/ is_WriteError r }


// error-handling

// the connection fails now, and should not be resumed.
val disconnect: c: connection -> ST unit
  (requires (fun h0 -> st_inv c h0))
  (ensures (fun h0 _ h1 -> st_inv c h1 /\ modifies (Set.singleton (C.region c)) h0 h1))

let disconnect c =
    invalidateSession c.hs; //changes (HS.region c.hs)
    c.state := Close

// on some errors, we locally give up the connection
let unrecoverable c reason : ioresult_w =
    disconnect c;
    WriteError None reason


val send_payload: c:connection -> i:id -> f: Content.fragment i -> ST (encrypted f)
  (requires (fun h ->
    let es = epochs c h in // implying epochs_inv es
    let j = iT c.hs Writer h in
    st_inv c h /\
    (if j < 0 then i == noId else
       let e = Seq.index es j in
       i = hsId e.h /\
       incrementable (writer_epoch e) h)))
  (ensures (fun h0 payload h1 ->
    let es = epochs c h0 in
    let j = iT c.hs Writer h0 in
    st_inv c h0 /\
    st_inv c h1 /\
    op_Equality #int j (iT c.hs Writer h1) /\  //16-05-16 would be nice to write just j = iT c.hs Writer h1
    (if j < 0 then i == noId /\ h0 == h1 else 
       let e = Seq.index es j in   
       i = hsId e.h /\ (
       let wr: writer i = writer_epoch e in
       modifies (Set.singleton (region wr)) h0 h1 /\
       seqnT wr h1 = seqnT wr h0 + 1 /\
       (authId i ==> StAE.fragments #i wr h1 = snoc (StAE.fragments #i wr h0) f)
//		     /\ StAE.frame_f (StAE.fragments #i wr) h1 (Set.singleton (StAE.log_region wr)))
       )) /\
    True ))

(* #reset-options "--log_queries --initial_fuel 0 --initial_ifuel 0 --max_fuel 0 --max_ifuel 0" *)
let send_payload c i f =
    let j = Handshake.i c.hs Writer in
    if j<0 
    then Content.repr i f
    else let es = MS.i_read c.hs.log in
	 let e = Seq.index es j in 
	 (* let _ = reveal_epoch_region_inv e in *)
	 StAE.encrypt (writer_epoch e) f
 

(* assume val frame_ae:  *)
(*   h0:HH.t -> h1: HH.t -> c:connection -> Lemma( *)
(*     // restrictions of h0 and h1 to the footprint of st_inv and iT in c are the same /\ *)
(*     st_inv c h0 ==> st_inv c h1 /\ op_Equality #int (iT c.hs Writer h0) (iT c.hs Writer h1)) *)

// used e.g. for writing while reading
let currentId (c:connection) (rw:rw) : id = 
  let j = Handshake.i c.hs rw in 
  if j<0 then noId 
  else 
    let es = MR.m_read c.hs.log in
    let e = Seq.index es j in
    let id = hsId e.h in
    if rw = Writer then id else peerId id


// check vs record
let send_requires (c:connection) (i:id) (h:HH.t) = 
    let st = sel h c.state in
    let es = epochs c h in 
    let j = iT c.hs Writer h in
    // j < Seq.length es /\
    st_inv c h /\
    st <> Close /\
    st <> Half Reader /\
    (j < 0 ==> i = noId) /\
    (j >= 0 ==> (
       let e = Seq.index es j in
       let wr = writer_epoch e in 
       Map.contains h (StAE.region wr) /\ //NS: Needed to add this explicitly here. TODO: Soon, we will get this by just requiring mc_inv h, which includes this property
       Map.contains h (StAE.log_region wr) /\ //NS: Needed to add this explicitly here. TODO: Soon, we will get this by just requiring mc_inv h, which includes this property
       i = hsId e.h /\
       incrementable (writer_epoch e) h))
       
val send: c:connection -> #i:id -> f: Content.fragment i -> ST (result unit)
  (requires (send_requires c i))
  (ensures (fun h0 _ h1 ->
    let es = epochs c h0 in
    let j = iT c.hs Writer h0  in
    let st = sel h0 c.state in
    st_inv c h0 /\
    st_inv c h1 /\
    j == iT c.hs Writer h1 /\ // should follow from the modifies clause
    (if j < 0 then i == noId /\ h0 = h1 else
       let e = Seq.index es j in
       i = hsId e.h /\ (
       let wr: writer i = writer_epoch e in
       modifies (Set.singleton (region wr)) h0 h1 /\
       seqnT wr h1 = seqnT wr h0 + 1 /\
       (authId i ==> StAE.fragments #i wr h1 = snoc (StAE.fragments #i wr h0) f )))))


//16-05-29 timing out?
#set-options "--lax" 
let send c #i f =
  let pv = outerPV c in
  let ct, rg = Content.ct_rg i f in
  let payload = send_payload c i f in
  lemma_repr_bytes_values (length payload);
  let record = Record.makePacket ct pv payload in
  let r  = Platform.Tcp.send (C.tcp c) record in
  (* let h1 = ST.get() in *)
  (* cut (trigger_frame h1); *)
  match r with
    | Error(x)  -> Error(AD_internal_error,x)
    | Correct _ -> Correct()


(* 
assume val admit_st_inv: c: connection -> ST unit
  (requires (fun _ -> True))
  (ensures (fun h0 _ h1 -> h0 = h1 /\ st_inv h1 c))
*)


// auxiliary functions for projections; floating.
let appfragment (i:id) (o: option (rg:frange i & DataStream.fragment i rg) { is_Some o }) : Content.fragment i =
  match o with
  | Some (| rg, f |) -> Content.CT_Data rg f

let datafragment (i:id) (o: option (rg:frange i & DataStream.fragment i rg) { is_Some o }) : DataStream.delta i =
  match o with
  | Some (| rg, f |) -> let f: DataStream.pre_fragment i = f in //16-05-16 unclear why we now need this step
                       DataStream.Data f



(*16-05-20 not used yet?

(* Several test functions to drive the Handshake manually until the big
 [writeOne] function is complete. *)

let test_send_alert (c: connection) (i: id) (ad: alertDescription) =
  match send c #i (Content.ct_alert i ad) with
  | Correct () ->
      disconnect c; WriteError (Some ad) ""
  | Error (x,y) ->
      unrecoverable c y

let test_send (c:connection) (i:id) =
  let hs_response = Handshake.next_fragment c.hs in
  match hs_response with
  | Handshake.OutSome rg f ->
     send c #i (Content.CT_Handshake rg f)
  | _ -> failwith "ERROR"

let test_send_hs_fragment (c: connection) (i: id) (rg: frange i) (f: rbytes rg) =
  match send c #i (Content.CT_Handshake rg f) with
  | Correct ()   -> WriteAgain
  | Error (x,y) -> unrecoverable c y

let test_send_data (c: connection) (i: id) (rg: frange i) (f: rbytes rg) =
  match send c (Content.CT_Data rg f) with
  | Correct ()   -> Written (* Fairly, tell we're done, and we won't write more data *)
  | Error (x,y) -> unrecoverable c y
*) 



(* which fragment should we send next? *)
(* we must send this fragment before restoring the connection invariant *)

//* pick & send one pending message from any protocol state, in two modes:
//* when writing for the application code, we may send is_Some ghost.
//* when writing while reading, is_None ghost.
//* the result ranges over...
//* | WriteDone         when is_None ghost, notifying there is nothing left to send
//* | Written when is_Some ghost, notifying the appdata fragment was sent
//* | WriteError (unrecoverable \/ after sending alert)
//* | WriteClose
//* | WriteAgain | WriteAgainFinishing | WriteAgainClosing
//* | WriteHSComplete
//* the state changes accordingly.

let trigger_peer (#a:Type) (x:a) = True


let cwriter (i:id) (c:connection) = 
  w:writer i{exists (r:reader (peerId i)).{:pattern (trigger_peer r)}
	       epoch_region_inv' (HS.region c.hs) r w}

//16-05-29 duplicating no_seqn_overflow?
private let check_incrementable (#c:connection) (#i:id) (wopt:option (cwriter i c))
  : ST bool
    (requires (fun h -> True))
    (ensures (fun h0 b h1 -> 
	      h0 = h1 
	      /\ (b <==> (match wopt with 
		        | None -> True
			| Some w -> incrementable w h1))))
  = admit()//TODO

let sendFragment_requires (#c:connection) (#i:id) (wo:option(cwriter i c)) h = 
     st_inv c h 
  /\ (match wo with 
     | None    -> i = noId
     | Some wr ->  Map.contains h (StAE.region wr)
	       /\ Map.contains h (StAE.log_region wr))

#set-options "--initial_fuel 0 --initial_ifuel 1 --max_fuel 0 --max_ifuel 1"  

//16-05-29 note that AD_record_overflow os for oversized incoming records, not seqn overflows! See slack.
// let ad_overflow : result unit = Error (AD_internal_error, "seqn overflow")
let ad_overflow : result unit = Error (AD_record_overflow, "seqn overflow")

val sendFragment: c:connection -> #i:id -> wo:option (cwriter i c) -> f: Content.fragment i -> ST (result unit)
  (requires (sendFragment_requires wo))
  (ensures (fun h0 r h1 -> 
    (r=ad_overflow ==> is_Some wo /\ not(incrementable (Some.v wo) h1))
    /\ (is_None wo \/ r=ad_overflow ==> modifies Set.empty h0 h1)
    /\ (is_Some wo /\ r<>ad_overflow ==> 
	(let wr = Some.v wo in
 	   modifies_one (region wr) h0 h1 
        /\ seqnT wr h1 = seqnT wr h0 + 1 
        /\ (authId i ==> StAE.fragments wr h1 = snoc (StAE.fragments wr h0) f)))))

let regions (#i:id) (#c:connection) (wopt:option (cwriter i c)) : Tot (set HH.rid) = 
  match wopt with 
  | None -> Set.empty
  | Some wr -> Set.singleton (region wr)


let sendFragment c #i wo f =
  reveal_epoch_region_inv_all ();
  if not (check_incrementable wo)
  then ad_overflow
  else begin
       let payload: encrypted f = 
           match wo with
	   | None    -> Content.repr i f //16-05-20 don't understand error.
	   | Some wr -> StAE.encrypt wr f in 
       let pv = outerPV c in //16-05-20  compare with i.pv?; Needs hs_inv
       let ct, rg = Content.ct_rg i f in
       lemma_repr_bytes_values (length payload);
       let record = Record.makePacket ct pv payload in
       let r  = Platform.Tcp.send (c.tcp) record in
       match r with
       | Error(x)  -> Error(AD_internal_error,x)
       | Correct _ -> Correct()
  end       


val current_writer : //A slightly exotic style here, because we can; using a local definition for the pre-condition, repeated in the post
    (let current_writer_pre (c:connection) (i:id) (h:HH.t) : GTot Type0 = 
	let hs = c.hs in 
	let ix = iT hs Writer h in
	if ix < 0
	then b2t (i = noId)
	else let epoch_i = eT hs Writer h in 
   	     b2t (i=hsId (Epoch.h epoch_i)) in
     c:connection -> i:id -> ST (option (cwriter i c))
       (requires (current_writer_pre c i))
       (ensures (fun h0 wo h1 -> 
	       current_writer_pre c i h1
	       /\ h0=h1
	       /\ (match wo with 
		  | None -> i=noId
		  | Some w -> 
		    i<>noId //needed for well-formedness of eT
		    /\ (let epoch_i = eT c.hs Writer h1 in 
	               let w_i = Epoch.w epoch_i in
		       trigger_peer (Epoch.r epoch_i) /\
		       op_Equality #(cwriter i c) w w_i)))))
let current_writer c i = 
  let ix = Handshake.i c.hs Writer in 
  if ix < 0
  then None
  else let epochs = MS.i_read (HS.log c.hs) in
       let e = Seq.index epochs ix in
       let _ = cut (trigger_peer (Epoch.r e)) in
       Some (Epoch.w e)


private let sendAlert (c:connection) (ad:alertDescription) (reason:string)
  :  ST ioresult_w
	(requires (fun _ -> True)) //was: send_requires c i
	(ensures (fun h0 r h1 -> True))
          //16-05-29 TODO: write precise post, adapted from sendFragment, with three cases:
          // | WriteError (Some ad) txt  -> write log += ad; state = Close
          // | WriteClose                 -> write log += closeNotify; state = ...
          // | WriteError None txt       -> no change except state = Close

  = let i = currentId c Writer in 
    let wopt = current_writer c i in 
    let st = !c.state in
    // We don't pad alerts
    match sendFragment c #i wopt (Content.CT_Alert #i (point 2) ad) with
    | Error xy -> unrecoverable c (snd xy) // or reason?
    | Correct _   ->
        if ad = AD_close_notify then
          begin // graceful closure
            c.state := (if st = Half Writer then Close else Half Reader);
            WriteClose
          end
        else
          begin
            disconnect c;
            WriteError (Some ad) reason
          end


private let sendHandshake (#c:connection) (#i:id) (wopt:option (cwriter i c)) (om:option (message i)) (send_ccs:bool)
  : ST (result unit)
       (requires (fun h -> sendFragment_requires wopt h))
       (ensures (fun h0 r h1 -> modifies_just (regions wopt) h0 h1))
  =  let result0 = // first try to send handshake fragment, if any
         match om with
         | None             -> Correct()
         | Some (| rg, f |) -> sendFragment c wopt (Content.CT_Handshake rg f) in 
     reveal_epoch_region_inv_all ();
     let h1 = ST.get() in 
     cut (st_inv c h1);
     // then try to send CCS fragment, if requested
     match result0 with
     | Error e -> Error e
     | _ ->
       if not send_ccs
       then result0
       else sendFragment c wopt (Content.CT_CCS #i (point 1)) // Don't pad



// (old) outcomes?
// | WriteAgain -> sent any higher-priority fragment, same index, same app-level log (except warning)
// | Written    -> sent application fragment (when is_Some appdata)
// | WriteDone  -> sent nothing              (when appdata = None)
// | WriteError None      _ -> closed the connection on unrecoverable error (same log, unclear app-level signal)
// | WriteError (Some ad) _ -> closed the connection (log extended with fatal alert)
// | WriteAgainClosing      -> will attempt to send an alert before closing
// | WriteClose              -> similar
// | WriteAgainFinishing    -> incremented the writer epoch.

//16-05-27 updated post-condition branches; 
//         to be share between writing functions (each returning a subset of results); still missing details.

let write_ensures (c:connection) (i:id) (appdata: option (rg:frange i & DataStream.fragment i rg)) (r: ioresult_w) h0 h1 =
  let st0 = sel h0 c.state in 
  let st1 = sel h1 c.state in 
  let es0 = epochs c h0 in 
  let es1 = epochs c h1 in 
  let j = iT c.hs Writer h0 in
  st_inv c h0 /\
  st_inv c h1 /\
  begin
    match r with     
    | Written -> // writer view += Data appdata; no other visible effects. 
        (match appdata with 
        | None -> False
        | Some  (| rg, f |) ->
        j >= 0 /\ st0 = AD (* 16-05-27 not typechecking:  /\
        ( let wr = writer_epoch (Seq.index es0 j) in 
          modifies_one (region wr) h0 h1 /\
          seqnT wr h1 = seqnT wr h0 + 1 /\
          (authId i ==> StAE.fragments wr h1 = snoc (StAE.fragments wr h0) (Content.CT_Data rg f))) *)
          // add something on the projection?
        )  
    | WriteClose -> // writer view += Close (so we can't send anymore); only from calling sendAlert.
        st1 <> AD

    | WriteError oad reason -> 
        // Something bad happened while writing (underspecified, for convenience)
        // * if appdata = None, then the current writer may have changed.
        // * current writer view += appdata.value (or not) += oad.value (or not) 
        st1 = Close /\
        (match oad with 
        | Some ad -> True //TBC: writer view += at most appdata.value + ad  
        | None    -> True //TBC: writer view += at most appdata.value 
        )
        // TBC, describing what may have been added to the projection

    | WrittenHS newWriter complete -> True
        // we sent higher-priority traffic; no visible effects,
        // we may be in a new epoch and/or have completed a handshake
        // several cases to be detailed (see below), none of them changing writer views.

(* replacing:
    | WriteAgain -> // we sent higher-priority traffic; no visible effects.
        st0 = st1
        // only HS, Alert, and region wr were modified
        // the writer projection is unchanged
        // the iT indexes are unchanged

    | WriteDone -> // there was nothing to send [before reading]
        is_None appdata
        // only internal changes in HS.

    | WriteAgainFinishing -> 
        st0 = st1 
        // we now have a new writer with an empty view; no other visible effects.
        // appdata was not sent, and we can't send AD until completion.

    | WriteHSComplete -> // rejoice! the handshake completed
        st1 = AD /\ 
        iT c.hs Writer h1 = iT c.hs Reader h1
        // should also state that the old epoch's log is unchanged, and the new epoch's log is empty.

    | WriteAgainClosing -> False
*)
  end


#set-options "--initial_fuel 0 --initial_ifuel 0 --max_fuel 0 --max_ifuel 0"  

// simplified to loop over Handshake traffic only;
// called both when writing and reading 
// returns WriteError or WrittenHandshake
//TODO: consider sending handshake warnings
//TODO: consider keeping some errors private
//TODO: consider inlining sendHandshake to save a spec.
//TODO: consider immediately sending post-completion traffic (e.g. TLS 1.2 Finished and TLS 1.3 Tickets)
let rec writeHandshake (c:connection) (newWriter:bool) : St ioresult_w =
  let i = currentId c Writer in 
  let wopt = current_writer c i in
  match next_fragment i c.hs with
  | Handshake.OutError (ad,reason) -> sendAlert c ad reason 
  | Handshake.Outgoing om send_ccs next_keys complete ->
	    
      // we send handshake & CCS messages, and process key changes
      match sendHandshake wopt om send_ccs with 
      | Error (ad,reason) -> sendAlert c ad reason 
      | _   -> 
        if next_keys           then c.state := BC; // much happening ghostly
        let st = !c.state in
        let newWriter = newWriter || next_keys in 
        if complete && st = BC then c.state := AD; // much happening ghostly too
        if complete || ( is_None om && not send_ccs) 
	then 
          // done, either to completion or because there is nothing left to do
          WrittenHS newWriter complete
        else 
          // keep writing until something happens
          writeHandshake c newWriter  

// then we can use this variant of write, and get rid of the rest below.
let write c #i #rg data = 
  let wopt = current_writer c i in
  match writeHandshake c false with 
  | WrittenHS false false -> 
      begin // we attempt to send some application data
        match sendFragment c wopt (Content.CT_Data rg data) with
	| Error(ad,reason) -> sendAlert c ad reason
	| _                -> Written 
      end
  | r  -> r // we report some handshake action; the user may retry at a different index.
           // variants may be more convenient, 
           // e.g WrittenHS true false signals 0.5 writing, and we could then write AD and report completion.

(*16-05-29 BEGIN OLDER VARIANT 

val writeOne: c:connection -> i:id -> appdata: option (rg:frange i & DataStream.fragment i rg) -> ST ioresult_w
  (requires (fun h ->
    send_requires c i h
    /\ (let st = sel h c.state in
       let j = iT c.hs Writer h in
       j >= 0 ==> st=AD))) // CF 16-05-27 too strong
  (ensures (fun h0 r h1 -> True))
(*     let st = sel h0 c.state in *)
(*     let es = sel h0 c.hs.log in *)
(*     let j = iT c.hs Writer h0  in *)
(*     st_inv c h0 /\ *)
(*     st_inv c h1 /\ *)
(*     j == iT c.hs Writer h1 /\ //16-05-16 used to be =; see other instance above *)
(*     (if j < 0 then i == noId /\ h0 = h1 else *)
(*        let e = Seq.index es j in *)
(*        i == hsId e.h /\ ( *)
(*        let wr:writer i = writer_epoch e in *)
(*        modifies (Set.singleton (C.region c)) h0 h1 *)
(* )))) *)


let writeOne c i appdata =
  allow_inversion (Handshake.outgoing i);
  let h0 = ST.get() in
  let wopt = current_writer c i in
  // alerts are now sent immediately, so we now start with Handshake
   match next_fragment i c.hs with
    | Handshake.OutError (x,y) -> unrecoverable c y // a bit blunt
    | Handshake.Outgoing om send_ccs next_keys complete ->
	    
      // we send handshake & CCS messages, and process key changes (TODO:restore precise checks and error handling)
      match sendHandshake wopt om send_ccs with 
      | Error (_,y) -> unrecoverable c y
      | _   -> 
        if next_keys           then c.state := BC; // much happening ghostly
        let st = !c.state in
        if complete && st = BC then c.state := AD; // much happening ghostly too
        if complete            
	then WriteHSComplete
        else if is_Some om && send_ccs 
	then WriteAgain
        else 
             // we finally attempt to send some application data; we may statically know that st = AD
             match st, appdata with 
	     | AD, Some (|rg,f|) -> begin
	       match sendFragment c wopt (Content.CT_Data rg f) with
	       | Error (_,y) -> unrecoverable c y
	       | _   -> Written (* Fairly, tell we're done, and we won't write more data *)
	       end
             | _ -> WriteDone // We are finishing a handshake. Tell we're done; the next read will complete it.



let is_current_writer (#c:connection) (#i:id) (wopt:option (cwriter i c)) (h:HH.t) = 
  match wopt with 
  | None -> True
  | Some w -> 
    iT c.hs Writer h >= 0
    /\ (let epoch_i = eT c.hs Writer h in 
       w == Epoch.w epoch_i)


////////////////////////////////////////////////////////////////////////////////
//NS reached up to here
////////////////////////////////////////////////////////////////////////////////


// in TLS 1.2 we send the Finished messages immediately after CCS
// in TLS 1.3 we send e.g. ServerHello in plaintext then encrypted HS

val writeAllFinishing: c:connection -> i:id -> ST ioresult_w
  (requires (fun h ->
    send_requires c i h)) //16-05-28 too strong: already includes incrementable.
  (ensures (fun h0 r h1 ->
    st_inv c h1 /\ modifies (Set.singleton c.region) h0 h1 /\
    (is_WriteError r \/ is_WriteClose r \/ is_Written r)
  ))

let rec writeAllFinishing c i =
    assume false; //16-05-28 
    if no_seqn_overflow c Writer then
    match writeOne c i None with
    // we disable writing temporarily
    | WriteAgain          -> writeAllFinishing c i
//   | WriteDone           -> MustRead

    // all other cases disable writing permanently
//  | WriteAgainClosing   -> writeClosing c i
    | WriteError x y      -> WriteError x y
    | WriteClose           -> WriteClose // why would we do that?

//  | MustRead            // excluded since responded only here
//  | Written             // excluded since we are not sending AD
//  | WriteAgainFinishing // excluded by the handshake logic (not easily proved)
    | WriteHSComplete     // excluded since we need an incoming CCS (not easily proved)
                          -> unexpected "[writeAllFinishing] writeOne returned wrong result"
    else                    unexpected "[writeAllFinishing] seqn overflow"


// called both by read (with no appData) and write (with some appData fragment)
// returns to read  { WriteError, WriteClose, WriteDone, WriteHSComplete }
// returns to write { WriteError, Written }
// (TODO: write returns { WriteHSComplete, MustRead } in renegotiation)
val writeAll: c:connection -> i:id -> appdata: option (rg:frange i & DataStream.fragment i rg) -> ST ioresult_w
  (requires (fun h ->
    send_requires c i h /\  //16-05-28 too strong: already includes incrementable.
    (is_Some appdata ==> sel h c.state = AD)))
  (ensures (fun h0 r h1 ->
    st_inv c h1 /\ modifies (Set.singleton c.region) h0 h1 /\
    (is_None appdata ==> is_WriteError r \/ is_WriteDone r \/ is_WriteHSComplete r )))

let rec writeAll c i appdata =
    if no_seqn_overflow c Writer then
    (assume false; // TODO
    match writeOne c i appdata with
    | WriteAgain          -> writeAll c i appdata
//  | WriteAgainClosing   -> writeClosing c i // TODO, using updated epoch_id (epoch_w c)
    | WriteAgainFinishing -> // next writer epoch!
                            writeAllFinishing c i // TODO, using updated epoch_id (epoch_w c)
    | WriteError x y      -> WriteError x y
    | WriteClose           -> WriteClose
    | WriteDone           -> WriteDone
//  | MustRead            -> MustRead
    | Written             -> Written
    | _                   -> unexpected "[writeAll] writeOne returned wrong result")
    else                    unexpected "[writeAll] seqn overflow"


//Question: NS, BP, JL: Is it possible for write to return WriteAgain or a partially written data?
// no: we always write the whole fragment or we get a fatal error.

let write c i rg data = writeAll c i (Some (| rg, data |))

END OLDER VARIANT *)



// Two API functions to close down the connection
// [review function names]

// Our monotonic invariant on streams already indicates
// whether the last delta is final, so there is no need
// for additional state to keep track of half-closure.

// We notify, and hope to get back the peer's notify.

let writeCloseNotify c =
  sendAlert c AD_close_notify "full shutdown"

// We notify and don't wait for confirmation.
// Less reliable. Makes the connection unwritable.
// Returns sentClose  ==> the datastream is extended with AD_close_notify
//      or some unrecoverable error (in which case we don't know)

let writeClose c =
  let r = sendAlert c AD_close_notify "half shutdown" in
  c.state := Close;
  r


(*** incoming (implicitly writing) ***)

// By default, all i:id are reader identifiers, i.e. peerId (hsId (reader_epoch.h)
// Tricky for noId?       

// FIXME: Put the following definitions close to range and delta, and use them

type query = Cert.chain
type msg_i (i:id) = (range * DataStream.delta i)

(* merged with ioresult_i
type readOutcome (e:epoch) =
    | WriteOutcome of writeOutcome    // now? { ReadError, DontWrite, CompletedSecond, Read(Close) }
    | RError of string (* internal *) // now ReadError(None,err)
    | CertQuery of query * bool       // now CertQuery
    | RHSDone                         // now Complete
    // now Read(delta e) with subcases Data, Close, Alert
    | RAppDataDone of msg_i | RClose
    | RFatal of alertDescription (* The alert we received *)
    | RWarning of alertDescription (* The alert we received *)
    // internal states only
    | ReadAgain | ReadAgainFinishing | ReadFinished *)


type ioresult_i (i:id) =
    | Read of DataStream.delta i
        // This delta has been added to the input stream;
        // We may have read
        // - an application-data fragment or a warning (leaving the connection live)
        // - a closure or a fatal alert (tearing down the connection)
        // If the alert is a warning, the connection remains live.
        // If the alert is final, the connection has been closed by our peer;
        // the application may reuse the underlying TCP stream
        // only after normal closure (a = AD_close_notify)
        // We have not sent anything notable (no AD, no alerts).

    | ReadError: o:option alertDescription -> txt:string -> ioresult_i i
        // We encountered an error while reading, so the connection dies.
        // we return the fatal alert we may have sent, if any,
        // or None in case of an internal error.
        // The connection is gone; its state is undefined.

    | CertQuery: query -> bool -> ioresult_i i
        // We received the peer certificates for the next epoch, to be authorized before proceeding.
        // the bool is what the Windows certificate store said about this certificate.
    | Complete
        // Handshake is completed, and we have already sent our finished message,
        // so only the incoming epoch changes
//    | CompletedSecond

    // internal states only
    | ReadAgain
    | ReadAgainFinishing

//  | ReadFinished
//  | DontWrite
//      // Nothing read yet, but we can't write anymore.



let live_i e r = // is the connection still live?
  match r with
  | Read d        -> not(DataStream.final e d)
  | ReadError _ _ -> false
  | _             -> true

// let's specify reading d off the input DataStream (incrementing the reader pos)

val sel_reader: h:HyperHeap.t -> connection -> GTot (option (| i:id & StAE.reader i |)) // self-specified
let sel_reader h c =
  let es = epochs c h in
  let j = iT c.hs Reader h in
  (if j < 0 then None else 
  let e = Seq.index es j in 
  let i = peerId (hsId e.h) in
  assume(is_stream_ae i);
  Some (| i, reader_epoch e|))
  // todo: add other cases depending on dispatch state

type delta h c = 
  (match sel_reader h c with 
  | Some (| i , _ |) -> DataStream.delta i
  | None             -> DataStream.delta noId)


// frequent error handler; note that i is the (unused) reader index
let alertFlush c ri (ad:alertDescription { isFatal ad }) (reason:string): ioresult_i ri =
  let written = sendAlert c ad reason in
  match written with
  | WriteClose      -> Read DataStream.Close // do we need this case?
  | WriteError x y -> ReadError x y         // how to compose ad reason x y ? 


#reset-options 

val readFragment: c:connection -> i:id -> ST (result (Content.fragment i))
  (requires (fun h0 ->
    let es = epochs c h0 in 
    let j = iT c.hs Reader h0 in 
    st_inv c h0 /\
    (if j < 0 then i == noId else 
      let e = Seq.index es j in
      i = peerId (hsId e.h) /\
      incrementable (reader_epoch e) h0)))
  (ensures (fun h0 r h1 -> 
    let es = epochs c h0 in 
    let j = iT c.hs Reader h0 in 
    st_inv c h0 /\
    st_inv c h1 /\
    j == iT c.hs Reader h1 /\
    (if j < 0 then i == noId /\ h0 == h1 else 
      let e = Seq.index es j in
      i = peerId (hsId e.h) /\
      (let rd: reader i = reader_epoch e in 
      modifies (Set.singleton (region rd)) h0 h1 /\
      (match r with 
      | Error e -> True // don't know what seqnT is, don't care.
      | Correct f -> 
          seqnT rd h1 = seqnT rd h0 + 1 /\
          (authId i ==>
            (let frs = StAE.fragments #i rd h0 in
            let n = seqnT rd h0 in 
            n < Seq.length frs /\
            f == Seq.index frs n) 
  ))))))

let readFragment c i = 
  assume false; // 16-05-19 can't prove POST.
  match Record.read c.tcp i.pv with 
  | Error e -> Error e
  | Correct(ct,pv,payload) -> 
    let es = MR.m_read c.hs.log in 
    let j : logIndex es = Handshake.i c.hs Reader in 
    if j < 0 then // payload is in plaintext
      let rg = Range.point (length payload) in 
      Correct(Content.mk_fragment i ct rg payload)
    else
      // payload decryption
      let e = Seq.index es j in 
      match StAE.decrypt (reader_epoch e) payload with 
      | Some f -> Correct f
      | None   -> Error(AD_internal_error,"") //16-05-19 adjust! 

// We receive, decrypt, parse a record (ct,f); what to do with it?
// i is the presumed reader, threaded from the application.

private val readOne: c:connection -> i:id -> St (ioresult_i i) 
//  (ensures ioresult is not Complete | CompletedSecond | DontWrite)

let readOne c i =
  assume false; //16-05-19 
  match readFragment c i with 
  | Error (x,y) -> alertFlush c i x y
  | Correct (Content.CT_Alert rg ad) ->
      begin
        if ad = AD_close_notify then 
          if !c.state = Half Reader 
          then ( // received a notify response; cleanly close the connection.
            c.state := Close; 
            Read (DataStream.Alert ad))
          else ( // received first notification; immediately enqueue notify response [RFC 7.2.1]
            c.state := Half Writer; 
            alertFlush c i AD_close_notify "notify response")  // NB we could ignore write errors here. 
        else (   // 
          if isFatal ad then disconnect c; 
          Read (DataStream.Alert ad))
          // else we carry on; the user will know what to do
      end
      // recheck we tolerate alerts in all states; used to be just Init|Open, otherwise:
      // alertFlush c AD_unexpected_message (perror __SOURCE_FILE__ __LINE__ "Message type received in wrong state")

  | Correct(Content.CT_Handshake rg f) -> 
      begin
        match recv_fragment c.hs (| rg, f |) with
        | InError (x,y) -> alertFlush c i x y
        | InQuery q a   -> CertQuery q a
        | InAck next_keys complete -> 
            if complete then 
            ( match !c.state with
            | BC -> // TODO: additional sanity check: in and out epochs should be the same
                   // if epoch_r c = epoch_w c then 
                   (c.state := AD; Complete)
                   // else (disconnect c; ReadError None "Invalid connection state")
                   )
            else ReadAgain
      //| InFinished    -> ReadAgain // should we care? probably before e.g. accepting falseStart traffic
      // recheck correctness for all states; used to be just Init|Finishing|Open
      end
  | Correct(Content.CT_CCS rg) ->
      begin
        // TODO exclude TLS 1.3, here or in the handshake
        match recv_ccs c.hs with
        | InError (x,y)    -> alertFlush c i x y
        | InAck true false -> ReadAgainFinishing // specialized for HS 1.2
      end
  | Correct(Content.CT_Data rg f) ->
      begin
        match !c.state with
        | AD | Half Reader        -> let f : DataStream.fragment i fragment_range = f in Read #i (DataStream.Data f)
        | _                       -> alertFlush c i AD_unexpected_message "Application Data received in wrong state"
      end


 
// scheduling: we always write up before reading, to advance the Handshake.
// those writes are never AppData; they may be for other/changing epochs;
// the write outcomes that matter are: Error, Complete, and Done.
val read: connection -> i:id -> St (ioresult_i i)
let rec read c i =
    assume false;//16-05-19 
    match writeHandshake c false with

    | WriteError x y             -> ReadError x y           // TODO review errors; check this is not ambiguous
    | WriteClose                  -> unexpected "Sent Close" // can't happen while sending?
    | WrittenHS newWriter complete -> 
        if complete then Complete // return at once, so that the app can authorize and use new indexes.
        // else ... then                // return at once, signalling falsestart
        else
    
    // nothing written; now we can read
    // note that the reader index is unchanged
    let result = readOne c i in (
    match result with
    // TODO: specify which results imply that c.state & epochs are unchanged
    | ReadAgain             -> read c i
    | ReadAgainFinishing    -> read c i //was: readAllFinishing c
    | ReadError x y         -> ReadError x y
    | CertQuery q adv       -> CertQuery q adv
    | Read delta            -> Read delta
    )


(* 16-05-28 WIP 

let read_ensures (c:connection) (i:id) (r:ioresult_i i) h0 h1 = 
  let st0 = sel h0 c.state in 
  let st1 = sel h1 c.state in 
  let es0 = epochs c h0 in 
  let es1 = epochs c h1 in 
  let j = iT c.hs Reader h0 in
  st_inv c h0 /\
  st_inv c h1 /\
  begin
    // When authId i, the reader's view is the projected fragment of the peer's writer log up to the reader's seqn 
    // (something worth defining, and monotonic).
    // Unless mentioned otherwise, the epoch indexes, the reader view, and the writer view are unchanged.
    match r with 
    | ReadError x y -> 
        // Local error; x indicates whether the writer view is extended by a fatal alert or not.
    
    | Read delta -> True 
        // If authId i, then the reader view is extended by delta.
        // If delta is terminal, then the connection is now closed.
        // In particular, if delta is a (first) closeNotify and the writer view was open, it has been extended with a (second) closeNotify.
        // [for now the second notify is deferred]
        // [DataStream.Close vs closeNotify?]
        // [We get non-alerts only in some states]

    | CompletedFist ->
        // We have new indexes, with empty reader and writer views. 
        // If the prior epoch was honest, their views are synchronized with the peer.
(*
    // We will need more signals for new keys:
    | NextWriter -> 
        // The writer has changed; the new writer view is empty. 
        // The connection is not writable, except perhaps with FalseStart/0.5RTT, or for alerts. 
*)

    | ReadAgain -> True            // nothing changed in views and epochs                      [local to read loop]
    | ReadAgainFinishing -> True   // nothing changed in views, but we have a new reader epoch [local to read loop]

    | CertQuery _ _ ->          // nothing changed, and we need to authorize the peer's certificate chain.



...
            let st = !c.state in
            match st with
            | Half Reader  ->

            | Closed -> Read DataStream.Close // we already sent a close_notify, tell the user it's over
            | _ ->
                let written = writeClosing c (rd_i c) (*FIXME*) in
                match written with
                | WriteClose      -> Read DataStream.Close // clean shutdown
                | WriteError x y -> ReadError x y
                | _              -> ReadError None (perror __SOURCE_FILE__ __LINE__ "") // internal error
                )
*)

//* we used to specify the resulting connection in ioresult_i,
//* now we do that in the read postcondition


(*
// -----------------------------------------------------------------------------

// responding to a certificate-validation query,
// so that we have an explicit user decision to blame,
// but in fact a follow-up read would do as well.
// to be adapted once we have a proper PKI model
//val authorize : c:Connection -> q:query -> ST ioresult_i
//  (requires (fun h0 -> True))
//  (ensures (fun h0 result h1))

let authorize c q =
    let res = Handshake.authorize (C.hs c) q in
    // AP: BEGIN: Inlined from handleHandshakeOutcome
    match res with
    | Handshake.InAck -> read c
        //? removed: let res = sameID (Conn(id,c1)) newConn res (Conn(id,c)) in
    | Handshake.InVersionAgreed pv ->
        (match !c.reading, !c.writing with
        | Init, Init  ->
            (* Then, also c_write must be in Init state. It means this is the very first, unprotected,
                handshake on the connection, and we just negotiated the version.
                Set the negotiated version in the current sinfo (read and write side),
                and move to the FirstHandshake state, so that
                protocol version will be properly checked *)
            c.reading := FirstHandshake pv;
            c.writing := FirstHandshake pv
            read c
            //? removed: let res = sameID (Conn(id,c1)) newConn res (Conn(id,c)) in

        | _ -> (* It means we are doing a re-negotiation. Don't alter the current version number, because it
                    is perfectly valid. It will be updated after the next CCS, along with all other session parameters *)
            read c)
            //? removed: let res = sameID (Conn(id,c1)) newConn res (Conn(id,c)) in

    | Handshake.InQuery _    -> unexpected "[authorize] A query should never be received"
    | Handshake.InFinished   -> unexpected "[authorize] The finished message should never be received right after a query"
    | Handshake.InComplete   -> unexpected "[authorize] Handshake should never complete right after a query"
    | Handshake.InError(x,y) -> alertFlush c x y

    // AP: END: Inlined from handleHandshakeOutcome

let refuse c (q:query) =
    let reason = perror __SOURCE_FILE__ __LINE__ "Remote certificate could not be verified locally" in
    abortWithAlert c AD_unknown_ca reason;
    writeClosing c
*)


