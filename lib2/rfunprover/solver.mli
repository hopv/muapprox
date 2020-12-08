open Fptprover
open Ast.Logic
open Hes

val solve_formula: Formula.t -> Status.t
(* solve hes need_example: return (_, None) if need_example is false but it runs fast *)
val solve: bool -> bool -> HesLogic.hes -> Status.t * int list option
val solve_onlymu_onlyexists: bool -> int -> bool -> HesLogic.hes -> Status.t * int list option
val solve_onlynu_onlyforall: bool -> int -> bool -> HesLogic.hes ->  Status.t * int list option
val solve_nobounds: bool -> int -> bool -> HesLogic.hes ->  Status.t * int list option