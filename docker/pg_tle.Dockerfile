# The pinned postgres image plus pg_tle, for validating that the
# release artifacts install through the flagship channel
# (CREATE EXTENSION via pgtle.install_extension). Validation-only:
# nothing built here is published.
#
# BASE_IMAGE must match compose.yaml's pinned image; the workflow
# extracts it from there so the two cannot drift.
ARG BASE_IMAGE=postgres:18-alpine
FROM ${BASE_IMAGE}

# Pinned like every other reference: a bump is a deliberate change.
ARG PG_TLE_VERSION=v1.5.2

RUN apk add --no-cache --virtual .build \
       build-base git flex bison openssl-dev krb5-dev \
  && git clone --depth 1 --branch "${PG_TLE_VERSION}" \
       https://github.com/aws/pg_tle.git /tmp/pg_tle \
  && make -C /tmp/pg_tle install with_llvm=no \
  && rm -rf /tmp/pg_tle \
  && apk del .build
