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


open Syntax
open Core
open DebugMessage
open MonadUtil
open Result.Let_syntax
open RunnerUtil
open PatternChecker

open TypeChecker.ScillaTypechecker

(* Check that the module parses *)
let check_parsing ctr = 
    let parse_module =
      FrontEndParser.parse_file ScillaParser.cmodule ctr in
    match parse_module with
    | None -> fail (sprintf "%s\n" "Failed to parse input file.")
    | Some cmod -> 
        plog @@ sprintf
          "\n[Parsing]:\nContract module [%s] is successfully parsed.\n" ctr;
        pure cmod

(* Type check the contract with external libraries *)
let check_typing cmod elibs =
  let open TypeChecker.ScillaTypechecker in
  let res = type_module cmod elibs in
  match res with
  | Error msg -> pout @@ sprintf "\n%s\n\n" msg; res
  | Ok typed_module -> pure @@ typed_module

module PM_SR = TypeChecker.ScillaTypechecker.STR
module PM_ER = TypeChecker.ScillaTypechecker.ETR
module PM_Checker = ScillaPatternchecker (PM_SR) (PM_ER)

let check_patterns e = PM_Checker.pm_check_module e

let () =
  if (Array.length Sys.argv) < 2
  then
    (perr (sprintf "Usage: %s foo.scilla\n" Sys.argv.(0))
    )
  else (
    let open GlobalConfig in
    set_debug_level Debug_None;
    (* Testsuite runs this executable with cwd=tests and ends
       up complaining about missing _build directory for logger.
       So disable the logger. *)
    let r = (
      let%bind cmod = check_parsing Sys.argv.(1) in
      (* This is an auxiliary executable, it's second argument must
       * have a list of stdlib dirs, so note that down. *)
      add_cmd_stdlib();
      (* Get list of stdlib dirs. *)
      let lib_dirs = StdlibTracker.get_stdlib_dirs() in
      if lib_dirs = [] then stdlib_not_found_err ();
      (* Import whatever libs we want. *)
      let elibs = import_libs cmod.elibs in
      let%bind (typed_cmod, tenv) = check_typing cmod elibs in
      let%bind pm_checked_cmod = check_patterns typed_cmod in
      pure @@ (cmod, tenv)
    ) in
    match r with
    | Error _ -> ()
    | Ok (cmod, _) ->
      pout (sprintf "%s\n" (JSON.ContractInfo.get_string cmod.contr));
  )
