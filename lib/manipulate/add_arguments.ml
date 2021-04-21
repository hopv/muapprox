open Hflmc2_syntax
open Hflz

let id_gen ?name ty =
  let id = Id.gen ?name ty in
  { id with name = id.name ^ string_of_int id.id }
  
(* let add_parameters_expr (phi : 'ty Hflz.t) =
  let rec go (phi : 'ty Hflz.t) =
    match phi with
    | Abs (x, p) -> begin
      match x.ty with
      | TyInt -> Abs (x, go p)
      | TySigma _ ->
        let id = id_gen ~name:x.name Type.TyInt in
        Abs (id, Abs (x, go p))
    end
    | Bool _ | Var _ | Arith _ | Pred _ -> phi
    | Or (p1, p2) -> Or (go p1, go p2)
    | And (p1, p2) -> And (go p1, p2)
    | Forall (x, p) -> Forall (x, go p)
    | Exists (x, p) -> Exists (x, go p)
    | App (p1, p2) -> App (go p1, go p2)
  in
  go phi

let add_parameters (hes : 'ty hes) =
  let entry, rules = hes in
  add_parameters_expr entry,
  List.map
    (fun {var; fix; body} -> {var; fix; body = add_parameters_expr body})
    rules
     *)
(* TODO: optimize formula? *)
let make_guessed_terms (coe1 : int) (coe2 : int) vars =
  let mk_affine term coe1 coe2 = Arith.Op (Arith.Add, [Arith.Op (Mult, [Int coe1; term]); Int coe2]) in
  match vars |>
    List.map (fun var -> mk_affine (Var var) coe1 coe2 :: [mk_affine (Var var) (-coe1) coe2]) |>
    List.flatten with
  | [] -> [Arith.Int coe2]
  | vars -> vars

let formula_fold func terms = match terms with
    | [] -> failwith "[formula_fold] Number of elements should not be zero."
    | term::terms -> begin
      List.fold_left func term terms
    end

let make_approx_formula fa_var_f bounds = 
  bounds
  |> List.map (fun bound -> Pred (Lt, [Var fa_var_f; bound]))
  |> formula_fold (fun acc f -> Or (acc, f))

let add_arguments_expr (phi : 'ty Hflz.t) (coe1: int) (coe2: int) =
  (* env contains only integer variables *)
  let rec go_expr (env : 'a list) (phi : 'ty Hflz.t) =
    match phi with
    | App _ -> begin
      (* Appのみを辿って、直近の祖先でAppでない部分式の直下に追加整数引数を追加する *)
      (* NOTE: 式の型がbool出ない場合はeta変換が必要 *)
      let ty = Hflz_util.get_hflz_type phi in
      assert (ty = Type.TyBool ());
      (* (* スコープ内の整数引数の集合は同一なので、同一の整数変数を使う *)
      let id = id_gen Type.TyInt in
      let id_getter () = id in *)
      (* 高階引数ごとに別の整数変数を使う *)
      let generated_ids = ref [] in
      let id_getter () =
        let id = id_gen ~name:"s" `Int in
        generated_ids := id :: !generated_ids;
        id
        in
      let phi = go_app env id_getter phi in
      match !generated_ids with
      | [] -> phi
      | generated_ids -> begin
        let bound =
          generated_ids |>
          List.map
            (fun id ->
              let bound_terms = make_guessed_terms coe1 coe2 env in
              let bound = make_approx_formula id bound_terms in
              bound
            ) |>
          formula_fold (fun a b -> Or (a, b)) in
        let body =
          Or (bound, phi) in
        let rec g xs b = match xs with
          | [] -> b
          | x::xs -> Forall ({x with ty=Type.TyInt}, g xs b) in
        g generated_ids body
      end
    end
    | Bool _ | Var _ | Arith _ | Pred _ -> phi
    | Or  (p1, p2) -> Or  (go_expr env p1, go_expr env p2)
    | And (p1, p2) -> And (go_expr env p1, go_expr env p2)
    | Abs (x, p) -> begin
      (* match x.ty with
      | TyInt -> Abs (x, go p)
      | TySigma _ ->
        let id = id_gen ~name:x.name Type.TyInt in
        Abs (id, Abs (x, go p)) *)
      match x.ty with
      | TyInt ->
        let env = Env.update [{x with ty=`Int}] env in
        Abs (x, go_expr env p)
      | TySigma _ ->
        let id = id_gen ~name:x.name Type.TyInt in
        let env = Env.update [{id with ty=`Int}] env in
        Abs (id, Abs (x, go_expr env p))
    end
    | Forall (x, p) ->
      let env = Env.update [{x with ty=`Int}] env in
      Forall (x, go_expr env p)
    | Exists (x, p) ->
      let env = Env.update [{x with ty=`Int}] env in
      Exists (x, go_expr env p)
  and go_app env (id_getter : unit -> [`Int] Id.t) (phi : 'ty Hflz.t) =
    match phi with
    | App (p1, p2) -> begin
      match p2 with
      | Arith _ -> App (go_app env id_getter p1, p2)
      | _ ->
        let id = id_getter () in
        App (App (go_app env id_getter p1, Arith (Var id)), go_app env id_getter p2)
    end
    | _ -> go_expr env phi
  in
  go_expr Env.empty phi

let decomp (entry, rules) = Hflz.mk_entry_rule entry :: rules

let rec convert_ty ty =
  match ty with
  | Type.TyArrow (argid, ty) -> begin
    match argid.ty with
    | TyInt -> Type.TyArrow ({argid with ty = argid.ty}, convert_ty ty)
    | TySigma _ ->
      let id = Id.gen Type.TyInt in
      Type.TyArrow (
        id,
        Type.TyArrow ({argid with ty = convert_argty argid.ty}, convert_ty ty)
      )
  end
  | Type.TyBool () -> Type.TyBool ()

and convert_argty argty =
  match argty with
  | Type.TyInt -> Type.TyInt
  | Type.TySigma ty -> Type.TySigma (convert_ty ty)

let adjust_type_expr env phi =
  (* env contains only non-integer variables *)
  let rec go env phi = match phi with
    | Var x -> begin
      let x = Env.lookup x env in
      Var x
    end
    | Bool _ | Arith _ | Pred _ -> phi
    | Or (p1, p2) -> Or (go env p1, go env p2)
    | And (p1, p2) -> And (go env p1, go env p2)
    | Abs (x, p) -> begin
      match x.ty with
      | TySigma ty ->
        let x = { x with ty = convert_ty ty } in
        Abs ({x with ty = TySigma x.ty}, go (Env.update [x, x] env) p)
      | TyInt ->
        Abs (x, go env p)
    end
    | Forall (x, p) ->
      Forall (x, go env p)
    | Exists (x, p) ->
      Exists (x, go env p)
    | App (p1, p2) -> App (go env p1, go env p2)    
  in
  go env phi

let adjust_type (hes : 'ty hes) =
  let entry, rules = hes in
  let env =
    List.map
      (fun {var; _} ->
        let var = { var with ty = convert_ty var.ty } in
        var, var
      )
      rules in
  adjust_type_expr env entry,
  List.map
    (fun {var; fix; body} ->
      { var = Env.lookup var env;
        fix;
        body = adjust_type_expr env body }
    )
    rules
  
let add_arguments (hes : 'ty hes) (coe1: int) (coe2: int) =
  (* let hes = add_parameters hes in *)
  let entry, rules = hes in
  let hes =
    add_arguments_expr entry coe1 coe2,
    List.map
      (fun {var; fix; body} ->
        {var; fix; body = add_arguments_expr body coe1 coe2}
      )
      rules in
  print_endline @@ Print_syntax.show_hes (decomp hes);
  let hes = adjust_type hes in
  Hflz_typecheck.type_check hes;
  hes

(*  *)
let id_n n t = { Id.name = "x_" ^ string_of_int n; id = n; ty = t }

let to_ty_in_id id =
  match id.Id.ty with
  | Type.TySigma ty -> Hflz.Var {id with ty}
  | Type.TyInt -> Arith (Arith.Var {id with ty = `Int})

let to_int_in_id id =
  match id.Id.ty with
  | Type.TyInt -> Arith.Var {id with ty = `Int}
  | _ -> assert false
  
let%expect_test "add_arguments" =
  let open Type in
  (*   ∀x_11. (λx_22:int.λx_33:(int -> bool).x_33 x_22) 0 (λx_44:int.x_44 = x_11)   *)
  let v_n = id_n 1 TyInt in
  let v_x = id_n 2 TyInt in
  let v_f = id_n 3 (TySigma (TyArrow (id_n 0 TyInt, TyBool ()))) in
  let v_y = id_n 4 TyInt in
  let phi =
    Forall (v_n, App (App (Abs (v_x, Abs (v_f, App (to_ty_in_id v_f, to_ty_in_id v_x))), Arith (Int 0)), Abs (v_y, Pred (Eq, [to_int_in_id v_y; to_int_in_id v_n])))) in
  print_endline @@ Print_syntax.show_hflz phi;
  [%expect {|
    ∀x_11.
     (λx_22:int.λx_33:(int -> bool).x_33 x_22) 0 (λx_44:int.x_44 = x_11) |}];
  let ty' = Hflz_util.get_hflz_type phi in
  assert (ty' = Type.TyBool ());
  let phi = add_arguments_expr phi 10 20 in
  (* let phi = add_parameters_expr phi in *)
  ignore [%expect.output];
  print_endline @@ Print_syntax.show_hflz phi;
  [%expect {|
    ∀x_11.
     ∀x20.
      x20 < 10 * x_11 + 20 || x20 < (-10) * x_11 + 20
      || (λx_22:int.λx21:int.λx_33:(int -> bool).x_33 x_22) 0 x20
          (λx_44:int.x_44 = x_11) |}];
  let ty' = Hflz_util.get_hflz_type phi in
  assert (ty' = Type.TyBool ());
