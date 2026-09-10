# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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
