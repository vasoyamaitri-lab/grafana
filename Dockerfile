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
FROM alpine:3.24.1 AS alpine-base
FROM ubuntu:24.04 AS ubuntu-base
FROM golang:1.26.5-alpine AS go-builder-base
FROM --platform=${JS_PLATFORM} node:24-alpine AS js-builder-base
FROM gcr.io/distroless/static-debian13 AS distroless-base
# Javascript build stage
FROM --platform=${JS_PLATFORM} ${JS_IMAGE} AS js-builder
ARG JS_NODE_ENV=production
ARG JS_YARN_INSTALL_FLAG=--immutable
ARG JS_YARN_BUILD_FLAG=build

ENV NODE_OPTIONS=--max_old_space_size=8000

# Create non-root user for build
RUN addgroup -g 1000 builder && adduser -u 1000 -G builder -s /bin/sh -D builder

WORKDIR /tmp/grafana

RUN apk add --no-cache make build-base python3

COPY --chown=builder:builder package.json project.json nx.json yarn.lock .yarnrc.yml ./
COPY --chown=builder:builder .yarn .yarn
COPY --chown=builder:builder packages packages
COPY --chown=builder:builder e2e-playwright e2e-playwright
COPY --chown=builder:builder public public
COPY --chown=builder:builder LICENSE ./
COPY --chown=builder:builder conf/defaults.ini ./conf/defaults.ini

# Switch to non-root user
USER builder

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

COPY --chown=builder:builder tsconfig.json eslint.config.js .editorconfig .browserslistrc .prettierrc.js ./
COPY --chown=builder:builder scripts scripts
COPY --chown=builder:builder emails emails

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

# Create non-root user for build
RUN addgroup -g 1000 builder 2>/dev/null || true && \
    adduser -u 1000 -G builder -s /bin/sh -D builder 2>/dev/null || true

WORKDIR /tmp/grafana

COPY --chown=builder:builder go.mod go.sum go.work go.work.sum ./
COPY --chown=builder:builder .citools .citools

# Copy go.mod/go.sum from each workspace module for dependency caching.
# Only dependency file changes invalidate the go mod download cache layer.
# Uses --parents to preserve directory structure with fewer COPY directives.
COPY --chown=builder:builder --parents **/go.mod **/go.sum ./

# Switch to non-root user
USER builder

RUN --mount=type=cache,target=/home/builder/.cache/go,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/builder/go/pkg/mod,uid=1000,gid=1000 \
    go mod download

# Copy full source
COPY --chown=builder:builder embed.go Makefile package.json ./
COPY --chown=builder:builder cue.mod cue.mod
COPY --chown=builder:builder kinds kinds
COPY --chown=builder:builder local local
COPY --chown=builder:builder packages/grafana-schema packages/grafana-schema
COPY --chown=builder:builder packages/grafana-data/src/themes/themeDefinitions packages/grafana-data/src/themes/themeDefinitions
COPY --chown=builder:builder public/app/plugins public/app/plugins
COPY --chown=builder:builder public/api-merged.json public/api-merged.json
COPY --chown=builder:builder pkg pkg
COPY --chown=builder:builder apps apps
COPY --chown=builder:builder scripts scripts
COPY --chown=builder:builder conf conf
COPY --chown=builder:builder .github .github

ENV COMMIT_SHA=${COMMIT_SHA}
ENV BUILD_BRANCH=${BUILD_BRANCH}
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}
ENV GOCACHE=/home/builder/.cache/go
ENV GOMODCACHE=/home/builder/go/pkg/mod

RUN --mount=type=cache,target=/home/builder/go/pkg/mod,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/builder/.cache/go,uid=1000,gid=1000 \
    make build-go GO_BUILD_TAGS=${GO_BUILD_TAGS} WIRE_TAGS=${WIRE_TAGS}

USER root
RUN mkdir -p data/plugins-bundled && chown -R builder:builder data
USER builder

# From-tarball build stage
FROM alpine-base AS tgz-builder

WORKDIR /tmp/grafana

ARG GRAFANA_TGZ="grafana-latest.linux-x64-musl.tar.gz"

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

# Add healthcheck for runtime monitoring
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD ["grafana", "healthcheck"] || exit 1

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
