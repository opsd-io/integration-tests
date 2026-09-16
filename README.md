# OPSd integration tests

This repository is the single public source of OPSd provider scenarios and the
runner used to execute them.

The same scenarios can run in two modes:

- `plan` validates generated Terraform or OpenTofu without cloud credentials;
- `apply` provisions a real environment, runs the scenario stages, and destroys
  the environment afterwards.

Workflow repositories provide the execution environment. This repository keeps
the scenario definitions and test logic so public and credentialed runs do not
drift apart.

Scenario runs should pin the CLI, provider module, and this repository to
explicit refs when reproducibility matters.
