# Dev environment for working on repo-skills — and for dogfooding /repo:remote.
# /repo:remote builds and runs this on the remote host when the repo's .env sets
# REPO_REMOTE_DOCKERFILE=./Dockerfile. It carries the toolchain needed to work on
# the /repo:* commands (bash, git, gh, shellcheck, ripgrep, jq) plus the Claude
# Code CLI. Auth tokens (gh, claude) are injected at container-run time via the
# environment — never baked into this image and never committed.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash git ca-certificates curl jq ripgrep shellcheck less openssh-client \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) from GitHub's official apt repo
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (native installer). Auth is provided at runtime via
# CLAUDE_CODE_OAUTH_TOKEN in the container env, not baked in here.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /work
CMD ["sleep", "infinity"]
