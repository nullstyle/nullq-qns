#!/bin/bash
# Entrypoint for the QUIC interop runner.
#
# The runner sets ROLE=server|client and TESTCASE=<name>, plus a handful of
# scenario-specific env vars (REQUESTS, SERVER, SERVER_NAME). Unknown
# testcases must exit 127 so the harness records them as 'unsupported'.
# See https://github.com/marten-seemann/quic-interop-runner for the contract.

set -eu

# Set up the routing the network simulator expects.
/setup.sh

case "${TESTCASE:-}" in
    ""|handshake|transfer|longrtt|chacha20|multiplexing|retry|resumption|zerortt|keyupdate|blackhole|handshakeloss|transferloss|handshakecorruption|transfercorruption)
        # Supported (or no testcase pinned: use defaults).
        ;;
    versionnegotiation|http3|multiconnect|connectionmigration|amplificationlimit|crosstraffic|goodput|v2|ecn)
        echo "nullq-qns does not yet implement TESTCASE=${TESTCASE}" >&2
        exit 127
        ;;
    *)
        echo "nullq-qns does not recognise TESTCASE=${TESTCASE:-unset}" >&2
        exit 127
        ;;
esac

case "${ROLE:-server}" in
    server)
        echo ">>> nullq-qns server: TESTCASE=${TESTCASE:-default}"
        retry_arg=""
        if [ "${TESTCASE:-}" = "retry" ]; then
            retry_arg="-retry"
        fi
        set -- /qns-endpoint server \
            -listen 0.0.0.0:443 \
            -www /www \
            -cert /certs/cert.pem \
            -key /certs/priv.key
        if [ -n "${SSLKEYLOGFILE:-}" ]; then
            set -- "$@" -keylog-file "${SSLKEYLOGFILE}"
        fi
        if [ -n "${QLOGDIR:-}" ]; then
            set -- "$@" -qlog-dir "${QLOGDIR}"
        fi
        if [ -n "${retry_arg}" ]; then
            set -- "$@" "${retry_arg}"
        fi
        exec "$@"
        ;;
    client)
        echo ">>> nullq-qns client: TESTCASE=${TESTCASE:-default} REQUESTS=${REQUESTS:-}"
        server_arg="${SERVER:-}"
        if [ -z "${server_arg}" ] && [ -n "${REQUESTS:-}" ]; then
            first_request=${REQUESTS%% *}
            server_arg=${first_request#*://}
            server_arg=${server_arg%%/*}
        fi
        if [ -z "${server_arg}" ]; then
            server_arg="server4:443"
        fi
        server_name_arg="${SERVER_NAME:-}"
        if [ -z "${server_name_arg}" ]; then
            server_name_arg=${server_arg%%:*}
        fi
        set -- /qns-endpoint client \
            -server "${server_arg}" \
            -server-name "${server_name_arg}" \
            -downloads /downloads \
            -requests "${REQUESTS:-}" \
            -testcase "${TESTCASE:-}"
        if [ -n "${SSLKEYLOGFILE:-}" ]; then
            set -- "$@" -keylog-file "${SSLKEYLOGFILE}"
        fi
        if [ -n "${QLOGDIR:-}" ]; then
            set -- "$@" -qlog-dir "${QLOGDIR}"
        fi
        exec "$@"
        ;;
    *)
        echo "nullq-qns: unknown ROLE=${ROLE:-unset}" >&2
        exit 127
        ;;
esac
