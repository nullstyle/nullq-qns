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

default:
	@echo "valid targets: build build-local interop interop-client interop-both interop-features interop-loss interop-loss-client interop-loss-both interop-lossy-scenario interop-lossy-scenario-client push push-amd64 all"

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

all: build push

.PHONY: default build prepare-local-context build-local interop interop-client interop-both interop-features interop-loss interop-loss-client interop-loss-both interop-lossy-scenario interop-lossy-scenario-client push push-amd64 clean-local-context all
