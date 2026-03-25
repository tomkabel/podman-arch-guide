# Podman Arch Linux Production Guide - Makefile

.PHONY: help test health-check deploy clean

help:
	@echo "Podman Production Guide - Available Commands:"
	@echo ""
	@echo "  make test              Run all tests"
	@echo "  make test-scripts      Test shell scripts"
	@echo "  make test-integration  Run integration tests"
	@echo "  make health-check      Check system health"
	@echo "  make deploy            Deploy single-node example"
	@echo "  make deploy-blue-green Deploy blue/green example"
	@echo "  make clean             Clean up test resources"
	@echo "  make cost-estimate     Calculate cloud costs"
	@echo "  make chaos-test        Run chaos engineering tests"

test: test-scripts test-integration
	@echo "✅ All tests passed"

test-scripts:
	@echo "Testing shell scripts..."
	@find scripts -name "*.sh" -exec bash -n {} \;
	@echo "✅ Shell script syntax OK"
	@which shellcheck > /dev/null && \
		find scripts -name "*.sh" -exec shellcheck {} \; || \
		echo "⚠️  shellcheck not installed"

test-integration:
	@echo "Running integration tests..."
	@cd tests/integration && ./run-all.sh

health-check:
	@./scripts/health-check.sh

deploy:
	@./scripts/deploy.sh examples/single-node/webapp

deploy-blue-green:
	@./scripts/blue-green-deploy.sh webapp v1.0.0

clean:
	@echo "Cleaning up..."
	@podman system prune -f
	@podman volume prune -f 2>/dev/null || true
	@echo "✅ Cleanup complete"

cost-estimate:
	@./tools/cost-calculator/calculate.sh

chaos-test:
	@./tests/chaos/run-all.sh

lint:
	@echo "Linting scripts..."
	@shellcheck scripts/*.sh
	@echo "✅ Linting complete"

fmt:
	@echo "Formatting scripts..."
	@shfmt -w scripts/*.sh
	@echo "✅ Formatting complete"

install-hooks:
	@echo "Installing git hooks..."
	@cp .github/hooks/pre-commit .git/hooks/
	@chmod +x .git/hooks/pre-commit
	@echo "✅ Hooks installed"
