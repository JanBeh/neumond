# One-shot algebraic effect handling and asynchronous I/O in Lua

This library is work in progress.

## Module `effect`

Module for algebraic effect handling implemented in pure Lua.

  * **`effect.new(name)`** returns an object that is suitable to be used as an
    effect. Note that any other object can be used as an effect as well, but an
    object `x` returned by this function is automatically callable such that
    `x(...)` is a short form for `effect.perform(x, ...)`. Moreover, the
    generated object has a string representation (using the `__tostring`
    metamethod) based on the `name` and a suffix, which may be useful for
    debugging.

  * **`effect.perform(eff, ...)`** performs the effect `eff` with optional
    arguments.

  * **`effect.handle(handlers, action, ...)`** calls the `action` function with
    given arguments and, during execution of the action function, handles those
    effects which are listed as key in the `handlers` table. The value in the
    handlers table is the corresponding handler, which is is a function that
    retrieves a continuation function (usually named "`resume`") as first
    argument followed by optional arguments that have been passed to the
    `effect.perform` function. Handlers in the `handlers` table passed to the
    `effect.handle` function may resume the action only *before* returning.

  * **`effect.handle_once(handlers, action, ...)`** does the same as `handle`,
    but:

    * allows resuming the action also after a handler has returned;
    * does not automatically handle further effects after resuming the action.

  * **`effect.discontinue(resume)`** releases a continuation (`resume`) passed
    to an effect handler by unwinding the stack of the interrupted action. It
    is only applicable for continuations generated by `effect.handle_once` but
    must not be used for continuations generated by `effect.handle` as
    continuations generated by the `effect.handle` function are automatically
    discontinued when an effect handler returns (or throws an error) without
    resuming.

## Module `fiber`

Module for lightweight threads implemented in pure Lua by using the `effect`
module.

Note that it is required to run `fiber.main(action, ...)` before any other
functions of this module can be used. All other functions *must* be called from
within the `action` function.

The fiber module provides the following functions:

  * **`fiber.main(action, ...)`** runs the `action` function with given
    arguments as main fiber which may spawn additional fibers. It returns the
    return values of the main fiber when execution of all fibers has stopped
    (i.e. when all fibers have terminated or are sleeping).

  * **`fiber.scope(action, ...)`** runs the `action` function with given
    arguments and handles spawning (but still requires `fiber.main` to be
    already running). It does not return until all spawned fibers within the
    action have terminated, and, in turn, allows any effects caused by spawned
    fibers to be handled by effect handlers that have been installed before
    calling `fiber.scope`.

  * **`fiber.current()`** obtains a handle for the currently running fiber.

  * **`fiber.sleep()`** puts the currently running fiber to sleep.

  * **`fiber.yield()`** allows the main loop to execute a different fiber.

  * **`fiber.spawn(action, ...)`** runs the `action` function with given
    arguments in a separate fiber and returns a handle for the spawned fiber.

  * **`fiber.other()`** returns `true` if there is any other fiber. This
    function can be used to check if a main event loop should terminate, for
    example.

  * **`fiber.pending()`** returns `true` if there is any woken fiber. This
    function can be used to check if it's okay to make a main event loop wait
    for I/O (e.g. by using an OS call that blocks execution).

  * **`fiber.handle(handlers, action, ...)`** acts like `effect.handle` but
    additionally applies the effect handling to all spawned fibers. Thus
    `fiber.handle` will not return until all fibers have terminated.

A fiber handle `f` provides the following attributes and methods:

  * **`f:wake()`** wakes up fiber `f`.

  * **`f.results`** is a table containing the return value of the action
    function of fiber `f`, or `nil` if the action has not terminated yet or if
    it has been killed due to a non-resuming effect.

  * **`f.killed`** is `true` if fiber `f` got killed due to a non-resuming
    effect before its action function could return; otherwise `false`.

  * **`f:await()`** puts the currently running fiber to sleep until fiber `f`
    has terminated. The method then returns its return values. If the awaited
    fiber got killed due to a non-resuming effect, the current fiber will be
    killed as well.

## Module `eio`

Module for asynchronous I/O, working with the `effect` and `fiber` modules.
The usual way to use this module is:

```
local effect = require "effect"
local fiber = require "fiber"
local eio = require "eio"

fiber.main(
  eio.main,
  function()
    -- code goes here
  end
)
```

Available functions:

  * **`eio.stdin()`**, **`eio.stdout()`**, **`eio.stderr()`** open the standard
    input, output, or error stream, respectively and return an I/O handle.

  * **`eio.tcpconnect(host, port)`** initiates opening a TCP connection to the
    given `host` and `port` and returns an I/O handle on success (`nil` and
    error message otherwise).

  * **`eio.tcplisten(host, port)`** runs a TCP server at the given interface
    (`host`) and `port` and returns a listener handle on success (`nil` and
    error message otherwise).

Note that name resolution is blocking, even though any other I/O is handled
async.

A listener handle `l` provides the following attributes and methods:

  * **`l.fd`** is the underlying file descriptor.

  * **`l.accept()`** puts the currently running fiber to sleep until an
    incoming connection or I/O error. Returns an I/O handle on success (`nil`
    and error message otherwise).

An I/O handle `h` provides the following attributes and methods:

  * **`h.fd`** is the underlying file descriptor.

  * **`h:read(maxlen, terminator)`** repeatedly puts the currently running
    fiber to sleep until `maxlen` bytes could be read, a `terminator` byte was
    read, EOF occurred, or an I/O error occurred (whichever happens first). If
    at least some bytes could be read, it returns a string containing the read
    data. This method may read more bytes than requested and/or read beyond the
    terminator byte and will then buffer that data for the next invocation of
    the `read` method.

  * **`h:write(data)`** repeatedly puts the currently running fiber to sleep
    until all `data` could be written out and/or be stored in a buffer.

  * **`h:flush()`** repeatedly puts the currently fiber to sleep until all
    buffered data could be written out.

  * **`h:read_unbuffered(maxlen)`** puts the currently running fiber to sleep
    until some data is available for reading or an I/O error occurred. It then
    reads a maximum number of `maxlen` bytes.

  * **`h:write_unbuffered(data, from, to)`** puts the currently running fiber
    to sleep until some data can be written or an I/O error occurred. If
    possible, it writes some bytes of `data`, optionally from a given starting
    position (`from`) to a maximum ending position (`to`) within the `data`,
    and returns the number of bytes written.

The methods for reading and writing return `nil` and an error message in case
of I/O errors, but `false` and an error message in case of EOF (when reading)
or broken pipe (when writing).

## Caveats

On Linux, [`libkqueue`] is needed. Some older versions of this library do not
properly support waiting for either reading or writing on the same file
descriptor at the same time. See the [release notes] for `libkqueue`
version 2.4.0. Unfortunately, some Linux distributions ship with old versions
of that library. For example, Ubuntu 22.04 LTS ships with version 2.3.1, which
is subject to this bug.

[`libkqueue`]: https://github.com/mheily/libkqueue
[release notes]: https://github.com/mheily/libkqueue/releases/tag/v2.4.0

Also note, that the provided `Makefile` is a BSD Makefile. Use `bmake` instead of `make` on Linux platforms.

## Related work

See also ["One-shot Algebraic Effects as Coroutines"](http://logic.cs.tsukuba.ac.jp/~sat/pdf/tfp2020-postsymposium.pdf), 21st International Symposium on Trends in Functional Programming (TFP), 2020, (post symposium) by Satoru Kawahara and Yukiyoshi Kameyama, Department of Computer Science, University of Tsukuba, Japan, who provide theoretic background and also presented a similar [implementation](https://github.com/Nymphium/eff.lua) of (one-shot) algebraic effects in Lua based on coroutines.
