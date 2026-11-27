ifeq ($(strip $(MIX_APP_PATH)),)
$(error MIX_APP_PATH must name the Mix application build directory)
endif
ifneq ($(words $(MIX_APP_PATH)),1)
$(error MIX_APP_PATH cannot contain whitespace)
endif
ifneq ($(MIX_APP_PATH),$(strip $(MIX_APP_PATH)))
$(error MIX_APP_PATH cannot contain whitespace)
endif

BUILD = $(MIX_APP_PATH)/opus_build
LIB = $(BUILD)/install/lib/libopus.a
BIN = $(MIX_APP_PATH)/priv/opus_encoder
export MIX_APP_PATH MED_EX_OPUS_TARBALL XDG_CACHE_HOME CC CFLAGS CPPFLAGS LDFLAGS AR RANLIB
export MED_EX_OPUS_CONFIGURE_FLAGS
.DEFAULT_GOAL := all
.PHONY: all FORCE clean test-decoder
all: $(BIN)

# Validation is mandatory even when every output and success stamp exists.
$(LIB): FORCE
	@sh c_src/build_native.sh library

$(BIN): $(LIB) FORCE
	@sh c_src/build_native.sh encoder

test-decoder: $(LIB)
	$(CC) -std=c11 -I"$(BUILD)/install/include/opus" "$(DECODER_SRC)" "$(LIB)" -lm -o "$(DECODER)"

clean:
	@sh c_src/build_native.sh clean
FORCE:
