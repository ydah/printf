RUBY ?= ruby
CLANG ?= clang
CLANG_FIXTURE_SOURCES := $(wildcard samples/clang/*.c)
CLANG_FIXTURES := $(CLANG_FIXTURE_SOURCES:.c=.ll)

.PHONY: test fixtures fixtures-check
test:
	$(RUBY) -Ilib:test test/all_test.rb

fixtures: $(CLANG_FIXTURES)

samples/clang/%.ll: samples/clang/%.c script/generate_clang_fixture.rb
	CLANG="$(CLANG)" $(RUBY) script/generate_clang_fixture.rb --opt=2 $< $@

fixtures-check:
	@if command -v "$(CLANG)" >/dev/null 2>&1; then \
		$(MAKE) fixtures CLANG="$(CLANG)" RUBY="$(RUBY)"; \
		for fixture in $(CLANG_FIXTURES); do \
			$(RUBY) -Ilib bin/pfc llvm-capabilities --check "$$fixture" >/dev/null || exit $$?; \
		done; \
	else \
		echo "skip fixtures-check: $(CLANG) not found"; \
	fi
