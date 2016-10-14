(*---------------------------------------------------------------------------
   Copyright (c) 2016 Andrew Rudenko. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open! Core.Std
open! Async.Std

module Cli = struct
  open Cmdliner

  type config = {
    config_path : string;
    consul_bin : string;
    consul_endpoint : Async_http.addr;
    watched_pairs : (string * string) list;
  }

  let config config_path consul_bin consul_endpoint watched_pairs () =
    {config_path; consul_bin; consul_endpoint; watched_pairs}

  let endpoint =
    let endpoint_str = function
    | `Unix s -> (sprintf "unix://%s" s)
    | `Inet (h,p) -> (sprintf "tcp://%s:%i" h p) in

    let parse s =
      if Str.string_match (Str.regexp {|unix://\(.+\)|}) s 0 then
        `Ok (`Unix (Str.matched_group 1 s))
      else (if Str.string_match (Str.regexp {|tcp://\(.+\):\([0-9]+\)|}) s 0 then
              `Ok (`Inet ((Str.matched_group 1 s), int_of_string @@ (Str.matched_group 2 s)))
            else `Error "Bad formatted docker endpoint") in
    parse, fun ppf p -> Format.fprintf ppf "%s" (endpoint_str p)

  let consul_endpoint =
    Arg.(value & opt endpoint (`Inet ("localhost", 8500)) & info ["consul-endpoint"])

  let config_path =
    let doc = "Path to consul-template config" in
    Arg.(required & opt (some string) None & info ["c"; "config"] ~docv:"PATH" ~doc)

  let consul_bin =
    let doc = "consul-template binary" in
    Arg.(value & opt string "consul-template" & info ["b"; "bin"] ~docv:"BIN" ~doc)

  let watched_pairs =
    let doc = "List of pairs in format of FROM:TO where FROM is prefix in consul and TO is directory in filesystem" in
    Arg.(non_empty & pos_all (pair ~sep:':' string dir) [] & info [] ~docv:"PAIR" ~doc)

  let setup_log =
    let setup style_renderer level =
      Fmt_tty.setup_std_outputs ?style_renderer ();
      Logs.set_level level;
      Logs.set_reporter (Logs_fmt.reporter ~pp_header:Logs_fmt.pp_header ());
      () in
    Term.(const setup $ Fmt_cli.style_renderer () $ Logs_cli.level ())

  let cmd =
    let doc = "" in
    Term.(const config $ config_path $ consul_bin $ consul_endpoint $ watched_pairs $ setup_log),
    Term.info "multi-consul-template" ~doc

end

type change = Created of (string * string)
            | Removed of string
            | Updated of (string * string)

module Consul = struct
  type t = {
    endpoint : Async_http.addr;
  }
  let create endpoint = { endpoint }

  let path_extension path =
    Filename.basename path
    |> String.split ~on:'.'
    |> List.last_exn

  let parse v =
    let open Yojson.Basic in
    let open Util in
    from_string v
    |> to_list
    |> List.map ~f:(fun v ->
        v |> member "Key" |> to_string,
        v |> member "Value" |> to_string |> B64.decode,
        v |> member "ModifyIndex" |> to_int)

  let apply_res state w body =
    let removed = String.Set.(diff
                                (of_list (List.map state ~f:(fun (k, _) -> k)))
                                (of_list (List.map body ~f:(fun (k, _, _) -> k)))
                              |> to_list) in
    let%bind () = Deferred.List.iter removed ~f:(fun path ->
        Pipe.write w (Removed path)) in
    let f state' (k, v, modify) =
      let%map () = match List.Assoc.find state k with
      | Some prev_modify when prev_modify <> modify ->
          Pipe.write w (Updated (k, v))
      | None -> Pipe.write w (Created (k, v))
      | _ -> return () in
      (k, modify)::state' in
    let only_templates = List.filter body ~f:(fun (k, _, _) -> "ctmpl" = path_extension k) in
    Deferred.List.fold only_templates ~f ~init:[]

  let watch_prefix t prefix =
    let (r, w) = Pipe.create () in
    let tick (index, state) =
      match%bind Async_http.(request_of_addr t.endpoint
                             |> path (Filename.concat "/v1/kv/" prefix)
                             |> query_param "recurse" ""
                             |> query_param "wait" "10s"
                             |> query_param "index" (string_of_int index)
                             |> parser parse
                             |> get) with
      | Error err ->
          Logs.err (fun m -> m "Error while consul request: %s" (Exn.to_string err));
          let%map () = after (Time.Span.of_int_sec 5) in
          `Continue (index, state)
      | Ok {Async_http.Response.body; headers} ->
          let%map state' = apply_res state w body in
          let index' = match List.Assoc.find headers ~equal:String.Caseless.equal "X-Consul-Index" with
          | Some v -> (try (int_of_string v) with _ -> index)
          | None -> index in
          `Continue (index', state') in
    Cancellable.worker ~tick:(Cancellable.wrap_tick tick) (0, [])
    |> Cancellable.wait |> Deferred.ignore |> don't_wait_for;
    r
end

module System = struct
  type t = {
    consul : Consul.t;
    config_path : string;
    consul_template : Process.t option ref;
  }

  let write_template path contents =
    Writer.save ~fsync:true path ~contents

  let generated_mark =  "//GENERATED BY MULTI-CONSUL-TEMPLATE"

  let write_config path templates =
    let%bind lines = Reader.file_lines path in
    let not_generated = List.take_while lines ~f:(fun l -> l <> generated_mark) in
    let config = String.concat ~sep:"\n" not_generated ^ "\n" in
    let template_config template =
      sprintf "template {\nsource = \"%s\"\ndestination = \"%s\"\n}\n"
        template (Filename.chop_extension template) in
    let config' = config ^ generated_mark ^ "\n" ^ (String.concat ~sep:"\n" (List.map ~f:template_config templates)) in
    Writer.save ~fsync:true path ~contents:config'

  let hup_consul t =
    match !(t.consul_template) with
    | Some p -> Signal.send_i Signal.hup (`Pid (Process.pid p))
    | None -> ()

  let handle_change t state = function
  | Created (path, content) ->
      let%bind () = write_template path content in
      let state' = path::state in
      let%map () = write_config t.config_path state' in
      hup_consul t;
      state'
  | Updated (path, content) ->
      let%map () = write_template path content in
      hup_consul t;
      state
  | Removed path ->
      let%bind () = Unix.unlink path in
      let state' = List.filter state ~f:(fun v -> v <> path) in
      let%bind () = write_config t.config_path state' in
      hup_consul t;
      let%map _ = try_with (fun () -> Unix.unlink (Filename.chop_extension path)) in
      state'

  let tick t changes state control =
    choose
      [choice (Pipe.read changes) (function
         | `Eof -> failwith "Unexpected close"
         | `Ok change -> let%map res = handle_change t state change in
             `Continue res) ;
       choice control (fun () -> return @@ `Complete state)]
    |> Deferred.join

  let make_changes_pipe t pairs =
    let (r, w) = Pipe.create () in
    let map_change dir = function
    | Created (path, v) -> Created (Filename.(concat dir (basename path)), v)
    | Updated (path, v) -> Updated (Filename.(concat dir (basename path)), v)
    | Removed path -> Removed Filename.(concat dir (basename path)) in
    List.iter pairs ~f: (fun (consul_prefix, dir) ->
        let changes = Consul.watch_prefix t.consul consul_prefix in
        Pipe.transfer changes w ~f:(map_change dir) |> don't_wait_for);
    r

  let start_consul_template container prog config_path =
    let rec tick () =
      match%bind Process.create ~prog ~args:["-config"; config_path] () with
      | Error err ->
          Logs.err (fun m -> m "Can't start consul-template: %s" (Error.to_string_hum err));
          let%bind () = after @@ Time.Span.of_int_sec 5 in
          tick ()
      | Ok p ->
          Pipe.iter (Process.stderr p |> Reader.lines) ~f:
            (fun l -> return @@ Logs.app (fun m -> m "consul-template stderr: %s" l)) |> don't_wait_for;
          Pipe.iter (Process.stdout p |> Reader.lines) ~f:
            (fun l -> return @@ Logs.app (fun m -> m "consul-template stdout: %s" l)) |> don't_wait_for;
          (* we need to give consul-template a chance to setup HUP-handlers *)
          let%bind () = after @@ Time.Span.of_int_sec 1 in
          Signal.send_i Signal.hup (`Pid (Process.pid p));
          container := Some p;
          let%bind res = Process.wait p in
          Logs.err (fun m -> m "consul-template %s" (Unix.Exit_or_signal.to_string_hum res));
          tick () in
    tick ()

  let create {Cli.config_path; consul_endpoint; consul_bin; watched_pairs} =
    let consul = Consul.create consul_endpoint in
    let consul_template = ref None in
    start_consul_template consul_template consul_bin config_path |> don't_wait_for;
    let t = {consul; config_path; consul_template} in
    let changes = make_changes_pipe t watched_pairs in
    let wrapped state =
      Cancellable.wrap (tick t changes state) in
    Cancellable.worker ~tick:wrapped []
    |> Cancellable.wait
    |> Deferred.ignore
end

let start config =
  System.create config |> don't_wait_for;
  never_returns (Scheduler.go ())

let () =
  let open Cmdliner in
  match Term.eval Cli.cmd with
  | `Error _ -> exit 1 |> ignore
  | `Ok v -> start v
  | _ -> exit 0 |> ignore