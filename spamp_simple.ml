#!/usr/bin/env -S opam exec --switch=4.14.2+options -- utop

#thread
#require "feather"
#require "containers"

open Feather

let () =
  let files =
    process "find" [ "."; "-iname"; "*small_*.mp3" ]
    |. shuf
    |> collect stdout
    |> lines 
  in
  while true do
    files |> CCList.iter (fun file ->
      process "mpv" [ file; "--length=0.06" ] |> run
    )
  done




