FROM ghcr.io/hylo-lang/hylo-dev-toolchain:v1.0.0
RUN apt-get update && apt-get install jq -y && rm -rf /var/lib/apt/lists/*
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && \
    \. "$HOME/.nvm/nvm.sh" && nvm install 22 && node -v