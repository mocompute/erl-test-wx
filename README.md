# test_wx

The module `test_wx_win` demonstrates the use of `wx` to create a
window with a single GL context along with various event handlers.

It also demonstrates the use of a manually-managed mutable binary
implemented as a NIF. A mutable buffer is allocated and written into
by copying an Erlang binary into it, and its data is passed directly
to the OpenGL functions that operate on pixel data.

# AI

The `test_wx_win` demonstration includes AI-generated code and
comments. Some of the comments may be out of date since I integrated
mut_bin after completing the test with standard Erlang binaries.

The included mutable binary library `mut_bin` is developed with no
code from AI.

# License

GNU General Public License.
