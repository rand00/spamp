Tillykke med fødselsdagen Valdefar (:

## `spamp`
Spam `mpv` using OCaml as `bash` alternative. The scripts show how to use OCaml as a sensible `bash` alternative, to iterate through your
audio archive and play parts of each sound in a random sequence using `mpv`. 
* `spamp_simple.ml` shows how you would do this in a simple way, like one would do in `bash`
* `spamp.ml` implements more complex handling of the `mpv` socket protocol using OCaml, to spam much faster 

## why
My good friend Valdemar showed me a simple one-liner `bash` script that made some interesting rhythms by iterating through his music samples archive.
A bunch of stuff could be better, enabling faster spamming:
* there were unintentional bugs because of `bash` expanding wildcards before they were given to `find`
* `shuf` was run inside a while-loop - which should be better to have on the outside of the loop:
  * to avoid the bad timecomplexity of shuf going through all files
  * to avoid playing the same sounds randomly again
  * to avoid `shuf` seemingly running out of randomness at some point
* `mpv` could be run as a server instead of per file, where one loads new files via its socket protocol

But `bash` wouldn't make this easy... so I wanted to make an OCaml library to do this - but instead found the [`feather`](https://github.com/charlesetc/feather) library. 
Advantages of OCaml over `bash`:
* you can avoid the bad semantics of `bash` with [whitespace inside variables and how you need to iterate through this](https://superuser.com/questions/284187/how-to-iterate-over-lines-in-a-variable-in-bash)
* you can keep open a socket-connection to `mpv` instead of reconnecting on each loop-iteration with `socat`
* you can avoid confusion about wild-card expansions etc. when running stuff like `find`
* while you don't loose
  * the simple piping syntax of `bash`
  * the script-semantics of `bash` (by using `#! /usr/bin/env opam exec -- utop`)

## running
[Install](https://opam.ocaml.org/doc/Install.html) `opam`, the OCaml package manager.
E.g. on Arch Linux:
```bash
pacman -S opam
opam init
```

Install OCaml:
```bash
opam switch create 4.14.2+options
```

Then clone this repository and install dependencies:
```bash
git clone https://github.com/rand00/spamp
cd spamp
opam install utop containers feather 
```

Note that for running `spamp.ml` you also need `mpv` to run as a server in the background: 
```bash
mpv --loop --idle --keep-open --audio-display=no --input-ipc-server=/tmp/valdefars_sock
```

Make the changes you want to `spamp.ml` or `spamp_simple.ml` in your shell, and execute them as scripts.

## notes on the script semantics
The `*.ml` files are setup to be runnable like `bash` scripts calling into the OCaml package 
manager `opam` to select the right *opam switch* that contains the library dependencies. Specifically we are using the library `feather` 
to make OCaml get the concise piping and shell semantics you are used to in bash - but which avoids the bull**** semantics of iterating 
through variables containing whitespace or *bash-lists*. 

At the top of `spamp.ml` you'll see:
```ocaml
#!/usr/bin/env -S opam exec --switch=4.14.2+options -- utop

(** Utop REPL statements *)
#thread
#require "feather"
#require "containers"
#require "unix"
```

.. the first line calls into `opam`, chooses the *switch* and runs the `utop` REPL. Following is a set of `utop` 
statements that enable *threads* and load the library dependencies. After that follows ordinary OCaml code.
`utop` compiles the code as *bytecode* before running it, which happens quite fast. The runtime speed of the code
is also much faster than `bash` if you e.g. need to do any custom calculations within the script.






























