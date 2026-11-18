# Terminal Prompter agent image (docs/06 route A, "Docker-variant").
#
# The container gives a terminal on the HOST, not in the container: run it
# with --pid=host --privileged and the nsenter shell from
# docker/config.toml.example. That is full root access to the host, which is
# the point; protect it like SSH root access.
#
#   docker build -f docker/Dockerfile -t tp-agent .
#   docker run -d --name tp-agent --pid=host --privileged \
#     -v /etc/tp-agent:/etc/tp-agent -v /var/lib/tp-agent:/var/lib/tp-agent \
#     -p 127.0.0.1:7681:7681 tp-agent

FROM dart:stable AS build
WORKDIR /src
COPY . .
ARG TP_VERSION=docker
RUN dart pub get \
 && make web embed VERSION=$TP_VERSION \
 && cd packages/tp_agent \
 && dart compile exe -DTP_VERSION=$TP_VERSION -o /tp-agent bin/tp_agent.dart

FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends util-linux ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /tp-agent /usr/local/bin/tp-agent
COPY docker/config.toml.example /etc/tp-agent/config.toml.example
EXPOSE 7681
HEALTHCHECK --interval=30s --timeout=3s CMD ["/usr/local/bin/tp-agent", "version"]
ENTRYPOINT ["/usr/local/bin/tp-agent"]
CMD ["run", "--config", "/etc/tp-agent/config.toml"]
