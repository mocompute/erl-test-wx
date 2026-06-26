eunit:
	rebar3 as brief eunit

dialyzer:
	rebar3 as brief dialyzer

xref:
	rebar3 as brief xref

tags:
	find src -name '*.erl' -or -name '*.hrl'
	find src $$(dirname $$(realpath $$(which erl)))/../lib/erlang -name '*.erl' -or -name '*.hrl' | etags -DI --no-globals --no-members -

clean:
	find src -name '*.beam'
	find src -name '*.beam' -exec rm {} ';'
