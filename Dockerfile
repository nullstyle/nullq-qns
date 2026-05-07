FROM martenseemann/quic-network-simulator-endpoint:latest AS build

ARG TARGETPLATFORM
ARG ZIG_VERSION=0.16.0
ARG NULLQ_REPO=https://github.com/nullstyle/nullq.git
ARG NULLQ_REF=main

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils git \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETPLATFORM:-linux/amd64}" in \
        "linux/arm64") zig_arch="aarch64-linux" ;; \
        *)             zig_arch="x86_64-linux" ;; \
    esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

# nullq pins boringssl-zig as a URL+hash dep, so it's fetched by Zig
# during build. Only nullq itself needs to be checked out here.
WORKDIR /src
RUN git clone "${NULLQ_REPO}" /src/nullq \
    && git -C /src/nullq checkout "${NULLQ_REF}"

# Build for the architecture's baseline CPU. Without this, Zig defaults
# to "native" (the build host's CPU), which makes BoringSSL's CRYPTO_is_*_capable
# helpers compile-time-shortcut to `return 1` whenever the build host advertises
# the feature (e.g. __SHA__, __AVX2__). The resulting binary then dispatches
# into hardware paths the deployment CPU may not support — SIGILL on the first
# sha256rnds2, vpshufb, etc. Baseline keeps the runtime CPUID checks honest.
WORKDIR /src/nullq
RUN zig build qns-endpoint -Doptimize=ReleaseSafe -Dcpu=baseline


FROM martenseemann/quic-network-simulator-endpoint:latest

WORKDIR /
COPY --from=build /src/nullq/zig-out/bin/qns-endpoint /qns-endpoint
COPY run_endpoint.sh /run_endpoint.sh
RUN chmod +x /run_endpoint.sh

EXPOSE 443/udp

ENTRYPOINT ["/run_endpoint.sh"]
