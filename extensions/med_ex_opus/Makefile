OPUS       = opus-1.5.2
VENDOR     = c_src/vendor
CACHE_DIR  = $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/med_ex_opus
TARBALL    = $(if $(MED_EX_OPUS_TARBALL),$(MED_EX_OPUS_TARBALL),$(CACHE_DIR)/$(OPUS).tar.gz)
URL_XIPH   = https://downloads.xiph.org/releases/opus/$(OPUS).tar.gz
URL_GH     = https://github.com/xiph/opus/releases/download/v1.5.2/$(OPUS).tar.gz
BUILD      = $(MIX_APP_PATH)/opus_build
LIB        = $(BUILD)/install/lib/libopus.a
BIN        = $(MIX_APP_PATH)/priv/opus_encoder

$(BIN): c_src/opus_encoder.c $(LIB)
	mkdir -p $(dir $@)
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
		-I$(BUILD)/install/include/opus -o $@ $< $(LIB) -lm

$(LIB): $(VENDOR)/SHA256SUMS
	@set -eu; \
	tarball="$(TARBALL)"; \
	if [ ! -f "$$tarball" ]; then \
		mkdir -p "$$(dirname "$$tarball")"; \
		tmp="$$tarball.tmp.$$$$"; \
		(curl -fsSL -o "$$tmp" "$(URL_XIPH)" || curl -fsSL -o "$$tmp" "$(URL_GH)") || { rm -f "$$tmp"; exit 1; }; \
		mv "$$tmp" "$$tarball"; \
	fi; \
	expected="$$(awk '{print $$1}' $(VENDOR)/SHA256SUMS)"; \
	actual="$$( (sha256sum "$$tarball" 2>/dev/null || shasum -a 256 "$$tarball") | awk '{print $$1}' )"; \
	if [ "$$actual" != "$$expected" ]; then \
		echo "SHA-256 mismatch for $$tarball: expected $$expected, got $$actual" >&2; \
		exit 1; \
	fi; \
	rm -rf $(BUILD) && mkdir -p $(BUILD)/src; \
	tar -xzf "$$tarball" -C $(BUILD)/src; \
	(cd $(BUILD)/src/$(OPUS) && ./configure --prefix=$(abspath $(BUILD))/install \
		--disable-shared --enable-static --with-pic --disable-doc --disable-extra-programs); \
	$(MAKE) -C $(BUILD)/src/$(OPUS) install

clean:
	rm -rf $(BUILD) $(BIN)

.PHONY: clean
