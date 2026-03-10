# Contributing to HA-Laravel

Thanks for your interest in contributing! Here's how to get started.

## Reporting Issues

- Check existing issues before opening a new one.
- Include your HA version, architecture, addon logs, and the Laravel app
  you're trying to run.

## Development Setup

1. Fork and clone this repository.
2. Make changes in the `template/` directory.
3. Test locally by generating an addon instance:

   ```bash
   ./generate.sh --name "Test App" --slug test-app
   ```

4. Build and test the Docker image:

   ```bash
   cd test-app
   docker build -t ha-laravel-test .
   ```

## Pull Requests

- Keep PRs focused on a single change.
- Update the README if your change affects user-facing behavior.
- Add a clear description of what the PR does and why.

## Adding Package Detection

To add detection for a new Laravel package in `discover.sh`:

1. Add a `pkg()` call for the package name.
2. Decide whether it needs a daemon (Supervisor program), forces the
   scheduler on, forces the queue worker on, or runs a one-time setup
   command.
3. Add the appropriate logic in the relevant section of `discover.sh`.
4. Update the README's auto-discovery table.

## Code Style

- Shell scripts: use `set -euo pipefail`, quote variables, use `[[ ]]` for
  conditionals.
- PHP: follow PSR-12 / Laravel conventions.

## License

By contributing, you agree that your contributions will be licensed under
the [MIT License](LICENSE).
