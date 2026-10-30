#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
# Share the production builder's persistent lock before accessing its caches.
# The preview helper only publishes separately identified audit applications.
mkdir -p .build
exec python3 Tools/Distribution/release-guard.py run-locked .build/.softlock-build.lock \
    python3 Tools/DesignPreview/build-preview.py
