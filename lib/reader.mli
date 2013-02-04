(** [Reader] is Async's main API for buffered input from a file descriptor.  It is the
    analog of [Core.Std.In_channel].

    Each reader has an internal buffer, which is filled via [read()] system calls when
    data is needed to satisfy a [Reader.read*] call.

    Each of the read functions returns a deferred that will become determined when the
    read completes.  It is an error to have two simultaneous reads.  That is, if one calls
    a read function, one should not call another read function until the first one
    completes.

    If the file descriptor underlying a reader is closed, the reader will return EOF
    (after all the buffered bytes have been read).

    Any [Reader.read*] call could, rather than determine its result, send an exception to
    the monitor in effect when [read] was called.  Such exceptions can be handled in the
    usual way by using [try_with], e.g.:

    {[
      try_with (fun () -> Reader.read reader ...)
    ]}
*)

open Core.Std
open Import

module Read_result : sig
  type 'a t = [ `Ok of 'a | `Eof ] with bin_io, sexp

  include Monad.S with type 'a t := 'a t
end

module Id : Unique_id

type t with sexp_of

include Invariant.S with type t := t

(** [io_stats] Overall IO statistics for all readers *)
val io_stats : Io_stats.t

(** [last_read_time t] returns time of the most recent [read] system call that
    returned data. *)
val last_read_time : t -> Time.t

(** [stdin] is a reader for file descriptor 0.  It is lazy because we don't want
   to create it in all programs that happen to link with async. *)
val stdin : t Lazy.t

(** [open_file file] opens [file] for reading and returns a reader reading from it. *)
val open_file : ?buf_len:int -> string -> t Deferred.t

(** [transfer t pipe_w] transfers data from [t] into [pipe_w] one chunk at a time
    (whatever is read from the underlying file descriptor without post-processing).  The
    result becomes determined after reaching EOF on [t] and the final bytes have been
    transferred.

    This function will normally not be needed (see [pipe]). *)
val transfer : t -> string Pipe.Writer.t -> unit Deferred.t

(** [pipe t] returns the reader end of a pipe that will continually be filled with chunks
    of data from the underlying Reader.t.  When the reader reaches EOF or the pipe is
    closed, [pipe] closes the the reader, and then after the reader close is finished,
    closes the pipe. *)
val pipe : t -> string Pipe.Reader.t

(** [create ~buf_len fd] creates a new reader that is reading from [fd].
    @param access_raw_data default = None if specified this function will
    be given access to the raw bits as they are read by the reader. No
    guarantee of granularity is made. *)
val create : ?buf_len:int -> Fd.t -> t

val of_in_channel : in_channel -> Fd.Kind.t -> t

(** [with_file file f] opens [files], creates a reader with it, and passes the reader to
    [f].  It closes the reader when the result of [f] becomes determined, and returns
    [f]'s result.

    NOTE, you need to be careful that all your IO is done when the deferred you return
    becomes determined. If for example, you use [with_file], and call [lines], make sure
    you return a deferred that becomes determined when the EOF is reached on the pipe,
    not when you get the pipe (because you get it straight away). *)
val with_file
  :  ?buf_len:int
  -> ?exclusive:bool (* defaults to false *)
  -> string
  -> f:(t -> 'a Deferred.t)
  -> 'a Deferred.t

(** [close t] prevents further use of [t] and closes [t]'s underlying file descriptor.
    The result of [close] becomes determined once the underlying file descriptor has been
    closed.  It is an error to call other operations on [t] after [close t] has been
    called, except that calls of [close] subsequent to the original call to [close] will
    return the same deferred as the original call.

    [close_finished t] becomes determined after [t]'s underlying file descriptor has been
    closed, i.e. it is the same as the result of [close].  [close_finished] differs from
    [close] in that it does not have the side effect of initiating a close.

    [is_closed t] returns [true] iff [close t] has been called.

    [with_close t ~f] runs [f ()], and closes [t] after [f] finishes or raises. *)
val close          : t -> unit Deferred.t
val close_finished : t -> unit Deferred.t
val is_closed      : t -> bool
val with_close     : t -> f:(unit -> 'a Deferred.t) -> 'a Deferred.t

(** [id t] @return a name for this reader that is unique across all
    instances of the reader module. *)
val id : t -> Id.t

(** [fd t] @return the Fd.t used to create this reader *)
val fd : t -> Fd.t

(** [read t ?pos ?len buf] reads up to [len] bytes into buf, blocking
    until some data is available or end-of-input is reached.  The resulting
    [i] satisfies [0 < i <= len]. *)
val read : t -> ?pos:int -> ?len:int -> string -> int Read_result.t Deferred.t

(** [read_one_chunk_at_a_time_until_eof t ~handle_chunk] reads into [t]'s internal buffer,
    and whenever bytes are available, applies [handle_chunk] to them.  It waits to read
    again until the deferred returned by [handle_chunk] becomes determined. *)
type 'a read_one_chunk_at_a_time_until_eof_result =
[ `Eof
| `Stopped of 'a
(** [`Eof_with_unconsumed_data s] means that [handle_chunk] returned [`Consumed (c, _)]
    and left data in the reader's buffer (i.e. [c < len]), and that the reader reached eof
    without reading any more data into the buffer; hence the data in the buffer was never
    consumed (and never will be, since the reader is at eof). *)
| `Eof_with_unconsumed_data of string
]
with sexp_of

val read_one_chunk_at_a_time_until_eof
  :  t
  -> handle_chunk:(Bigstring.t
                   -> pos:int
                   -> len:int
                   -> [ `Stop of 'a
                      (** [`Continue] means that [handle_chunk] has consumed all [len]
                          bytes. *)
                      | `Continue
                      (** [`Consumed (c, need)] means that [c] bytes were consumed and
                          [need] says how many bytes are needed (including the data
                          remaining in the buffer after the [c] were already consumed).
                          It is an error if [c < 0 || c > len].  For [`Need n], it is an
                          error if [n < 0 || c + n <= len]. *)
                      | `Consumed of int * [ `Need of int
                                           | `Need_unknown
                                           ]
                      ] Deferred.t)
  -> 'a read_one_chunk_at_a_time_until_eof_result Deferred.t

(** [read_substring t ss] reads up to [Substring.length ss] bytes into [ss],
    blocking until some data is available or Eof is reched.  The resulting [i]
    satisfies [0 < i <= Substring.length ss]. *)
val read_substring : t -> Substring.t -> int Read_result.t Deferred.t

val read_bigsubstring : t -> Bigsubstring.t -> int Read_result.t Deferred.t

val read_char : t -> char Read_result.t Deferred.t

(** [really_read t buf ?pos ?len] reads until it fills [len] bytes of [buf]
    starting at [pos] or runs out of input.  In the former case it returns `Ok.
    In the latter, it returns [`Eof n] where [n] is the number of bytes that
    were read before end of input, and [0 <= n < String.length ss]. *)
val really_read :
  t -> ?pos:int -> ?len:int -> string
  -> [ `Ok
     | `Eof of int ] Deferred.t

val really_read_substring :
  t -> Substring.t
  -> [ `Ok
     | `Eof of int (* 0 <= i < Substring.length ss *)] Deferred.t

val really_read_bigsubstring :
  t -> Bigsubstring.t
  -> [ `Ok
     | `Eof of int (* 0 <= i < Substring.length ss *)] Deferred.t

(** [read_until t pred ~keep_delim] reads until it hits a delimiter [c] such that:

    - if [pred = `Char c'] then [c = c']
    - if [pred = `Pred p] then [p c]

    [`Char c'] is equivalent to [`Pred (fun c -> c = c')] but the underlying
    implementation is more efficient, in particular it will not call a function on every
    input character.

    [read_until] returns a freshly-allocated string consisting of all the characters read
    and optionally including the delimiter as per [keep_delim]. *)
val read_until
  :  t
  -> [`Pred of (char -> bool) | `Char of char]
  -> keep_delim:bool
  ->  [ `Ok of string
      | `Eof_without_delim of string
      | `Eof
      ] Deferred.t

(** just like [read_until], except you have the option of specifiying a maximum number of
    chars to read. *)
val read_until_max :
  t
  -> [`Pred of (char -> bool) | `Char of char]
  -> keep_delim:bool
  -> max:int
  -> [ `Ok of string
     | `Eof_without_delim of string
     | `Eof
     | `Max_exceeded of string
     ] Deferred.t

(** [read_line t] reads up to, and including the next newline (\n) character and returns a
    freshly-allocated string containing everything up to but not including the newline
    character.  If [read_line] encounters EOF before the newline char then everything read
    up to but not including EOF will be returned as a line. *)
val read_line : t -> string Read_result.t Deferred.t

(** [really_read_line ~wait_time t] reads up to, and including the next newline (\n)
    character and returns an optional, freshly-allocated string containing everything up
    to but not including the newline character.  If [really_read_line] encounters EOF
    before the newline char, then a time span of [wait_time] will be used before the input
    operation is retried.  If the descriptor is closed, [None] will be returned. *)
val really_read_line : wait_time : Time.Span.t -> t -> string option Deferred.t

type 'a read = ?parse_pos : Sexp.Parse_pos.t -> 'a

(** [read_sexp t] reads the next sexp. *)
val read_sexp : (t -> Sexp.t Read_result.t Deferred.t) read

(** [read_sexps t] reads all the sexps and returns them as a pipe.  When the reader
    reaches EOF or the pipe is closed, [read_sexps] closes the the reader, and then
    after the reader close is finished, closes the pipe. *)
val read_sexps : (t -> Sexp.t Pipe.Reader.t) read

(** [read_bin_prot ?max_len t bp_reader] reads the next binary protocol message using
    binary protocol reader [bp_reader].  The format is the "size-prefixed binary
    protocol", in which the length of the data is prefixed as a 64-bit integer to the
    data.  This is the format that Writer.write_bin_prot writes. *)
val read_bin_prot
  :  ?max_len:int
  -> t
  -> 'a Bin_prot.Type_class.reader
  -> 'a Read_result.t Deferred.t

(** Read and return a buffer containing one marshaled value, but don't unmarshal it. You
    can just call Marshal.from_string on the string, and cast it to the desired type
    (preferrably the actual type). similar to Marshal.from_channel, but suffers from the
    String-length limitation (16MB) on 32bit platforms. *)
val read_marshal_raw : t -> string Read_result.t Deferred.t

(** Like read_marshal_raw, but unmarshal the value after reading it *)
val read_marshal : t -> _ Read_result.t Deferred.t

(** [recv t] returns a string that was written with Writer.send *)
val recv : t -> string Read_result.t Deferred.t

(** [read_all t read_one] returns a pipe that receives all values read from [t] by
    repeatedly using [read_one t].  When the reader reaches EOF, it closes the reader,
    and then after the reader close is finished, closes the pipe. *)
val read_all : t -> (t -> 'a Read_result.t Deferred.t) -> 'a Pipe.Reader.t

(** [lines t] reads all the lines from [t] and puts them in the pipe, one line per pipe
    element.  When the reader reaches EOF or the pipe is closed, [lines] closes the the
    reader, and then after the reader close is finished, closes the pipe. *)
val lines : t -> string Pipe.Reader.t

(** [contents t] returns the string corresponding to the full contents (up to EOF) of the
    reader.  [contents] closes [t] before returning the string.*)
val contents : t -> string Deferred.t

(** [file_contents file] returns the string with the full contents of the file *)
val file_contents : string -> string Deferred.t

(** [load_sexp ?exclusive file ~f] loads and convert the S-expression in a given [file]
    using [f], and returns the deferred conversion result as a variant of either [Ok res]
    or [Error exn] otherwise.  This function provides accurate error locations for failed
    conversions. *)
val load_sexp
  : ?exclusive:bool (* defaults to false *)
  -> string
  -> (Sexp.t -> 'a)
  -> 'a Or_error.t Deferred.t
val load_sexp_exn
  : ?exclusive:bool (* defaults to false *)
  -> string
  -> (Sexp.t -> 'a)
  -> 'a Deferred.t

(** [load_sexps file ~f] load and convert the S-expressions in a given [file] using [f],
    and return the deferred list of conversion results as variants of either [Ok res] or
    [Error exn] otherwise.  This function is as efficient as [load_sexps] followed by
    conversion if there are no errors, but provides accurate error locations for failed
    conversions. *)
val load_sexps
  :  ?exclusive:bool (* defaults to false *)
  -> string
  -> (Sexp.t -> 'a)
  -> 'a list Or_error.t Deferred.t

val load_sexps_exn
  : ?exclusive:bool (* defaults to false *)
  -> string
  -> (Sexp.t -> 'a)
  -> 'a list Deferred.t
