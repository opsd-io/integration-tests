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

The DigitalOcean integration suite uses one lifecycle scenario. It creates the
Kubernetes foundation, applies incremental changes for supported components,
removes a component again, verifies the final plan, and destroys the
environment. Each IaC tool gets its own state file and executes the complete
lifecycle independently. Resource names are namespaced by the workflow run and
IaC tool, so parallel Terraform and OpenTofu jobs cannot collide in
DigitalOcean. The lifecycle uses an explicit local backend per IaC tool, so
the state path is shared between stages without deprecated CLI flags.

The lifecycle is declared in `ci/public-compatibility.yaml`. Its steps contain
OPSd commands and a `covers` list. The required module list is checked both for
declared step coverage and against the rendered Terraform configuration, so
adding a module without adding real integration coverage fails CI.

Gateway and TLS render-only scenarios also live in the compatibility matrix.
They verify generated Gateway profiles, cert-manager resources, the DigitalOcean
DNS-01 solver, and the TLS Secret reference without requiring a live cluster or
publishing DNS credentials.

The ExternalDNS render-only scenario checks the pinned chart, Gateway API route
and Service sources, domain filters, TXT ownership policy, and Secret-backed
DigitalOcean webhook configuration. It does not contact DigitalOcean or verify
a live DNS record.

Apply-mode scenarios may declare `metadata.version_upgrade`. The runner then
resolves provider versions from the provider API, creates resources with the
previous available version, and adds upgrade stages targeting the latest
available version. The resolved pair is written to the temporary
`version-resolution.yaml` file for diagnostics. The token is supplied by the
workflow and is never written to that file.

Scenario runs should pin the CLI, provider module, and this repository to
explicit refs when reproducibility matters.

See the [central OPSd contribution guide](https://github.com/opsd-io/.github/blob/main/CONTRIBUTING.md)
for scenario conventions, local checks, and the public-plan/private-apply test
flow.
