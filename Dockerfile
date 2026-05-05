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

WORKDIR /src/nullq
RUN zig build qns-endpoint -Doptimize=ReleaseSafe


FROM martenseemann/quic-network-simulator-endpoint:latest

WORKDIR /
COPY --from=build /src/nullq/zig-out/bin/qns-endpoint /qns-endpoint
COPY run_endpoint.sh /run_endpoint.sh
RUN chmod +x /run_endpoint.sh

EXPOSE 443/udp

ENTRYPOINT ["/run_endpoint.sh"]
