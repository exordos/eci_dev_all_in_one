SHELL := bash
ifeq ($(SSH_KEY),)
	SSH_KEY = ~/.ssh/id_rsa.pub
endif

all: help

help:
	@echo "build_realm       - build exordos realm"

build_realm:
	INVENTORY="0.2.27-dev+20260916060655.7bac8cd5" exordos build -i $(SSH_KEY) -f
