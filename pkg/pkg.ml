#!/usr/bin/env ocaml
#use "topfind"
#require "topkg"
open Topkg

let () =
  Pkg.describe "multi-consul-template" @@ fun c ->
  Ok [ Pkg.bin "src/multi_consul_template" ~dst:"multi-consul-template"]
