ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
# we are intentionally pinning the ECS version here, when ecs releases a new version
# we'll discuss whether we need to release a new package and bump the version here
ECS_GIT_REF ?= v1.11.0

# This variable specifies to location of the package-storage repo. It is used for automatically creating a PR
# to release a new endpoint package. This can be overridden with the location on your file system using the config.mk
# file.
PACKAGE_STORAGE_REPO ?= $(ROOT_DIR)/../package-storage

# the config.mk file can be used to override variables in the Makefile
ifneq (,$(wildcard $(ROOT_DIR)/config.mk))
    $(info loading $(ROOT_DIR)/config.mk file)
    include $(ROOT_DIR)/config.mk
endif

# the ecs repo will be cloned in the out directory unless this is already set and exists at the specified path
ECS_DIR ?= $(ROOT_DIR)/out/ecs
REAL_ECS_DIR := $(abspath $(ECS_DIR))
ECS_TAG_REF := $(REAL_ECS_DIR)/.git/refs/tags/$(ECS_GIT_REF)
$(info ecs dir: $(REAL_ECS_DIR))
$(info ecs git ref: $(ECS_GIT_REF))


# Package directories
PKG_DIR = package/endpoint# final package definition that gets shipped in EPR
PKG_CTR_DIR = out/packages# used for running a local EPR container
SCHEMA_DIR = custom_schemas
SUBSET_DIR = custom_subsets/elastic_endpoint
EVENT_SCHEMA_GEN = scripts/event_schema_generator
VENV_DIR ?= venv# python virtual env dir, contains the installed pip packages
GO_TOOLS = $(ROOT_DIR)/scripts/go-tools/bin# where elastic-package gets installed
ESTC_PKG_BIN = $(GO_TOOLS)/elastic-package# the formatting, linting & promotion tool
DATA_STREAMS = $(notdir $(wildcard $(SUBSET_DIR)/*))# top-level name of each data_stream we ship
CUST_SCHEMAS = $(wildcard $(SCHEMA_DIR)/*)# each custom schema file

# Get the package version from the manifest file
PACKAGE_VERSION := $(shell awk '/^version: /{print $$2}' $(PKG_DIR)/manifest.yml)

# define some expected final file outputs
PKG_FIELDS_TARGETS = $(addsuffix /fields/fields.yml,$(addprefix $(PKG_DIR)/data_stream/,$(DATA_STREAMS)))
ECS_FLAT_TARGETS = $(addsuffix /ecs/ecs_flat.yml,$(addprefix generated/,$(DATA_STREAMS)))
ES_7_TARGETS = $(addsuffix /elasticsearch/7/template.json,$(addprefix generated/,$(DATA_STREAMS)))
MANIFESTS = $(addsuffix /manifest.yml,$(addprefix $(PKG_DIR)/data_stream/,$(DATA_STREAMS)))
SCHEMA_TARGETS = $(subst $(SUBSET_DIR),schemas/v1,$(wildcard $(SUBSET_DIR)/**/*))
DOC_TARGET = $(PKG_DIR)/docs/README.md

SED := sed

ifeq ($(shell uname -s), Darwin)
ifeq (, $(shell which gsed))
# add mac gsed install target
# mac's freebsd sed command doesn't accept the same parameters as linux
all: mac-deps
endif
SED := gsed
endif


all: $(VENV_DIR) $(ECS_TAG_REF) $(PKG_FIELDS_TARGETS) $(DOC_TARGET) $(ESTC_PKG_BIN) $(SCHEMA_TARGETS) $(ECS_FLAT_TARGETS) $(ES_7_TARGETS)
	cd $(PKG_DIR) && $(ESTC_PKG_BIN) format
	cd $(PKG_DIR) && $(ESTC_PKG_BIN) lint

mac-deps:
	@echo Installing gsed for mac
	brew install gnu-sed

clean:
	rm -rf $(ROOT_DIR)/out
	# this will be produced by running elastic-package check or build
	rm -rf $(ROOT_DIR)/build
	rm -rf generated
	rm -rf $(GO_TOOLS)
	rm -rf $(VENV_DIR)

# create package/endpoint/docs/README.md based on the template file, and the fields inputs
$(DOC_TARGET): doc_templates/endpoint/docs/* $(PKG_FIELDS_TARGETS) $(MANIFESTS)
	go run $(ROOT_DIR)/scripts/generate-docs

# how to generate the schema files
schemas/v1/%.yaml: $(SUBSET_DIR)/%.yaml $(CUST_SCHEMAS)
	mkdir -p schemas/v1/$(dir $*)
	. $(VENV_DIR)/bin/activate; cd $(EVENT_SCHEMA_GEN) && python main.py \
		--out-schema-dir $(ROOT_DIR)/schemas/v1/$(dir $*) \
		--ecs_git_ref $(ECS_GIT_REF) \
		$(REAL_ECS_DIR) \
		$(ROOT_DIR)/$(SCHEMA_DIR) \
		$(ROOT_DIR)/$(SUBSET_DIR)/$*.yaml \
		$(ROOT_DIR)/out/schema

# primary package build step. Runs the ECS generator to create the subsets from the schemas, etc into out/{stream-name}/*
out/%/generated/beats/fields.ecs.yml out/%/generated/elasticsearch/7/template.json out/%/generated/ecs/ecs_flat.yml: $(SUBSET_DIR)/%/*.yaml $(CUST_SCHEMAS)
	. $(VENV_DIR)/bin/activate; cd $(REAL_ECS_DIR) && python scripts/generator.py \
		--out $(ROOT_DIR)/out/$* \
		--include $(ROOT_DIR)/$(SCHEMA_DIR) \
		--ref $(ECS_GIT_REF) \
		--subset $(ROOT_DIR)/$(SUBSET_DIR)/$*/* 2>/dev/null
	# remove the first 8 lines
	$(SED) -i out/$*/generated/beats/fields.ecs.yml -e '1,8d'
	#unindent
	$(SED) -i out/$*/generated/beats/fields.ecs.yml -e 's/^  //g'



# copies some of the stuff generated from out/ into a saved place, for reference purposes
generated/%/beats/fields.ecs.yml: out/%/generated/beats/fields.ecs.yml
	mkdir -p generated/$*
	cp -r out/$*/generated/beats generated/$*
generated/%/elasticsearch/7/template.json: out/%/generated/elasticsearch/7/template.json
	mkdir -p generated/$*
	cp -r out/$*/generated/elasticsearch generated/$*
	$(RM) -r generated/$*/elasticsearch/6
	$(RM) -r generated/$*/elasticsearch/component
generated/%/ecs/ecs_flat.yml: out/%/generated/ecs/ecs_flat.yml
	mkdir -p generated/$*/ecs
	cp $< $@
	$(RM) generated/$*/ecs/ecs_nested.yml
	$(RM) -r generated/$*/ecs/subset

# copies the fields file into the actual package directory
$(PKG_DIR)/data_stream/%/fields/fields.yml: generated/%/beats/fields.ecs.yml
	cp generated/$*/beats/fields.ecs.yml $(PKG_DIR)/data_stream/$*/fields/fields.yml

# tags are omitted so they do not end up in .git/packed-refs. If we fetch separately, then they appear in .git/refs/tags/{}
$(REAL_ECS_DIR):
	git clone --no-tags https://github.com/elastic/ecs.git $@

# deleting the tag helps deal with mod time differences between ecs dir and the tag ref file
$(ECS_TAG_REF): $(REAL_ECS_DIR)
	rm -rf $@
	git -C $(REAL_ECS_DIR) pull -t origin master
	git -C $(REAL_ECS_DIR) checkout $(ECS_GIT_REF)

$(ESTC_PKG_BIN):
	GOBIN=$(GO_TOOLS) go install github.com/elastic/elastic-package

$(VENV_DIR): $(VENV_DIR)/touchfile

$(VENV_DIR)/touchfile: scripts/requirements.txt
	test -d $(VENV_DIR) || python3 -m venv $(VENV_DIR)
	. $(VENV_DIR)/bin/activate; pip install -r $<
	touch $@

check-docker:
	docker -v || { echo "please install docker before running the package registry"; exit 1; }
	docker-compose -v || { echo "please install docker-compose before running the package registry"; exit 1; }

out:
	mkdir -p $@

# This target removes the current staged package and uses the current changes in package/endpoint
# It handles parsing out the package version from the manifest.yml file
build-package: out
	rm -rf $(PKG_CTR_DIR)
	mkdir -p $(PKG_CTR_DIR)/endpoint/$(PACKAGE_VERSION)
	cp -r $(ROOT_DIR)/package/endpoint/* $(PKG_CTR_DIR)/endpoint/$(PACKAGE_VERSION)

# Use this target to run the package registry with your modifications to the endpoint package
run-registry: check-docker build-package
	docker-compose pull
	docker-compose up

# Use this target to run the linter on the current state of the package
lint: $(ESTC_PKG_BIN)
	cd $(ROOT_DIR)/package/endpoint && $(ESTC_PKG_BIN) lint

# Use this target to release the package (dev or prod) to the package storage repo
release: $(VENV_DIR)
	. $(VENV_DIR)/bin/activate; python $(ROOT_DIR)/scripts/release_manager/main.py $(PACKAGE_STORAGE_REPO) $(ROOT_DIR)/package

# Use this target to promote a package that exists in the package-storage repo from one environment to another
promote: $(ESTC_PKG_BIN)
	$(ESTC_PKG_BIN) promote

# Update elastic-package tooling
update-elastic-package:
	GO111MODULE=on go get -u github.com/elastic/elastic-package
	go mod tidy

# recipes / commands. Not necessarily targets to build
.PHONY: all update-elastic-package promote release lint run-registry clean mac-deps build-package check-docker
