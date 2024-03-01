.PHONY: all update clean

JQ ?= jq
CURL ?= curl

CURL_FLAGS := -fsS --compressed --create-dirs

BUILD_DIR := bin
SCHEMA_DIR := schemas
APIS_JSON := $(BUILD_DIR)/apis.json
APIS := apis.mk

JQ_PROG := '.items | (.[] | "$$(SCHEMA_DIR)/\(.name).json:\n\t$$(CURL) $$(CURL_FLAGS) -o $$@ '\''\(.discoveryRestUrl | gsub("\\$$"; "$$$$"))'\''"), ([.[].name] | join(" ") | "\(.): %: $$(SCHEMA_DIR)/%.json\nall .PHONY: \(.)")'

all:

update: $(APIS_JSON)
	$(JQ) --raw-output $(JQ_PROG) $^ > $(APIS)

clean:
	$(RM) -r $(SCHEMA_DIR) $(APIS_JSON)

$(APIS_JSON):
	$(CURL) $(CURL_FLAGS) -o $@ 'https://discovery.googleapis.com/discovery/v1/apis?preferred=true&prettyPrint=false'

include ./$(APIS)
