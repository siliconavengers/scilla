(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

open Core
open Result.Let_syntax
open MonadUtil
open Syntax
open TypeUtil
open PrimTypes

(* The storage cost of a literal, based on it's size. *)
let rec literal_cost lit =
  let%bind lt = literal_type lit in
  if not (is_storable_type lt) then
    fail @@ sprintf "Cannot determine cost of non-storable literal %s" (pp_literal lit)
  else match lit with
  (* StringLits have fixed cost till a certain
     length and increased cost after that. *)
  | StringLit s ->
    let l = String.length s in
    pure @@ if l <= 20 then 20 else l
  | BNum _ -> pure @@ 32 (* 256 bits *)
  (* (bit-width, value) *)
  | IntLit (w, _) | UintLit (w, _) -> pure @@ w/8
  (* (bit-width, value) *)
  | ByStr (w, _) -> pure @@ w
  (* Message: an associative array *)    
  | Msg m ->
    foldM ~f:(fun acc (s, lit') ->
      let%bind cs = literal_cost (StringLit(s)) in
      let%bind clit' = literal_cost lit' in
      pure (acc + cs + clit')) ~init:0 m
  (* A dynamic map of literals *)    
  | Map (_, m) ->
    foldM ~f:(fun acc (lit1, lit2) ->
      let%bind clit1 = literal_cost lit1 in
      let%bind clit2 = literal_cost lit2 in
      pure (acc + clit1 + clit2)) ~init:0 m
  (* A constructor in HNF *)      
  | ADTValue (_, _, ll) ->
    foldM ~f:(fun acc lit' ->
      let%bind clit' = literal_cost lit' in
      pure (acc + clit')) ~init:0 ll

(* A signature for functions that determine dynamic cost of built-in ops. *)
(* op -> arguments -> base cost -> total cost *)
type coster = string -> literal list -> int -> (int, string) result
(* op, arg types, coster, base cost. *)
type builtin_record = string * (typ list) * coster * int
(* a static coster that only looks at base cost. *)
let base_coster (_ : string) (_ : literal list) base = pure base

let string_coster op args base =
  match op, args with
  | "eq", [StringLit s1; StringLit s2]
  | "concat", [StringLit s1; StringLit s2] ->
    pure @@ (String.length s1 + String.length s2) * base
  | "substr", [StringLit s; UintLit(_, _); UintLit(_, _)] ->
    pure @@ (String.length s) * base
  | _ -> fail @@ "Gas cost error for string built-in"

let hash_coster op args base =
  let open BatOption in
  let%bind types = mapM args ~f:literal_type in
  match op, types, args with
  | "eq", [a1;a2], _
    when is_bystr_type a1 && is_bystr_type a2 &&
         get (bystr_width a1) = get (bystr_width a2)
       -> pure @@ get (bystr_width a1) * base
  | "sha256hash", _, [a] ->
    pure @@ (String.length (pp_literal a) + 20) * base
  | _ -> fail @@ "Gas cost error for hash built-in"

let map_coster _ args base =
  match args with
  | Map (_, m)::_ ->
    (* TODO: Should these be linear? *)
    pure @@ (List.length m) * base
  | _ -> fail @@ "Gas cost error for map built-in"

let to_nat_coster _ args base =
  match args with
  (* TODO: Is this good? *)
  | [UintLit(_, i)] -> pure @@ Int.of_string i * base
  | _ -> fail @@ "Gas cost error for to_nat built-in"

let int_coster _ args base =
  match args with
  | [IntLit(w, _)] | [UintLit(w, _)]
  | [IntLit(w, _); IntLit(_, _)]
  | [UintLit(w, _); UintLit(_, _)] ->
    if w = 32 || w = 64 then pure base
    else if w = 128 then pure (base * 2)
    else if w = 256 then pure (base * 4)
    else fail @@ "Gas cost error for integer built-in"
  | _ -> fail @@ "Gas cost error for integer built-in"

let tvar s = TypeVar(s)

(* built-in op costs are propotional to size of data they operate on. *)
let builtin_records : builtin_record list = [
  (* Strings *)
  ("eq", [string_typ;string_typ], string_coster, 1);
  ("concat", [string_typ;string_typ], string_coster, 1);
  ("substr", [string_typ; tvar "'A"; tvar "'A"], string_coster, 1);
  
  (* Block numbers *)
  ("eq", [bnum_typ;bnum_typ], base_coster, 4);
  ("blt", [bnum_typ;bnum_typ], base_coster, 4);
  ("badd", [bnum_typ;tvar "'A"], base_coster, 4);

  (* Hashes *)
  ("eq", [tvar "'A"; tvar "'A"], hash_coster, 1);
  (* We currently only support `dist` for ByStr32. *)
  ("dist", [bystr_typ hash_length; bystr_typ hash_length], base_coster, 32);
  ("sha256hash", [tvar "'A"], hash_coster, 1);

  (* Maps *)
  ("contains", [tvar "'A"; tvar "'A"], map_coster, 1);
  ("put", [tvar "'A"; tvar "'A"; tvar "'A"], map_coster, 1);
  ("get", [tvar "'A"; tvar "'A"], map_coster, 1);
  ("remove", [tvar "'A"; tvar "'A"], map_coster, 1);
  ("to_list", [tvar "'A"], map_coster, 1); 
  
  (* Integers *)
  ("eq", [tvar "'A"; tvar "'A"], int_coster, 2);
  ("lt", [tvar "'A"; tvar "'A"], int_coster, 2);
  ("add", [tvar "'A"; tvar "'A"], int_coster, 2);
  ("sub", [tvar "'A"; tvar "'A"], int_coster, 2);
  ("mul", [tvar "'A"; tvar "'A"], int_coster, 2);
  ("to_int32", [tvar "'A"], int_coster, 2);
  ("to_int64", [tvar "'A"], int_coster, 2);
  ("to_int128", [tvar "'A"], int_coster, 2);
  ("to_int256", [tvar "'A"], int_coster, 2);
  ("to_uint32", [tvar "'A"], int_coster, 2);
  ("to_uint64", [tvar "'A"], int_coster, 2);
  ("to_uint128", [tvar "'A"], int_coster, 2);
  ("to_uint256", [tvar "'A"], int_coster, 2);
  ("to_nat", [tvar "'A"], to_nat_coster, 1);
]

let builtin_cost op_i arg_literals =
  let op = get_id op_i in
  let%bind arg_types = mapM arg_literals ~f:literal_type in
  let matcher (name, types, fcoster, base) = 
    (* The names and type list lengths must match and *)
    if name = op && List.length types = List.length arg_types
      && (List.for_all2_exn ~f:(fun t1 t2 ->
        (* the types should match *)
        TypeUtil.type_equiv t1 t2 ||
        (* or the built-in record is generic *)
        (match t2 with | TypeVar _ -> true | _ -> false)) 
        arg_types types)
    then fcoster op arg_literals base (* this can fail too *)
    else fail @@ "Name or arity doesn't match"
  in
  let msg = sprintf "Unable to determine gas cost for \"%s %s\""
        op (pp_literal_list arg_literals) in
  let %bind (_, cost) = tryM builtin_records ~f:matcher ~msg:msg in
    pure cost
