# Chainguard bases only, pinned :latest@sha256 (CLAUDE.md invariant; Renovate owns the bumps, D-019).
# The runtime base (BASE_IMAGE) is what admission binds: reusable-build-sign verifies its Chainguard signature, and its
# digest becomes the base-image attestation (ADR-0005).
ARG BUILDER_IMAGE=cgr.dev/chainguard/go:latest-dev@sha256:2c32cf4edc1a6c4888501693c6e88e5e979c6137715368331d1a59a7b3a15733
ARG BASE_IMAGE=cgr.dev/chainguard/static:latest@sha256:8658e9eaeb2294fa0e49b0667f7d66b4e21fa7690b8d2a4c30cd1d013ceb9eb7

FROM ${BUILDER_IMAGE} AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/hello .

FROM ${BASE_IMAGE}
COPY --from=build /out/hello /hello
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/hello"]
