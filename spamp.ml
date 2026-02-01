#!/usr/bin/env -S opam exec --switch=4.14.2+options -- utop

(** Utop REPL statements *)
#thread
#require "feather"
#require "containers"
#require "unix"

open Feather

let sp = CCFormat.sprintf

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
  let socket_addr = Unix.ADDR_UNIX socket_file

  let () =
    Unix.connect socket socket_addr;
    at_exit (fun () -> Unix.shutdown socket Unix.SHUTDOWN_SEND)

  let read_response =
    let len = 1024 in
    let buf = Bytes.create len in
    let rec aux ~success_event n_read =
      if n_read >= len then (
        CCFormat.eprintf "Warning: command response was too long, so cut it\n%!";
        Bytes.sub_string buf 0 len
      ) else (
        (*> Note: we read just 1 char as we currently don't want to make a
            local buffer abstraction over data read from socket
            .. @optimization; could read arbitrary amount of bytes and cut out
               needed string (until newline) and save rest of bytes for next 'read_response'
               call into new local buffer of 'extra data to prepend'
               * @important; in the simple case without keeping a local buffer of
                 'extra' data: as we don't know what events MPV sends when,
                 we are not allowed to read all available data on socket, if the
                 next call to 'read_response' should be able to read an unbroken
                 message
        *)
        let n_read' = Unix.read socket buf n_read 1 in
        let n_read = n_read + n_read' in
        if Bytes.get buf (n_read-1) = '\n' then (
          let resp = Bytes.sub_string buf 0 n_read in
          if CCString.mem ~sub:success_event resp then
            resp
          else ( (*> We drop all other events*)
            (* CCFormat.eprintf "DEBUG: dropping non-response event \n\t%s%!" *)
            (*   (Bytes.sub_string buf 0 n_read) *)
            (* ; *)
            aux ~success_event 0
          ) 
        ) else if n_read' = 0 then (
          (*Warning: in theory mpv could be in the middle of writing a message
            that we have only read partially here
            * @note; it could also be the case that mpv was killed before
              finishing writing a message, which would make us hang
            => more correct solution;
              * try to read the next chars until newline here, and put a timeout on this
                Unix.read call
          *)
          CCFormat.eprintf "Warning: data response stopped without a newline\n%!";
          Bytes.sub_string buf 0 n_read
        ) else (*> We continue reading*)
          aux ~success_event n_read
      )
    in
    fun ?(success_event="request_id") () ->
      aux ~success_event 0

  let send_string str =
    let len = CCString.length str in
    let bytes = Bytes.unsafe_of_string str in
    let rec aux from =
      let written = Unix.write socket bytes from (len - from) in
      if written = 0 then failwith "Socket closed"
      else if written <> len then (
        (* CCFormat.eprintf "DEBUG: didn't write full string to socket\n%!"; *)
        aux (from + written)
      ) else ()
    in
    aux 0

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
      |> sp "{ \"command\": [ %s ] }\n"

  end

  let send_cmd cmd =
    cmd |> Cmd.serialize |> send_string;
    (*> Note: the protocol of Mpv seems to expect that we always read back the
        response. This fixed that Mpv stopped responding after a while.
        Though many responses read here are not direct responses to the current
        command - so we just skip these until we see a relevant reponse. 
    *)
    read_response ()

  let wait_for_event = function
    | `File_loaded ->
      (*Note: this is needed as mpv doesn't load the file before it returns success
        to the 'load-file' command - so if we 'seek' before this event it fails*)
      let success_event = "file-loaded" in
      read_response ~success_event ()
        
end

let print_response str = CCFormat.printf "%s\n%!" str

(** The script *)

let () =
  let files =
    process "find" [ "."; "-iname"; "*.mp3" ]
    |. shuf
    |> collect stdout
    |> lines 
  in
  while true do
    files |> CCList.iter (fun file ->
      CCFormat.printf "loading file %s\n%!" file;
      `Load file |> Mpv.send_cmd |> print_response;
      CCFormat.printf "waiting for 'file-loaded'\n%!";
      Mpv.wait_for_event `File_loaded |> print_response;
      CCFormat.printf "sending 'seek'\n%!";
      `Seek (`Absolute_percent 50.) |> Mpv.send_cmd |> print_response;
      CCFormat.printf "sending 'play'\n%!";
      `Play |> Mpv.send_cmd |> print_response;
      Unix.sleepf 0.03;
    )
  done




