# Contributing

Follow the [central OPSd contribution guide](https://github.com/opsd-io/.github/blob/main/CONTRIBUTING.md)
for organization-wide rules. The scenario-specific guidance below applies in
this repository.

## Pull Requests And Commits

Use the following format for the pull request title and every commit:

~~~text
type(scope): short imperative description
~~~

Allowed scopes are tests, ci, docs, and release, for example
feat(tests): cover managed mysql in the lifecycle. Breaking changes may use
the ! marker.

The required Conventional Commits check must pass. Release Please uses the
messages to generate shared release notes.

## Scenario Changes

Keep scenario definitions in ci/public-compatibility.yaml and extend the
shared lifecycle instead of duplicating provider workflows. Every supported
module must be covered by a scenario operation and listed in its coverage
metadata. The runner verifies that added resources appear in the rendered
configuration and that removed resources disappear again.

Use the provider's native names and keep resource names isolated per run so
Terraform and OpenTofu can run in parallel without collisions.

## Validation Flow

Public workflow runs execute the complete scenario through plan for both
Terraform and OpenTofu without cloud credentials. Private workflow runs use
the same scenario runner with apply, real credentials, and cleanup. Never
commit tokens, state files, or generated infrastructure output.

For reproducible checks, pin cli-ref, modules-ref, and integration-tests-ref
to explicit tags or commits. Use main when testing the latest unreleased
changes.
