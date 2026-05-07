#!/usr/bin/make

IMG      ?= nullq-qns
TAG      ?= latest
LOCALTAG ?= local
REG      ?= ghcr.io/nullstyle
REPO     ?= $(REG)/$(IMG)

NULLQ_DIR         ?= ../nullq
RUNNER_DIR        ?= ../quic-interop-runner
CLIENTS           ?= quic-go,ngtcp2,quiche
SERVERS           ?= quic-go,ngtcp2,quiche
TESTS             ?= H,D
LOSS_TESTS        ?= loss
CLIENT_LOSS_TESTS ?= transferloss,blackhole
LOSS_SCENARIO     ?= drop-rate --delay=15ms --bandwidth=10Mbps --queue=25 --rate_to_server=2 --rate_to_client=2 --burst_to_server=3 --burst_to_client=3
SCENARIO_ARGS     = $(if $(SCENARIO),--scenario "$(SCENARIO)",)
LOCAL_CONTEXT     ?= .local-context

# Remote interop runner targets (a Digital Ocean droplet, etc.).
# REMOTE_HOST is the ssh destination — either an alias from ~/.ssh/config
# or `user@host`. Override for a different droplet:
#   make interop-remote-mainstream REMOTE_HOST=root@1.2.3.4
REMOTE_HOST       ?= root@nullq-interop
REMOTE_DIR        ?= /root/quic-interop-runner
REMOTE_PYTHON     ?= $(REMOTE_DIR)/.venv/bin/python3
MAINSTREAM_IMPLS  ?= quic-go,ngtcp2,quiche,picoquic,aioquic,msquic,neqo,quinn,s2n-quic,lsquic,xquic
FEATURE_CLIENTS   ?= quic-go,ngtcp2,quiche
FEATURE_TESTS     ?= handshake,transfer,chacha20,retry,resumption,zerortt,multiplexing,keyupdate,longrtt

default:
	@echo "Image build / publish:"
	@echo "    build build-local push push-amd64 all"
	@echo "Local interop (nullq-qns:local against sibling impls):"
	@echo "    interop interop-client interop-both interop-features"
	@echo "    interop-loss interop-loss-client interop-loss-both"
	@echo "    interop-lossy-scenario interop-lossy-scenario-client"
	@echo "Remote interop (runner on \$$REMOTE_HOST, default $(REMOTE_HOST)):"
	@echo "    interop-remote-pull interop-remote-mainstream"
	@echo "    interop-remote-features interop-remote-matrix"

build:
	docker build --pull -t $(IMG):$(TAG) -f Dockerfile .

prepare-local-context:
	rm -rf $(LOCAL_CONTEXT)
	mkdir -p $(LOCAL_CONTEXT)/nullq
	git -C $(NULLQ_DIR) archive --format=tar HEAD | tar -x -C $(LOCAL_CONTEXT)/nullq

build-local: prepare-local-context
	docker build --pull \
		--build-context nullq=$(LOCAL_CONTEXT)/nullq \
		-t $(IMG):$(LOCALTAG) \
		-f Dockerfile.local .

interop:
	cd $(NULLQ_DIR) && mise exec -- zig build external-interop -- runner \
		--role server \
		--runner-dir $(RUNNER_DIR) \
		--image $(IMG):$(LOCALTAG) \
		--clients $(CLIENTS) \
		--tests $(TESTS) \
		$(SCENARIO_ARGS)

interop-client:
	cd $(NULLQ_DIR) && mise exec -- zig build external-interop -- runner \
		--role client \
		--runner-dir $(RUNNER_DIR) \
		--image $(IMG):$(LOCALTAG) \
		--servers $(SERVERS) \
		--tests $(TESTS) \
		$(SCENARIO_ARGS)

interop-both: interop interop-client

interop-features:
	$(MAKE) interop CLIENTS=quic-go TESTS=H,D,C,S,R,Z,M

interop-loss:
	$(MAKE) interop CLIENTS=quic-go TESTS=$(LOSS_TESTS)

interop-loss-client:
	$(MAKE) interop-client SERVERS=quic-go TESTS=$(CLIENT_LOSS_TESTS)

interop-loss-both: interop-loss interop-loss-client

interop-lossy-scenario:
	$(MAKE) interop CLIENTS=quic-go TESTS=H,D,Z SCENARIO="$(LOSS_SCENARIO)"

interop-lossy-scenario-client:
	$(MAKE) interop-client SERVERS=quic-go TESTS=H,D,Z SCENARIO="$(LOSS_SCENARIO)"

push:
	docker tag $(IMG):$(TAG) $(REPO):$(TAG)
	docker push $(REPO):$(TAG)

# Build linux/amd64 directly to GHCR without staging a local image.
# Useful from arm64 hosts when CI is lagging the latest nullq commit.
# Requires `docker login ghcr.io` and a buildx builder.
push-amd64:
	docker buildx build --pull --push \
		--platform linux/amd64 \
		-t $(REPO):$(TAG) \
		-f Dockerfile .

clean-local-context:
	rm -rf $(LOCAL_CONTEXT)

# Refresh the published nullq-qns image on the droplet.
interop-remote-pull:
	ssh $(REMOTE_HOST) 'docker pull ghcr.io/nullstyle/nullq-qns:latest && \
		docker image inspect ghcr.io/nullstyle/nullq-qns:latest \
		    --format "pulled commit_id={{index .Config.Labels \"commit_id\"}}"'

# nullq vs the mainstream impl set, handshake + transfer (~10-15 min on c-8).
# Uses -i nullq so only pairs that include nullq run.
interop-remote-mainstream: interop-remote-pull
	ssh -t $(REMOTE_HOST) "cd $(REMOTE_DIR) && $(REMOTE_PYTHON) run.py -i nullq \
		-s $(MAINSTREAM_IMPLS) -c $(MAINSTREAM_IMPLS) -t handshake,transfer"

# Strongest feature signal: nullq vs the known-good clients, full feature
# gate (~5-10 min on c-8).
interop-remote-features: interop-remote-pull
	ssh -t $(REMOTE_HOST) "cd $(REMOTE_DIR) && $(REMOTE_PYTHON) run.py -s nullq \
		-c $(FEATURE_CLIENTS) -t $(FEATURE_TESTS)"

# Everything nullq is in, every test the runner knows about (~1.5-2.5 hr on
# c-8). Writes a JSON report and a stable log dir for post-processing.
interop-remote-matrix: interop-remote-pull
	ssh -t $(REMOTE_HOST) "cd $(REMOTE_DIR) && $(REMOTE_PYTHON) run.py -i nullq \
		-j /tmp/matrix.json -l logs/full-matrix"

all: build push

.PHONY: default build prepare-local-context build-local interop interop-client interop-both interop-features interop-loss interop-loss-client interop-loss-both interop-lossy-scenario interop-lossy-scenario-client push push-amd64 interop-remote-pull interop-remote-mainstream interop-remote-features interop-remote-matrix clean-local-context all
