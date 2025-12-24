#!/bin/bash
set -euo pipefail

printf '%s' "$1" | base64 --decode > .env
