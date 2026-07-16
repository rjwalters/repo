# Dev environment for working on repo-skills — and for dogfooding /repo:remote.
# /repo:remote builds and runs this on the remote host when the repo's .env sets
# REPO_REMOTE_DOCKERFILE=./Dockerfile. It carries the toolchain needed to work on
# the /repo:* commands (bash, git, gh, shellcheck, ripgrep, jq). Claude Code is
# installed in-session by /repo:remote, not baked in, to keep the image lean.
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

WORKDIR /work
CMD ["sleep", "infinity"]
