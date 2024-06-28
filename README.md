# One-shot algebraic effect handling and asynchronous I/O in Lua

This library is a proof of concept for implementing:

  * *effect handling* on top of Lua's coroutines (in pure Lua)
  * and on top of that effect handling system (i.e. without further use of
    coroutines):
      * *fibers* (lightweight threads)
      * *asynchronous I/O*

Some basic asynchronous I/O support is given for:

  * byte streams over local sockets or TCP sockets
    (including TCP server support)
  * subprocesses with stdin, stdout, and stderr

Moreover, a small example for integration with a third party C library [libpq] is included (Lua module `pgeff`, written in C), allowing asynchronous communication with a [PostgreSQL] server.

Web applications can be built using the `scgi` module, which allows creating an [SCGI] application server using fibers and asynchronous I/O.

[libpq]: https://www.postgresql.org/docs/current/libpq.html
[PostgreSQL]: https://www.postgresql.org/
[SCGI]: https://en.wikipedia.org/wiki/Simple_Common_Gateway_Interface

## Overview of core modules (dependency tree)

  * **`effect`** (effect handling)
      * **`yield`** (abstract yield effect)
          * **`fiber`** (lightweight threads)
              * `wait_posix_fiber`
      * **`wait`** (platform independent waiting and synchronization)
          * **`wait_posix`** (waiting for I/O on POSIX platforms)
              * **`wait_posix_blocking`** (waiting through blocking)
              * **`wait_posix_fiber`** (waiting in a fiber environment)
              * **`eio`** (basic I/O)
  * ***`lkq`*** ([kqueue] interface)
      * `wait_posix_blocking`
      * `wait_posix_fiber`
  * ***`nbio`*** (basic non-blocking I/O interface written in C)
      * `eio`

[kqueue]: https://man.freebsd.org/cgi/man.cgi?kqueue

Names of modules written in C are marked as *italic* in the above tree.
Duplicates due to multiple dependencies are non-bold.

Further modules are `web`, `scgi`, `pgeff`, and `subprocess`. Those are not
documented in this documentation file; see source code instead.


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

The module provides the following functions and tables:

  * **`effect.new(name)`** returns an object that is suitable to be used as an
    effect. Note that any other object can be used as an effect as well, but an
    object `x` returned by this function is automatically callable such that
    `x(...)` is a short form for `effect.perform(x, ...)`. Moreover, the
    generated object has a string representation (using the `__tostring`
    metamethod) including the `name`, which may be useful for debugging.

  * **`effect.perform(eff, ...)`** performs the effect `eff` with optional
    arguments. May or may not return.

  * **`effect.handle(handlers, action, ...)`** calls the `action` function with
    given arguments and, during execution of the action function, handles those
    effects which are listed as key in the `handlers` table. The value in the
    handlers table is the corresponding handler, which is is a function that
    retrieves a continuation object (usually named "`resume`") as first
    argument followed by optional arguments that have been passed to the
    `effect.perform` function. Handlers may resume the action by calling the
    continuation, where optional arguments are returned by `effect.perform`
    then. If a continuation object needs to be called after an effect handler
    returned, it needs to be made persistent with the **`resume:persistent()`**
    method and can later be called or discontinued with
    **`resume:discontinue()`** (which closes all to-be-closed variables of the
    action). `effect.handle` returns the return values of the action function
    or the return values of the first invoked handler; return values of later
    invoked handlers or of the resumed action are returned by the corresponding
    `resume` calls.

  * **`effect.default_handlers`** is a table that maps an effect to a default
    handler function. If no effect handler but only a default handler is found,
    then the respective default handler function will be called with the
    arguments that have been passed to `effect.perform` (without a continuation
    object) and the return values of the default handler function are passed
    back to the caller of `effect.perform`.

  * **`effect.auto_traceback(action, ...)`** calls the `action` function with
    given arguments and ensures that thrown error objects are automatically
    stringified and get a stack trace appended. This function should be used
    as an outer wrapper if non-string error objects may be thrown, in order to
    see stack traces in case of unhandled errors.

Sometimes an effect hander may wish to execute code in the context of the
performer of the effect (e.g. to perform other effects in *that* context). To
achieve this, it is possible to use the method **`resume:call(func, ...)`**.
In that case, `effect.perform` will call the function `func` (with given
arguments) and return `func`'s return values.

## Module `yield`

Module for yielding. The module also serves as an effect, thus it is possible
to write:

```
local yield = require "yield"
yield()
```

The module's only effect (itself) is:

  * **`yield()`** allows an environment to yield and allow other program code
    to be executed. It is a no-op if no effect handler for `yield` is
    installed.

## Module `fiber`

Module for lightweight threads implemented in pure Lua by using the `effect`
module.

The module provides the following functions (of which some are implemented as
effects, but usually shouldn't be handled manually):

  * **`fiber.scope(action, ...)`** runs the `action` function with given
    arguments as a fiber and allows spawning additional fibers from within that
    fiber. `fiber.scope` returns as soon as `action` returns, in which case any
    spawned fibers within `action` (that have not terminated yet) are
    automatically killed. Note that effect handlers installed from within the
    `action` function do not affect spawned fibers unless spawning the fibers
    is further wrapped within another invocation of `fiber.scope`.

  * **`fiber.try_current()`** obtains a handle for the currently running fiber
    or returns `nil` if there is no fiber running (e.g. when called from
    outside `fiber.scope`'s `action` function).

  * **`fiber.current()`** obtains a handle for the currently running fiber.
    This function raises an error if there is no fiber running.

  * **`fiber.sleep()`** puts the currently running fiber to sleep. This
    function raises an error if there is no fiber running.

  * **`fiber.yield()`** allows the main loop to execute a different fiber.
    `fiber.yield` is simply an alias for module `yield` (which is an effect)
    and is a no-op if there is no fiber running.

  * **`fiber.suicide()`** kills the currently running fiber without providing a
    return value. It is equivalent to `fiber.current():kill()` but slightly
    faster. This function raises an error if there is no fiber running.

  * **`fiber.spawn(action, ...)`** runs the `action` function with given
    arguments in a separate fiber and returns a handle for the spawned fiber.
    This function raises an error if there is no fiber running, i.e. it must be
    called from within an `action` passed to `fiber.scope(action, ...)` or a
    previous `fiber.spawn(action, ...)` call.

  * **`fiber.pending()`** returns `true` if there is any woken fiber and
    `false` if no other fiber is woken (or if there is no fiber running at
    all). This function can be used to check if it's okay to make a main event
    loop wait for I/O (e.g. by using an OS call that blocks execution).

  * **`fiber.handle(handlers, action, ...)`** is equivalent to
    `effect.handle(handlers, fiber.scope, action, ...)` and acts like
    `effect.handle` but additionally applies the effect handling to all spawned
    fibers within the `action` function. Any spawned fibers within `action` get
    killed once `action` returns.

A fiber handle `f` provides the following attributes and methods:

  * **`f:wake()`** wakes up fiber `f` if it has not terminated yet.

  * **`f:kill()`** kills fiber `f` if it has not terminated yet.

  * **`f.results`** is a table containing the return value of the action
    function of fiber `f`, or `nil` if the action has not terminated yet, or
    `false` if it has been killed.

  * **`f:await()`** puts the currently running fiber to sleep until fiber `f`
    has terminated. The method then returns its return values. If the awaited
    fiber got killed, the current fiber will be killed as well.

  * **`f:try_await()`** puts the currently running fiber to sleep until fiber
    `f` has terminated. If `f` was killed, this method returns `false`,
    otherwise returns `true` followed by `f`'s return values.

## Module `wait`

Module for waiting and synchronization.

The module provides the following effects:

  * **`wait.select(...)`** waits until one of several listed events occurred.
    Each event is denoted by two arguments, i.e. the number of arguments passed
    to the select effect must be a multiple of two. This module only defines
    the following arguments:

      * `"handle"` followed by a handle returned by some other functions in
        this module

    But in a POSIX environment (see `wait_posix` module), other modules are
    expected to additionally support:

      * `"fd_read"` followed by an integer file descriptor
      * `"fd_write"` followed by an integer file descriptor
      * `"pid"` followed by an integer process ID

    When passing a handle `h` to `wait.select` by calling
    `wait.select(..., "handle", h, ...)`, then, after `wait.select` returns,
    `h.ready` indicates if the corresponding event occurred. `h.ready` must be
    reset to `false` when wanting to reuse the handle to wait for the next
    event (e.g. another occurrence of the next interval tick).

  * **`wait.timeout(seconds)`** starts a timer that elapses after given
    `seconds` and returns a callable handle that, when called, waits until the
    time has elapsed. The handle can be closed by storing it in a `<close>`
    variable that eventually goes out of scope to ensure cleanup (otherwise
    resource cleanup may be delayed until the time has elapsed or garbage
    collection happens). The callable handle may also be passed to the
    `wait.select` effect (after the string `"handle"`).

  * **`wait.interval(seconds)`** creates an interval with given `seconds` and
    returns a callable handle that, when called, waits until the next interval
    has elapsed. The handle can be closed by storing it in a `<close>` variable
    that eventually goes out of scope to ensure cleanup (otherwise resource
    cleanup may be delayed until garbage collection is performed). The callable
    handle may also be passed to the `wait.select` effect (after the string
    `"handle"`).

  * **`wait.notify()`** creates and returns a handle `sleeper` and a function
    `waker`. Calling `sleeper` will wait until `waker` has been called. The
    `waker` function may be called first, in which case the next call to
    `sleper` will return immediately. The `sleeper` handle may also be passed
    to the `wait.select` effect (after the string `"handle"`).

The module additionally provides the following function:

  * **`wait.mutex()`** returns a mutex `m`. Calling `m` locks the mutex and
    returns a guard that should be stored in a `<close>` variable which will
    unlock the mutex when closed.

A mutex protected section looks as follows:

```
local mutex = wait.mutex()
local func()
  local guard <close> = mutex()
  -- do stuff here
end
```

## Module `wait_posix`

Module providing additional effects and functions for waiting on POSIX
platforms.

The module provides the following effects:

  * **`wait_posix.catch_signal(sig)`** starts listening for signal `sig` and
    returns a callable handle, which, upon calling, waits until a signal has
    been delivered. The callable handle may also be passed to the `wait.select`
    effect (after the string `"handle"`).

  * **`wait_posix.deregister_fd(fd)`** must be performed before closing a file
    descriptor `fd` that is currently waited on. The effect resumes immediately
    with no value and can be safely performed multiple times on the same file
    descriptor and does not raise any error in that case. In a multi-fiber
    environment, a fiber waiting for reading from or writing to that file
    desciptor will be woken up.

Since, in a POSIX environment, `wait.select` is also expected to wait for file
descriptors and process IDs, the following convenience functions are provided:

  * **`wait_posix.wait_fd_read(fd)`** waits until file descriptor `fd` is ready
    for reading.

  * **`wait_posix.wait_fd_write(fd)`** waits until file descriptor `fd` is
    ready for writing.

  * **`wait_posix.wait_pid(pid)`** waits until process with process ID `pid`
    has terminated.

It is not allowed to wait for the same resource more than once in parallel
except for those resources where a handle for waiting is created. Reading and
writing are considered as two different resources in that matter. Where handles
are created for waiting, each handle must not be used more than once in
parallel. Violating these rules may result in an error or unspecified behavior,
e.g. deadlocks.

## Module `wait_posix_fiber`

Module providing handling of the effects defined in the `wait` and `wait_posix`
modules in a POSIX environment using `kqueue` system/library calls (through the
`lkq` Lua module written in C) and fibers to avoid blocking.

The module provides the following function:

  * **`wait_posix_fiber.main(action, ...)`** runs the `action` function while
    the effects of the `wait` and `wait_posix` modules are handled with the
    help of fibers provided by the `fiber` module.

Example use:

```
local wait_posix_fiber = require "wait_posix_fiber"

wait_posix_fiber.main(
  function()
    -- code here may perform "wait" or "wait_posix" effects (e.g. through "eio"
    -- module), or spawn fibers that use these effects
  end
)
```

## Module `eio`

Module for basic I/O, using non-blocking I/O (through the `nbio` Lua module
written in C) and the `wait_posix` module to wait for I/O.

With the exception of depending on POSIX file descriptors, this module generic
in regard to how "waiting" is implemented. In particular, `eio` does not depend
on the `fiber` module, and whenever there is a need to wait for I/O, the
effects of the `wait_posix` module are performed. In order to use `eio`,
appropriate handlers have to be installed. One way to achieve this is to use
`wait_posix_fiber.main(action, ...)` as in the following example:

```
local wait_posix_fiber = require "wait_posix_fiber"
local eio = require "eio"

wait_posix_fiber.main(
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

    Note that `r`, `w`, and `rw` are mutually exclusive and exactly only one of
    them must be specified unless `flags` is `nil` (which then defaults to
    `"r"`).

  * **`eio.localconnect(path)`** initiates opening a local socket connection
    with the socket on the filesystem given by `path` and returns an I/O handle
    on success (`nil` and error message otherwise).

  * **`eio.tcpconnect(host, port)`** initiates opening a TCP connection to the
    given `host` and `port` and returns an I/O handle on success (`nil` and
    error message otherwise).

  * **`eio.locallisten(path)`** listens for connections to a local socket given
    by `path` on the filesystem and returns a listener handle on success (`nil`
    and error message otherwise). A pre-existing socket entry in the file
    system is unlinked automatically and permissions of the new socket are set
    to world read- and writeable.

  * **`eio.tcplisten(host, port)`** runs a TCP server at the given interface
    (`host`) and `port` and returns a listener handle on success (`nil` and
    error message otherwise).

  * **`eio.execute(file, ...)`** executes `file` with optional arguments in a
    subprocess and returns a child handle on success (`nil` and error message
    otherwise). Note that no shell is involved unless `file` is a shell. The
    search path for executables (`PATH` environment variable) applies.

  * **`eio.catch_signal(sig)`** is an alias for `waitio.catch_signal(sig)`.

  * **`eio.timeout(seconds)`** is an alias for `waitio.timeout(seconds)`.

  * **`eio.interval(seconds)`** is an alias for `waitio.interval(seconds)`.

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
    Returns `nil` and an error message in case of an I/O error. Be aware that
    if `maxlen` is absent or `nil`, there is no boundary on the number of bytes
    read and input data may cause unbounded memory allocation. If `terminator`
    is absent or `nil`, then it is always attempted to read `maxlen` bytes or
    until EOF if `maxlen` is `nil`. This method may read more bytes than
    requested and/or read beyond the terminator byte and will then buffer that
    data for the next invocation of the `read` method.

  * **`h:read_unbuffered(maxlen)`** waits until some data is available for
    reading or an I/O error occurred. It then reads a maximum number of
    `maxlen` bytes. The return value may be shorter than `maxlen` even if there
    was no EOF. However, the empty string (`""`) is only returned on EOF and if
    no bytes could be read before the EOF occured. Returns `nil` and an error
    message in case of an I/O error. If `maxlen` is absent or `nil`, some
    (finite) default value will be used.

  * **`h:read_nonblocking(maxlen)`** acts like `h:read_unbuffered(maxlen)` but
    returns immediately with an empty string if no data is available. To avoid
    ambiguities, EOF is indicated by returning `false` (and an error message).
    I/O errors are indicated by `nil` and an error message. If `maxlen` is
    absent or `nil`, some (finite) default value will be used.

  * **`h:unread(data, ...)`** puts `data` at beginning of read buffer, which
    can be used to "undo" reading, similar to the `ungetc` C function but
    allowing to put back more than one byte at a time.

  * **`h:write(data, ...)`** waits repeatedly until all `data` could be stored
    in a buffer and/or written out. Returns `true` on success, `false` and an
    error message in case of a disconnected receiver (broken pipe), and `nil`
    and an error message in case of other I/O errors. Multiple arguments may be
    supplied in which case they get concatenated.

  * **`h:flush(data, ...)`** waits repeatedly until all buffered data and the
    optionally passed `data` could be written out. Returns `true` on success,
    `false` and an error message in case of a disconnected receiver (broken
    pipe), and `nil` and an error message in case of other I/O errors. Multiple
    arguments may be supplied in which case they get concatenated.

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
of that library. For example, Ubuntu 22.04 LTS as well as Ubuntu 24.04 LTS ship
with version 2.3.1, which is subject to this bug.

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
