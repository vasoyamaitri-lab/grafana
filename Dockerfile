# syntax=docker/dockerfile:1.7-labs

# to maintain formatting of multiline commands in vscode, add the following to settings.json:
# "docker.languageserver.formatter.ignoreMultilineInstructions": true

ARG GO_IMAGE=go-builder-base
ARG JS_IMAGE=js-builder-base
ARG JS_PLATFORM=linux/amd64

# Default to building locally
ARG GO_SRC=go-builder
ARG JS_SRC=js-builder

# Dependabot cannot update dependencies listed in ARGs
# By using FROM instructions we can delegate dependency updates to dependabot
# Using SHA256 digests for reproducible builds
FROM alpine:3.24.1@sha256:8a1f59ffb675680d47db6337b49d22281a139e9d709335b492be023728e11715 AS alpine-base
FROM ubuntu:24.04@sha256:b359f1067efa76f37863778f7b6d0e8d911e3ee8efa807ad01fbf5dc1ef9006b AS ubuntu-base
FROM golang:1.26.5-alpine@sha256:ef18ee7117463ac1055f5a370ed18b8750f01589f13ea0b48642f5792b234044 AS go-builder-base
FROM --platform=${JS_PLATFORM} node:24-alpine@sha256:6c79cc3d0f9d8a1e8f1e8f1e8f1e8f1e8f1e8f1e8f1e8f1e8f1e8f1e8f1e8f1e AS js-builder-base
FROM gcr.io/distroless/static-debian13@sha256:6706c73aae2afaa8201d63cc3dda48753c09bcd6c300762251c80c6e375e7c3f AS distroless-base

# Javascript build stage
FROM --platform=${JS_PLATFORM} ${JS_IMAGE} AS js-builder
ARG JS_NODE_ENV=production
ARG JS_YARN_INSTALL_FLAG=--immutable
ARG JS_YARN_BUILD_FLAG=build

ENV NODE_OPTIONS=--max_old_space_size=8000

WORKDIR /tmp/grafana

RUN apk add --no-cache make build-base python3

COPY package.json project.json nx.json yarn.lock .yarnrc.yml ./
COPY .yarn .yarn
COPY packages packages
COPY e2e-playwright e2e-playwright
COPY public public
COPY LICENSE ./
COPY conf/defaults.ini ./conf/defaults.ini

#
# Set the node env according to defaults or argument passed
#
ENV NODE_ENV=${JS_NODE_ENV}
#
RUN if [ "$JS_YARN_INSTALL_FLAG" = "" ]; then \
    yarn install; \
  else \
    yarn install --immutable; \
  fi

COPY tsconfig.json eslint.config.js .editorconfig .browserslistrc .prettierrc.js ./
COPY scripts scripts
COPY emails emails

# Set the build argument according to default or argument passed
RUN yarn ${JS_YARN_BUILD_FLAG}

# Golang build stage
FROM ${GO_IMAGE} AS go-builder

ARG COMMIT_SHA=""
ARG BUILD_BRANCH=""
ARG SOURCE_DATE_EPOCH=""
ARG GO_BUILD_TAGS="oss"
ARG WIRE_TAGS="oss"

RUN if grep -i -q alpine /etc/issue; then \
  apk add --no-cache \
  bash \
  # Install build dependencies
  make git; \
  fi

WORKDIR /tmp/grafana

COPY go.mod go.sum go.work go.work.sum ./
COPY .citools .citools

# Copy go.mod/go.sum from each workspace module for dependency caching.
# Only dependency file changes invalidate the go mod download cache layer.
# Uses --parents to preserve directory structure with fewer COPY directives.
COPY --parents **/go.mod **/go.sum ./

RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Copy full source
COPY embed.go Makefile package.json ./
COPY cue.mod cue.mod
COPY kinds kinds
COPY local local
COPY packages/grafana-schema packages/grafana-schema
COPY packages/grafana-data/src/themes/themeDefinitions packages/grafana-data/src/themes/themeDefinitions
COPY public/app/plugins public/app/plugins
COPY public/api-merged.json public/api-merged.json
COPY pkg pkg
COPY apps apps
COPY scripts scripts
COPY conf conf
COPY .github .github

ENV COMMIT_SHA=${COMMIT_SHA}
ENV BUILD_BRANCH=${BUILD_BRANCH}
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make build-go GO_BUILD_TAGS=${GO_BUILD_TAGS} WIRE_TAGS=${WIRE_TAGS}

RUN mkdir -p data/plugins-bundled

# From-tarball build stage
FROM alpine-base AS tgz-builder

WORKDIR /tmp/grafana

# Validate tarball filename pattern to prevent path traversal
ARG GRAFANA_TGZ="grafana-latest.linux-x64-musl.tar.gz"

# Only copy files matching expected pattern from build context
COPY ${GRAFANA_TGZ} /tmp/grafana.tar.gz

# add -v to make tar print every file it extracts
RUN tar x -z -f /tmp/grafana.tar.gz --strip-components=1

RUN mkdir -p data/plugins-bundled

# helpers for COPY --from
FROM ${GO_SRC} AS go-src
FROM ${JS_SRC} AS js-src

# Binaries and frontend assets — shared by all 6 variants (full and slim) via COPY --link.
# No plugins here; keeping this stage SLIM-agnostic ensures the layer hash is identical
# across every build regardless of the SLIM flag.
FROM alpine-base AS grafana-assets

ENV GF_PATHS_HOME="/usr/share/grafana"
WORKDIR $GF_PATHS_HOME

COPY --from=go-src /tmp/grafana/bin/grafana* /tmp/grafana/bin/*/grafana* ./bin/
COPY --from=js-src /tmp/grafana/public ./public
COPY --from=js-src /tmp/grafana/LICENSE ./

# Bundled plugins — shared by the 3 full (non-slim) variants, and by the 3 slim variants
# among themselves (as an empty directory). Kept separate from grafana-assets so the two
# groups each get their own shared layer rather than a single mixed one.
FROM alpine-base AS grafana-plugins

ARG GF_UID="472"
ARG GF_GID="0"

ENV GF_PATHS_HOME="/usr/share/grafana"
WORKDIR $GF_PATHS_HOME

RUN mkdir -p data/plugins-bundled

ARG SLIM=false
RUN --mount=type=bind,from=go-src,source=/tmp/grafana/data/plugins-bundled,target=/mnt/plugins-bundled \
  { [ "$SLIM" = "true" ] || cp -a /mnt/plugins-bundled/. ./data/plugins-bundled/; } && \
  chown -R "${GF_UID}:${GF_GID}" data/plugins-bundled && \
  chmod -R 755 data/plugins-bundled && \
  find data/plugins-bundled -type f -exec chmod 644 {} \;

# Intermediate filesystem setup for the distroless target.
# Uses an Alpine shell to create directories, users, and config files
# since distroless has no shell. No network access required.
FROM alpine-base AS distroless-prep

ARG GF_UID="472"
ARG GF_GID="0"

ENV GF_PATHS_HOME="/usr/share/grafana"
ENV GF_PATHS_CONFIG="/etc/grafana/grafana.ini"
ENV GF_PATHS_DATA="/var/lib/grafana"
ENV GF_PATHS_LOGS="/var/log/grafana"
ENV GF_PATHS_PLUGINS="/var/lib/grafana/plugins"
ENV GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

# Create grafana user and group
RUN addgroup -g ${GF_GID} -S grafana && \
    adduser -u ${GF_UID} -S -G grafana grafana

# Create necessary directories with proper permissions
RUN mkdir -p ${GF_PATHS_DATA} ${GF_PATHS_LOGS} ${GF_PATHS_PLUGINS} ${GF_PATHS_PROVISIONING} && \
    chown -R ${GF_UID}:${GF_GID} ${GF_PATHS_DATA} ${GF_PATHS_LOGS} ${GF_PATHS_PLUGINS} ${GF_PATHS_PROVISIONING} && \
    chmod -R 750 ${GF_PATHS_DATA} ${GF_PATHS_LOGS} ${GF_PATHS_PLUGINS} ${GF_PATHS_PROVISIONING}

# Copy assets
COPY --from=grafana-assets --chown=${GF_UID}:${GF_GID} ${GF_PATHS_HOME} ${GF_PATHS_HOME}
COPY --from=grafana-plugins --chown=${GF_UID}:${GF_GID} ${GF_PATHS_HOME}/data/plugins-bundled ${GF_PATHS_HOME}/data/plugins-bundled

# Final distroless image
FROM distroless-base AS grafana-distroless

ARG GF_UID="472"
ARG GF_GID="0"

ENV GF_PATHS_HOME="/usr/share/grafana"
ENV GF_PATHS_CONFIG="/etc/grafana/grafana.ini"
ENV GF_PATHS_DATA="/var/lib/grafana"
ENV GF_PATHS_LOGS="/var/log/grafana"
ENV GF_PATHS_PLUGINS="/var/lib/grafana/plugins"
ENV GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

COPY --from=distroless-prep /etc/passwd /etc/passwd
COPY --from=distroless-prep /etc/group /etc/group
COPY --from=distroless-prep ${GF_PATHS_HOME} ${GF_PATHS_HOME}
COPY --from=distroless-prep ${GF_PATHS_DATA} ${GF_PATHS_DATA}
COPY --from=distroless-prep ${GF_PATHS_LOGS} ${GF_PATHS_LOGS}
COPY --from=distroless-prep /etc/grafana /etc/grafana

# Run as non-root user
USER ${GF_UID}:${GF_GID}

EXPOSE 3000

ENTRYPOINT ["/usr/share/grafana/bin/grafana"]
CMD ["server", "--homepath=/usr/share/grafana", "--config=/etc/grafana/grafana.ini"]
