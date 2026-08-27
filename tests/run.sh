#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$TEST_ROOT/tests/test_manifest.sh"
bash "$TEST_ROOT/tests/test_parsers.sh"
bash "$TEST_ROOT/tests/test_skills_pass.sh"
bash "$TEST_ROOT/tests/test_mcp_pass.sh"
bash "$TEST_ROOT/tests/test_idempotence.sh"
bash "$TEST_ROOT/tests/test_cli.sh"
bash "$TEST_ROOT/tests/test_bootstrap.sh"
