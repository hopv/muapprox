open CSyntax
open Util.LexingHelper

exception Err of string

let parse_from_lexbuf lexbuf =
  try
    let graph = BaParsing.toplevel BaLexer.main lexbuf in
    let strid_to_intid_buf = Hashtbl.create 123456 in
    let initial_state = ref (-1) in
    let final_states = ref [] in
    let states = ref 0 in
    let register strid =
      let intid = !states in
      states := !states + 1;
      if Core.String.is_prefix strid ~prefix:"accept_" then
        final_states := intid :: !final_states;
      if Core.String.is_suffix strid ~suffix:"_init" then (
        if !initial_state >= 0 then
          raise (Err "initial state is anbiguous");
        initial_state := intid
      );
      Hashtbl.add strid_to_intid_buf strid intid
    in
    let strid_to_intid strid =
      if not (Hashtbl.mem strid_to_intid_buf strid) then
        register strid;
      Hashtbl.find strid_to_intid_buf strid
    in
    let transition =
      List.map
        (fun (from_strid, to_strid, cond) ->
           strid_to_intid from_strid, strid_to_intid to_strid, cond
        )
        graph
    in
    if !initial_state < 0 then
      raise (Err "can't find an initial state");
    Ok (BuchiAutomaton.init_ba ~states:!states ~initial_state:!initial_state ~final_states:!final_states ~transition)
  with
  | CSyntax.SemanticError error ->
    Error (Printf.sprintf "semantic error: %s" error)
  | CSyntax.SyntaxError error ->
    Error (Printf.sprintf "%s: syntax error: %s" (get_position_string lexbuf) error)
  | BaParsing.Error ->
    Error (Printf.sprintf "%s: syntax error" (get_position_string lexbuf))
  | BaLexer.ErrorFormatted error ->
    Error error
  | BaLexer.SyntaxError error ->
    Error (Printf.sprintf "%s: syntax error: %s" (get_position_string lexbuf) error)
  | Err error ->
    Error error

let from_file file =
  let ic = open_in file in
  Lexing.from_channel ic |> parse_from_lexbuf

let parse str =
  Lexing.from_string str |> parse_from_lexbuf
