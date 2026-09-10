/**
 * The entry point `dub test` links against.
 *
 * It is empty on purpose. D runs every `unittest` block in the program before
 * `main`, and druntime's default test mode reports the result and exits
 * without calling `main` at all — so by the time control would reach here, the
 * whole pure-logic suite has already run and said how it went.
 *
 * The tests that need something to talk to are not here; they have an entry
 * point of their own, `tests/integration_main.d`.
 */
module tests.unittest_main;

void main()
{
}
