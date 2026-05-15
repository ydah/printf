RUBY ?= ruby
CLANG ?= clang
CLANG_FIXTURE_SOURCE := samples/clang/optimized_smoke.c
CLANG_FIXTURES := \
	samples/clang/optimized_smoke.ll \
	samples/clang/optimized_smoke_O0.ll \
	samples/clang/optimized_smoke_O1.ll \
	samples/clang/optimized_smoke_O2.ll \
	samples/clang/optimized_smoke_Oz.ll

.PHONY: test fixtures fixtures-check
test:
	$(RUBY) -Ilib:test test/all_test.rb

fixtures: $(CLANG_FIXTURES)

samples/clang/optimized_smoke.ll: $(CLANG_FIXTURE_SOURCE) script/generate_clang_fixture.rb
	CLANG="$(CLANG)" $(RUBY) script/generate_clang_fixture.rb --opt=2 $< $@

samples/clang/optimized_smoke_O%.ll: $(CLANG_FIXTURE_SOURCE) script/generate_clang_fixture.rb
	CLANG="$(CLANG)" $(RUBY) script/generate_clang_fixture.rb --opt=$* $< $@

fixtures-check:
	@if command -v "$(CLANG)" >/dev/null 2>&1; then \
		for spec in "2 samples/clang/optimized_smoke.ll" "0 samples/clang/optimized_smoke_O0.ll" "1 samples/clang/optimized_smoke_O1.ll" "2 samples/clang/optimized_smoke_O2.ll" "z samples/clang/optimized_smoke_Oz.ll"; do \
			opt="$${spec%% *}"; \
			fixture="$${spec#* }"; \
			CLANG="$(CLANG)" $(RUBY) script/generate_clang_fixture.rb --check --opt="$$opt" "$(CLANG_FIXTURE_SOURCE)" "$$fixture" || exit $$?; \
			$(RUBY) -Ilib bin/pfc llvm-capabilities --check "$$fixture" >/dev/null || exit $$?; \
		done; \
	else \
		echo "skip fixtures-check: $(CLANG) not found"; \
	fi
