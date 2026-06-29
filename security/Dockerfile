# Reproducible runner for the DETERMINISTIC security-review gates.
#
# These three checks (differential fuzz, ASan/UBSan, ctgrind) verify data-flow
# facts, not wall-clock timing, so their results are platform-independent — a
# container reproduces the cloud review exactly. This is the recommended way to
# run them from macOS, where valgrind has no native support: a Linux container
# runs valgrind/ctgrind un-emulated.
#
#   IMPORTANT: do NOT use this for the statistical dudect timing pass (issue
#   #25). dudect measures cycle counts; virtualization invalidates the t-test.
#   That one needs quiet bare metal (see docs/timing-verification-runbook.md).
#
# On Apple Silicon, build/run NATIVELY (linux/arm64) so valgrind is not under
# qemu emulation (valgrind supports arm64 Linux, but not amd64-under-qemu):
#
#   # from the repo root:
#   docker build --platform linux/arm64 -f security/Dockerfile -t secp-review .
#   docker run --rm --platform linux/arm64 secp-review
#
# On an Intel host, omit --platform (linux/amd64 is native).
#
# NOTE: ubuntu:24.04 matches the toolchain the review ran on (gcc 13, clang 18,
# valgrind 3.22). This image was authored from commands verified directly on
# that toolchain; the image build itself was not exercised in the review
# environment (no Docker daemon there).

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang make valgrind python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY ext/ ext/
COPY timing/ timing/
COPY security/ security/

WORKDIR /src/security
CMD ["./run-checks.sh"]
