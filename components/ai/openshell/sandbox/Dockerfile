FROM ghcr.io/nvidia/openshell-community/sandboxes/base:latest

# Install the correct opencode CLI (opencode-ai npm package, Bun binary).
# The base image ships a Node.js opencode wrapper from a different project at
# /usr/bin/opencode (symlink to node_modules/opencode-ai/bin/opencode).
# Forge invokes the real OpenCode CLI as `opencode run` and redirects stdout
# to /sandbox/.forge/result.json from the orchestrator-side runner wrapper.
# Download the linux-x64 Bun binary and install it as root so it takes
# precedence over /usr/bin/opencode via /usr/local/bin in PATH.
USER root
RUN set -e; \
    curl -fsSL https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-1.17.11.tgz \
      | tar -xz -C /tmp --strip-components=2 package/bin/opencode; \
    install -m 755 /tmp/opencode /usr/local/bin/opencode; \
    rm /tmp/opencode; \
    opencode --version
USER sandbox
