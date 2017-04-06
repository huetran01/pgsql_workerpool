PROJECT = psql
REBAR = ./rebar

.PHONY: all rel deps compile clean 

all: deps compile

deps:
	$(REBAR) get-deps

compile:
	$(REBAR) compile

rel : rebar
	$(REBAR) generate

clean:
	$(REBAR) clean
	rm -f test/*.beam
	rm -f erl_crash.dump

