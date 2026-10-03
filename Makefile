RACO ?= raco
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
TESTS ?= tests/

.PHONY: build test exe clean bdd-prepare test-bdd

build:
	$(RACO) make src/main.rkt

# All tests, in parallel:      make test
# A subset:                    make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt"
# More or fewer workers:       make test JOBS=8
test:
	$(RACO) test -j $(JOBS) $(TESTS)

exe: build
	mkdir -p dist
	$(RACO) exe -o dist/agentica src/main.rkt

bdd-prepare: exe
	rm -rf dist/runtime
	$(RACO) distribute dist/runtime dist/agentica
	docker image inspect agentica-eval:local >/dev/null 2>&1 || docker build -f tests/eval/Dockerfile -t agentica-eval:local .

test-bdd: bdd-prepare
	AGENTICA_BDD_INTEGRATION=1 $(RACO) test tests/bdd-integration.rkt
	dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc

clean:
	find . -name compiled -type d -prune -exec rm -rf {} +
	rm -rf dist
