open Hflmc2_util

type raw_hflz =
  | Bool of bool
  | Var  of string
  | Or   of raw_hflz * raw_hflz
  | And  of raw_hflz * raw_hflz
  | Abs  of string * raw_hflz
  | App  of raw_hflz * raw_hflz
  | Int  of int
  | Op   of Arith.op * raw_hflz list
  | Pred of Formula.pred * raw_hflz list
  | Forall of string * raw_hflz
  | Exists of string * raw_hflz
  | Not of raw_hflz
  [@@deriving eq,ord,show,iter,map,fold,sexp]
type hes_rule =
  { var  : string
  ; args : string list
  ; fix  : Fixpoint.t
  ; body : raw_hflz
  }
  [@@deriving eq,ord,show,iter,map,fold,sexp]
type hes = hes_rule list
  [@@deriving eq,ord,show,iter,map,fold,sexp]

let mk_int n     = Int(n)
let mk_bool b    = Bool b
let mk_var x     = Var x
let mk_op op as' = Op(op,as')
let mk_forall var body = Forall(var, body)
let mk_exists var body = Exists(var, body)
let mk_and f1 f2 = And (f1, f2)
let mk_or f1 f2  = Or  (f1, f2)

let mk_ands = function
  | [] -> Bool true
  | x::xs -> List.fold_left xs ~init:x ~f:(fun a b -> And(a,b))

let mk_ors = function
  | [] -> Bool false
  | x::xs -> List.fold_left xs ~init:x ~f:(fun a b -> Or(a,b))

let mk_not x = Not x

let mk_preds pred bs = Pred(pred, bs)
let mk_pred pred a1 a2 = Pred(pred, [a1;a2])

let mk_app t1 t2 = App(t1,t2)
let mk_apps t ts = List.fold_left ts ~init:t ~f:mk_app

let mk_abs x t = Abs(x, t)
let mk_abss xs t = List.fold_right xs ~init:t ~f:mk_abs

let rec decompose_app = function
  | App(phi1, phi2) ->
      let (a, args) = decompose_app phi1 in
      a, args @ [phi2]
  | phi -> phi, []
let rec decompose_abs = function
  | Abs(x, phi) ->
      let (args, body) = decompose_abs phi in
      x::args, body
  | phi -> [], phi

module Typing = struct
  let log_src = Logs.Src.create ~doc:"Simple Typing" "Typing"
  module Log = (val Logs.src_log log_src)

  open Type
  exception Error of string
  let error s = raise (Error s)

  type info =
    | InfoProg of {expr: raw_hflz}
    | InfoDummy
  
  let pp_info fmt info = match info with
    | InfoDummy -> Fmt.nop fmt ()
    | InfoProg {expr} -> pp_raw_hflz fmt expr
  
  let show_info info = match info with
    | InfoDummy -> ""
    | InfoProg {expr} -> show_raw_hflz expr
    
  type tyvar = (* simple_ty + simple_argty + type variable *)
    | TvRef of int * tyvar option ref * info
    | TvInt of info
    | TvBool of info
    | TvArrow of tyvar * tyvar * info
    [@@deriving show { with_path = false }]
  
  let get_info v = match v with
    | TvRef (_, _, i) -> i
    | TvInt i -> i
    | TvBool i -> i
    | TvArrow (_, _, i) -> i
    
  type id = int
  let new_id    : unit -> id    = Id.gen_id
  let new_tyvar : info -> tyvar =
    let counter = new Fn.counter in
    fun info -> TvRef (counter#tick, ref None, info)

  let rec pp_hum_tyvar : tyvar Print.t =
    fun ppf tv -> match tv with
      | TvInt _ -> Fmt.string ppf "int"
      | TvBool _ -> Fmt.string ppf "o"
      | TvRef(id,{contents=None }, _) ->
          Fmt.pf ppf "tv%d" id
      | TvRef(id,{contents=Some tv}, _) ->
          Fmt.pf ppf "tv%d@%a" id pp_hum_tyvar tv
      | TvArrow(tv1,tv2, _) ->
          Fmt.pf ppf "(%a -> %a)"
            pp_hum_tyvar tv1
            pp_hum_tyvar tv2

  (* TODO: show info *)
  
  exception Alias
  let rec occur : top:bool -> tyvar option ref -> tyvar -> bool =
    fun ~top r tv -> match tv with
      | TvInt _ | TvBool _ -> false
      | TvArrow(tv1, tv2, _) -> occur ~top:false r tv1 || occur ~top:false r tv2
      | TvRef(_, ({contents=None} as r'), _) ->
          if r == r' && top then raise Alias else r == r'
      | TvRef(_, ({contents=Some tv} as r'), _) ->
          if r == r' && top then raise Alias else r == r' || occur ~top r tv
  type occur_check_result = [ `Ok | `Alias ]
  let occur_check r tv =
    try
      if occur ~top:true r tv then begin
        Log.err begin fun m -> m ~header:"Occur Check"
          "r=%a; tv=%a" pp_hum_tyvar (TvRef (-1, r, InfoDummy)) pp_hum_tyvar tv;
        end;
        Fn.fatal "Recursive type is unsupported"
      end else begin
        `Ok
      end
    with Alias -> `Alias

  let rec write : tyvar option ref -> tyvar -> unit =
    fun r tv -> match tv with
      | TvInt _ | TvBool _ | TvArrow _ -> r := Some tv
      | TvRef (_, r', _) ->
          begin match !r' with
          | None -> r := Some tv
          | Some tv' -> write r tv'
                      (* ; write r' tv' (*経路圧縮*) *)
          end

  let rec unify : tyvar -> tyvar -> unit =
    fun tv1 tv2 ->
      (* Log.debug begin fun _ -> Print.pr "UNIFY %a -- %a@."
        pp_hum_tyvar tv1
        pp_hum_tyvar tv2
      end; *)
      (* Print.pr "UNIFY %a (%a) -- %a (%a)@."
        pp_hum_tyvar tv1
        pp_info (get_info tv1)
        pp_hum_tyvar tv2
        pp_info (get_info tv2); *)
      (* Print.pr "UNIFY %a -- %a@."
        pp_hum_tyvar tv1
        pp_hum_tyvar tv2; *)
      match tv1, tv2 with
      | TvInt _, TvInt _ -> ()
      | TvBool _, TvBool _ -> ()
      | TvArrow(tv11,tv12, _),  TvArrow(tv21,tv22, _) ->
          unify tv11 tv21; unify tv12 tv22
      | TvRef (_,r1, _), TvRef (_,r2, _) when r1 == r2 ->
          Log.debug begin fun _ -> Print.pr "EQUAL %a == %a@."
            pp_hum_tyvar tv1
            pp_hum_tyvar tv2
          end;
          if !r1 = None && !r2 = None then begin
            match occur_check r1 tv2 with
            | `Ok ->
                Log.debug begin fun _ -> Print.pr "APPLY1 %a := %a@."
                  pp_hum_tyvar tv1
                  pp_hum_tyvar tv2
                end;
                write r1 tv2
            | `Alias -> ()
          end;
      | (TvRef (_, ({contents = None} as r), _) as tv_src), tv
      | tv, (TvRef (_, ({contents = None} as r), _) as tv_src) ->
          Log.debug begin fun _ -> Print.pr "APPLY2 %a := %a@."
            pp_hum_tyvar tv_src
            pp_hum_tyvar tv
          end;
          begin match occur_check r tv with
          | `Ok -> write r tv
          | `Alias -> ()
          end
      | (TvRef (_, ({contents = Some tv_inner} as r), _) as _tv_src), tv
      | tv, (TvRef (_, ({contents = Some tv_inner} as r), _) as _tv_src) ->
          (* XXX occur_check r tv; *)
          Log.debug begin fun _ -> Print.pr "HERE@." end;
          write r tv;
          unify tv_inner tv
      | x, y ->
          (Print.pr "FAIL %a := %a@."
            pp_hum_tyvar x
            pp_hum_tyvar y
          );
          failwith @@ "FAIL unify: left=" ^ (show_info @@ get_info x) ^ " / right=" ^ (show_info @@ get_info y)

  type id_env = int StrMap.t   (* name to id *)
  (* なんでid_envとty_envの持ち方が違う実装になってるんだろう．これ書いた人バカなのかな？ *)
  let pp_id_env : id_env Print.t =
    fun ppf env ->
      let open Print in
      list_comma (pair string int) ppf (StrMap.to_alist env)
  type ty_env = tyvar IntMap.t (* id to tyvar *)

  class add_annot = object (self)
    (* for compatibility with Suzuki's implementation *)
    val mutable unbound_ints : id_env = StrMap.empty
    val mutable ty_env : ty_env = IntMap.empty

    method get_unbound_ints : id_env = unbound_ints
    method get_ty_env : ty_env = ty_env

    method add_ty_env : 'a. 'a Id.t -> tyvar -> unit =
      fun x tv ->
        Log.debug begin fun _ ->
          Print.pr "TyENV %s : %a@." (Id.to_string x) pp_hum_tyvar tv
        end;
        match IntMap.find ty_env x.id with
        | None -> ty_env <- IntMap.add_exn ty_env ~key:x.id ~data:tv
        | Some tv' -> unify tv tv'

    method arith : id_env -> raw_hflz -> Arith.t =
      fun id_env a -> match a with
        | Int n -> Int n
        | Var name ->
            let x =
              match
                StrMap.find id_env name,
                StrMap.find unbound_ints name
              with
              | None, None ->
                  let id = Id.gen_id() in
                  unbound_ints <- StrMap.add_exn unbound_ints ~key:name ~data:id;
                  Id.{ name; id; ty=`Int }
              | Some id, _ | _, Some id  -> (* the order of match matters! *)
                  Id.{ name; id; ty=`Int }
            in
            self#add_ty_env x (TvInt (InfoProg {expr=Var name})); Arith.mk_var x
        | Op (op, as') -> Op (op, List.map ~f:(self#arith id_env) as')
        | _ -> failwith @@ "annot.arith (should be arithmetic expression. but found \"" ^ show_raw_hflz a ^ "\")"

    method term : id_env -> raw_hflz -> tyvar -> unit Hflz.Sugar.t =
      fun id_env psi tv ->
        Log.debug begin fun _ -> Print.pr "term %a |- %a : %a@."
          pp_id_env id_env
          pp_raw_hflz psi
          pp_hum_tyvar tv
        end;
        match psi with
        | Bool b -> unify tv (TvBool (InfoProg {expr=psi})); Bool b
        | Var name ->
            let id,ty =
              match
                StrMap.find id_env name,
                StrMap.find unbound_ints name
              with
              | Some id, _ ->
                  id, tv
              | _, Some id ->
                  unify tv (TvInt (InfoProg {expr=psi}));
                  id, (TvInt (InfoProg {expr=psi}))
              | _, _ ->
                  let id = new_id() in
                  unify tv (TvInt (InfoProg {expr=psi}));
                  unbound_ints <- StrMap.add_exn unbound_ints ~key:name ~data:id;
                  id, (TvInt (InfoProg {expr=psi}))
            in
            let x = Id.{ name; id; ty=() } in
            self#add_ty_env x ty;
            Hflz.Sugar.mk_var x
        | Or (psi1,psi2) ->
            let psi1 = self#term id_env psi1 (TvBool(InfoProg{expr=psi1})) in
            let psi2 = self#term id_env psi2 (TvBool(InfoProg{expr=psi2})) in
            unify tv (TvBool(InfoProg{expr=psi}));
            Or (psi1,psi2)
        | And (psi1,psi2) ->
            let psi1 = self#term id_env psi1 (TvBool(InfoProg{expr=psi1})) in
            let psi2 = self#term id_env psi2 (TvBool(InfoProg{expr=psi2})) in
            unify tv (TvBool(InfoProg{expr=psi}));
            And (psi1,psi2)
        | Not (psi1) ->
            let psi1 = self#term id_env psi1 (TvBool(InfoProg{expr=psi1})) in
            unify tv (TvBool(InfoProg{expr=psi}));
            Not (psi1)
        | Pred (pred,as') ->
            unify tv (TvBool(InfoProg{expr=psi}));
            Pred(pred, List.map ~f:(self#arith id_env) as')
        | Int _ | Op _ ->
            unify tv (TvInt(InfoProg{expr=psi}));
            Arith (self#arith id_env psi)
        | Abs(name, psi) ->
            let id = new_id() in
            let x = Id.{ name; id; ty = () } in
            let tv_arg = new_tyvar(InfoProg{expr=Var x.name}) in
            let tv_ret = new_tyvar(InfoProg{expr=psi}) in
            unify tv (TvArrow(tv_arg, tv_ret, (InfoProg{expr=Abs(name, psi)})));
            let id_env = StrMap.replace id_env ~key:name ~data:id in
            self#add_ty_env x tv_arg;
            let psi = self#term id_env psi tv_ret in
            Abs(lift_arg x, psi)
        | Forall(name, psi) -> 
            let id = new_id() in
            let x = Id.{ name; id; ty = () } in
            let tv_arg = new_tyvar(InfoProg{expr=Var x.name}) in
            unify tv_arg (TvInt(InfoProg{expr=Var x.name}));
            unify tv (TvBool(InfoProg{expr=Forall(name,psi)}));
            let id_env = StrMap.replace id_env ~key:name ~data:id in
            self#add_ty_env x tv_arg;
            let psi = self#term id_env psi (TvBool(InfoProg{expr=psi})) in
            Forall(lift_arg x, psi)
        | Exists(name, psi) -> 
            let id = new_id() in
            let x = Id.{ name; id; ty = () } in
            let tv_arg = new_tyvar(InfoProg{expr=Var x.name}) in
            unify tv_arg (TvInt(InfoProg{expr=Var x.name}));
            unify tv (TvBool(InfoProg{expr=Exists(name,psi)}));
            let id_env = StrMap.replace id_env ~key:name ~data:id in
            self#add_ty_env x tv_arg;
            let psi = self#term id_env psi (TvBool(InfoProg{expr=psi})) in
            Exists(lift_arg x, psi)
        | App (psi1, psi2) ->
            let tv_arg = new_tyvar(InfoProg{expr=psi2}) in
            let psi1 = self#term id_env psi1 (TvArrow(tv_arg, tv, InfoProg{expr=psi1})) in
            let psi2 = self#term id_env psi2 tv_arg in
            App (psi1, psi2)
            

    method hes_rule : id_env -> hes_rule -> unit Hflz.Sugar.hes_rule =
      fun id_env rule ->
        Log.debug begin fun _ -> 
          Print.pr "hes_rule.vars %a@." Print.string rule.var
        end;
        let id   = StrMap.find_exn id_env rule.var in
        let tv_F = new_tyvar(InfoProg({expr=Var rule.var})) in
        let _F   = Id.{ name=rule.var; id=id; ty=() } in
        self#add_ty_env _F tv_F;

        Log.debug begin fun _ -> 
          Print.pr "hes_rule.vars %a@." Print.(list_comma string) rule.args
        end;
        let var_env =
          List.map rule.args ~f:begin fun name ->
            let id  = new_id() in
            let tv  = new_tyvar(InfoProg({expr=Var name})) in
            let var = Id.{ name; id; ty = TySigma() } in
            self#add_ty_env var tv;
            (var, id, tv)
          end
        in
        let vars, _, tv_vars = List.unzip3 var_env in
        let id_env =
          List.fold_left var_env ~init:id_env ~f:begin fun env (var,id,_tv) ->
            StrMap.replace env ~key:var.name ~data:id
          end
        in
        Log.debug begin fun _ -> 
          Print.pr "ID_ENV: %a@." pp_id_env id_env
        end;
        let body = self#term id_env rule.body (TvBool(InfoProg{expr=rule.body})) in
        unify tv_F @@
          List.fold_left (List.rev tv_vars)
            ~init:(TvBool(InfoProg{expr=rule.body})) ~f:(fun ret arg -> TvArrow (arg, ret, get_info arg));
        { var  = _F
        ; body = Hflz.Sugar.mk_abss vars body
        ; fix  = rule.fix }

    method hes : hes -> unit Hflz.Sugar.hes =
      fun hes ->
        let id_env =
          List.fold_left hes ~init:StrMap.empty ~f:begin fun id_env rule ->
            try
              StrMap.add_exn id_env ~key:rule.var ~data:(new_id())
            with _ ->
              error @@ Fmt.str "%s is defined twice" rule.var
          end
        in
        match List.map hes ~f:(self#hes_rule id_env) with
        | [] -> failwith "raw_hflz: hes"
        | {body=entry; _}::rules -> (entry, rules)
  end

  exception IntType

  class deref ty_env = object (self)
    val ty_env : ty_env = ty_env

    method arg_ty : string -> tyvar -> simple_ty arg = fun info -> function
      | TvInt _ -> TyInt
      | TvBool _ -> TySigma (TyBool())
      | TvRef (_, {contents=None}, _) as tv ->
          Log.debug begin fun _ ->
            Print.pr "DEFAULT %s : %a@." info pp_hum_tyvar tv
          end;
          TySigma (TyBool())
      | TvRef (_, {contents=Some tv}, _) -> self#arg_ty info tv
      | TvArrow (tv1, tv2, _) ->
          let x = Id.gen ~name:"t" (self#arg_ty (info^".arg") tv1) in
          TySigma (TyArrow (x, self#ty (info^".ret") tv2))
    method ty : string -> tyvar -> simple_ty =
      fun info tv -> match self#arg_ty info tv with
      | TyInt -> raise IntType
      | TySigma ty -> ty

    method id : unit Id.t -> simple_ty Id.t =
      fun x -> match IntMap.find ty_env x.id with
        | None -> failwith @@ Fmt.str "%s" (Id.to_string x)
        | Some ty -> { x with ty = self#ty (Id.to_string x) ty }
    method arg_id : unit arg Id.t -> simple_ty arg Id.t =
      fun x -> match IntMap.find ty_env x.id with
        | None -> failwith @@ Fmt.str "%s" (Id.to_string x)
        | Some tv -> { x with ty = self#arg_ty (Id.to_string x) tv }

    method term : unit Hflz.Sugar.t -> simple_ty Hflz.Sugar.t = function
      | Var x ->
          begin match self#id x with
          | x -> Var x
          | exception IntType -> Arith (Arith.mk_var x)
          end
      | Bool b           -> Bool b
      | Or  (psi1,psi2)  -> Or  (self#term psi1, self#term psi2)
      | And (psi1,psi2)  -> And (self#term psi1, self#term psi2)
      | App (psi1, psi2) -> App (self#term psi1, self#term psi2)
      | Not (psi1)       -> Not (self#term psi1)
      | Abs (x, psi)     -> Abs (self#arg_id x, self#term psi)
      | Forall(x, psi)   -> Forall (self#arg_id x, self#term psi)
      | Exists(x, psi)   -> Exists (self#arg_id x, self#term psi)
      | Arith a          -> Arith a
      | Pred (pred,as')  -> Pred(pred, as')

    method hes_rule : unit Hflz.Sugar.hes_rule -> simple_ty Hflz.Sugar.hes_rule =
      fun rule ->
        let var  = self#id rule.var in
        let body = self#term rule.body in
        { var; body; fix = rule.fix }

    method hes : unit Hflz.Sugar.hes -> simple_ty Hflz.Sugar.hes =
      fun (entry, rules) -> self#term entry, List.map rules ~f:self#hes_rule
  end

  let to_typed rhes =
    let add_annot = new add_annot in
    let annotated = add_annot#hes rhes in
    let ty_env, unbound_ints =
      add_annot#get_ty_env, add_annot#get_unbound_ints
    in
    if StrMap.length unbound_ints <> 0 then
      failwith @@ "to_typed: unbound integer variables: " ^ (String.concat ~sep:", " (List.map (StrMap.to_alist unbound_ints) ~f:(fun (name, _) -> name)));
    let deref     = new deref ty_env in
    let hes       = deref#hes annotated in
    hes
    (* match hes with
    | (main, rest) ->
        (* dirty hack for compatibility with Suzuki's impl*)
        let ub_ints =
          List.map (StrMap.to_alist unbound_ints) ~f:begin
            fun (name,id) -> Id.{name;id;ty=TyInt}
          end
        in
        let main =
          let var  = { main.var with ty = mk_arrows ub_ints main.var.ty } in
          let body = Hflz.Sugar.mk_abss ub_ints main.body in
          { main with var; body }
        in
        main :: rest
    | _ -> assert false *)
end

open Type

let rename_simple_ty_rule
      : simple_ty Hflz.Sugar.hes_rule
     -> simple_ty Hflz.Sugar.hes_rule =
  fun rule ->
    let sty        = rule.var.ty in
    let vars, _    = Hflz.Sugar.decompose_abs rule.body in
    let ty_vars, _ = decompose_arrow sty in
    let ty_vars' =
      List.map2_exn vars ty_vars ~f:begin fun var ty_var ->
        { ty_var with name = var.name }
      end
    in
    let sty' = mk_arrows ty_vars' (TyBool()) in
    { rule with var = { rule.var with ty = sty' } }

let rec rename_abstraction_ty
      : ?env:[`Int] Id.t IdMap.t
     -> simple_ty
     -> abstraction_ty
     -> abstraction_ty =
  fun ?(env=IdMap.empty) orig aty -> match orig, aty with
    | TyBool(), TyBool fs ->
        TyBool(List.map ~f:(Trans.Subst.Id.formula env) fs)
    | TyArrow({ty=TyInt;_} as x , ret_sty),
      TyArrow({ty=TyInt;_} as x', ret_aty) ->
        let env = IdMap.replace env x' {x with ty=`Int} in
        TyArrow({x with ty=TyInt}, rename_abstraction_ty ~env ret_sty ret_aty)
    | TyArrow({ty=TySigma arg_sty;_} as x , ret_sty),
      TyArrow({ty=TySigma arg_aty;_}, ret_aty) ->
        let ty = TySigma(rename_abstraction_ty ~env arg_sty arg_aty) in
        TyArrow({x with ty}, rename_abstraction_ty ~env ret_sty ret_aty)
    | _ ->
        invalid_arg "Raw_hflz.rename_abstraction_ty: Simple type mismatch"

let rename_ty_body : simple_ty Hflz.Sugar.hes -> simple_ty Hflz.Sugar.hes =
  fun hes ->
    let rec term : simple_ty IdMap.t -> simple_ty Hflz.Sugar.t -> simple_ty Hflz.Sugar.t =
      fun env psi -> match psi with
        | Bool b           -> Bool b
        | Var x            -> Var { x with ty = IdMap.lookup env x }
        | Or  (psi1, psi2) -> Or  (term env psi1, term env psi2)
        | And (psi1, psi2) -> And (term env psi1, term env psi2)
        | App (psi1, psi2) -> App (term env psi1, term env psi2)
        | Not (psi1)       -> Not (term env psi1)
        | Arith a          -> Arith a
        | Pred (pred, as') -> Pred (pred, as')
        | Abs ({ty=TySigma ty;_} as x, psi) ->
            Abs(x, term (IdMap.add env x ty) psi)
        | Abs ({ty=TyInt;_} as x, psi) -> Abs(x, term env psi)
        | Forall ({ty=TySigma ty;_} as x, psi) ->
            Forall (x, term (IdMap.add env x ty) psi)
        | Forall ({ty=TyInt;_} as x, psi) -> Forall (x, term env psi)
        | Exists ({ty=TySigma ty;_} as x, psi) ->
            Exists (x, term (IdMap.add env x ty) psi)
        | Exists ({ty=TyInt;_} as x, psi) -> Exists (x, term env psi)
    in
    let rule : simple_ty IdMap.t
            -> simple_ty Hflz.Sugar.hes_rule
            -> simple_ty Hflz.Sugar.hes_rule =
      fun env rule ->
        { rule with body = term env rule.body }
    in
    let env =
      IdMap.of_list @@
        List.map (snd hes) ~f:begin fun rule ->
          rule.var, rule.var.ty
        end
    in
    let (entry, rules) = hes in
    term env entry,
    List.map rules ~f:(rule env)

let to_typed (raw_hes, env) =
  let typed_hes =
    raw_hes
    |> Typing.to_typed
    |> (fun (e, rules) -> e, List.map ~f:rename_simple_ty_rule rules)
  in
  let () = (* check env *)
    let unknown_nt =
      List.find env ~f:begin fun (f,_) ->
        List.for_all (snd typed_hes) ~f:(fun r -> r.var.name <> f)
      end
    in
    match unknown_nt with
    | None -> ()
    | Some (f,_) -> Fn.fatal @@ "ENV: There is no NT named " ^ f
  in
  let gamma = IdMap.of_list @@
    List.map (snd typed_hes) ~f:begin fun rule ->
      let v = rule.var in
      let aty =
        match List.Assoc.find ~equal:String.equal env v.name with
        | Some aty -> rename_abstraction_ty v.ty aty
        | None -> map_ty (fun () -> []) v.ty
      in rule.var, aty
    end
  in
  rename_ty_body typed_hes, gamma

