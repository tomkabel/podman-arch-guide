# Contributing Guide

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/yourname/podman-arch-guide`
3. Create branch: `git checkout -b feature/your-feature`

## Development Workflow

### Testing Changes

```bash
# Run all tests
make test

# Test specific script
bash -n scripts/your-script.sh
shellcheck scripts/your-script.sh

# Integration test
./tests/integration/test-your-feature.sh
```

### Submitting Changes

1. Add tests for new functionality
2. Update documentation
3. Run `make test` - all tests must pass
4. Submit Pull Request with clear description

## Commit Message Format

```
type(scope): subject

body (optional)

footer (optional)
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`

Example:
```
feat(scripts): add blue-green deployment

Adds production-tested blue/green deployment script
with health checks and automatic rollback.

Closes #123
```
