.PHONY: help test test-unit test-integration test-image clean

help:
	@echo "test            - run unit + integration tests"
	@echo "test-unit       - run bats unit tests on host"
	@echo "test-integration - run integration tests in Docker sandbox"
	@echo "test-image      - rebuild the test sandbox image"
	@echo "clean           - remove test artifacts"

test: test-unit test-integration

test-unit:
	bats tests/unit

test-image:
	docker build -t hermes-setup-test -f tests/Dockerfile.ubuntu-systemd .

test-integration: test-image
	bash tests/run-tests.sh

clean:
	rm -rf tests/.bats-tmp
