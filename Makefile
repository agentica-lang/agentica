.PHONY: build test exe clean

build:
	raco make src/main.rkt

test:
	raco test tests/

exe: build
	mkdir -p dist
	raco exe -o dist/agentica src/main.rkt

clean:
	find . -name compiled -type d -prune -exec rm -rf {} +
	rm -rf dist
