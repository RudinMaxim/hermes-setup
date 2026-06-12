.PHONY: help setup-macos check-multimedia test test-unit test-integration test-image clean update

help:
	@echo "update          - git pull + re-sync hermes/mcp/gateway (run on the VPS as hermes)"
	@echo "setup-macos     - configure native Hermes/Ollama/Obsidian on macOS"
	@echo "check-multimedia - verify native speech, vision, and media dependencies"
	@echo "test            - run unit + integration tests"
	@echo "test-unit       - run bats unit tests on host"
	@echo "test-integration - run integration tests in Docker sandbox"
	@echo "test-image      - rebuild the test sandbox image"
	@echo "clean           - remove test artifacts"

update:
	bash scripts/update.sh

setup-macos:
	bash scripts/setup-macos.sh

check-multimedia:
	bash scripts/macos/check-multimedia.sh

test: test-unit test-integration

test-unit:
	bats tests/unit

test-image:
	docker build -t hermes-setup-test -f tests/Dockerfile.ubuntu-systemd .

test-integration: test-image
	bash tests/run-tests.sh

clean:
	rm -rf tests/.bats-tmp
