# Lem

This is a preliminary release of Lem which is not yet feature complete.
It is released under the BSD 3-clause license, though some of the OCaml
library files are released under the GNU Library GPL.

Lem depends on OCaml (http://caml.inria.fr/). Lem is tested against OCaml
3.12.1. Earlier versions might or might not work.

To build Lem run make in Lem’s top-level directory. This builds the executable
lem, and places a symbolic link to it in Lem’s root directory. Now set the
`LEMLIB` environment variable to `path_to_lem/library`, or alternately pass the
`-lib path_to_lem/library` flag to lem when you run it. This tells Lem where to
find its library of types for HOL/Isabelle/OCaml/Coq built-in functions.

Please see the manual at http://www.cl.cam.ac.uk/~so294/lem/lem-manual.pdf or
http://www.cl.cam.ac.uk/~so294/lem/lem-manual.html.
