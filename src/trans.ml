(**************************************************************************)
(*                        Lem                                             *)
(*                                                                        *)
(*          Dominic Mulligan, University of Cambridge                     *)
(*          Francesco Zappa Nardelli, INRIA Paris-Rocquencourt            *)
(*          Gabriel Kerneis, University of Cambridge                      *)
(*          Kathy Gray, University of Cambridge                           *)
(*          Peter Boehm, University of Cambridge (while working on Lem)   *)
(*          Peter Sewell, University of Cambridge                         *)
(*          Scott Owens, University of Kent                               *)
(*          Thomas Tuerk, University of Cambridge                         *)
(*                                                                        *)
(*  The Lem sources are copyright 2010-2013                               *)
(*  by the UK authors above and Institut National de Recherche en         *)
(*  Informatique et en Automatique (INRIA).                               *)
(*                                                                        *)
(*  All files except ocaml-lib/pmap.{ml,mli} and ocaml-libpset.{ml,mli}   *)
(*  are distributed under the license below.  The former are distributed  *)
(*  under the LGPLv2, as in the LICENSE file.                             *)
(*                                                                        *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*  notice, this list of conditions and the following disclaimer.         *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*  notice, this list of conditions and the following disclaimer in the   *)
(*  documentation and/or other materials provided with the distribution.  *)
(*  3. The names of the authors may not be used to endorse or promote     *)
(*  products derived from this software without specific prior written    *)
(*  permission.                                                           *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS    *)
(*  OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED     *)
(*  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE    *)
(*  ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY       *)
(*  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL    *)
(*  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE     *)
(*  GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS         *)
(*  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER  *)
(*  IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR       *)
(*  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN   *)
(*  IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.                         *)
(**************************************************************************)

open Typed_ast
open Typed_ast_syntax
open Pattern_syntax
open Util
exception Trans_error of Ast.l * string

let r = Ulib.Text.of_latin1

type 'a macro = 'a -> 'a option
type pat_macro = Macro_expander.pat_position -> pat macro

module Macros(I : Types.Global_defs)(E : sig val env : env end) = struct

module C = Exps_in_context(struct let check = Some(I.d) let avoid = None end)
module T = Types.Constraint(I)

let d = I.d
let inst = I.i
open E

(* Macros *)

let remove_singleton_record_updates e =
    match C.exp_to_term e with
      | Recup(s1, exp, s2, fields, s3) ->
        begin
            match Seplist.to_list fields with
              | [x] ->
                  let (field_descr_id, s4, exp', loc) = x in
                  let field_descr = field_descr_id.descr in
                  let field_names = field_descr.field_names in
                    if List.length field_names = 1 then
                      Some (C.mk_record_coq loc s1 fields s3 (Some (exp_to_typ e)))
                    else
                      None
              | _   -> None
        end
      | _ -> None
;;

let sort_record_fields e =
  let l_unk = Ast.Trans("sort_record_fields", Some (exp_to_locn e)) in
    match C.exp_to_term e with
      | Record(s1,fields,s2) -> if Seplist.length fields < 2 then None else
        begin
          let field_names = begin
                let (field_descr_id, s4, exp', loc) = Seplist.hd fields in
                let field_descr = field_descr_id.descr in
                field_descr.field_names
          end in
          let (hd_sep_opt, fieldsL) = Seplist.to_pair_list None fields in
          let find_field_fun n (a,s) = begin
                let (field_descr_id, s4, exp', loc) = a in
                let n' = Path.get_name (field_descr_id.descr.field_binding) in		
					(n = n')
              end in
          let rec find_field n b = function
                | [] -> raise Not_found
                | x::xs ->
                      (if find_field_fun n x then (x, b, xs) else
      		      let (y, b', ys) = find_field n true xs in (y, b', x::ys)) in
          let (changed, _, resultL) = try List.fold_left (fun (changed, fieldL, resultL) n -> 
               let (y, changed', ys) = find_field n changed fieldL in (changed', ys, y::resultL)) 
               (false, fieldsL, []) field_names
            with Not_found -> (false, fieldsL, fieldsL) 
          in if (not changed) then None else begin
            let fields' = Seplist.from_pair_list hd_sep_opt (List.rev resultL) None in
            let res = C.mk_record l_unk s1 fields' s2 (Some (exp_to_typ e)) in
            let _ = Reporting.report_warning (Reporting.Warn_record_resorted (exp_to_locn e, e)) in
            Some (res) end
        end 
      | _ -> None
;;

(* Turn function | pat1 -> exp1 ... | patn -> expn end into
 * fun x -> match x with | pat1 -> exp1 ... | patn -> expn end *)
let remove_function e = Patterns.remove_function d (fun e -> e) e

(* Remove patterns from (fun ps -> ...), except for variable and 
 * (optionally) tuple patterns *)
(* Patterns.remove_fun is very similar, but introduces case-expressions *)
let remove_fun_pats keep_tup e = 
  let l_unk = Ast.Trans("remove_fun_pats", Some (exp_to_locn e)) in
  let rec keep p = if keep_tup then Pattern_syntax.is_var_tup_pat p else Pattern_syntax.is_ext_var_pat p in
  let rec group acc = function
    | [] -> 
        if acc = [] then
          []
        else
          [(true,List.rev acc)]
    | p::ps -> 
        if keep p then
          group (p::acc) ps
        else if acc = [] then 
          (false,[p])::group [] ps 
        else 
          (true,List.rev acc)::(false,[p])::group [] ps
  in
    match C.exp_to_term e with
      | Fun(s1,ps,s2,e') ->
          let pss = group [] ps in
            begin
              match pss with
                | [(true,_)] -> None
                | _ ->
                    let e =
                      List.fold_right
                        (fun ps res_e ->
                           match ps with
                             | (true,ps) ->
                                 C.mk_fun l_unk space ps space res_e None
                             | (false,[p]) ->
                                 C.mk_function l_unk 
                                   space 
                                   (Seplist.from_list [((p,space,res_e,l_unk),no_lskips)])
                                   no_lskips
                                   None
                             | _ -> assert false)
                        pss
                        e'
                    in
                      match (C.exp_to_term e) with
                        | Fun(_,ps,_,e') ->
                            Some(C.mk_fun (exp_to_locn e) s1 ps s2 e'
                                   (Some(exp_to_typ e)))
                        | Function(_,x,_) ->
                            Some(C.mk_function (exp_to_locn e) 
                                   (Ast.combine_lex_skips s1 s2) x no_lskips
                                   (Some(exp_to_typ e)))
                        | _ -> assert false
            end
      | _ -> None
;;


let app_list e = 
  let rec help e = match (C.exp_to_term e) with
    | App(e1,e2) ->
        let (f,infix,args) = help e1 in
          (f,infix,(e2,exp_to_locn e)::args)
    | Infix(e1,e2,e3) ->
       (e2,true,[(e3,exp_to_locn e);(e1,exp_to_locn e)]) 
    | _ -> (e,false,[])
  in
  let (f,infix,args) = help e in
    (f, infix, List.rev args)

let in_target p t =
  let tn = target_to_mname t in
    Path.check_prefix tn p

let insert2 subst (p1,e1) (p2,e2) =
  Nfmap.insert (Nfmap.insert subst (p1,e1)) (p2,e2)

let rec build_subst (params : (Name.t,unit) annot list) (args : (exp * Ast.l) list) 
      : exp_subst Nfmap.t * (Name.t,unit) annot list * (exp * Ast.l) list =
  match (params, args) with
    | ([],args) -> (Nfmap.empty, [], args)
    | (params, []) -> (Nfmap.empty, params, [])
    | (p::params, (a,_)::args) ->
        let (subst, x, y) = build_subst params args in
          (Nfmap.insert subst (p.term, Sub(a)), x, y)

(* Inline sub [target] bindings *)
let do_substitutions target e =
  let l_unk = Ast.Trans("do_substitutions", Some (exp_to_locn e)) in
  let (f,infix,args) = app_list e in
    match C.exp_to_term f with
      | Constant(c) ->
          begin
            match Targetmap.apply c.descr.substitutions target with
              | None -> None
              | Some((params,body)) ->
                  let tsubst = 
                    Types.TNfmap.from_list2 c.descr.const_tparams c.instantiation
                  in
                  let (vsubst, leftover_params, leftover_args) = 
                    build_subst params args
                  in
                  let b = 
                    C.exp_subst (tsubst,vsubst) 
                      (fst (alter_init_lskips (fun _ -> (ident_get_first_lskip c, None)) body))
                  in
                    if params = [] && infix then
                      begin
                        match leftover_args with
                          | (a1,l)::(a2,_)::args ->
                              Some(List.fold_left 
                                     (fun e (e',l) -> C.mk_app l e e' None)
                                     (C.mk_infix l a1 b a2 None)
                                     args)
                          | _ -> assert false
                      end
                    else if leftover_params = [] then
                      Some(List.fold_left 
                             (fun e (e',l) -> C.mk_app l e e' None)
                             b
                             leftover_args)
                    else
                      Some(C.mk_fun l_unk
                             None (List.map 
                                     (fun n -> 
                                        C.mk_pvar n.locn (Name.add_lskip n.term) n.typ) 
                                     leftover_params) 
                             None b
                             None)
          end
      | _ -> None

(* Change constructors into tupled constructors *) 
let rec tup_ctor build_result args e = 
  let l_unk = Ast.Trans("tup_ctor", None) in
  match C.exp_to_term e with
  | Constructor(c) ->
      let l = List.length c.descr.constr_args in
        if Seplist.length args = l then
          Some(C.mk_tup_ctor (exp_to_locn e) c None args None None)
        else
          let names = Name.fresh_list l (r"x") (fun n -> true) in
          let tsubst = Types.TNfmap.from_list2 c.descr.constr_tparams c.instantiation in
          let types = List.map (Types.type_subst tsubst) c.descr.constr_args in
          let pats = 
            List.map2 
              (fun n t -> C.mk_pvar l_unk (Name.add_lskip n) t)
              names
              types
          in
          let refs =
            List.fold_right2 
              (fun n t l -> 
                 Seplist.cons_entry
                   (C.mk_var l_unk (Name.add_lskip n) t)
                   (Seplist.cons_sep_alt None l))
              names
              types
              Seplist.empty
          in
          let body = C.mk_tup_ctor l_unk c None refs None None in
          let f = C.mk_fun l_unk None pats None body None in
            Some(build_result f)
  | App(e1,e2) ->
      tup_ctor 
        (fun e' -> 
           build_result 
             (C.mk_app (exp_to_locn e) e' e2 (Some (exp_to_typ e)))) 
        (Seplist.cons_entry e2 (Seplist.cons_sep_alt None args)) e1
  (* TODO: Is this right *)
  | Infix(e1,e2,e3) ->
      tup_ctor 
        (fun e' ->
           build_result 
             (C.mk_infix (exp_to_locn e) e1 e' e3 (Some (exp_to_typ e))))
        (Seplist.cons_entry e1 
           (Seplist.cons_sep_alt None 
              (Seplist.cons_entry e3 
                 (Seplist.cons_sep_alt None args)))) e2
  | _ -> None


let names_mk_ident l i loc =
  Ident.mk_ident (List.map (fun r -> (Name.add_lskip r, None)) l)
    (Name.add_lskip i)
    loc

let mk_ident l i loc =
  names_mk_ident (List.map Name.from_rope l) (Name.from_rope i) loc

(* TODO: Get the Suc constructor properly when the library is working with
 * datatypes *)
let peanoize_num_pats_aux suc _ p =
  let l_unk = Ast.Trans("peanoize_num_pats", Some p.locn) in

  let pean_pat s i p = begin   
    let rec f i = if i = 0 then p else C.mk_pconstr l_unk suc [f (i - 1)] None
    in Pattern_syntax.mk_opt_paren_pat (pat_append_lskips s (f i))
  end in
  let string_to_comment s = Some([Ast.Com(Ast.Comment([Ast.Chars(Ulib.Text.of_latin1 s)]))]) in
  match p.term with
    | P_lit({ term = L_num(s,i)}) when i > 0 ->
        let pat0 = C.mk_plit l_unk (C.mk_lnum l_unk None 0 None) None in
        let com_ws = (Ast.combine_lex_skips s (string_to_comment (string_of_int i))) in
        Some(pean_pat com_ws i pat0)
    | P_num_add ((n,l), s1, s2, 0) -> 
        let pat0 = C.mk_pvar l_unk n { Types.t = Types.Tapp([], Path.numpath) } in
        let com_ws = Ast.combine_lex_skips s1 s2 in
        Some(pat_append_lskips com_ws pat0)
    | P_num_add ((n,l), s1, s2, i) -> 
        let pat0 = C.mk_pvar l_unk n  { Types.t = Types.Tapp([], Path.numpath) } in
        let com_ws = Ast.combine_lex_skips s1 (Ast.combine_lex_skips s2 (string_to_comment ("_ + " ^ string_of_int i))) in
        Some(pean_pat com_ws i pat0)
    | _ -> None


let isa_suc = { id_path = Id_none None;
        id_locn = Ast.Trans ("trans.ml - isa_suc", None);
        descr = 
           { constr_binding = Path.mk_path [] (Name.from_rope (r"Suc"));
             constr_tparams = [];
             constr_args = [{ Types.t = Types.Tapp([], Path.numpath) }];
             constr_tconstr = Path.numpath;
             constr_names = 
               NameSet.add (Name.from_rope (r"Zero"))
               (NameSet.singleton (Name.from_rope (r"Suc")));
             constr_l = Ast.Trans ("trans.ml - isa_suc", None) };
           instantiation = [] }

let hol_suc = { id_path = Id_none None;
        id_locn = Ast.Trans ("trans.ml - hol_suc", None);
        descr = 
           { constr_binding = Path.mk_path [] (Name.from_rope (r"SUC"));
             constr_tparams = [];
             constr_args = [{ Types.t = Types.Tapp([], Path.numpath) }];
             constr_tconstr = Path.numpath;
             constr_names = 
               NameSet.add (Name.from_rope (r"Zero"))
               (NameSet.singleton (Name.from_rope (r"SUC")));
             constr_l = Ast.Trans ("trans.ml - hol_suc", None) };
           instantiation = [] }

let peanoize_num_pats_hol = peanoize_num_pats_aux hol_suc
let peanoize_num_pats_isa = peanoize_num_pats_aux isa_suc


let remove_unit_pats _ p =
  let l_unk = Ast.Trans("remove_unit_pats", Some p.locn) in
  match p.term with
    | P_lit({ term = L_unit(s1, s2)}) ->
        Some(C.mk_pwild l_unk s1 { Types.t = Types.Tapp([], Path.unitpath) } )
     | _ -> None

(* Turn comprehensions into nested folds, fails on unrestricted quantifications *)
let remove_comprehension for_lst e = 
  let l_unk n = Ast.Trans("remove_comprehension " ^ string_of_int n, Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Comp_binding(is_lst,s1,e1,s2,s3,qbs,s4,e2,s5) when is_lst = for_lst ->
      let (acc_name,param_name) = 
        let avoid = 
          List.fold_right
            (fun qb s ->
               match qb with 
                 | Qb_var(n) ->
                     raise (Trans_error(l_unk 0, "cannot generate code for unrestricted set comprehension"))
                 | Qb_restr(_,_,_,_,e,_) ->
                     Nfmap.union (C.exp_to_free e) s)
            qbs
            (Nfmap.union (C.exp_to_free e1) (C.exp_to_free e2))
        in
        match
          List.map (fun n -> Name.add_pre_lskip space (Name.add_lskip n))
            (Name.fresh_list 2 (r"x") (fun n -> not (Nfmap.in_dom n avoid)))
        with
          | [x;y] -> (x,y)
          | _ -> assert false
      in
      let acc_var = C.mk_var (l_unk 1) acc_name (exp_to_typ e) in
      let acc_pat = C.mk_pvar (l_unk 2) acc_name (exp_to_typ e) in
      let result_type = 
        { Types.t = 
            Types.Tapp([(exp_to_typ e1)], 
                       if is_lst then Path.listpath else Path.setpath) }
      in
      let list_fold_const t =
        append_lskips space
          (mk_const_exp env (l_unk 4) ["List" ] "fold_right" [t; result_type])
      in
      let set_fold_const t =
        append_lskips space
          (mk_const_exp env (l_unk 5) ["Set" ] "fold" [t; result_type])
      in
      let f = 
        if is_lst then
          let add_const =(mk_const_exp env (l_unk 8) [] "::" [exp_to_typ e1]) in
            C.mk_infix (l_unk 9) e1 add_const acc_var None
        else
          let add_const = mk_const_exp env (l_unk 11) ["Set"] "add" [exp_to_typ e1] in
          let f_app1 = 
            C.mk_app (l_unk 12) add_const e1 None
          in
            C.mk_app (l_unk 13) f_app1 acc_var None
      in
      let rec helper = function
        | [] -> C.mk_if (l_unk 14) space e2 space f space acc_var None
        | Qb_var(n)::_ -> assert false
        | Qb_restr(is_lst,s1',p,s2',e,s3')::qbs ->
            let param_var = C.mk_var (l_unk 15) param_name p.typ in
            let param_pat = C.mk_pvar (l_unk 16) param_name p.typ in
            let res = helper qbs in
            let s = lskips_only_comments [s1';s2';s3'] in
            let arg1 = 
              if Pattern_syntax.single_pat_exhaustive p then
                C.mk_fun (l_unk 17) s [p; acc_pat] space res None
              else
                C.mk_fun (l_unk 18) s [param_pat; acc_pat] space
                  (C.mk_case false (l_unk 19) space param_var space
                     (Seplist.from_list
                        [((p, space, res, l_unk 20), space);
                         ((C.mk_pwild (l_unk 21) space p.typ, space, acc_var, 
                           (l_unk 22)), space)])
                     None
                     None)
                  None
            in
            let app1 = 
              C.mk_app (l_unk 23) 
                (if is_lst then
                   list_fold_const p.typ 
                 else 
                   set_fold_const p.typ) 
                arg1 
                None
            in
            let app2 = C.mk_app (l_unk 24) app1 e None in
              C.mk_app (l_unk 25) app2 acc_var None
      in
      let t = 
        { Types.t = 
            Types.Tapp([exp_to_typ e1], if for_lst then Path.listpath else Path.setpath) }
      in
      let empexp = 
        (if for_lst then C.mk_list else C.mk_set) 
          (l_unk 26) space (Seplist.from_list []) None t in
      let letexp = 
        C.mk_let (exp_to_locn e) 
          s1 
          (C.mk_let_val (l_unk 27) acc_pat None space empexp) 
          (lskips_only_comments [s2;s3;s4;s5])
          (helper qbs)
          None
      in
        Some(letexp)
  | _ -> 
      None

let rec var_tup_pat_eq_exp p e =
  match dest_var_pat p with
    | Some n -> (match dest_var_exp e with None -> false | Some n' -> Name.compare n n' = 0)
    | None -> 
      begin
        match dest_tup_pat None p with 
          | None -> false
          | Some pL -> 
	    begin
              match dest_tup_exp None e with 
                | None -> false
                | Some eL -> 
		    (List.length pL = List.length eL) &&
		    List.for_all2 var_tup_pat_eq_exp pL eL
	    end
      end

(* Replaces set comprehension by introducing set_image and set_filter. Perhaps
   cross is added as well. *)
let remove_set_comprehension_image_filter allow_sigma e = 
  let l_unk = Ast.Trans("remove_set_comprehension_image_filter", Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Comp_binding(false,s1,e1,s2,s3,qbs,s4,e2,s5) ->
      let all_quant_vars = List.fold_left (fun acc -> function Qb_var _ -> acc | Qb_restr (_, _, p, _, _, _) -> 
                              NameSet.union (nfmap_domain p.rest.pvars) acc) NameSet.empty qbs in
      let ok = List.for_all (function Qb_var _ -> false | Qb_restr (_, _, p, _, e, _) -> is_var_tup_pat p) qbs in
      let need_sigma = List.exists (function Qb_var _ -> false | Qb_restr (_, _, p, _, e, _) -> not (
                   NameSet.is_empty (NameSet.inter all_quant_vars (nfmap_domain (C.exp_to_free e))))) qbs in
      if not (ok && ((not need_sigma) || allow_sigma)) then None else
      begin
        (* filter the quantifiers that need to be in a cross-product and ones that need to go to the expression *)
        let all_vars = NameSet.union (nfmap_domain (C.exp_to_free e1)) all_quant_vars in
        let (qbs_set_p, qbs_set_e, qbs_cond) = List.fold_right (fun qb (s_p, s_e, c) -> (
           match qb with 
              Qb_var _ -> raise (Reporting_basic.err_unreachable true l_unk "previosly checked")
            | Qb_restr (is_lst, sk1, p, sk2, e, sk3) -> begin
                let can_move = NameSet.is_empty (NameSet.inter all_vars (nfmap_domain p.rest.pvars)) in
                if can_move then (s_p, s_e, qb::c) else (
                  let e' = if is_lst then mk_from_list_exp env e else e in
                  (p::s_p, e'::s_e, c))
              end
             )) qbs ([], [], []) in

        let ok2 = (match qbs_set_p with [] -> false | _ -> true) in
        if not ok2 then None else
        begin
          (* new condition *)
          let e2' = if List.length qbs_cond = 0 then e2 else 
                      C.mk_quant l_unk (Ast.Q_exists None) qbs_cond space e2 (Some bool_ty) in
          (* cross or big_union set *)
          let p = mk_tup_pat qbs_set_p in
          let mk_exp env s (p, s') = if need_sigma then mk_set_sigma_exp env s' (mk_fun_exp [p] s) else mk_cross_exp env s' s in
          let s = List.fold_left (mk_exp env) (List.hd (List.rev qbs_set_e)) (List.tl (List.rev (List.combine qbs_set_p qbs_set_e))) in

          let res0 = mk_set_filter_exp env (mk_fun_exp [p] e2') s in
          let res1 = if (var_tup_pat_eq_exp p e1) then res0 else
                       mk_set_image_exp env (mk_fun_exp [p] e1) res0 in
          Some res1
        end
      end
  | _ -> 
      None

(* Replaces Setcomp with Comp_binding. *)
let remove_setcomp e = 
  let l_unk = Ast.Trans("remove_setcomp", Some (exp_to_locn e)) in
  match C.exp_to_term e with
   | Setcomp(s1,e1,s2,e2,s3,bindings) -> begin
       let e1_free_map = C.exp_to_free e1 in
       let qb_name (n : Name.t) = begin
         match Nfmap.apply e1_free_map n with
            | None -> None
            | Some ty -> Some (Qb_var{ term = Name.add_lskip n; locn = l_unk; typ = ty; rest = (); })
       end in 
       match Util.map_all qb_name (NameSet.elements bindings) with
         | None -> None
         | Some qbs -> Some (C.mk_comp_binding l_unk false s1 e1 s2 space qbs space e2 s3 (Some (exp_to_typ e)))
     end
  | _ -> None

(* Remove set notation *)
let special_type = 
  { Types.t = Types.Tapp([], Path.mk_path [Name.from_rope (r"MachineDefTypes")] (Name.from_rope (r"instruction_instance"))) }

let get_compare t = 
  let l_unk = Ast.Trans("get_compare", None) in
  (* TODO: Remove this hack *)
  if Types.compare (Types.head_norm d t) special_type = 0 then
    mk_const_exp env l_unk ["MachineDefTypes"] "compare_instruction_instance" []
  else
  C.mk_const l_unk
    { id_path = Id_none None;
      id_locn = l_unk;
      descr = get_const env ["Ocaml"] "compare";
      instantiation = [t] }
    None

let remove_sets e = 
  let l_unk = Ast.Trans("remove_sets", Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Set(s1,es,s2) ->
      begin
        match (Types.head_norm d (exp_to_typ e)).Types.t with
          | Types.Tapp([t],_) ->
              let lst = 
                C.mk_list (exp_to_locn e) 
                  space es s2 { Types.t = Types.Tapp([t],Path.listpath) }
              in
              let from_list =
                C.mk_const l_unk
                  { id_path = Id_none None;
                    id_locn = l_unk;
                    descr = get_const env ["Ocaml"; "Pset"] "from_list";
                    instantiation = [t] }
                  None
              in
              let cmp = get_compare t in
              let app1 = C.mk_app l_unk from_list (append_lskips space cmp) None in
              let app = C.mk_app l_unk app1 lst None in
                Some(app)
          | _ -> 
              assert false
      end
  | Setcomp _ ->
      raise (Trans_error(l_unk, "cannot generate code for unrestricted set comprehension"))
  | _ -> remove_comprehension false e

(* Turn list comprehensions into nested folds *)
let remove_list_comprehension e = remove_comprehension true e
let remove_set_comprehension e = remove_comprehension false e

let get_quant_lskips = function
  | Ast.Q_forall(s) -> s
  | Ast.Q_exists(s) -> s

let strip_quant_lskips = function
  | Ast.Q_forall(s) -> Ast.Q_forall(space)
  | Ast.Q_exists(s) -> Ast.Q_exists(space)

let get_quant_impl is_lst t : Ast.q -> exp = 
  let l_unk = Ast.Trans("get_quant_impl", None) in
  let f path name s =
    let d = get_const env path name in
      append_lskips s
        (C.mk_const l_unk 
          { id_path = Id_none None;
             id_locn = l_unk;
             descr = d;
             instantiation = [t] }
           None)
  in
    function
      | Ast.Q_forall(s) ->
          if is_lst then
            f ["List"] ("for_all") s
          else
            f ["Set"] ("for_all") s
      | Ast.Q_exists(s) ->
          if is_lst then
            f ["List"] ("exist") s
          else
            f ["Set"] ("exist") s

(* Turn quantifiers into iteration, fails on unrestricted quantifications *)
let remove_quant e = 
  let l_unk = Ast.Trans("remove_quant", Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Quant(q,[],s,e) ->
      Some(append_lskips s e)
  | Quant(q,qb::qbs,s1,e') ->
      begin
        match qb with
          | Qb_var(n) ->
              raise (Trans_error(l_unk, "cannot generate code for unrestricted quantifier"))
          | Qb_restr(is_lst,s2,p,s3,e_restr,s4) ->
              let q_impl = get_quant_impl is_lst p.typ q in
              let f = 
                C.mk_fun l_unk
                  (lskips_only_comments [s2;s3;s4])
                  [pat_append_lskips space p] 
                  space
                  (C.mk_quant l_unk (strip_quant_lskips q) qbs s1 e' None)
                  None
              in
              let app1 = C.mk_app l_unk q_impl f None in
                Some(C.mk_app (exp_to_locn e) app1 e_restr None)
      end
  | _ -> None

(* Turn forall (x MEM L). P x into forall (x IN Set.from_list L). P x *)
let list_quant_to_set_quant e = 
  let l_unk = Ast.Trans("list_quant_to_set_quant", Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Quant(q,qbs,s1,e') ->
      let qbs =
        Util.map_changed
          (fun e -> match e with
             | Qb_restr(is_lst,s2,p,s3,e,s4) when is_lst->
                 let lst_to_set = 
                   append_lskips space
                     (mk_const_exp env l_unk ["Set"] "from_list" [p.typ])
                 in
                 let app = C.mk_app l_unk lst_to_set e None in
                   Some(Qb_restr(false,s2,p,s3,app,s4))
             | _ -> None)
          qbs
      in
        begin
          match qbs with
            | None -> None
            | Some(qbs) -> Some(C.mk_quant (exp_to_locn e) q qbs s1 e' None)
        end
  | _ -> None


exception Pat_to_exp_unsupported of Ast.l * string
let rec pat_to_exp env p = 
  let l_unk = Ast.Trans("pat_to_exp", Some p.locn) in
  match p.term with
    | P_wild(lskips) -> 
        raise (Pat_to_exp_unsupported(p.locn, "_ pattern"))
    | P_as(_,p,_,(n,_),_) ->
        raise (Pat_to_exp_unsupported(p.locn, "as pattern"))
    | P_typ(lskips1,p,lskips2,t,lskips3) ->
        C.mk_typed p.locn lskips1 (pat_to_exp env p) lskips2 t lskips3 None
    | P_var(n) ->
        C.mk_var p.locn n p.typ
    | P_constr(c,ps) ->
        List.fold_left
          (fun e p -> C.mk_app l_unk e (pat_to_exp env p) None)
          (C.mk_constr p.locn c None)
          ps
    | P_record(_,fieldpats,_) ->
        raise (Pat_to_exp_unsupported(p.locn, "record pattern"))
    | P_tup(lskips1,ps,lskips2) ->
        C.mk_tup p.locn lskips1 (Seplist.map (pat_to_exp env) ps) lskips2 None
    | P_list(lskips1,ps,lskips2) ->
        C.mk_list p.locn lskips1 (Seplist.map (pat_to_exp env) ps) lskips2 p.typ
    | P_vector(lskips1,ps,lskips2) ->
        C.mk_vector p.locn lskips1 (Seplist.map (pat_to_exp env) ps) lskips2 p.typ
    | P_vectorC(lskips1,ps,lskips2) ->
        raise (Pat_to_exp_unsupported(p.locn, "vector concat pattern")) (* NOTE Would it be good enough to expand this into n calls to Vector.vconcat *)
    | P_paren(lskips1,p,lskips2) ->
        C.mk_paren p.locn lskips1 (pat_to_exp env p) lskips2 None
    | P_cons(p1,lskips,p2) ->
        let cons = Typed_ast_syntax.mk_const_exp env l_unk [] "::" [p1.typ] in
          C.mk_infix p.locn (pat_to_exp env p1) (append_lskips lskips cons) (pat_to_exp env p2) None
    | P_lit(l) ->
        C.mk_lit p.locn l None
    | P_num_add _ -> 
        raise (Pat_to_exp_unsupported(p.locn, "add_const pattern"))
    | P_var_annot(n,t) ->
        C.mk_typed p.locn None (C.mk_var p.locn n p.typ) None t None None


(* Turn restricted quantification into unrestricted quantification:
 * { f x | forall (p IN e) | P x } goes to
 * { f x | FV(p) | forall FV(p). p IN e /\ P x } 

 * In order to do this the pattern p is converted into an expression.
 * This is likely to fail for more complex patterns. In these cases, pattern 
 * compilation is needed. 
 *)
let remove_set_restr_quant e = 
  let l_unk = Ast.Trans("remove_set_restr_quant", Some (exp_to_locn e)) in
  let qb_OK = (function | Qb_var _ -> true | Qb_restr _ -> false) in
  try (
  match C.exp_to_term e with
  | Comp_binding(false,s1,e1,s2,s3,qbs,s4,e2,s5) ->
      if List.for_all qb_OK qbs then
        None
      else
        let and_const = mk_const_exp env l_unk [] "&&" [] in
        let in_const t = mk_const_exp env l_unk [] "IN" [t] in
        let mem_const t = mk_const_exp env l_unk ["List"] "mem" [t] in
        let pred_exp =
          List.fold_right 
            (fun qb res_e ->
               match qb with
                 | Qb_var(n) -> res_e
                 | Qb_restr(is_lst, s1', p, s2', e', s3') ->
                     let e =
                       C.mk_paren l_unk 
                         s1'
                         (C.mk_infix l_unk
                            (pat_to_exp env p)
                            (append_lskips s2' (if is_lst then mem_const p.typ else in_const p.typ))
                            e'
                            None)
                         s3'
                         None
                     in
                       C.mk_infix l_unk
                         e
                         (append_lskips space and_const)
                         res_e
                         None)
            qbs
            e2
        in
        let new_qbs = 
          List.concat
            (List.map 
               (function
                  | Qb_var(n) -> [Qb_var(n)]
                  | Qb_restr(_,_,p,_,_,_) -> List.map (fun v -> Qb_var(v)) (Pattern_syntax.pat_vars_src p))
               qbs)
        in
          Some(C.mk_comp_binding l_unk
                 false s1 e1 s2 s3 new_qbs s4 pred_exp s5 None)
  | _ -> None)
  with Pat_to_exp_unsupported (l, m) -> 
    (Reporting.report_warning (Reporting.Warn_general (true, exp_to_locn e, m^" in restricted set comprehension")); None) (* it can still be handled by pattern compilation *)


(* Moves quantification to the condition part of the 
   set comprehension, if it does not concern any variables in the pattern
 * { f x | forall (p IN e) xx yy | P x } goes to 
 * { f x | forall xx yy | exists (p IN e). P x } 
 * if x notin FV p.
 *)
let cleanup_set_quant e = 
  let l_unk = Ast.Trans("cleanup_set_restr_quant", Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Comp_binding(false,s1,e1,s2,s3,qbs,s4,e2,s5) ->
      let used_vars = List.fold_left (fun acc -> function 
             Qb_var nsa -> acc
           | Qb_restr (_, _, _, _, e, _) -> NameSet.union (nfmap_domain (C.exp_to_free e)) acc)
         (nfmap_domain (C.exp_to_free e1)) qbs in

      let can_move = function 
          Qb_var nsa -> not (NameSet.mem (Name.strip_lskip nsa.term) used_vars)
	| Qb_restr (_, _, p, _, e, _) ->
            NameSet.is_empty (NameSet.inter used_vars (nfmap_domain p.rest.pvars)) 
      in
      let (qbs_move, qbs_keep) = List.partition can_move qbs in
      if List.length qbs_move = 0 then
        None
      else
        let e2' = C.mk_quant l_unk (Ast.Q_exists None) qbs_move  space e2 (Some bool_ty) in 
        let res = C.mk_comp_binding l_unk false s1 e1 s2 s3 qbs_keep s4 e2' s5 (Some (exp_to_typ e)) in
          Some res
  | _ -> None

(* Turn unrestricted comb-bindings into set_comb
 * { f x | x | P x y1 ... yn } goes to
 * { f x | P x y1 ... yn } 
 *)
let remove_set_comp_binding e = 
  let l_unk = Ast.Trans("remove_comp_binding", Some (exp_to_locn e)) in
  let qb_OK = (function | Qb_var _ -> true | Qb_restr _ -> false) in
  match C.exp_to_term e with
  | Comp_binding(false,s1,e1,s2,s3,qbs,s4,e2,s5) ->
      if not (List.for_all qb_OK qbs) then None
      else begin
        let e_vars = nfmap_domain (C.exp_to_free e1) in
        let b_vars = begin 
          let bound_vars = List.map (function Qb_var v -> Name.strip_lskip (v.term) | _ -> 
               raise (Reporting_basic.err_unreachable false l_unk "Unreachable because of qb_OK check")) qbs in
          let module NameSetE = Util.ExtraSet(NameSet) in
          let bvs = NameSetE.from_list bound_vars in
          bvs
        end in
        if not (NameSet.equal e_vars b_vars) then
          None
        else begin
          let s234 = (Ast.combine_lex_skips s2 (Ast.combine_lex_skips s3 s4)) in
          let res = C.mk_setcomp l_unk s1 e1 s234 e2 s5 e_vars (Some (exp_to_typ e)) in
          Some res
        end
      end 
  | _ -> None


(* Turn restricted quantification into unrestricted quantification.
 * forall (p IN e). P x  goes to
 * forall FV(p). p IN e --> P x 
 * patterns, for which pat_OK returns true are kept 
 *)
let remove_restr_quant pat_OK e = 
  let l_unk = Ast.Trans("remove_restr_quant", Some (exp_to_locn e)) in
  let qb_OK = (function | Qb_var _ -> true | Qb_restr(_,_,p,_,_,_) -> pat_OK p) in
  try (match C.exp_to_term e with
  | Quant(q,qbs,s,e) ->
      if List.for_all qb_OK qbs then
        None
      else
        let imp_const = mk_const_exp env l_unk [] "-->" [] in
        let and_const = mk_const_exp env l_unk [] "&&" [] in
        let comb_const = match q with Ast.Q_forall _ -> imp_const | Ast.Q_exists _ -> and_const in
        let in_const t = mk_const_exp env l_unk [] "IN" [t] in
        let mem_const t = mk_const_exp env l_unk ["List"] "mem" [t] in
        let pred_exp =
          List.fold_right 
            (fun qb res_e ->
               match qb with
                 | Qb_var(n) -> res_e
                 | Qb_restr(is_lst, s1', p, s2', e', s3') ->
                     if Pattern_syntax.is_var_wild_pat p then res_e else begin
                       let e =
                         C.mk_paren l_unk 
                           s1'
                           (C.mk_infix l_unk
                              (pat_to_exp env p)
                              (append_lskips s2' (if is_lst then mem_const p.typ else in_const p.typ))
                              e'
                              None)
                           s3'
                           None
                       in
                         C.mk_infix l_unk
                           e
                           (append_lskips space comb_const)
                           res_e
                           None
                    end)
            qbs
            e
        in
        let new_qbs = 
          List.concat
            (List.map 
               (fun qb -> match qb with
                  | Qb_var(n) -> [Qb_var(n)]
                  | Qb_restr(_,_,p,_,_,_) -> (if pat_OK p then [qb] else (List.map (fun v -> Qb_var(v)) (Pattern_syntax.pat_vars_src p))))
               qbs)
        in
          Some(C.mk_quant (exp_to_locn e) q new_qbs s pred_exp None)
  | _ -> None)
  with Pat_to_exp_unsupported (l, m) -> 
    (Reporting.report_warning (Reporting.Warn_general (true, exp_to_locn e, m^" in restricted set comprehension")); None) (* it can still be handled by pattern compilation *)


let eq_path = Path.mk_path [Name.from_rope (r"Ocaml"); Name.from_rope (r"Pervasives")] (Name.from_rope (r"="))

let hack e = 
  let l_unk = Ast.Trans("hack", Some (exp_to_locn e)) in
  match C.exp_to_term e with
  | Constant(c) ->
      if Path.compare c.descr.const_binding eq_path = 0 then
        begin
          match c.instantiation with
            | [t] when Types.compare (Types.head_norm d t) special_type = 0 ->
                Some
                  (C.mk_const l_unk
                    { id_path = Id_none None;
                       id_locn = l_unk;
                       descr = { const_binding = Path.mk_path [Name.from_rope (r"")] (Name.from_rope (r"eq_instruction_instance"));
                                 const_tparams = [];
                                 const_class = [];
                                 const_type = Types.multi_fun [special_type; special_type] 
                                                { Types.t = Types.Tapp([], Path.mk_path [] (Name.from_rope (r"num"))) };
                                 env_tag = K_target(true,Targetset.empty);
                                 spec_l = l_unk;
                                 substitutions = Targetmap.empty };
                       instantiation = [] }
                     None)
            | _ -> None
        end
      else
        None
  | _ -> None

let tnfmap_apply m k =
  match Types.TNfmap.apply m k with
    | None -> assert false
    | Some x -> x

let remove_method e =
  let l_unk = Ast.Trans("remove_method", Some (exp_to_locn e)) in
  match C.exp_to_term e with
    | Constant(c) ->
        begin
          match c.descr.env_tag with
            | K_method ->
                begin 
                  match (c.descr.const_class, c.instantiation) with
                    | ([(c_path,tparam)],[targ]) -> 
                        begin
                          match Types.get_matching_instance d (c_path, targ) inst with
                            | Some(instance_path, subst, instance_constraints) ->
                                (* There is an instance for this method at this type, so
                                 * we directly call the instance *)
                                begin
                                  let new_const = 
                                    names_get_const env instance_path (Path.get_name c.descr.const_binding)
                                  in
                                  let id = 
                                    { id_path = Id_none (Typed_ast.ident_get_first_lskip c);
                                      id_locn = c.id_locn;
                                      descr = new_const;
                                      instantiation = List.map (tnfmap_apply subst) new_const.const_tparams; }
                                  in
                                  let new_e = C.mk_const l_unk id None in
                                    Some(new_e)
                                end
                            | None ->
                                let tv = 
                                  match targ.Types.t with
                                    | Types.Tvar tv -> Types.Ty tv
                                    | Types.Tne { Types.nexp = Types.Nvar v } -> Types.Nv v
                                    | _ -> raise (Reporting_basic.err_unreachable true l_unk "because there was no instance")
                                in
                                let n = class_path_to_dict_name c_path tv in
                                let t = class_path_to_dict_type c_path targ in
                                let dict = C.mk_var l_unk (Name.add_lskip n) t in
                                let (c_pnames,_) = Path.to_name_list c_path in
                                let (_,mname) = Path.to_name_list c.descr.const_binding in
                                let mname = Name.rename (fun x -> Ulib.Text.(^^^) x (r"_method")) mname in
                                let sk = ident_get_first_lskip c in
                                let field = 
                                  { id_path = Id_none None;
                                    id_locn = c.id_locn;
                                    descr = names_get_field env (c_pnames @ [mname]);
                                    instantiation = [targ] }
                                in
                                let new_e = 
                                  C.mk_field l_unk (fst (alter_init_lskips (fun _ -> (sk,None)) dict)) None field (Some (exp_to_typ e))
                                in
                                    Some(new_e)
                        end
                    | _ -> assert false
                end
            | _ -> None
        end
    | _ -> None


let remove_class_const e =
  let l_unk = Ast.Trans("remove_class_const", Some (exp_to_locn e)) in
  match C.exp_to_term e with
    | Constant(c) ->
        begin
          match c.descr.env_tag with
            | K_let | K_target _ ->
                if c.descr.const_class = [] then
                  None
                else
                  let subst = Types.TNfmap.from_list2 c.descr.const_tparams c.instantiation in
                  let args = 
                    List.map
                      (fun (c_path, tv) ->
                         let t_inst = tnfmap_apply subst tv in
                         let open Types in 
                           match get_matching_instance d (c_path, t_inst) inst with
                             | Some(instance_path, subst, instance_constraints) ->
                                 let dict_const = names_get_const env instance_path (Name.from_rope (r"dict")) in
                                   C.mk_const l_unk
                                     { id_path = Id_none None;
                                       id_locn = l_unk;
                                       descr = dict_const;
                                       instantiation = List.map (tnfmap_apply subst) dict_const.const_tparams }
                                     None
                             | None ->
                                let tv = 
                                  match t_inst.t with
                                    | Tvar tv -> Ty tv
                                    | Tne { nexp = Nvar v } -> Nv v
                                    | _ -> raise (Reporting_basic.err_unreachable true l_unk "because there was no instance")
                                in
                                let t = class_path_to_dict_type c_path t_inst in
                                  C.mk_var l_unk (Name.add_lskip (class_path_to_dict_name c_path tv)) t)
                      c.descr.const_class
                  in
                  let (c_path1,c_path2) = Path.to_name_list c.descr.const_binding in
                  let new_c = names_get_const env c_path1 c_path2 in
                  let new_id = {c with descr = new_c } in
                  let new_e = 
                    List.fold_left
                      (fun e arg -> C.mk_app l_unk e arg None)
                      (C.mk_const l_unk new_id None)
                      args
                  in
                    Some(new_e)
            | _ -> 
                None
        end
    | _ -> None


(*Convert nexpressions to expressions *)
let nexp_to_exp n =
   let l_unk = Ast.Trans ("nexp_to_exp", None) in
   let num_type = { Types.t = Types.Tapp([],Path.numpath) } in
   let bin_op_type = { Types.t = Types.Tfn(num_type,num_type) } in
   let rec to_exp n =
      match n.Types.nexp with
      | Types.Nvar(n) -> C.mk_nvar_e l_unk Typed_ast.no_lskips n num_type
      | Types.Nconst(i) -> let lit =  C.mk_lnum l_unk Typed_ast.no_lskips i (Some num_type) in
                           C.mk_lit l_unk lit (Some num_type)
      | Types.Nadd(n1,n2) -> 
               let plus_const_id = get_const_id env l_unk ["Pervasives"] "+" [] in
               let plus = C.mk_const l_unk plus_const_id (Some bin_op_type) in
               C.mk_infix l_unk (to_exp n1) plus (to_exp n2) (Some num_type)
      | Types.Nmult(n1,n2) ->
               let mult_const_id = get_const_id env l_unk ["Pervasives"] "*" [] in
               let mult = C.mk_const l_unk mult_const_id (Some bin_op_type) in
               C.mk_infix l_unk (to_exp n1) mult (to_exp n2) (Some num_type)
      | _ -> assert false
    in to_exp n

let rec remove_tne ts =
  match ts with 
    | [] -> [],[]
    | ({Types.t = Types.Tne _} as n) :: ts -> let (tns,oths) = remove_tne ts in
                                              (n::tns,oths)
    | t :: ts -> let (tns,oths) = remove_tne ts in
                 (tns,t::oths)

(*add numeric parameter for nexp type parameter in function calls with constants*)
let add_nexp_param_in_const e =
  let l_unk = Ast.Trans("add_nexp_param_in_const", Some (exp_to_locn e)) in
  match C.exp_to_term e with
    | Constant(c) ->
        begin
          match c.descr.env_tag with
            | K_method -> None 
            | K_let | K_target _ ->
                if c.descr.const_tparams = [] then None
                else    
                  let (nvars,tvars) = Types.tnvar_split c.descr.const_tparams in
                  if nvars = [] then None
                  else
                    let (c_path1,c_path2) = Path.to_name_list c.descr.const_binding in
                    let new_c = names_get_const env c_path1 c_path2 in
                    (* This causes the add_nexp_param_in_const to terminate as the def_trans will update nvar types in the descr,
                       and the add_nexp updates the local descr. This only works when the macro is run after the def_trans for nvars
                       and before other macros have updated the local descr.
                    *)
                    if c.descr = new_c then None
                    else 
                      let (args,instances) = remove_tne c.instantiation in
                      let args = List.map (fun t -> match t.Types.t with | Types.Tne(n) -> nexp_to_exp n | _ -> assert false) args in
                      let new_id = {c with descr = new_c } in
                      (*let _ = Format.printf "%a@ =@ %a@\n" Types.pp_type (exp_to_typ (C.mk_const l_unk new_id None)) Types.pp_type (exp_to_typ e) in*)
                      let new_e = 
                        List.fold_left
                          (fun e arg -> C.mk_app l_unk e arg None)
                          (C.mk_const l_unk new_id None)
                           args in
                        Some(new_e)
            | _ -> None
        end
    | _ -> None

(*Replace vector access with an appropriate external library call, ocaml specific at the moment*)
let remove_vector_access e =
  let l_unk = Ast.Trans("remove_vector_acc", Some (exp_to_locn e)) in
  match C.exp_to_term e with
    | VectorAcc(v, sk1, i, sk2) -> 
      let vlength = match (exp_to_typ v).Types.t with | Types.Tapp([n;a],_) -> n | _ -> assert false in
      let num_type = { Types.t = Types.Tapp([],Path.numpath) } in
      let acc_typ1 = { Types.t = Types.Tfn(exp_to_typ v,exp_to_typ e) } in
      let acc_typ = { Types.t = Types.Tfn(num_type, acc_typ1) } in
      let f_id = get_const_id env l_unk ["Vector"] "vector_access" [(exp_to_typ e); {Types.t = Types.Tne(i.nt)}; vlength ] in
      let f = C.mk_const l_unk f_id (Some acc_typ) in
      let app1 = C.mk_app l_unk f (nexp_to_exp i.nt) (Some acc_typ1) in
      Some(C.mk_app l_unk app1 v (Some (exp_to_typ e)))
    | _ -> None

(*Replace vector sub with an appropriate external library call, ocaml specific at the moment*)
let remove_vector_sub e =
  let l_unk = Ast.Trans("remove_vector_sub", Some (exp_to_locn e)) in
  match C.exp_to_term e with
    | VectorSub(v, sk1, i1, sk2, i2, sk3) -> 
      let (vlength1,a) = match (exp_to_typ v).Types.t with | Types.Tapp([n;a],_) -> (n,a) | _ -> assert false in
      let vlength2 = match (exp_to_typ e).Types.t with | Types.Tapp([n;a],_) -> n | _ -> assert false in
      let num_type = { Types.t = Types.Tapp([],Path.numpath) } in
      let acc_typ1 = { Types.t = Types.Tfn(exp_to_typ v,exp_to_typ e) } in
      let acc_typ2 = { Types.t = Types.Tfn(num_type, acc_typ1) } in
      let acc_typ3 = { Types.t = Types.Tfn(num_type, acc_typ2) } in
      let f_id = get_const_id env l_unk ["Vector"] "vector_slice" [a; { Types.t = Types.Tne(i1.nt)}; {Types.t = Types.Tne(i2.nt)}; vlength1; vlength2] in 
      let f = C.mk_const l_unk f_id (Some acc_typ3) in
      let app1 = C.mk_app l_unk f (nexp_to_exp i1.nt) (Some acc_typ2) in
      let app2 = C.mk_app l_unk app1 (nexp_to_exp i2.nt) (Some acc_typ1) in
      Some(C.mk_app l_unk app2 v (Some (exp_to_typ e)))
    | _ -> None


(* Add type annotations to pattern variables whose type contains a type variable
 * (only add for arguments to top-level functions) *)
let rec coq_type_annot_pat_vars (level,pos) p = 
  let l_unk = Ast.Trans("coq_type_annot_pat_vars", Some p.locn) in
  match p.term with
    | P_var(n) when level = Macro_expander.Top_level && 
                    pos = Macro_expander.Param && 
                    not (Types.TNset.is_empty (Types.free_vars p.typ)) ->
        Some(C.mk_pvar_annot l_unk n (C.t_to_src_t p.typ) (Some(p.typ)))
    | _ -> None

end

