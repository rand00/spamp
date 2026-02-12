#!/usr/bin/env -S opam exec --switch=4.14.2+options -- utop

(** Utop REPL statements *)
#thread
#require "feather"
#require "containers"
#require "unix"

open Feather

let sp = CCFormat.sprintf

module Socket = struct

  let read_response chan ~success_event =
    let rec aux () =
      (*> Note that we use an 'in_channel' here that wraps the unix-socket
          file-descriptor - this is an abstraction that has an internal buffer
          which then minimizes Unix.read calls and allows to read a 'line' efficiently
          * specifically this will also block until there is a line available
          * unix SIGPIPE is signaled when socket is closed unexpectedly 
      *)
      match In_channel.input_line chan with
      | None -> failwith "Socket was closed"
      | Some event -> 
        if CCString.mem ~sub:success_event event then
          event
        else ( (*> We drop all other events*)
          (* CCFormat.eprintf "DEBUG: dropping non-response event \n\t%s%!" *)
          (*   (Bytes.sub_string buf 0 n_read) *)
          (* ; *)
          aux ()
        ) 
    in
    aux ()

  let send_line chan str =
    Out_channel.output_string chan @@ str ^ "\n";
    Out_channel.flush chan

end

(** Mpv socket IPC *)
module Mpv = struct

  (*How to run Mpv as a server:
      $ mpv --loop --idle --keep-open --audio-display=no --input-ipc-server=/tmp/valdefars_sock
    Notes:
      * --loop enables you to granulate through a single big file with relative
        seeking commands
      * --idle + --keep-open allows mpv to continue running as a server while there
        are no files in queue and when all files have finished playing
      * --audio-display=no avoids a video-popup showing the album-cover, which
        is also extremely slow - which then slows down loading of files, which
        in effect slows down when you are allowed to seek into file
      * --input-ipc-server refers to the unix socket we communicate through
  *)
    
  let socket_file = "/tmp/valdefars_sock"
    
  (*Warning: global state*)
  let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0
  let socket_in_chan = Unix.in_channel_of_descr socket
  let socket_out_chan = Unix.out_channel_of_descr socket
  let socket_addr = Unix.ADDR_UNIX socket_file
      
  let () =
    Unix.connect socket socket_addr;
    at_exit (fun () ->
      Unix.shutdown socket Unix.SHUTDOWN_SEND;
      close_in socket_in_chan; (*< Note this closes whole socket file-descriptor*)
    )

  module Cmd = struct 

    type t = [
      | `Stop
      | `Play
      | `Pause
      | `Loop of bool (*toggled*)
      | `Seek of seek
      | `Load of string (*audio-path*)
    ]

    and seek = [
      | `Absolute_seconds of int
      | `Relative_seconds of int
      | `Absolute_percent of float
      | `Relative_percent of float
    ]

    let str s = sp "\"%s\"" s (*json str*)
    let bool b = sp "%b" b (*json bool*)

    (*> Note: returned string list represents json fields of protocol *)
    let to_mpv_cmd : t -> string list = function
      | `Stop -> [ str "stop" ]
      | `Play -> [ str "set_property"; str "pause"; bool false ]
      | `Pause -> [ str "set_property"; str "pause"; bool true ]
      | `Loop loop -> [ str "set_property"; str "loop-file"; bool loop ]
      | `Load file -> [ str "loadfile"; str file; ]
      | `Seek (`Absolute_seconds seconds) ->
        let minutes = seconds / 60 in
        let seconds_left = seconds mod 60 in
        [
          str "seek";
          str @@ sp "%02d:%02d" minutes seconds_left;
          (* str "absolute+exact"; *)
          str "absolute";
        ]
      | `Seek (`Relative_seconds seconds) ->
        let minutes = seconds / 60 in
        let seconds_left = seconds mod 60 in
        [
          str "seek";
          str @@ sp "%02d:%02d" minutes seconds_left;
          (* str "relative+exact"; *)
          str "relative";
        ]
      | `Seek (`Absolute_percent pct) ->
        [
          str "seek";
          str @@ sp "%f" pct;
          str "absolute-percent"
        ]
      | `Seek (`Relative_percent pct) ->
        [
          str "seek";
          str @@ sp "%f" pct;
          str "relative-percent"
        ]

    (*> Note that enabling 'async' didn't help loading files faster after big file*)
    let serialize cmd =
      cmd
      |> to_mpv_cmd
      |> String.concat ", "
      |> sp "{ \"command\": [ %s ] }"

  end

  let send_cmd cmd =
    cmd |> Cmd.serialize |> Socket.send_line socket_out_chan;
    (*> Note: the protocol of Mpv seems to expect that we always read back the
        response. This fixed that Mpv stopped responding after a while.
        Though many responses read here are not direct responses to the current
        command - so we just skip these until we see a relevant reponse. 
    *)
    Socket.read_response socket_in_chan
      ~success_event:"request_id"

  let wait_for_event = function
    | `File_loaded ->
      (*Note: this is needed as mpv doesn't load the file before it returns success
        to the 'load-file' command - so if we 'seek' before this event it fails*)
      Socket.read_response socket_in_chan
        ~success_event:"file-loaded"
        
end

(** Pmmd socket IPC *)
module Pmmd = struct

  (*Note: You need to run the corresponding `pmmd_spamp` binary in parallel*)
    
  let socket_file = "/tmp/valdefars_pmmd_sock"
    
  (*Warning: global state*)
  let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0
  let socket_in_chan = Unix.in_channel_of_descr socket
  let socket_out_chan = Unix.out_channel_of_descr socket
  let socket_addr = Unix.ADDR_UNIX socket_file
      
  let () =
    Unix.connect socket socket_addr;
    at_exit (fun () ->
      Unix.shutdown socket Unix.SHUTDOWN_SEND;
      close_in socket_in_chan; (*< Note this closes whole socket file-descriptor*)
    )

  let parse_response str =
    let wavestack_vs =
      str
      |> CCString.split_on_char ' '
      |> CCList.map CCFloat.of_string_exn
    in
    match wavestack_vs with
    | [ v0; v1; v2; v3 ] -> v0, v1, v2, v3
    | _ -> failwith "Couldn't parse wavestacks"

  let read_wavestacks () = 
    "now" |> Socket.send_line socket_out_chan;
    Socket.read_response socket_in_chan
      ~success_event:"" (*< matches on all events*)
    |> parse_response 

  let read_wavestacks_on_beat () =
    "beat" |> Socket.send_line socket_out_chan;
    Socket.read_response socket_in_chan
      ~success_event:"" (*< matches on all events*)
    |> parse_response 
      
end

let print_response str = CCFormat.printf "%s\n%!" str

(** The script *)

let () =
  let files =
    let not_query = [ "-not"; "-iname"; ".*" ] in
    process "find" @@ [ "."; "-iname"; "*small*.mp3" ] @ not_query
    |. shuf
    |> collect stdout
    |> lines
    |> CCArray.of_list
  in
  while true do
    let w0, w1, w2, w3 = Pmmd.read_wavestacks_on_beat () in
    let file_idx = w1 *. float (CCArray.length files -1) |> CCInt.of_float in
    let file = files.(file_idx) in
    CCFormat.printf "loading file (idx = %d) %s\n%!" file_idx file;
    `Load file |> Mpv.send_cmd |> print_response;
    CCFormat.printf "waiting for 'file-loaded'\n%!";
    Mpv.wait_for_event `File_loaded |> print_response;
    let seek_pct = 100. *. w2 in
    CCFormat.printf "sending 'seek' to %f%%\n%!" seek_pct;
    `Seek (`Absolute_percent seek_pct) |> Mpv.send_cmd |> print_response;
    CCFormat.printf "sending 'play'\n%!";
    `Play |> Mpv.send_cmd |> print_response;
  done




