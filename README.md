# One-shot algebraic effect handling and asynchronous I/O in Lua

This library is work in progress. It contains several modules for effect
handling as well as lightweight threads (fibers) and asynchronous I/O based on
the effect handling system.

## Module overview (dependency tree)

  * **`effect`** (effect handling)
      * **`fiber`** (lightweight threads)
          * `waitio_fiber`
      * **`waitio`** (waiting for I/O)
          * **`waitio_blocking`** (waiting for I/O through blocking)
          * **`waitio_fiber`** (waiting for I/O utilizing fibers)
          * **`eio`** (basic I/O)
  * ***`lkq`*** ([`kqueue`] interface)
      * `waitio_blocking`
      * `waitio_fiber`
  * ***`nbio`*** (basic non-blocking I/O interface written in C)
      * `eio`

[`kqueue`]: https://man.freebsd.org/cgi/man.cgi?kqueue

Names of modules written in C are marked as *italic* in the above tree.
Duplicates due to multiple dependencies are non-bold.

## Module `effect`

Module for algebraic effect handling implemented in pure Lua with no
dependencies other than Lua's standard library.

The `effect` module allows to perform an effect (similar to an exception),
which will then bubble up the stack until it hits a handler that "catches" the
effect. Distinct from exception handlers, an effect handler may decide to
*resume* the program flow at the position where the effect has been performed
and also optionally modify the final return value of that continuation.

The following example demonstrates control flow using effects. It prints out
the two lines "`Hello`" and "`World`":

```
local effect = require "effect"

local increment_result = effect.new("increment_result")

local function foo()
  increment_result("Hello")
end

local retval = effect.handle(
  {
    [increment_result] = function(resume, message)
      print(message)
      return resume() + 1
    end,
  },
  function()
    foo()
    print("World")
    return 5
  end
)

assert(retval == 6)
```

The module provides the following functions:

  * **`effect.new(name)`** returns an object that is suitable to be used as an
    effect. Note that any other object can be used as an effect as well, but an
    object `x` returned by this function is automatically callable such that
    `x(...)` is a short form for `effect.perform(x, ...)`. Moreover, the
    generated object has a string representation (using the `__tostring`
    metamethod) based on the `name` and a suffix, which may be useful for
    debugging.

  * **`effect.perform(eff, ...)`** performs the effect `eff` with optional
    arguments. May or may not return.

  * **`effect.handle(handlers, action, ...)`** calls the `action` function with
    given arguments and, during execution of the action function, handles those
    effects which are listed as key in the `handlers` table. The value in the
    handlers table is the corresponding handler, which is is a function that
    retrieves a continuation function (usually named "`resume`") as first
    argument followed by optional arguments that have been passed to the
    `effect.perform` function. Handlers in the `handlers` table passed to the
    `effect.handle` function may resume the action only *before* returning.
    Optional arguments passed to the continuation function are returned by
    `effect.perform`.

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

In many cases, tail-call elimination can be performed. If an effect handler
installed with `effect.handle` exits with `return resume(...)`, or if an effect
handler installed with `effect.handle_once` exits with
`return effect.handle_once(handlers, resume, ...)`, then the corresponding
effect may be performed and over again, without causing a stack overflow.

Sometimes an effect hander may wish to execute code in the context of the
performer of the effect (e.g. to perform other effects in *that* context). To
achieve this, it is possible to pass to the continuation function (`resume`)
the special value **`effect.call`** followed by a function (or callable object)
`f` and optional arguments. In that case, `effect.perform` will not return
those values but call the function `f` (with given arguments) and return `f`'s
return values.

## Module `fiber`

Module for lightweight threads implemented in pure Lua by using the `effect`
module.

Note that it is required to run `fiber.main(action, ...)` before any other
functions of this module can be used. All other functions *must* be called from
within the `action` function.

The module provides the following functions:

  * **`fiber.main(action, ...)`** runs the `action` function with given
    arguments as main fiber which may spawn additional fibers. `fiber.main`
    returns as soon as `action` returns (i.e. won't wait for spawned fibers to
    terminate).

  * **`fiber.scope(action, ...)`** runs the `action` function with given
    arguments and handles spawning (but still requires `fiber.main` to be
    already running). When `action` terminates all spawned fibers within the
    action which are still running are automatically killed. In turn, this
    allows any effects caused by spawned fibers to be handled by effect
    handlers that have been installed before calling `fiber.scope`.

  * **`fiber.current()`** obtains a handle for the currently running fiber.

  * **`fiber.sleep()`** puts the currently running fiber to sleep.

  * **`fiber.yield()`** allows the main loop to execute a different fiber.

  * **`fiber.spawn(action, ...)`** runs the `action` function with given
    arguments in a separate fiber and returns a handle for the spawned fiber.

  * **`fiber.pending()`** returns `true` if there is any woken fiber. This
    function can be used to check if it's okay to make a main event loop wait
    for I/O (e.g. by using an OS call that blocks execution).

  * **`fiber.handle(handlers, action, ...)`** is equivalent to
    `effect.handle(handlers, fiber.scope, action, ...)` and acts like
    `effect.handle` but additionally applies the effect handling to all spawned
    fibers within the `action` function. Any spawned fibers within `action` get
    killed once `action` returns.

A fiber handle `f` provides the following attributes and methods:

  * **`f:wake()`** wakes up fiber `f` if it has not terminated yet.

  * **`f:kill()`** kills fiber `f` if it has not terminated yet.

  * **`f.results`** is a table containing the return value of the action
    function of fiber `f`, or `nil` if the action has not terminated with a
    return value yet or if it has been killed.

  * **`f.killed`** is `true` if fiber `f` got killed manually or due to a
    non-resuming effect or due to an error before its action function could
    return; otherwise `false`.

  * **`f:await()`** puts the currently running fiber to sleep until fiber `f`
    has terminated. The method then returns its return values. If the awaited
    fiber got killed, the current fiber will be killed as well.

  * **`f:try_await()`** puts the currently running fiber to sleep until fiber
    `f` has terminated. If `f` was killed, this method returns `false`,
    otherwise returns `true` followed by `f`'s return values.

## Module `waitio`

Module using effects to wait for I/O.

The module provides several effects only (no handlers):

  * **`waitio.deregister_fd(fd)`** deregisters file descriptor `fd`, which
    should be done before closing a file descriptor that is currently being
    waited on.

  * **`waitio.wait_fd_read(fd)`** waits until file descriptor `fd` is ready for
    reading.

  * **`waitio.wait_fd_write(fd)`** waits until file descriptor `fd` is ready
    for writing.

  * **`waitio.catch_signal(sig)`** starts listening for signal `sig` and
    returns a callable handle, which, upon calling, waits until a signal has
    been delivered.

## Module `waitio_fiber`

Module providing handling of the effects defined in the `waitio` module using
`kqueue` system/library calls (through the `lkq` Lua module written in C) and
fibers to avoid blocking.

The module provides the following functions:

  * **`waitio_fiber.run(action, ...)`** runs the `action` function while the
    effects of the `waitio` module are handled with the help of fibers provided
    by the `fiber` module. This function does not install a fiber scheduler and
    thus must be called within the context of `fiber.main`.

  * **`waitio_fiber.main(action, ...)`** is equivalent to
    `fiber.main(waitio_fiber.run, action, ...)`.

Example use:

```
local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"

fiber.main(
  waitio_fiber.run,
  function()
    -- code here may use waitio's functions
  end
)
```

Or:

```
local waitio_fiber = require "waitio_fiber"

waitio_fiber.main(
  function()
    -- code here may use waitio's functions
  end
)
```

## Module `eio`

Module for basic I/O, using non-blocking I/O (through the `nbio` Lua module
written in C) and the `waitio` module to wait for I/O.

This module generic in regard to how "waiting" is implemented. In particular,
`eio` does not depend on the `fiber` module, and whenever there is a need to
wait for I/O, the effects of the `waitio` module are performed. In order to use
`eio`, appropriate handlers have to be installed. One way to achieve this is to
use `waitio_fiber.main(action, ...)` as in the following example:

```
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

waitio_fiber.main(
  function()
    eio.stdout:flush("Hello World!\n")
  end
)
```

Available functions:

  * **`eio.open(path, flags)`** opens a file at the given `path` and returns an
    I/O handle on success (`nil` and error message otherwise). The optional
    `flags` argument is a string containing a comma separated list of one or
    more of the following flags:
      * `r`: read-only
      * `w`: write-only
      * `rw`: read and write
      * `append`: each write appends to file
      * `create`: create file if not existing
      * `truncate`: if existing, truncate file to a size of zero
      * `exclusive`: report error if file already exists

  * **`eio.localconnect(path)`** initiates opening a local socket connection
    with the socket on the filesystem given by `path` and returns an I/O handle
    on success (`nil` and error message otherwise).

  * **`eio.tcpconnect(host, port)`** initiates opening a TCP connection to the
    given `host` and `port` and returns an I/O handle on success (`nil` and
    error message otherwise).

  * **`eio.locallisten(path)`** listens for connections to a local socket given
    by `path` on the filesystem and returns a listener handle on success (`nil`
    and error message otherwise).

  * **`eio.tcplisten(host, port)`** runs a TCP server at the given interface
    (`host`) and `port` and returns a listener handle on success (`nil` and
    error message otherwise).

  * **`eio.execute(file, ...)`** executes `file` with optional arguments in a
    subprocess and returns a child handle on success (`nil` and error message
    otherwise). Note that no shell is involved unless `file` is a shell. The
    search path for executables (`PATH` environment variable) applies.

Note that name resolution is blocking, even though any other I/O is handled
async.

A listener handle `l` provides the following methods:

  * **`l:accept()`** waits until an incoming connection or I/O error. Returns
    an I/O handle on success (`nil` and error message otherwise).

  * **`l:close()`** closes the listener. This function returns immediately and
    does not report any errors.

A child handle `c` provides the following attributes and methods:

  * **`c:kill(sig)`** kills the process with signal number `sig` (defaults to
    `9` for SIGKILL).

  * **`c:wait()`** waits until the process has terminated and returns a
    positive exit code or a negated signal number, depending on how the process
    terminated.

  * **`c.stdin`**, **`c.stdout`**, **`c.stderr`** are I/O handles connected
    with the process' stdin, stderr, and stdout, respectively.

An I/O handle `h` provides the following attributes and methods:

  * **`h:read(maxlen, terminator)`** waits repeatedly until `maxlen` bytes
    could be read, a `terminator` byte was read, EOF occurred, or an I/O error
    occurred (whichever happens first). If all bytes or some bytes followed by
    EOF could be read, it returns a string containing the read data. If EOF
    occurred before any bytes could be read, returns the empty string (`""`).
    Returns `nil` and an error message in case of an I/O error. This method may
    read more bytes than requested and/or read beyond the terminator byte and
    will then buffer that data for the next invocation of the `read` method.

  * **`h:read_unbuffered(maxlen)`** waits until some data is available for
    reading or an I/O error occurred. It then reads a maximum number of
    `maxlen` bytes. The return value may be shorter than `maxlen` even if there
    was no EOF. However, the empty string (`""`) is only returned on EOF and if
    no bytes could be read before the EOF occured. Returns `nil` and an error
    message in case of an I/O error.

  * **`h:read_nonblocking(maxlen)`** acts like `h:read_unbuffered(maxlen)` but
    returns immediately with an empty string if no data is available. To avoid
    ambiguities, EOF is indicated by returning `false` (and an error message).
    I/O errors are indicated by `nil` and an error message.

  * **`h:write(data)`** waits repeatedly until all `data` could be stored in a
    buffer and/or written out. Returns `true` on success, `false` and an error
    message in case of a disconnected receiver (broken pipe), and `nil` and an
    error message in case of other I/O errors.

  * **`h:flush(data)`** waits repeatedly until all buffered data and the
    optionally passed `data` could be written out. Returns `true` on success,
    `false` and an error message in case of a disconnected receiver (broken
    pipe), and `nil` and an error message in case of other I/O errors.

  * **`h:shutdown()`** closes the sending part but not the receiving part of a
    connection. This function returns immediately and may discard any
    non-flushed data. Returns `true` on success, or `nil` and an error message
    otherwise.

  * **`h:close()`** closes the handle (sending and receiving part). Any
    non-flushed data may be discarded. This function returns immediately and
    does not report any errors.

There are three preopened handles **`eio.stdin`**, **`eio.stdout`**, and
**`eio.stderr`**, which may exhibit blocking behavior, however.

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

The I/O related modules of this library support POSIX operating systems (Linux,
BSD, etc.) only. In particular, there is no support for Microsoft Windows.
However, it is possible to use the `effect` and `fiber` modules on Windows,
since those are implemented in pure Lua and do not have any operating system
dependencies.

## Related work

See also ["One-shot Algebraic Effects as Coroutines"](http://logic.cs.tsukuba.ac.jp/~sat/pdf/tfp2020-postsymposium.pdf), 21st International Symposium on Trends in Functional Programming (TFP), 2020, (post symposium) by Satoru Kawahara and Yukiyoshi Kameyama, Department of Computer Science, University of Tsukuba, Japan, who provide theoretic background and also presented a similar [implementation](https://github.com/Nymphium/eff.lua) of (one-shot) algebraic effects in Lua based on coroutines.
