#!/bin/sh
# Fixture stand-in for the plugin's real scaffold.sh. Exists so tests can
# assert that scaffold.sh never survives into scaffolded output (it is
# plugin tooling, not part of a generated exporter's repo) — see the
# self-copy assertion in scaffold_edge_test.sh.
echo "not the real scaffold.sh"
