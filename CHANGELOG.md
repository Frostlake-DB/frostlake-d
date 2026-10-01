# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A lost session is recovered from, or reported.** Once the engine's first answer carries
  `newSession` (engines from 0.1.0 on), every request that names the session also sends
  `requireSession: true`, so an engine that no longer holds the session — it expired, was
  released, or the server restarted — refuses the request with HTTP 404 rather than running it
  in a fresh session at the server's default scope. The driver then puts the DSN's scope onto a
  fresh session and sends the statement once more, or, when the lost session held an open
  transaction or context set up on it (a `USE`, `SET`/`UNSET`, `ALTER SESSION`, a temporary
  object, a `CREATE`/`DROP` of a database or schema), raises the new `SessionLostException`:
  the statement did not run, and the connection's next statement starts a fresh session on the
  DSN's scope. An engine without `newSession` is sent no such field.
- **`close()` gives the session back** with `DELETE /api/sessions/{id}`, which also rolls back a
  transaction left open on it, instead of leaving it to the engine's 30-minute idle expiry. It is
  best effort — at most the shorter of five seconds and the DSN's `timeout`, and it never raises —
  and it is sent only to an engine that answers `newSession`; a second `close()` sends nothing. A
  connect whose scope the engine refused releases the session it started the same way.

- **A request can declare its own statement count.** `ExecuteOptions.multiStatementCount`, taken by
  `execute`, `executeAll`, `executePositional` and `executeNamed`, says how many statements the one
  request carries. It outranks the session's `MULTI_STATEMENT_COUNT` for that request and moves no
  session state, so nothing has to be put back afterwards; `0` accepts any number, and a call that
  leaves it unset sends exactly what it always sent.
- **A text or binary column reports the width it was declared with.** `Column.length` carries a
  `VARCHAR`'s width in characters and a `BINARY`'s in bytes — the number the account's own driver
  reports as such a column's precision and its display size — and the maximum, 16777216 or
  8388608, for one declared without a width. Every other type leaves it empty, as does a server
  that predates the field: absent stays absent rather than becoming a width of 0.

### Fixed

- **A colon glued to a `?` reads a path off the bound value.** `SELECT ?:a` was refused as mixing
  `?` and `:name` placeholders, whatever arguments came with it; a `?` now ends an operand as a
  name, a closing bracket or a quote already did. Spaced off (`? :a`), the colon still opens a
  `:name` placeholder.
- **A statement deadline no longer ends the connect-time health check.** The `GET /api/health` a
  new connection makes ran under `timeout`, so a statement deadline shorter than that round trip
  failed the connect, naming `/api/health`, and only on a loaded machine. It is part of
  connecting, so `connectTimeout` bounds it now. A later `ping()` still runs under `timeout`.
- **`asDouble` is correctly rounded.** It answers the double nearest the digits the engine sent, a
  tie going to the even neighbour. Phobos' parser, which it used to answer through, lands an ulp
  away on some values — `486.3026820789797` among them.
- **`connectTimeout` bounds the whole connect.** Each address the host resolves to is tried once,
  within one deadline. The resolver listed every address once per socket type and each copy was
  tried with the full timeout, so a blackholed host took three timeouts to fail and `localhost`
  six.
- **A signal no longer fails a connect, a write or a read.** In a multi-threaded program druntime
  stops every thread with a signal for each collection; besides the `select` wait fixed in 0.1.0,
  an interrupted `connect`, `send` or `receive` surfaced as `Unable to connect socket: Interrupted
  system call`, `cannot write to …` or `cannot read from …`. Interrupted, such a call moved no
  bytes, so it is waited on and made again — the statement itself is never re-sent. A write or
  read that really fails now names the operating system's reason.
- **An IPv6 host is bracketed** in the `Host` header and in `baseUrl` (`http://[::1]:18082`).
- **Only the driver's own exceptions escape.** A process out of file descriptors fails to connect
  with a `ConnectionException` rather than std.socket's `SocketOSException`, as does a failed
  `select`; `asSysTime` refuses an offset of a day or more, such as `+2500`, with a
  `ValueException` rather than Phobos' `TimeException`.
- **A column that merely starts `number of` is data.** A DML answer is recognised only by the
  engine's own counters — `number of rows inserted`, `updated` and `deleted`, and `number of
  multi-joined rows updated` — so `SELECT 5 AS "number of apples"` is no longer an update.
- **`ConnectOptions` can remove a DSN bound.** Left unset, a duration keeps the DSN's value; set to
  `Duration.zero`, it removes the bound, as the documentation always said.
- **`transaction` rolls back whatever its work throws**, an `Error` included, and re-raises it.
- **`transaction`, `Result` and `Row` take `@system` work.** Each has a `@system` overload, so a
  transaction delegate or a `foreach` body may call unannotated code.
- **Every wire failure drops the socket** — a malformed status line, a bad chunk header and a body
  past the 256 MB cap included — so nothing half-read can reach the next statement.
- **A JSON array or object cell reads as its JSON text** instead of an empty string.

### Changed

- `ConnectOptions.timeout`, `connectTimeout` and `idleLimit` are `Nullable!Duration`. Assigning a
  `Duration` works as before; code that reads one back gets a `Nullable`.
- **`idleLimit` applies only to an engine without `newSession`.** Such an engine rebuilds a lapsed
  session silently, so the DSN's scope still goes back on after an idle gap; one that answers
  `newSession` refuses a lapsed session instead, and the refusal is recovered from where it
  lands. The re-scope is also no longer sent into an open transaction.
- **`inTransaction` sees a `BEGIN` run as a statement**, until its `COMMIT` or `ROLLBACK`, as well as
  one opened by `begin`.
- **`sessionId` is empty once the connection is closed.**

## [0.1.0] — 2026-09-11

First release. A complete D driver for Frostlake's HTTP protocol, depending on nothing outside
Phobos.

### Added

- **Connections.** `connect(dsn)` opens a connection that carries one engine session, so `USE`,
  session variables and open transactions carry from statement to statement. The DSN's scope —
  database, schema, role, warehouse — is selected before the constructor returns, so a DSN naming
  a database that does not exist fails at `connect` rather than on a later query.
- **Statements.** `execute`, `executeAll` for multi-statement requests, `executePositional` and
  `executeNamed` for parameters built at runtime, and `render` to see what a bind produced without
  sending it.
- **Typed binding.** `?` and `:name` placeholders are inlined client-side, with the literal chosen
  from the D type of the argument: a `string` is quoted, an integer is a bare numeral, an empty
  `Nullable!T` is `NULL`. `Param.ofVariant`, `Param.identifier` and `Param.raw` cover what
  inference cannot reach.
- **Results.** `Result`, `Row`, `Column` and `Value`. Cells keep the engine's own text and every
  reading is an explicit call — `asLong`, `asDouble`, `asBigInt`, `asBytes`, `asDate`,
  `asTimeOfDay`, `asDateTime`, `asSysTime`, and `opt!T` for a `Nullable`. Nothing is converted
  behind the caller's back, so a `NUMBER(38,0)` is never rounded.
- **Update counts**, derived from the `number of rows ...` counter grid the engine answers DML
  with, alongside the raw counters and the grid itself.
- **Transactions.** `begin`, `commit`, `rollback`, and a scoped `transaction(delegate)` that rolls
  back and re-raises the original exception.
- **Transport.** An HTTP/1.1 client on raw sockets, holding one keep-alive socket for a
  connection's whole life, with a single deadline over each whole exchange. Chunked bodies,
  case-folded headers and `Connection: close` are all handled; a broken exchange drops the socket
  and is reported, never retried.
- **Errors.** `UsageException`, `ConnectionException`, `QueryException` and `ValueException`, all
  under `FrostlakeException`.
- **Tests.** `unittest` blocks throughout the library; a scripted-server suite for the answers a
  healthy engine will never give; and 18 integration tests against an engine the suite boots
  itself.

### Notes on this engine

Behaviours measured against engine 0.0.7 while building the driver, true for any client:

- A refused statement comes back as **HTTP 500 carrying the ordinary JSON envelope**, so a driver
  must read `success` from the body rather than treat the status as a transport failure.
- A failure answers `sessionId: null`. Taking that at face value would drop the session and
  silently start a new one, losing `USE`, variables and any open transaction.
- `TIMESTAMP_TZ` **parses only a colonised offset** (`+01:00`) but **prints** the bare form
  (`+0100`), so a value read out of a result and bound straight back in has to be repaired.
  `Param.ofTimestampTz` does that.
- `NaN` arrives as the JSON **string** `"NaN"`, even for a column declared `DOUBLE`. Binding one
  back needs `'NaN'::DOUBLE`; `'Infinity'` and `'-Infinity'` work, and the shorter `'Inf'` does
  not.
- A boolean-valued expression may declare its column `VARCHAR` while sending a JSON boolean —
  `SELECT 1=1` does. `Value.asBool` accepts both spellings.
- A backslash escapes inside a SQL string literal, so `'a\b'` is a backspace. Bound strings have
  their backslashes doubled.
- A blank statement is refused by the HTTP endpoint itself (400, `SQL is required`), so the
  engine's own "Empty SQL statement." wording cannot be observed over this transport.
- A session belongs to `/api/execute`, not `/api/health`, so a connection has no session id until
  its first statement.

### Verified

Engine 0.0.7, with DMD 2.112.0 on Windows and DMD 2.100.2, 2.112.0, 2.113.0 and LDC 1.40.0 on
Linux: 10 modules of unit tests, 7 scripted-transport tests and 18 integration tests.

### Known limitations

- **No TLS.** Phobos ships none, so an `https://` DSN is refused with an explanation rather than
  quietly sent in the clear. Terminate TLS in a proxy in front of the engine.
- **No error codes.** The HTTP protocol carries a message only, so a failure has no error code
  or SQLSTATE to report. This is a protocol gap shared by every Frostlake transport except
  Snowflake's.
- **A connection belongs to one thread.** Two statements half-interleaved on one session would
  corrupt the state a session exists to keep, so the second is refused rather than half-done.
