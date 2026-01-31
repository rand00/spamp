## `spamp` - spam `mpv`
.. using OCaml as `bash` alternative. The scripts show how to use OCaml as a sensible `bash` alternative, to iterate through your
audio archive and play parts of each sound in a random sequence using `mpv`. 
* `spamp_simple.ml` shows how you would do this in a simple way, like one would do in `bash`
* `spamp.ml` implements more complex handling of the `mpv` socket protocol using OCaml, to spam much faster 

## the history behind this
My good friend Valdemar showed me a simple one-liner `bash` script that made some interesting rhythms by iterating through his music samples archive.
I saw a bunch of stuff that could become better:
* there were unintentional bugs because of `bash` expanding wildcards before they were given to `find`
* `shuf` was run inside a while-loop - which should be better to have on the outside of the loop:
  * to avoid the bad timecomplexity of shuf going through all files
  * to avoid playing the same sounds randomly again
  * to avoid `shuf` seemingly running out of randomness at some point
* `mpv` could be run as a server, where one loads new files via a socket-connection

But `bash` wouldn't do this easily... so I wanted to make an OCaml library to do this - but instead found the excellent [`feather`](https://github.com/charlesetc/feather) library. 
Advantages of OCaml over `bash` here:
* you can avoid the bad semantics of `bash` with whitespace inside variables and how you need to iterate through this
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

Install OCaml 4.14.2:
```bash
opam switch install 4.14.2
```

Then clone this repository and install dependencies and `mtag`:
```bash
git clone https://github.com/rand00/spamp
cd spamp
opam install utop containers feather 
```

Make the scripts executeable (if not already):
```bash
chmod u+x *.ml
```

Note that for running `spamp.ml` you also need `mpv` to run as a server in the background: 
```bash
mpv --idle --pause --keep-open --input-ipc-server=/tmp/valdefars_sock
```

## implementation
The `*.ml` files are setup to be runnable like `bash` scripts calling into the OCaml package 
manager `opam` to select the right *opam switch* that contains the library dependencies. Specifically we are using the library `feather` 
to make OCaml get the concise piping and shell semantics you are used to in bash - but which avoids the bull**** semantics of iterating 
through variables containing whitespace or *bash-lists*. 






























