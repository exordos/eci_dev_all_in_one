SHELL := bash
ifeq ($(SSH_KEY),)
	SSH_KEY = ~/.ssh/id_rsa.pub
endif

all: help

help:
	@echo "build_realm       - build exordos realm"

build_realm:
	INVENTORY="latest" exordos build -i $(SSH_KEY) -f
