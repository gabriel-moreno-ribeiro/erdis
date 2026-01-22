# erdis: plain erlc build, EUnit tests, and a runner.
ERLC = erlc
ERLC_FLAGS = -Wall +debug_info -o ebin

SRC = $(wildcard src/*.erl)
TST = $(wildcard test/*.erl)

compile: ebin $(SRC:src/%.erl=ebin/%.beam)

ebin:
	mkdir -p ebin

ebin/%.beam: src/%.erl
	$(ERLC) $(ERLC_FLAGS) $<

test: compile
	$(ERLC) $(ERLC_FLAGS) $(TST)
	erl -noshell -pa ebin -eval 'case eunit:test(erdis_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end'

# make run PORT=6379
PORT ?= 6379
run: compile
	erl -noshell -pa ebin -s erdis run $(PORT)

clean:
	rm -rf ebin dump.erdis

.PHONY: compile test run clean
