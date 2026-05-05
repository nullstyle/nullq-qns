#!/usr/bin/make

IMG      ?= nullq-qns
TAG      ?= latest
LOCALTAG ?= local
REG      ?= ghcr.io/nullstyle
REPO     ?= $(REG)/$(IMG)

NULLQ_DIR         ?= ../nullq
BORINGSSL_ZIG_DIR ?= ../boringssl-zig
RUNNER_DIR        ?= ../quic-interop-runner
CLIENTS           ?= quic-go,ngtcp2,quiche
TESTS             ?= H,D
LOCAL_CONTEXT     ?= .local-context

default:
	@echo "valid targets: build build-local interop interop-features push all"

build:
	docker build --pull -t $(IMG):$(TAG) -f Dockerfile .

prepare-local-context:
	rm -rf $(LOCAL_CONTEXT)
	mkdir -p $(LOCAL_CONTEXT)/nullq $(LOCAL_CONTEXT)/boringssl-zig
	git -C $(NULLQ_DIR) archive --format=tar HEAD | tar -x -C $(LOCAL_CONTEXT)/nullq
	git -C $(BORINGSSL_ZIG_DIR) archive --format=tar HEAD | tar -x -C $(LOCAL_CONTEXT)/boringssl-zig

build-local: prepare-local-context
	docker build --pull \
		--build-context nullq=$(LOCAL_CONTEXT)/nullq \
		--build-context boringssl-zig=$(LOCAL_CONTEXT)/boringssl-zig \
		-t $(IMG):$(LOCALTAG) \
		-f Dockerfile.local .

interop:
	cd $(NULLQ_DIR) && mise exec -- zig build external-interop -- runner \
		--runner-dir $(RUNNER_DIR) \
		--image $(IMG):$(LOCALTAG) \
		--clients $(CLIENTS) \
		--tests $(TESTS)

interop-features:
	$(MAKE) interop CLIENTS=quic-go TESTS=H,D,C,S,R,Z,M

push:
	docker tag $(IMG):$(TAG) $(REPO):$(TAG)
	docker push $(REPO):$(TAG)

clean-local-context:
	rm -rf $(LOCAL_CONTEXT)

all: build push

.PHONY: default build prepare-local-context build-local interop interop-features push clean-local-context all
