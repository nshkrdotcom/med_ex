# Source development

These commands apply to the source checkout at
https://github.com/nshkrdotcom/med_ex.

On Ubuntu 26.04, install Git, curl, tar, build-essential, pkg-config and
libssl-dev. Activate the Erlang and Elixir versions in `.tool-versions`
through asdf or mise.

```sh
./onboard.sh
mix ci
mix weld.release.prepare
```

The release command prints the paths to the generated project, rendered
docs and Hex archive. The generated project's tests can be run from its
`project/` directory with `mix deps.get` followed by `mix test`.
